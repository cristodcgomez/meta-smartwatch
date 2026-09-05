require recipes-kernel/linux/linux.inc
inherit gettext

SECTION = "kernel"
SUMMARY = "TicWatch Pro 5 (dace/monaco) kernel — Qualcomm monaco 5.15.144 (google-eos, mismo SoC que aurora)"
HOMEPAGE = "https://gitlab.com/ubports/porting/community-ports/android13/google-eos/kernel-for-google-eos"
LICENSE = "GPL-2.0-only"
LIC_FILES_CHKSUM = "file://COPYING;md5=6bc538ed5bd9a7fc9398086aedcd7e46"
COMPATIBLE_MACHINE = "ticwatch-pro-5"

# ═══════════════════════════════════════════════════════════════════════════
# KERNEL QUALCOMM MONACO (google-eos, 5.15.144) — esquema GKI COMPLETO
#
# El bootloader UEFI del dace (Wear OS 4/Android 13, GKI) espera el layout:
#   boot.img        = kernel Image SOLO (header v4, sin ramdisk)
#   vendor_boot.img = ramdisk (modulos del SoC) + DTB real (monaco-real.dtb)
#   init_boot.img   = ramdisk de primera fase (nuestro init de adb)
# El bootloader concatena init_boot + vendor_boot ramdisks y pasa el conjunto
# como initrd al kernel, así /init (nuestro) ve /lib/modules con los .ko.
#
# LOS DRIVERS DEL SoC QUEDAN =m (MÓDULOS): Qualcomm resuelve muchos símbolos
# solo a nivel módulo (ipc_log_, iommu_logger_, regulator_proxy...); forzar
# =y rompe el link de vmlinux con undefined symbols. Se cargan desde el
# vendor ramdisk (que va en vendor_boot) en el primer boot.
# ═══════════════════════════════════════════════════════════════════════════
SRC_URI = "git:///home/cristo/TICWATCH/google-eos-kernel;branch=halium-13.0;protocol=file \
           git://android.googlesource.com/kernel/google-modules/bms;protocol=https;branch=android-msm-eos-5.15-tm-wear-kr3-dr-eos;name=bms;destsuffix=git-bms \
           file://t5-critical.fragment \
           file://eud-secure-fail-nonfatal.patch \
           file://slatecom-ssr-optional.patch \
           file://minidump-int-type.patch \
           file://dace-stock-stubs.patch \
           file://dwc3-core-probe-trace.patch \
           file://monaco-real.dtb \
           file://monacop.dtb \
           file://vendor-bootconfig \
           file://dace-bootcolor.py"
SRCREV = "063840c5aae117bf0faac8b34fba0e37c9f619f8"
# v57: pin del repo google-modules/bms (branch y SRCREV tomados de la receta
# linux-aurora-modules; provee gvotable.h y logbuffer.h que <misc/gvotable.h>
# requieren en drivers/power/supply/qcom/{smblite,pmic-voter-compat}.c).
SRCREV_bms = "51583026f264e7597808a16aa6809fb9279eb8c4"
SRCREV_FORMAT = "bms"

LINUX_VERSION ?= "5.15.144"
PV = "${LINUX_VERSION}+gki"

S = "${WORKDIR}/git"
B = "${WORKDIR}/build"

ARCH = "arm64"
KERNEL_IMAGETYPE = "Image"
KERNEL_DEVICETREE = ""

# ─── Toolchain clang LLVM (como linux-aurora) + tools p/ensamblado 3-imgs ───
DEPENDS += "clang-native rsync-native elfutils-native mkbootimg-tools-native lz4-native dtc-native kmod-native"
LLVM_BIN = "${STAGING_BINDIR_NATIVE}"
PATH:prepend = "${STAGING_BINDIR_NATIVE}:"
KERNEL_CC = "${LLVM_BIN}/clang --target=aarch64-linux-gnu -fuse-ld=lld -Wno-unused-command-line-argument"
KERNEL_LD = "${LLVM_BIN}/ld.lld"
KERNEL_AR = "${LLVM_BIN}/llvm-ar"
KERNEL_NM = "${LLVM_BIN}/llvm-nm"
KERNEL_OBJCOPY = "${LLVM_BIN}/llvm-objcopy"
KERNEL_OBJDUMP = "${LLVM_BIN}/llvm-objdump"
KERNEL_STRIP = "${LLVM_BIN}/llvm-strip"
EXTRA_OEMAKE:append = " LLVM=1 LLVM_IAS=1 ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu-"
# V65 VIA B: UTS_RELEASE = vermagic de los módulos vendor STOCK (Mobvoi
# msm-5.15 g7f9d6c16b5cd-ab151). same_magic() hace strcmp completo (los .ko
# van sin __versions) → la cadena de versión debe coincidir EXACTAMENTE.
EXTRA_OEMAKE:append = " EXTRAVERSION=-g7f9d6c16b5cd-ab151"
EXTRA_OEMAKE:append = " KCFLAGS='-Wno-error -Wno-implicit-function-declaration -Wno-error=implicit-function-declaration -Wno-error=implicit-int -Wno-error=int-conversion -Wno-error=incompatible-function-pointer-types -Wno-error=incompatible-pointer-types -Wno-error=strict-prototypes' HOSTCFLAGS=-Wno-error"

OBJCOPY = "${LLVM_BIN}/llvm-objcopy"
STRIP = "${LLVM_BIN}/llvm-strip"
NM = "${LLVM_BIN}/llvm-nm"
AR = "${LLVM_BIN}/llvm-ar"

# ─── do_configure: merge gki + monaco_GKI + fragment; BTF off ───
do_configure:prepend() {
    # Telemetría temporal de texto; slatecom ya se corrige con parche separado.
    python3 ${UNPACKDIR}/dace-bootcolor.py ${S}/init/main.c \
        ${S}/drivers/soc/qcom/slatecom_interface.c
    rm -f ${WORKDIR}/.config
    sh ${S}/scripts/kconfig/merge_config.sh -m -r -O ${WORKDIR} \
        ${S}/arch/arm64/configs/gki_defconfig \
        ${S}/arch/arm64/configs/vendor/monaco_GKI.config \
        ${UNPACKDIR}/t5-critical.fragment
    mv ${WORKDIR}/.config ${WORKDIR}/defconfig
    echo "# CONFIG_DEBUG_INFO_BTF is not set" >> ${WORKDIR}/defconfig
    echo "# CONFIG_DEBUG_INFO_BTF_MODULES is not set" >> ${WORKDIR}/defconfig
    echo "# CONFIG_WERROR is not set" >> ${WORKDIR}/defconfig
    echo "# CONFIG_LTO_CLANG_THIN is not set" >> ${WORKDIR}/defconfig
    echo "# CONFIG_LTO_CLANG_FULL is not set" >> ${WORKDIR}/defconfig
    echo "# CONFIG_LTO_CLANG is not set" >> ${WORKDIR}/defconfig
    echo "CONFIG_LTO_NONE=y" >> ${WORKDIR}/defconfig
    echo "# CONFIG_CFI_CLANG is not set" >> ${WORKDIR}/defconfig
}

do_configure:append() {
    sed -i "/^CONFIG_CMDLINE=/d" ${B}/.config 2>/dev/null || true
    # v13: restaurar RANDOMIZE_BASE=y y EFI/efi-stub (como el STOCK). Los
    # quitamos en v10/v12 para depurar, pero el stock los tiene y el ABL del
    # dace puede ESPERARLOS (un kernel estatico/sin stub se carga en la
    # direccion equivocada -> hang). Cmdline minimo, como el stock GKI.
    echo 'CONFIG_CMDLINE="androidboot.hardware=dace androidboot.selinux=permissive"' >> ${B}/.config
    sed -i '/^# CONFIG_RANDOMIZE_BASE is not set/d; /^# CONFIG_EFI is not set/d; /^# CONFIG_EFI_STUB is not set/d; /^# CONFIG_EFI_GENERIC_STUB is not set/d' ${B}/.config
    echo 'CONFIG_RANDOMIZE_BASE=y' >> ${B}/.config
    echo 'CONFIG_EFI=y' >> ${B}/.config
    echo 'CONFIG_EFI_STUB=y' >> ${B}/.config
    echo 'CONFIG_EFI_GENERIC_STUB=y' >> ${B}/.config
    yes '' | oe_runmake -C ${S} O=${B} ARCH=arm64 \
        CC="${LLVM_BIN}/clang --target=aarch64-linux-gnu -fuse-ld=lld -Wno-unused-command-line-argument" \
        LD="${LLVM_BIN}/ld.lld" LLVM=1 LLVM_IAS=1 \
        CROSS_COMPILE=aarch64-linux-gnu- HOSTCC=gcc HOSTCXX=g++ olddefconfig
    # BTF off definitivo (el árbol google lo re-fuerza tras el merge)
    sed -i "/^CONFIG_DEBUG_INFO_BTF=/d; s/^CONFIG_DEBUG_INFO_BTF=y/# CONFIG_DEBUG_INFO_BTF is not set/" ${B}/.config
    yes '' | oe_runmake -C ${S} O=${B} ARCH=arm64 \
        CC="${LLVM_BIN}/clang --target=aarch64-linux-gnu -fuse-ld=lld -Wno-unused-command-line-argument" \
        LD="${LLVM_BIN}/ld.lld" LLVM=1 LLVM_IAS=1 \
        CROSS_COMPILE=aarch64-linux-gnu- HOSTCC=gcc HOSTCXX=g++ olddefconfig
    # monaco_GKI re-marca USB_F_QDSS=m y USB_CONFIGFS_F_QDSS=m; ambos
    # duplican dwc3_msm_* (f_qdss/u_qdss). Los apagamos TODOS.
    sed -i "/^CONFIG_USB_F_QDSS=/d; /^CONFIG_USB_CONFIGFS_F_QDSS=/d" ${B}/.config
    echo '# CONFIG_USB_F_QDSS is not set' >> ${B}/.config
    echo '# CONFIG_USB_CONFIGFS_F_QDSS is not set' >> ${B}/.config
    # v43: PROXY_CONSUMER OFF (fix USB de aurora, mismo SoC): con él activo el
    # probe de gdsc-regulator hace regulator_get sobre reguladores RPM que en
    # un first-stage-only nunca llegan → defer -517 permanente → USB3_GDSC
    # jamás se registra → dwc3_msm_probe difiere -517 → sin UDC/adb.
    # (verificado v39-v42: step=17 ret=-517; aurora lo documenta igual).
    sed -i "/^CONFIG_REGULATOR_PROXY_CONSUMER=/d" ${B}/.config
    echo '# CONFIG_REGULATOR_PROXY_CONSUMER is not set' >> ${B}/.config
    echo '# CONFIG_REGULATOR_PROXY_CONSUMER_LEGACY is not set' >> ${B}/.config
    # v14: FORZAR =y la cadena de arranque temprano del SoC (el olddefconfig
    # los revierte a =m porque son tristate seleccionados por otros =m).
    # Son los que el kernel 5.4 del dace tiene built-in. Sin ellos =y el
    # kernel se cuelga en arranque temprano (logo congelado).
    for sym in QCOM_SMEM QCOM_SOC_SLEEP_STATS MSM_BOOT_STATS MSM_BOOT_TIME_MARKER \
               IPC_LOGGING QCOM_SCM QCOM_SECURE_BUFFER QCOM_MPM QCOM_SMP2P \
               QCOM_SMP2P_SLEEPSTATE QCOM_GLINK QCOM_RPMH QCOM_CLK_RPMH \
               PINCTRL_MSM PINCTRL_MONACO ARM_SMMU ARM_SMMU_QCOM QTI_IOMMU_SUPPORT \
               SERIAL_MSM_GENI RPMSG_QCOM_GLINK_SLATECOM \
               MSM_SLATECOM MSM_SLATECOM_INTERFACE MSM_SLATECOM_RPMSG \
               QCOM_IOMMU_UTIL IOMMU_IO_PGTABLE_FAST IOMMU_IO_PGTABLE_LPAE \
               QSEECOM_PROXY QCOM_RPROC_COMMON QCOM_Q6V5_PAS; do
        sed -i "/^CONFIG_${sym}=/d; /^# CONFIG_${sym} is not set/d" ${B}/.config
        echo "CONFIG_${sym}=y" >> ${B}/.config
    done
    # re-resolver deps tras forzar =y (puede activar mas símbolos necesarios)
    yes '' | oe_runmake -C ${S} O=${B} ARCH=arm64 \
        CC="${LLVM_BIN}/clang --target=aarch64-linux-gnu -fuse-ld=lld -Wno-unused-command-line-argument" \
        LD="${LLVM_BIN}/ld.lld" LLVM=1 LLVM_IAS=1 \
        CROSS_COMPILE=aarch64-linux-gnu- HOSTCC=gcc HOSTCXX=g++ olddefconfig
    # QCOM_RPROC_COMMON es tristate ciego: solo queda =y si un driver =y lo
    # SELECT. QCOM_Q6V5_PAS=y lo arrastra (junto a Q6V5_COMMON, PIL_INFO,
    # MDT_LOADER). Forzamos todo con scripts/config DESPUES del olddefconfig
    # (sin re-resolver, para que no se revierta).
    ${S}/scripts/config --file ${B}/.config -e QCOM_Q6V5_PAS -e QCOM_RPROC_COMMON \
        -e QCOM_Q6V5_COMMON -e QCOM_PIL_INFO -e QCOM_MDT_LOADER
    grep '^CONFIG_CMDLINE=' ${B}/.config
    grep -E '^CONFIG_DEBUG_INFO_BTF' ${B}/.config || true
}

do_install:append() {
    rm -rf ${D}/usr/src/usr/
    find ${D}/usr/src/ -name ..install.cmd -delete 2>/dev/null || true
}

# Charger externo: google-modules/bms (gvotable/logbuffer) + smblite.
do_compile_kernelmodules:append() {
    # ── google-modules/bms — gvotable / logbuffer / qpnp-smblite-main ──
    #
    # El Makefile de drivers/power/supply/qcom espera:
    #   -I<dir_de_kernel>/../google-modules/bms  (para <misc/gvotable.h>)
    #   EXTRA_SYMBOLS = <build_dir>/../google-modules/bms/misc/Module.symvers
    # Replicamos el layout hermano que usa linux-aurora-modules:
    #   /workdir/google-modules/bms -> repo clonado (destsuffix=git-bms)
    #   ${KDIR} = ${S} = ${WORKDIR}/git  →  ../google-modules/bms resuelve.
    # Usamos UNPACKDIR (sources-unpack) porque WORKDIR/git-bms puede ser
    # un residuo/caché corrupto (verificado: sources-unpack/git-bms tiene
    # misc/ completo con gvotable.h; work-dir/git-bms está vacío/broken).
    BMS=${UNPACKDIR}/git-bms
    mkdir -p ${WORKDIR}/google-modules
    ln -sfn ${BMS} ${WORKDIR}/google-modules/bms
    # ⚠️ ${S} es un symlink al kernel real (work-shared/…/kernel-source).
    # El Makefile del charger usa -I$(KERNEL_SRC)/../google-modules/bms y
    # $(OUT_DIR)/../google-modules/bms/misc/Module.symvers; con symlink,
    # "../" resuelve junto al DESTINO real (como descubrió aurora: crea sus
    # symlinks hermanos junto a ${KDIR} en work-shared). Replicamos eso.
    KSR=$(readlink -f ${S})
    mkdir -p ${KSR}/../google-modules
    ln -sfn ${BMS} ${KSR}/../google-modules/bms
    BMSPATH="${KSR}/../google-modules/bms"

    CC="${LLVM_BIN}/clang --target=aarch64-linux-gnu -fuse-ld=lld -Wno-unused-command-line-argument"
    LD="${LLVM_BIN}/ld.lld"
    AR="${LLVM_BIN}/llvm-ar"
    NM="${LLVM_BIN}/llvm-nm"

    # (1) gvotable + logbuffer: lives in bms/misc, builds standalone.
    # Su Makefile es un WRAPPER que recursa con $(KERNEL_SRC) (default:
    # kernel del HOST). Hay que pasar KERNEL_SRC/OUT_DIR como hace la
    # receta linux-aurora-modules (ver su comentario KMOD_MAKE).
    bbnote "Building gvotable + logbuffer from bms/misc ..."
    make -C ${S} O=${B} ARCH=arm64 LLVM=1 LLVM_IAS=1 \
        CC="$CC" LD="$LD" AR="$AR" NM="$NM" \
        CROSS_COMPILE=aarch64-linux-gnu- \
        KERNEL_SRC=${KSR} OUT_DIR=${B} \
        M=${BMS}/misc \
        CONFIG_GOOGLE_VOTABLE=m CONFIG_GOOGLE_LOGBUFFER=m \
        modules 2>&1 | tee ${B}/bms-misc-build/build.log | tail -8
    [ -f "${BMS}/misc/gvotable.ko" ] || bbfatal "gvotable.ko NO compilado (ver ${B}/bms-misc-build/build.log)"

    # (2) qpnp-smblite-main + qti-qbg-main: mismo patrón wrapper. Su Makefile
    # ya añade solo: -I$(KERNEL_SRC)/../google-modules/bms (headers),
    # KBUILD_OPTIONS con CONFIG_QPNP_SMBLITE/QTI_QBG=m, el define
    # GOOGLE_DISABLE_SOFT_JEITA_INHIBIT_CHARGING y KBUILD_EXTRA_SYMBOLS
    # desde $(OUT_DIR)/../google-modules/bms/misc/Module.symvers (existe
    # tras paso 1 vía symlink). Los .ko caen junto a las fuentes.
    bbnote "Building qpnp-smblite-main + qti-qbg-main (M=drivers/power/supply/qcom) ..."
    make -C ${S} O=${B} ARCH=arm64 LLVM=1 LLVM_IAS=1 \
        CC="$CC" LD="$LD" AR="$AR" NM="$NM" \
        CROSS_COMPILE=aarch64-linux-gnu- \
        KERNEL_SRC=${KSR} OUT_DIR=${B} \
        M=${S}/drivers/power/supply/qcom \
        KBUILD_EXTRA_SYMBOLS="${BMSPATH}/misc/Module.symvers" \
        KCFLAGS="-Wno-error -I${BMSPATH}" \
        CONFIG_QPNP_SMBLITE=m CONFIG_QTI_QBG=m \
        modules 2>&1 | tee ${B}/qcom-supply-build/build.log | tail -8
    [ -f "${S}/drivers/power/supply/qcom/qpnp-smblite-main.ko" ] || bbfatal "qpnp-smblite-main.ko NO compilado (ver ${B}/qcom-supply-build/build.log)"

    bbnote "BMS modules built: gvotable=$(ls ${BMS}/misc/*.ko 2>/dev/null | xargs -I{} basename {} | tr '\n' ' ') smblite=$(ls ${S}/drivers/power/supply/qcom/qpnp-smblite*.ko 2>/dev/null | xargs -I{} basename {} | tr '\n' ' ') qbg=$(ls ${S}/drivers/power/supply/qcom/qti-qbg*.ko 2>/dev/null | xargs -I{} basename {} | tr '\n' ' ')"
}

# ─── Ensamblado GKI 3 imágenes (como aurora-boot-images.bb) ───
inherit mkbootimg old-kernel-gcc-hdrs
MKBOOTIMG_HEADER_VERSION = "0"

do_deploy:append() {
    set -e
    MKBOOTIMG=${STAGING_BINDIR_NATIVE}/mkbootimg
    test -x "${MKBOOTIMG}" || bbfatal "mkbootimg (AOSP) not found"
    KREL=${KERNEL_VERSION}
    DEPMOD_BIN="${STAGING_BINDIR_NATIVE}/depmod"
    [ -x "$DEPMOD_BIN" ] || DEPMOD_BIN="$(command -v depmod || echo depmod)"

    # ── (1) boot.img: kernel SOLO, header v4 (igual que el stock) ──
    "${MKBOOTIMG}" \
        --kernel "${B}/${KERNEL_OUTPUT_DIR}/Image" \
        --header_version 4 --pagesize 4096 \
        --os_version 13.0.0 --os_patch_level 2024-11 \
        -o "${DEPLOYDIR}/${DISTRO}-${MACHINE}-boot.img"
    bbnote "boot.img (v4 kernel-only) generado: $(stat -c%s ${DEPLOYDIR}/${DISTRO}-${MACHINE}-boot.img) bytes"

    # ── (2) vendor_boot.img: ramdisk con módulos .ko + DTB real ──
    # Mismo formato que el stock: ramdisk gzip (no lz4), bootconfig presente
    # (androidboot.hardware=dace), DTB monaco-real. Sin bootconfig el bootloader
    # del dace daba "Load Error" (primera prueba).
    #
    # ⚠️ DTB BLOB = DOS DTBs CONCATENADOS (como el stock): monaco-real.dtb
    # (qcom,monaco, msm-id 486) + monacop.dtb (qcom,monacop, msm-id 517).
    # El ABL selecciona el DTB por msm-id/board-id del hardware; sin el que
    # coincide (monacop) cae a EDL 05c6:900e (confirmado 22-08-2026).
    VEND=${B}/vendor-ramdisk
    rm -rf ${VEND} && mkdir -p ${VEND}/lib/modules
    # ── V65 VIA B: módulos vendor STOCK prebuilts (sin __versions) ──
    # Los .ko son los del vendor_boot stock (Mobvoi msm-5.15 g7f9d6c16b5cd),
    # con la sección __versions quitada en el host. Contra nuestro kernel:
    #   - CONFIG_MODULE_FORCE_LOAD=y (fragment) acepta módulos sin CRCs
    #   - EXTRAVERSION alinea UTS_RELEASE con el vermagic stock
    #   - MODVERSIONS=y mantiene las flags "modversions" del vermagic
    # Carga por insmod directo (sin modules.dep/depmod).
    STOCKMOD=/home/cristo/TICWATCH/ota-stock/extracted/modules-stripped
    test -d "$STOCKMOD" || bbfatal "$STOCKMOD no existe (extraer vendor_boot stock + llvm-objcopy --remove-section=__versions)"
    cp ${STOCKMOD}/*.ko ${VEND}/lib/modules/
    # modules.load: first-stage stock (orden stock) + cadena USB 2ª etapa
    # (orden verificado en dace stock) + resto alfabético. Dedup por awk.
    # El init hace dos pasadas sobre esta lista (resuelve dependencias en orden).
    ( cd ${VEND}/lib/modules
      {
        cat ${STOCKMOD}/../vendor-ramdisk-lib/modules/modules.load 2>/dev/null || true
        for f in eud.ko usb_bam.ko phy-generic.ko phy-msm-snps-hs.ko dwc3-msm.ko qpnp-smblite-main.ko qti_battery_charger.ko; do
            [ -f "$f" ] && echo "$f"
        done
        ls *.ko | sort
      } | awk '!seen[$0]++' > modules.load
    )
    test -s ${VEND}/lib/modules/modules.load || bbfatal "modules.load vacío o no generado"
    cp ${VEND}/lib/modules/modules.load ${VEND}/lib/modules/modules.load.recovery 2>/dev/null || true
    bbnote "vendor ramdisk FLAT: $(ls ${VEND}/lib/modules/*.ko 2>/dev/null | wc -l) .ko en /lib/modules"
    ( cd ${VEND} && find . | sort | cpio -o -H newc --owner root:root 2>/dev/null ) > ${B}/vendor_rd.cpio
    gzip -9 -f ${B}/vendor_rd.cpio
    # DTB blob stock: conserva extcon=<charger eud>, USB3_GDSC-supply y
    # el estado original de smblite (okay) y QBG (disabled). Sin bypasses.
    # V67: ÚNICO cambio — dr_mode otg→peripheral en el hijo dwc3: con "otg" el
    # core espera la decisión de rol del glue (extcon/io-channel del charger);
    # sin ella el gadget nunca se inicializa → sin UDC. peripheral = gadget
    # directo (un reloj solo necesita modo device). Probado fdtput en host.
    FDTPUT=$(find ${STAGING_BINDIR_NATIVE} -name fdtput 2>/dev/null | head -1)
    [ -n "$FDTPUT" ] || FDTPUT=$(command -v fdtput)
    test -n "$FDTPUT" || bbfatal "fdtput no encontrado (dtc-native)"
    for dtb in monaco-real monacop; do
        cp ${UNPACKDIR}/${dtb}.dtb ${B}/${dtb}-stock.dtb
        "$FDTPUT" -t s ${B}/${dtb}-stock.dtb /soc/hsusb@4e00000/dwc3@4e00000 dr_mode peripheral
        bbnote "$dtb: dr_mode=peripheral forzado en dwc3@4e00000"
    done
    cat ${B}/monaco-real-stock.dtb ${B}/monacop-stock.dtb > ${B}/dtb-blob-vendor.bin
    bbnote "DTB blob vendor_boot: $(stat -c%s ${B}/dtb-blob-vendor.bin) bytes (stock=572016)"
    "${MKBOOTIMG}" \
        --vendor_boot "${DEPLOYDIR}/${DISTRO}-${MACHINE}-vendor_boot.img" \
        --vendor_ramdisk ${B}/vendor_rd.cpio.gz \
        --vendor_bootconfig ${UNPACKDIR}/vendor-bootconfig \
        --dtb ${B}/dtb-blob-vendor.bin \
        --header_version 4 --pagesize 4096 \
        --base 0x00000000 \
        --kernel_offset 0x00008000 \
        --ramdisk_offset 0x01000000 \
        --tags_offset 0x00000100 \
        --dtb_offset 0x01f00000 \
        --vendor_cmdline 'lpm_levels.sleep_disabled=1 video=vfb:640x400,bpp=32,memsize=3072000 msm_rtb.filter=0x237 service_locator.enable=1 swiotlb=noforce kpti=off cgroup.memory=nokmem,nosocket loop.max_part=7 bootconfig qcom_geni_serial.con_enabled=0 androidboot.hardware=dace bootconfig buildvariant=user fw_devlink=permissive'
    bbnote "vendor_boot.img (v4, base 0 + cmdline stock + blob 2-dtb) generado: $(stat -c%s ${DEPLOYDIR}/${DISTRO}-${MACHINE}-vendor_boot.img) bytes"

    # ── (3) init_boot.img: nuestro initramfs (init de adb) como ramdisk v4 ──
    # Mismo formato que el stock: ramdisk gzip (no lz4), kernel vacio (size 0).
    CPIO_GZ=${DEPLOY_DIR_IMAGE}/initramfs-android-image-${MACHINE}.cpio.gz
    test -f "$CPIO_GZ" || bbfatal "initramfs cpio.gz no en $CPIO_GZ"
    # el cpio.gz del initramfs ya es gzip; lo pasamos directo como ramdisk
    : > ${B}/empty_kernel
    "${MKBOOTIMG}" \
        --header_version 4 --pagesize 4096 \
        --kernel ${B}/empty_kernel \
        --ramdisk "$CPIO_GZ" \
        --os_version 13.0.0 --os_patch_level 2024-11 \
        -o "${DEPLOYDIR}/${DISTRO}-${MACHINE}-init_boot.img"
    bbnote "init_boot.img (v4, nuestro initramfs gzip) generado: $(stat -c%s ${DEPLOYDIR}/${DISTRO}-${MACHINE}-init_boot.img) bytes"

    # listar los 3 (sin brace expansion, dash no la soporta)
    for f in boot vendor_boot init_boot; do
        ls -la "${DEPLOYDIR}/${DISTRO}-${MACHINE}-${f}.img"
    done
}

ERROR_QA:remove = "arch buildpaths"
WARN_QA:append = " arch buildpaths"
# .ko aarch64 en máquina armv7: el QA de arch es falso positivo
INSANE_SKIP += "arch buildpaths"