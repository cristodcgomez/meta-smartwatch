SUMMARY = "Dace flashable boot artifacts: boot.img, vendor_kernel_boot.img, init_boot.img"
DESCRIPTION = "\
Builds the three .img files dace's bootloader expects, end-to-end from \
bitbake-built inputs: \
\
 - boot.img            = our linux-dace kernel Image, empty ramdisk, \
                         mkbootimg header v4 \
 - vendor_kernel_boot  = ramdisk (kernel modules per dace-vkb-modules.lst, \
                         KMI-CRC-gated against this kernel) + DTB with \
                         ramoops node injected, mkbootimg header v4 \
 - init_boot.img       = initramfs-android-image's cpio.gz, repacked as \
                         lz4, mkbootimg header v4 \
\
The base DTB is shipped as a static input (vkb-base.dtb) -- the kernel \
doesn't build dtbs from gki_defconfig, and dace's runtime DT is the \
bootloader-assembled one anyway."

LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

# Los DTBs vienen de ota-stock/blobs: monaco-real.dtb + monacop.dtb son los
# que el ABL del T5 espera (board-id T5). vkb-base.dtb (aurora) fue rechazado
# por el ABL (EDL 05c6:900e). monaco-real ya trae ramoops@9ff00000 y splash.
SRC_URI = "\
    file://dace-vkb-assemble.py \
    file://dace-vkb-modules.lst \
    file://static/modules.alias \
    file://static/modules.softdep \
    file://static/modules.load.charger \
    file://static/modules.dep \
    file://static/bootconfig \
    file://static/monaco-real.dtb \
    file://static/monacop.dtb \
    file://static/monaco-idp-v1-overlay.dtbo \
    file://static/stock/qti-qbg-main.ko \
"
S = "${UNPACKDIR}"

COMPATIBLE_MACHINE = "dace"

# DEPENDS:
#  - virtual/kernel: provides Image + Module.symvers + kernel-built .ko's
#                    (we read them out of the linux-dace workdir).
#  - linux-dace-modules: techpack .ko's; we read its deploy ipk.
#  - initramfs-android-image: init_boot.img ramdisk content (cpio.gz).
#  - mkbootimg-tools-native: provides ${STAGING_BINDIR_NATIVE}/mkbootimg
#  - dtc-native: provides ${STAGING_BINDIR_NATIVE}/fdtput
DEPENDS = "\
    virtual/kernel \
    linux-dace-modules \
    initramfs-android-image \
    mkbootimg-tools-native \
    dtc-native \
    clang-native \
"
do_compile[depends] += "\
    virtual/kernel:do_compile \
    virtual/kernel:do_install \
    linux-dace-modules:do_package_write_ipk \
    initramfs-android-image:do_image_complete \
"

PACKAGES = ""
inherit deploy nopackages

# ─── Kernel artifact paths ───
# linux-dace builds out-of-tree: source in STAGING_KERNEL_DIR,
# .config/Image/Module.symvers in STAGING_KERNEL_BUILDDIR. .ko's install into
# the recipe's package/ via kernel.bbclass.
# layer.conf appends ${LAYERDIR} to BBPATH, so this layer-root-relative
# require resolves from any recipe in meta-dace.
require recipes-kernel/linux/linux-dace-version.inc
KMODVER ?= "${DACE_KERNEL_VERSION}"
# KREL del kernel: DACE_KERNEL_VERSION + EXTRAVERSION del vendorkernel
# (5.15.144 + -g7f9d6c16b5cd-ab151). La carpeta /lib/modules/<KREL> del
# workdir del kernel usa este nombre, no el DACE_KERNEL_VERSION pelado.
DACE_KREL ?= "${DACE_KERNEL_VERSION}-g7f9d6c16b5cd-ab151"
# linux-dace's workdir uses ${MACHINE}${TARGET_VENDOR}-${TARGET_OS}
# (= dace-oe-linux-gnueabi). do_install drops .ko's into package/.
LINUX_DACE_WORKDIR ?= "${TMPDIR}/work/${MACHINE}${TARGET_VENDOR}-${TARGET_OS}/linux-dace/${KMODVER}+git"
LINUX_DACE_PKGDIR  ?= "${LINUX_DACE_WORKDIR}/package/usr/lib/modules/${DACE_KREL}/kernel"
# linux-dace keeps its build artifacts in its own workdir's build/
# (out-of-tree B != S). STAGING_KERNEL_BUILDDIR is empty because we don't go
# through the standard kernel.bbclass staging for these.
LINUX_DACE_KIMG    ?= "${LINUX_DACE_WORKDIR}/build/arch/arm64/boot/Image"
LINUX_DACE_SYMVERS ?= "${LINUX_DACE_WORKDIR}/build/Module.symvers"

# Techpack ipk path. armv7vehf-neon is dace's userspace PKGARCH.
LINUX_DACE_MODULES_IPK ?= "${DEPLOY_DIR_IPK}/armv7vehf-neon/linux-dace-modules_${KMODVER}-r0_armv7vehf-neon.ipk"

# ─── mkbootimg v4 geometry ───
# BASE 0: el ABL del T5 espera load addresses ABSOLUTAS pequeñas
# (kernel_load_addr=0x8000, ramdisk=0x1000000, dtb=0x1f00000, tags=0x100),
# NO base+offset (0x10000000+0x8000=0x10008000). Con base!=0 el vendor_boot
# es rechazado -> EDL 05c6:900e directo. Igual que los lotes ticwatch que
# arrancaban (AGENTS.md: "base 0, NO 0x10000000").
MKBOOTIMG_BASE          ?= "0x0"
MKBOOTIMG_KERNEL_OFFSET ?= "0x00008000"
MKBOOTIMG_RAMDISK_OFFSET ?= "0x01000000"
MKBOOTIMG_TAGS_OFFSET   ?= "0x00000100"
MKBOOTIMG_DTB_OFFSET    ?= "0x01f00000"
MKBOOTIMG_PAGESIZE      ?= "4096"

# ─── Hard ceilings -- match flash-slotB sanity check + deviceinfo. ───
BOOT_IMG_CAP                   ?= "67108864"
VENDOR_KERNEL_BOOT_IMG_CAP     ?= "67108864"
INIT_BOOT_IMG_CAP              ?= "8388608"

# ─── Ramoops region (matches stock dtbo) ───
RAMOOPS_BASE      ?= "0x61f00000"
RAMOOPS_SIZE      ?= "0x400000"
RAMOOPS_RECORD    ?= "0x40000"
RAMOOPS_CONSOLE   ?= "0x200000"
RAMOOPS_PMSG      ?= "0x100000"

do_compile() {
    set -e

    # ─── Step 1: extract techpack ipk so dace-vkb-assemble.py can find .ko's ───
    if [ ! -f "${LINUX_DACE_MODULES_IPK}" ]; then
        bbfatal "linux-dace-modules ipk not at ${LINUX_DACE_MODULES_IPK} -- check linux-dace-modules:do_deploy"
    fi
    rm -rf ${WORKDIR}/tpmod
    mkdir -p ${WORKDIR}/tpmod
    ( cd ${WORKDIR}/tpmod && ar x "${LINUX_DACE_MODULES_IPK}" && tar -xf data.tar.* )

    # ─── Step 2: assemble ramdisk dir via the python helper ───
    if [ ! -d "${LINUX_DACE_PKGDIR}" ]; then
        bbfatal "linux-dace kernel modules not at ${LINUX_DACE_PKGDIR} -- check virtual/kernel build"
    fi
    if [ ! -f "${LINUX_DACE_SYMVERS}" ]; then
        bbfatal "Module.symvers not at ${LINUX_DACE_SYMVERS}"
    fi
    rm -rf ${WORKDIR}/vkb_ramdisk
    python3 ${S}/dace-vkb-assemble.py \
        --manifest      ${S}/dace-vkb-modules.lst \
        --kernel-pkgdir "${LINUX_DACE_PKGDIR}" \
        --techpack-dir  ${WORKDIR}/tpmod \
        --stock-dir     ${S}/static/stock \
        --symvers       "${LINUX_DACE_SYMVERS}" \
        --static-dir    ${S}/static \
        --out           ${WORKDIR}/vkb_ramdisk

    # ─── Step 2.5: strip debug info from aarch64 kernel modules ───
    # This recipe runs in an armv7 context but the vendor kernel modules
    # are aarch64 ELF. The default strip tool silently does nothing on a
    # foreign ELF target, leaving full debug info in every .ko file.
    # llvm-strip from clang-native is architecture-agnostic and correctly
    # strips aarch64 ELF from any build context.
    LLVM_STRIP=$(find ${STAGING_BINDIR_NATIVE} -name "llvm-strip" | head -1)
    if [ -z "$LLVM_STRIP" ]; then
        bbfatal "llvm-strip not found in ${STAGING_BINDIR_NATIVE} -- check clang-native is in DEPENDS"
    fi
    find ${WORKDIR}/vkb_ramdisk -name "*.ko" -exec "$LLVM_STRIP" --strip-debug {} \;
    bbnote "stripped debug info from aarch64 kernel modules"

    # ─── Step 3: DTB blob T5 = 2 DTBs CONCATENADOS (monaco-real + monacop). ───
    # El ABL selecciona el DTB por msm-id/board-id del hardware: monaco-real
    # (qcom,monaco, msm-id 486) + monacop (qcom,monacop, msm-id 517). Sin el
    # que coincide (monacop) cae a EDL 05c6:900e (confirmado 22-08-2026 en la
    # receta ticwatch). vkb-base.dtb (aurora) ya no se usa.
    # monaco-real ya trae ramoops@9ff00000 y splash_region — no inyectar.
    # VIA1 V67-fix: forzar dr_mode=peripheral en el hijo dwc3@4e00000. Con
    # "otg" el core espera la decisión de rol del glue (extcon/io-channels del
    # charger); sin charger/EUD no hay cable → el dwc3 nunca sale al bus y el
    # host no enumera (f_fs lee descriptores pero no hay señal USB física).
    # peripheral = gadget directo, sin esperar extcon → la UDC sale al bus.
    FDTPUT=$(find ${STAGING_BINDIR_NATIVE} -name fdtput 2>/dev/null | head -1)
    [ -n "$FDTPUT" ] || FDTPUT=$(command -v fdtput)
    test -n "$FDTPUT" || bbfatal "fdtput no encontrado (dtc-native)"
    FDTGET=$(find ${STAGING_BINDIR_NATIVE} -name fdtget 2>/dev/null | head -1)
    [ -n "$FDTGET" ] || FDTGET=$(command -v fdtget)
    test -n "$FDTGET" || bbfatal "fdtget no encontrado (dtc-native)"
    FDTOVERLAY="${STAGING_BINDIR_NATIVE}/fdtoverlay"
    test -n "$FDTOVERLAY" || bbfatal "fdtoverlay no encontrado (dtc-native)"
    for dtb in monaco-real monacop; do
        cp ${S}/static/${dtb}.dtb ${WORKDIR}/${dtb}-per.dtb
        # ruta del hijo dwc3: /soc/hsusb@4e00000/dwc3@4e00000 (del dts)
        "$FDTPUT" -t s ${WORKDIR}/${dtb}-per.dtb \
            /soc/hsusb@4e00000/dwc3@4e00000 dr_mode peripheral
        # VIA1: activar el eMMC (sdhc_1). En el stock DT viene disabled — Wear
        # OS lo activa via dtbo overlay del board; nuestro boot no aplica esos
        # overlays. Activa + supplies (phandles ya verificados: L25A=0x132,
        # L15A=0x182 en AMBOS dtbs). Supplies = pm5100_l25 (3.08V, del idp dtsi)
        # y pm5100_l15 (1.8V io). Sin esto sdhci queda deferred sin mmcblk0*.
        "$FDTPUT" -t s ${WORKDIR}/${dtb}-per.dtb /soc/sdhci@4744000 status ok
        "$FDTPUT" -t x ${WORKDIR}/${dtb}-per.dtb /soc/sdhci@4744000 vdd-supply 0x132
        "$FDTPUT" -t x ${WORKDIR}/${dtb}-per.dtb /soc/sdhci@4744000 vdd-io-supply 0x182
        # VIA1b: sin OPP table para el sdhci — la OPP requiere paths ICC
        # (required-opps) y sin qnoc los paths quedan vacíos -> _opp_add_static_v2
        # falla (-22 'opp key field not found') y el probe aborta. Sin OPP el
        # sdhci corre con los clocks fijos del ABL (devfreq opcional).
        "$FDTPUT" -d ${WORKDIR}/${dtb}-per.dtb /soc/sdhci@4744000 operating-points-v2
        # TACTIL: el nodo del T5 se llama "zinitix_ts@20" con
        # compatible = "zinitix,zinitix-ts", pero el driver del kernel
        # (drivers/input/touchscreen/zinitix.c) solo acepta "zinitix,bt541"
        # -> el driver no se enlazaba y NO existia /dev/input/eventX de tactil
        # (el compositor arrancaba con evdevtouch:/dev/input/event2, que no
        # existe; el unico input eran gpio-keys y qpnp_pon).
        # El nodo declara zinitix,pname="SM-G5308W" con x/y_resolution=0x1d1
        # (465, la del panel), o sea que es un BT541 rebautizado: se anade el
        # compatible que espera el driver DEJANDO tambien el original.
        "$FDTPUT" -t s ${WORKDIR}/${dtb}-per.dtb \
            /soc/qcom,qupv3_0_geni_se@4ac0000/i2c@4a84000/zinitix_ts@20 \
            compatible "zinitix,zinitix-ts" "zinitix,bt541"
        # REGULADORES DEL TACTIL. El nodo del T5 declara tres rieles del PMIC
        # (vdd=0x84, vdd-v1=0x83, vcc_i2c=0x85) y el driver del vendor los
        # enciende los tres. El mainline solo pedia "vdd"+"vddo" (bulk get, que
        # FALLA si falta una propiedad) y con solo esos dos el chip NO contesta
        # a su direccion i2c:
        #   zinitix_start: "Error while sending power-on sequence: -107"
        #   (-107 = -ENOTCONN = I2C_ADDR_NACK, en drivers/i2c/busses/i2c-msm-geni.c)
        # El "vddo" del Zinitix es su rail de I/O, que aqui es "vcc_i2c" (0x85):
        # se crea la propiedad vddo-supply apuntando ahi. Y el driver va
        # parcheado para pedir tambien "vdd-v1" (0x83), de forma que quedan
        # encendidos los TRES rieles.
        "$FDTPUT" -t x ${WORKDIR}/${dtb}-per.dtb \
            /soc/qcom,qupv3_0_geni_se@4ac0000/i2c@4a84000/zinitix_ts@20 \
            vddo-supply 0x85
        # zinitix_init_input_dev() llama a touchscreen_parse_properties(), que
        # exige las props ESTANDAR touchscreen-size-x/y; el DT del T5 solo trae
        # las del vendor (zinitix,x_resolution/y_resolution = 0x1d1 = 465, que es
        # justo la resolucion del panel). Sin esto:
        #   "Touchscreen-size-x and/or touchscreen-size-y not set in dts"
        #   probe failed with error -22
        "$FDTPUT" -t x ${WORKDIR}/${dtb}-per.dtb \
            /soc/qcom,qupv3_0_geni_se@4ac0000/i2c@4a84000/zinitix_ts@20 \
            touchscreen-size-x 0x1d1
        "$FDTPUT" -t x ${WORKDIR}/${dtb}-per.dtb \
            /soc/qcom,qupv3_0_geni_se@4ac0000/i2c@4a84000/zinitix_ts@20 \
            touchscreen-size-y 0x1d1
        # reset-gpios (propiedad ESTANDAR): el DT del T5 solo trae la del vendor
        # (zinitix,reset-gpio = <0x69 0x0c 0x00> = gpio 12 del TLMM). El driver
        # parcheado la pide con devm_gpiod_get_optional(..., "reset", ...) y
        # pulsa el reset al arrancar el chip (sin eso respondia por i2c pero no
        # reportaba toques). Flag 1 = GPIO_ACTIVE_LOW (lo normal en un reset).
        "$FDTPUT" -t x ${WORKDIR}/${dtb}-per.dtb \
            /soc/qcom,qupv3_0_geni_se@4ac0000/i2c@4a84000/zinitix_ts@20 \
            reset-gpios 0x69 0x0c 0x1
        # ── OVERLAY DE NUESTRA VARIANTE (Monaco IDP V1.0, board 0x10022) ────
        # Cada variante del SoC tiene su overlay en el dtbo (WDP -> Raydium,
        # IDP -> Zinitix...). El ABL los aplica por board-id, pero el del
        # reloj (0x10022) NO se aplica (se comprobo en vivo: el nodo del
        # tactil no recibe la propiedad 'panel' que anade el overlay). Aqui se
        # aplica a mano con fdtoverlay: el de IDP V1.0 anade al zinitix_ts@20
        # el enlace con el panel (panel = <&dsi_rm69090_amoled_cmd>), que es
        # lo que el driver del vendor usa para encender el chip.
        if [ -f ${S}/static/monaco-idp-v1-overlay.dtbo ]; then
            ${FDTOVERLAY} -i ${WORKDIR}/${dtb}-per.dtb \
                -o ${WORKDIR}/${dtb}-ovl.dtb \
                ${S}/static/monaco-idp-v1-overlay.dtbo \
                && mv ${WORKDIR}/${dtb}-ovl.dtb ${WORKDIR}/${dtb}-per.dtb \
                && bbnote "$dtb: overlay Monaco IDP V1.0 (board 0x10022) aplicado"
        else
            bbwarn "$dtb: falta monaco-idp-v1-overlay.dtbo"
        fi
        # ── BT/WCN3988: rieles del btpower ───────────────────────
        # El DTB stock trae el nodo pelado (solo compatible). Los rieles
        # reales estan en el source stock monaco-standalone-idp-v1.dtsi:
        # IO=L17A (0x184), core/RFA=L13A (0x181), PA/CH0=L26A (0x84),
        # XO=L14A (0x131). Todos RPM regulators (rpm_smd_regulator).
        # OJO ORDEN del compatible: __of_device_is_compatible() puntua mas alto
        # el compatible que va PRIMERO (score = INT_MAX/2 - index<<2). Con
        # "qcom,qcc5100" primero, btpower usaba la tabla qcc5100 (SOLO pa) y
        # dejaba io/core APAGADOS (chip mudo). Poniendo "qcom,wcn3990" primero
        # usa la tabla wcn399x (io/core/pa/xtal).
        "$FDTPUT" -t s ${WORKDIR}/${dtb}-per.dtb /soc/bt_wcn3990 \
            compatible "qcom,wcn3990" "qcom,qcc5100"
        "$FDTPUT" -t x ${WORKDIR}/${dtb}-per.dtb /soc/bt_wcn3990 \
            qcom,bt-vdd-io-supply 0x184
        "$FDTPUT" -t x ${WORKDIR}/${dtb}-per.dtb /soc/bt_wcn3990 \
            qcom,bt-vdd-core-supply 0x181
        "$FDTPUT" -t x ${WORKDIR}/${dtb}-per.dtb /soc/bt_wcn3990 \
            qcom,bt-vdd-pa-supply 0x84
        "$FDTPUT" -t x ${WORKDIR}/${dtb}-per.dtb /soc/bt_wcn3990 \
            qcom,bt-vdd-xtal-supply 0x131
        # ─ BT reset/enable: qcom,bt-sw-ctrl-gpio ────────────────────────────
        # El stock lo trae pero COMENTADO (monaco-standalone-idp-v1.dtsi:
        # //qcom,bt-sw-ctrl-gpio = <&tlmm 69 GPIO_ACTIVE_HIGH>). El HAL pide
        # BT_CMD_CHECK_SW_CTRL y btpower no tiene el gpio -> EINVAL
        # ('CheckSwCtrl: ioctl failed'). Se a~nade como en el resto de targets
        # Qualcomm (tlmm 69 high). El phandle del controlador se lee del propio
        # dtb (aqui es 0x69, no se hardcodea).
        TLMM=$("$FDTGET" -t x ${WORKDIR}/${dtb}-per.dtb /soc/pinctrl@500000 phandle)
        "$FDTPUT" -t x ${WORKDIR}/${dtb}-per.dtb /soc/bt_wcn3990 \
            qcom,bt-sw-ctrl-gpio "$TLMM" 69 0
        bbnote "$dtb: bt-sw-ctrl-gpio = <&tlmm 69 0> (tlmm phandle=$TLMM)"
        # ── BT UART pinctrl: parche en el DRIVER (no hog en el DT) ──────────
        # El nodo UART se deja EXACTAMENTE como el stock/aurora. Comprobado
        # 19-09-2026: (a) los grupos qupv3_se5_* son identicos a aurora y la
        # asignacion pinctrl-N tambien; (b) el hack 23259b2d (default/sleep =
        # qup05) NO muxea (los pines 26-29 siguen en function=gpio durante todo
        # el intento del HAL); (c) un HOG en /soc/pinctrl@500000 SI muxea a
        # qup05 pero RECLAMA los pines y rompe el probe del UART (msm_geni_serial
        # carga con 0 puertos: no aparece /dev/ttyHS*).
        # La solucion es forzar el mux desde el propio driver en
        # msm_geni_serial_probe() -> dace-hs-uart-pinctrl.patch (en linux-dace).
        bbnote "$dtb: BT UART pinctrl lo fuerza el driver (dace-hs-uart-pinctrl.patch)"
        # ── /cont-splash-fb → /dev/fb0 sobre el continuous-splash ──────────
        # AURORA-STYLE (Step 3b de aurora-boot-images.bb): el bootloader pinta
        # el logo en splash_region@0x5c000000 (label cont_splash_region) y el
        # SDE sigue escaneando ESA region hasta que el composer arranca. El
        # driver qcom-cont-splash-fb (CONFIG_FB_QCOM_CONT_SPLASH=y, ya en
        # nuestro kernel con 0001-video-fbdev-...) la expone como /dev/fb0,
        # pero SOLO si el nodo DT existe: aurora lo inyecta en su boot-images y
        # nosotros no lo teniamos.
        # Doble uso: (a) telemetria del bring-up (el panel conserva el ultimo
        # color pintado tras un cuelgue = unico canal cuando no hay USB), y
        # (b) splash de usuario (psplash) si algun dia hace falta.
        # Panel = 466x466 (rm69090-amoled-178-cmd), xRGB8888, stride 466*4.
        S_NODE=/cont-splash-fb
        "$FDTPUT" -c ${WORKDIR}/${dtb}-per.dtb "$S_NODE"
        "$FDTPUT" -t s ${WORKDIR}/${dtb}-per.dtb "$S_NODE" compatible "qcom,cont-splash-fb"
        "$FDTPUT" -t x ${WORKDIR}/${dtb}-per.dtb "$S_NODE" reg 0 0x5c000000 0 0x100000
        "$FDTPUT" -t u ${WORKDIR}/${dtb}-per.dtb "$S_NODE" width 466
        "$FDTPUT" -t u ${WORKDIR}/${dtb}-per.dtb "$S_NODE" height 466
        "$FDTPUT" -t u ${WORKDIR}/${dtb}-per.dtb "$S_NODE" stride 1864
        "$FDTPUT" -t s ${WORKDIR}/${dtb}-per.dtb "$S_NODE" format "x8r8g8b8"
        bbnote "$dtb: nodo /cont-splash-fb inyectado (fb0 = splash 0x5c000000, 466x466)"
        bbnote "$dtb: dr_mode=peripheral + sdhc_1 ok (vdd=l25/l15, sin OPP) + RAYDIUM rm32380 @0x39 (i2c-1) + zinitix disabled + BT rieles"
    done
    cat ${WORKDIR}/monaco-real-per.dtb ${WORKDIR}/monacop-per.dtb > ${WORKDIR}/dtb-blob-vendor.bin
    bbnote "DTB blob vendor_boot: $(stat -c%s ${WORKDIR}/dtb-blob-vendor.bin) bytes (stock=572016)"

    # ─── Step 4: cpio + gzip del ramdisk ───
    # dace-vkb-assemble.py ya dejó vkb_ramdisk/lib/modules/*.ko planos +
    # modules.dep (rutas absolutas) + modules.load(.recovery). Solo empaquetar
    # en cpio+gzip (formato del vendor_boot stock T5: gzip -> cpio-newc). ───
    ( cd ${WORKDIR}/vkb_ramdisk && find . | sort | \
        cpio -o -H newc --owner root:root 2>/dev/null ) > ${WORKDIR}/vkb_rd.cpio
    gzip -9 -c ${WORKDIR}/vkb_rd.cpio > ${WORKDIR}/vkb_rd.gz

    MKBOOTIMG=${STAGING_BINDIR_NATIVE}/mkbootimg

    # ─── Step 5: mkbootimg vendor_kernel_boot.img (v4) ───
    # Replica la receta ticwatch (que arranca): --base 0, cmdline stock
    # completa (con bootconfig Y fw_devlink), --vendor_bootconfig por archivo,
    # (debug-ramdisk quitado: el init.sh dace lo soporta, pero el lote normal
    #  debe hacer switch_root; para depurar usar /sdcard/debug-ramfs o el lote dbg)
    # a switch_root, que falla sin rootfs en el T5 -> EDL tras ~15s).
    #
    # OJO: 'dace.debug=1' al final del --vendor_cmdline es FASE DE BRING-UP.
    # Activa el modo de depuracion del init.sh (/sdcard/dace-mode, AGENTS §12):
    # SIN ese fichero el arranque por defecto es el RAMFS con adb (modo SEGURO)
    # y NO el rootfs. Para un arranque "de produccion" (que el reloj levante el
    # rootfs solo) hay que QUITARLO de aqui. Tiene que ir en el vendor_cmdline:
    # se probo en el bootconfig del vendor_boot y NO llega a /proc/cmdline.
    # blob de 2 DTBs. Sin el monacop el ABL cae a EDL.
    #
    # NI deferred_probe_timeout NI arm_smmu.disable_bypass (=0): los dos se
    # probaron el 20-09-2026 y los dos estan descartados con datos:
    #
    #  * deferred_probe_timeout=30: retrasa TODAS las dependencias -> la cadena
    #    USB se queda sin UDC y setup_usb_console() no encuentra /sys/class/udc
    #    -> SIN consola ni adb (parecia un cuelgue; el arranque seguia).
    #  * arm_smmu.disable_bypass=0: la telemetria del SMMU demostro que el bit
    #    sCR0.USFCFG esta BLOQUEADO POR TZ (want=0x00e01836 -> read=0x00e01c06
    #    conserva 0x400) -> no se puede quitar; los streams no identificados
    #    (0xe3 QUP, 0xf6 GPI) se ABORTAN siempre.
    # El arreglo bueno es el parche del kernel dace-iommu-defer.patch: los
    # consumers del IOMMU devuelven -EPROBE_DEFER (en vez del -ETIMEDOUT de
    # driver_deferred_probe_check_state) y asi esperan al apps-smmu y reciben
    # su dominio (como display/kgsl/USB, que si funcionan).
    "${MKBOOTIMG}" \
        --header_version 4 --pagesize ${MKBOOTIMG_PAGESIZE} \
        --vendor_boot ${WORKDIR}/vendor_kernel_boot.img \
        --vendor_ramdisk ${WORKDIR}/vkb_rd.gz \
        --vendor_bootconfig ${S}/static/bootconfig \
        --dtb ${WORKDIR}/dtb-blob-vendor.bin \
        --base ${MKBOOTIMG_BASE} \
        --kernel_offset ${MKBOOTIMG_KERNEL_OFFSET} \
        --ramdisk_offset ${MKBOOTIMG_RAMDISK_OFFSET} \
        --tags_offset ${MKBOOTIMG_TAGS_OFFSET} \
        --dtb_offset ${MKBOOTIMG_DTB_OFFSET} \
        --vendor_cmdline 'lpm_levels.sleep_disabled=1 video=vfb:640x400,bpp=32,memsize=3072000 msm_rtb.filter=0x237 service_locator.enable=1 swiotlb=noforce kpti=off cgroup.memory=nokmem,nosocket loop.max_part=7 bootconfig qcom_geni_serial.con_enabled=0 androidboot.hardware=dace bootconfig buildvariant=user fw_devlink=permissive dace.debug=1'

    # ─── Step 6: mkbootimg boot.img (v4): our kernel + empty ramdisk ───
    if [ ! -f "${LINUX_DACE_KIMG}" ]; then
        bbfatal "Kernel Image not at ${LINUX_DACE_KIMG}"
    fi
    : > ${WORKDIR}/empty_kernel
    : > ${WORKDIR}/empty_ramdisk
    "${MKBOOTIMG}" \
        --header_version 4 \
        --kernel "${LINUX_DACE_KIMG}" \
        --ramdisk ${WORKDIR}/empty_ramdisk \
        --cmdline '' \
        -o ${WORKDIR}/boot.img

    # ─── Step 7: mkbootimg init_boot.img (v4): asteroid initramfs as lz4 ───
    CPIO_GZ=$(ls -t ${DEPLOY_DIR_IMAGE}/initramfs-android-image-${MACHINE}-*.cpio.gz 2>/dev/null | grep -v debug | head -1)
    if [ -z "$CPIO_GZ" ] || [ ! -f "$CPIO_GZ" ]; then
        CPIO_GZ=${DEPLOY_DIR_IMAGE}/initramfs-android-image-${MACHINE}.cpio.gz
    fi
    if [ ! -f "$CPIO_GZ" ]; then
        bbfatal "initramfs-android-image cpio.gz not found in ${DEPLOY_DIR_IMAGE}"
    fi
    gunzip -c "$CPIO_GZ" | lz4 -l -9 > ${WORKDIR}/init_boot_rd.lz4
    "${MKBOOTIMG}" \
        --header_version 4 \
        --kernel ${WORKDIR}/empty_kernel \
        --ramdisk ${WORKDIR}/init_boot_rd.lz4 \
        --cmdline '' \
        -o ${WORKDIR}/init_boot.img

    # ─── Step 8: size-cap sanity check ───
    check_cap() {
        local f=$1 cap=$2
        local sz=$(stat -c%s "$f")
        if [ "$sz" -gt "$cap" ]; then
            bbfatal "$(basename $f) is ${sz}B > cap ${cap}B"
        fi
        bbnote "$(basename $f): ${sz}B (cap ${cap}B) OK"
    }
    check_cap ${WORKDIR}/boot.img                ${BOOT_IMG_CAP}
    check_cap ${WORKDIR}/vendor_kernel_boot.img  ${VENDOR_KERNEL_BOOT_IMG_CAP}
    check_cap ${WORKDIR}/init_boot.img           ${INIT_BOOT_IMG_CAP}
}

do_deploy() {
    install -d ${DEPLOYDIR}
    for f in boot.img vendor_kernel_boot.img init_boot.img; do
        install -m 0644 ${WORKDIR}/$f ${DEPLOYDIR}/$f
    done
    ( cd ${DEPLOYDIR} && sha256sum boot.img vendor_kernel_boot.img init_boot.img > SHA256SUMS-dace )
    bbnote "Dace boot artifacts deployed: ${DEPLOYDIR}/{boot,vendor_kernel_boot,init_boot}.img"
}
addtask deploy after do_compile before do_build
