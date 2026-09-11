#! /bin/sh

. /machine.conf

# ════════════════════════════════════════════════════════════════════
#  CANARY-B INIT — flujo completo (rootfs/adb) + telemetría (2026-09-08)
# ════════════════════════════════════════════════════════════════════
# Datos sabidos: phy completa probe (PHY=43), glue G7, core D0. El freeze
# ~30s es el watchdog de boot sin root/Adbize. Aquí:
#   1) modprobe (como canary) — el sistema carga la cadena.
#   2) telemetría breve en pantalla.
#   3) monta el sdcard (userdata) y busca rootfs alto; si hay asteroidos.ext4
#      → switch_root a systemd (señal de boot completo → watchdog off).
#   4) SI NO hay rootfs → activar el gadget USB (adb) desde el initramfs:
#      configfs + android-gadget-setup adb + adbd + poll UDC + bind.
#   5) bucle de telemetría SIEMPRE al final (si no pudo switch_root).
# ════════════════════════════════════════════════════════════════════

info() { echo "init: $1" > /dev/kmsg 2>/dev/null; }
ptext() { [ -w /sys/kernel/dace_text ] && printf '%s\n' "$1" > /sys/kernel/dace_text 2>/dev/null; }
SP=0
mark() { SP=$((SP+1)); ptext "CAN S${SP} $*"; info "CAN S${SP} $*"; }

hw_status() {
    local C=0 P=0 D=0 G="?" PHY="?" CORE="?"
    [ -n "$(ls /sys/bus/platform/drivers/qpnp-smblite/* 2>/dev/null | head -1)" ] && C=1
    [ -n "$(ls /sys/bus/platform/drivers/msm-usb-hsphy/* 2>/dev/null | head -1)" ] && P=1
    [ -n "$(ls /sys/bus/platform/drivers/dwc3/* 2>/dev/null | head -1)" ] && D=1
    [ -e /sys/kernel/dace_glue ] && G=$(tr -d '\n' < /sys/kernel/dace_glue 2>/dev/null)
    [ -e /sys/kernel/dace_phy ] && PHY=$(tr -d '\n' < /sys/kernel/dace_phy 2>/dev/null)
    [ -e /sys/kernel/dace_core ] && CORE=$(tr -d '\n' < /sys/kernel/dace_core 2>/dev/null)
    ptext "HW C${C} P${P} D${D} G=${G} PHY=${PHY} CORE=${CORE}"
    info "HW C${C} P${P} D${D} G=${G} PHY=${PHY} CORE=${CORE}"
}

setup_devtmpfs() {
    mount -t devtmpfs -o mode=0755,nr_inodes=0 devtmpfs $1/dev
    mkdir $1/dev/pts
    mount -t devpts none $1/dev/pts/
    test -c $1/dev/fd     || ln -sf /proc/self/fd $1/dev/fd
    test -c $1/dev/stdin  || ln -sf fd/0 $1/dev/stdin
    test -c $1/dev/stdout || ln -sf fd/1 $1/dev/stdout
    test -c $1/dev/stderr || ln -sf fd/2 $1/dev/stderr
    test -c $1/dev/socket || mkdir -m 0775 $1/dev/socket
}

mkdir -m 0755 /proc;  mount -t proc proc /proc
mkdir -m 0755 /sys;   mount -t sysfs sys /sys
mkdir -p /dev;        setup_devtmpfs ""
mark "mounts"

# ── arm_smmu: NO deshabilitar el bypass (dace bring-up) ──
# CONFIG_ARM_SMMU_DISABLE_BYPASS_BY_DEFAULT=y en GKI hace que
# arm_smmu_device_reset() ponga sCR0.USFCFG: los streams NO emparejados en la
# tabla SMR FALLAN en vez de hacer bypass. El firmware/TZ dejo el apps-smmu con
# solo el SMR de handoff (qcom,handoff-smrs = <0x420 0x02>), asi que con USFCFG
# el eMMC (y otros masters ya programados por el bootloader) empiezan a fallar
# la traduccion -> 'mmc0: ADMA error: 0x02000000' y, segun el master, reset
# duro a EDL. El kernel stock Mobvoi usa el default (bypass); lo replicamos con
# el module param (arm_smmu es =m, asi que modprobe.d lo aplica).
mkdir -p /etc/modprobe.d
printf '%s\n' 'options arm_smmu disable_bypass=0' \
    > /etc/modprobe.d/dace-smmu.conf
info "modprobe.d/arm_smmu disable_bypass=0"

# ── consola USB (ACM) ── (definida ANTES del bucle de modulos:
# el bucle la usa en cuanto carga dwc3-msm, para capturar el
# arranque del display)
setup_usb_console() {
    G=/sys/kernel/config/usb_gadget
    # Idempotente: si la consola ya esta enganchada, no la recreamos (cada
    # recreacion re-enumera el USB y perderiamos lineas de consola).
    if [ -n "$(cat $G/console/UDC 2>/dev/null)" ]; then
        return 0
    fi
    mkdir -p /sys/kernel/config
    mount -t configfs none /sys/kernel/config 2>/dev/null
    for u in $G/*/UDC; do
        [ -e "$u" ] || continue
        [ -n "$(cat $u 2>/dev/null)" ] && echo "" > "$u" 2>/dev/null
    done
    mkdir -p $G/console
    cd $G/console 2>/dev/null || return
    echo 0x18d1 > idVendor
    echo 0x4ee7 > idProduct
    mkdir -p strings/0x409
    echo "dace-console" > strings/0x409/serialnumber
    echo "AsteroidOS"   > strings/0x409/manufacturer
    echo "dace-console" > strings/0x409/product
    mkdir -p configs/c.1/strings/0x409
    echo "acm" > configs/c.1/strings/0x409/configuration
    mkdir -p functions/acm.usb0
    ln -sf functions/acm.usb0 configs/c.1/acm.usb0
    UDC=$(ls /sys/class/udc 2>/dev/null | sed -n 1p)
    [ -n "$UDC" ] && echo "$UDC" > UDC
    cd /
    ptext "console: UDC=${UDC:-none}"
    info "console: UDC=${UDC:-none}"
}

# ── modprobe vendor ──
KREL=$(uname -r)
[ ! -e "/lib/modules/$KREL" ] && ln -sf . "/lib/modules/$KREL"
mark "krel ${KREL}"
modprobe google-extcon-usb-shim usb_force_disable_boot=0 2>/dev/kmsg
MI=0
while read mod; do
    case "$mod" in ''|\#*) continue ;; esac
    name="${mod%.ko}"
    # qnoc-monaco / msm_drm / msm_kgsl se cargan MAS ABAJO, despues de montar
    # la consola USB: msm_smmu_probe() (driver de smmu_sde_unsec_cb, dentro de
    # msm_drm.ko) exige que el apps-smmu ya este para obtener dominio IOMMU, y
    # queremos la consola capturando el arranque del display.
    case "$name" in
        qnoc-monaco|msm_drm|msm_kgsl)
            info "M-- ${name} (diferido al arranque del display)"
            continue ;;
    esac
    MI=$((MI+1))
    ptext "CAN M${MI} ${name}"
    info "M${MI} ${name}"
    modprobe "$name" 2>/dev/kmsg
done < /etc/modules.load.dace
mark "modprobe done ${MI}"

# USB gate open
for fd in /sys/devices/platform/soc/soc:extcon_usb_shim/force_disable \
          /sys/bus/platform/devices/soc:extcon_usb_shim/force_disable; do
    [ -e "$fd" ] && echo 0 > "$fd" 2>/dev/kmsg
done
mount -t debugfs none /sys/kernel/debug 2>/dev/null || true
mark "usb gate + debugfs"

# ════════════════════════════════════════════════════════════════════
# Consola USB + ARRANQUE DEL DISPLAY (diagnostico)
# La consola se monta AQUI (no antes): dwc3-msm carga en la linea 61 pero la
# UDC no existe hasta despues (cadena extcon/phy completa). Con la consola ya
# arriba cargamos qnoc-monaco -> msm_drm -> msm_kgsl en orden: el apps-smmu
# debe existir ANTES que msm_drm o smmu_sde_unsec_cb nunca obtiene dominio
# IOMMU (-EINVAL, no EPROBE_DEFER) y msm_drm_bind() no crea /dev/dri.
# ════════════════════════════════════════════════════════════════════
setup_usb_console
sleep 2
info "DISPLAY: consola arriba, cargando qnoc-monaco"
modprobe qnoc-monaco 2>/dev/kmsg ; info "DISPLAY: qnoc-monaco rc=$?"
modprobe msm_drm 2>/dev/kmsg     ; info "DISPLAY: msm_drm rc=$?"
modprobe msm_kgsl 2>/dev/kmsg    ; info "DISPLAY: msm_kgsl rc=$?"
info "DISPLAY: fin de la carga (si sigues viendo esto, no hubo reset)"
sleep 2

# ── pequeña ventana de estado (2s) ──
i=0
while [ $i -lt 2 ]; do hw_status; sleep 1; i=$((i+1)); done

# ════════════════════════════════════════════════════════════════════
# sdcard/userdata + rootfs
# ════════════════════════════════════════════════════════════════════
mark "sdcard wait"
mkdir -m 0777 /sdcard /loop
# Esperar la partición con timeout: si no aparece, listar qué particiones hay
# (los números de partición reales y si el eMMC sdhci cargó). Así vemos la
# diferencia entre "el número no es p82" vs "el eMMC no cargó".
w=0
while [ ! -e /dev/$sdcard_partition ] && [ $w -lt 15 ]; do
    info "Waiting for $sdcard_partition..."
    sleep 1
    w=$((w+1))
    if [ $w -eq 15 ]; then
        # momento de diagnóstico: listar qué hay
        PARTS=$(ls /dev/ 2>/dev/null | grep -E '^mmcblk[0-9]' | tr '\n' ' ')
        ptext "PROBE: /dev=${PARTS:-NONE}"
        ptext "PROBE: block=$(ls /sys/block 2>/dev/null | tr '\n' ' ' | cut -c1-60)"
        ptext "PROBE: sdhci=$(ls /sys/bus/platform/drivers/ 2>/dev/null | grep -i sdhci | tr '\n' ' ' | cut -c1-60)"
        ptext "PROBE: mmc=$(ls /sys/bus/mmc/devices 2>/dev/null | tr '\n' ' ' | cut -c1-60)"
        # con dar un momento extra y reintentar (el eMMC puede tardar)
    fi
    if [ $w -ge 30 ]; then
        # forzado: seguir aunque no aparezca (no bloquear el boot)
        ptext "CAN no ${sdcard_partition} tras ${w}s — siguiendo"
        break
    fi
done
mark "sdcard post-wait (w=${w})"

if [ -e /dev/$sdcard_partition ]; then
    FSTYPE=${sdcard_fstype:-auto}
    # OJO: NO correr fsck.ext4 sobre la userdata: en dace.conf esta declarada
    # como F2FS (sdcard_fstype=f2fs). Con -p (preen) e2fsck INTENTA REPARAR y
    # escribiria metadatos ext4 sobre una particion F2FS. Solo se hace fsck si
    # el fstype de verdad es ext4.
    if [ "$FSTYPE" = "ext4" ]; then
        mark "fsck ext4..."
        /sbin/fsck.ext4 -p /dev/$sdcard_partition 2>/dev/null
        mark "fsck ext4 hecho"
    fi
    mark "montando $FSTYPE $sdcard_partition"
    mount -t $FSTYPE -o rw,noatime,nodiratime /dev/$sdcard_partition /sdcard 2>/dev/null
    mark "mount sdcard rc=$?"
else
    mark "NO ${sdcard_partition} — sdcard no montable"
    touch /tmp/NO_SDCARD
fi
[ -d /sdcard/media/0 ] && ANDROID_MEDIA_DIR="/sdcard/media/0" || ANDROID_MEDIA_DIR="/sdcard"
mark "after sdcard "

BOOT_DIR="/sdcard"
if [ -e $ANDROID_MEDIA_DIR/asteroidos.ext4 ] ; then
    mark "rootfs found"
    /sbin/fsck.ext4 -p $ANDROID_MEDIA_DIR/asteroidos.ext4 2>/dev/null
    # OJO: SIN 'sync' en el montaje. Con sync cada escritura va sincrona al
    # eMMC via loop+f2fs y systemd acaba bloqueado en un lock de inodo
    # (`locks_lock_inode_wait`): systemctl deja de responder. Se detecto al
    # arrancar el contenedor LXC con un crashlog escribiendo 20 KB/s.
    mount -o noatime,nodiratime,rw,loop $ANDROID_MEDIA_DIR/asteroidos.ext4 /loop 2>/dev/null \
      && BOOT_DIR="/loop"
fi

# system/vendor/firmware (los monta Android, aquí opcional)
if [ ! -e $system_partition ] && [ -n "$system_partition" ] && [ -e /dev/$system_partition ]; then
    mkdir -m 0777 $BOOT_DIR/system
    mount -t auto -o ro /dev/$system_partition $BOOT_DIR/system 2>/dev/null && mount --bind $BOOT_DIR/system /system 2>/dev/null
fi
if [ ! -e $vendor_partition ] && [ -n "$vendor_partition" ] && [ -e /dev/$vendor_partition ]; then
    mkdir -m 0777 $BOOT_DIR/vendor
    mount -t auto -o ro /dev/$vendor_partition $BOOT_DIR/vendor 2>/dev/null && mount --bind $BOOT_DIR/vendor /vendor 2>/dev/null
fi

# ════════════════════════════════════════════════════════════════════
# Consola del kernel por USB (configfs ACM). El kernel ya trae
# CONFIG_USB_CONFIGFS_ACM=y + CONFIG_U_SERIAL_CONSOLE=y y el cmdline lleva
# "console=ttyGS0,115200": un gadget ACM con el puerto 0 crea /dev/ttyGS0 y el
# host ve /dev/ttyACM0 con el log del kernel. Sirve para ver el boot del rootfs
# (el journal no da tiempo a sincronizar si hay reset duro a EDL).
# ════════════════════════════════════════════════════════════════════

# ════════════════════════════════════════════════════════════════════
# ¿Hay systemd real? → switch_root (señal de boot completo, watchdog off)
# ════════════════════════════════════════════════════════════════════
# debug-ramdisk (cmdline): quedarse en el initramfs con adb en vez de
# switch_root. El rootfs queda montado en /loop, asi que desde el shell adb
# se puede leer /loop/var/log (journal + android-tools-adbd.log) y parcharlo.
# Gate SOLO por fichero. OJO: 'debug-ramdisk' NO viene del vendor_cmdline sino
# de CONFIG_CMDLINE del kernel (linux-dace), o sea que SIEMPRE esta en
# /proc/cmdline y mirarlo dejaria el boot siempre en el initramfs.
# Para depurar: 'touch /sdcard/debug-ramfs' + reboot (adb desde el initramfs,
# rootfs montado en /loop). Para boot normal: 'rm /sdcard/debug-ramfs'.
DEBUG_RAMFS=0
[ -e /sdcard/debug-ramfs ] && DEBUG_RAMFS=1
# ── MODO DE DEPURACION ────────────────────────────────────────────
# El bootconfig del vendor_boot NO llega a /proc/cmdline (comprobado: ni
# androidboot.memcg=1 ni los flags dace.* aparecen), asi que el unico canal
# fiable es el --vendor_cmdline (de ahi si salen lpm_levels.sleep_disabled,
# fw_devlink=permissive, etc.). Con 'dace.debug=1' en el cmdline el initramfs
# decide el modo leyendo /sdcard/dace-mode (la raiz de la userdata, que el
# initramfs SI puede escribir) y BORRANDOLO acto seguido: asi, si el rootfs
# arranca y cae a EDL, el siguiente arranque ya no encuentra el fichero y
# vuelve solo al modo seguro con adb (imposible quedarse en bucle).
#
#   sin fichero        -> ramfs + adb + rootfs en /loop   (SEGURO)
#   boot               -> arranca el rootfs
#   boot noautoload    -> + vacia modules-load.d/dace-post-rootfs.conf
#   boot nolxc         -> + enmascara dace-lxc-android
#   boot console       -> + UDC para la consola del kernel (sin adb)
#   boot crashlog      -> + snapshot de dmesg en /var/log/dace-crash.log cada
#                         segundo (sobrevive a un reset duro a EDL)
#   boot noautoload nolxc crashlog   (combinable)
#
#   adb shell 'echo "boot noautoload nolxc" > /sdcard/dace-mode; reboot'
DEBUG_MODE=""
if grep -q "dace.debug=1" /proc/cmdline; then
    DEBUG_MODE=$(cat /sdcard/dace-mode 2>/dev/null | tr '\n' ' ')
    rm -f /sdcard/dace-mode; sync
    mark "dace-modo: '${DEBUG_MODE:-ramfs}' (fichero consumido)"
    [ -n "$DEBUG_MODE" ] || DEBUG_MODE="ramfs"
    DEBUG_RAMFS=1
    case " $DEBUG_MODE " in *" boot "*) DEBUG_RAMFS=0 ;; esac
fi
# Compatibilidad: flags sueltos en el cmdline.
grep -q "dace.ramfs=1" /proc/cmdline && DEBUG_RAMFS=1
[ -e /sdcard/debug-ramfs ] && DEBUG_RAMFS=1
[ "$DEBUG_RAMFS" = "1" ] && mark "debug-ramfs: sin switch_root (adb)"

if [ -x "$BOOT_DIR/lib/systemd/systemd" ] && [ "$DEBUG_RAMFS" = "0" ]; then
    # qnoc-monaco YA NO se blacklistea: se carga en el initramfs (ver
    # modules.load.dace) porque msm_smmu_probe() necesita el apps-smmu arriba
    # para obtener dominio IOMMU. Si quedara un blacklist de un boot anterior,
    # borrarlo (el modulo ya esta cargado, pero el archivo confunde).
    rm -f $BOOT_DIR/etc/modprobe.d/00-dace-no-qnoc.conf
    # Desenmascarar el USB del rootfs (un boot de debug anterior pudo
    # enmascararlo para proteger la consola). Con esto usb-moded del rootfs
    # levanta adb (fix PREFERRED_PROVIDER android-tools-conf-configfs).
    for u in init_gfs.service usb-moded.service android-tools-adbd.service adbd-prepare.service; do
        f="$BOOT_DIR/etc/systemd/system/$u"
        if [ -L "$f" ] && [ "$(readlink $f 2>/dev/null)" = "/dev/null" ]; then
            rm -f "$f"
            info "unmasked $u"
        fi
    done
    # Restaurar el enable symlink de init_gfs: sin el no existe
    # /config/usb_gadget/g1 y usb-moded (activado por dsme/usbtracker via D-Bus)
    # aborta en configfs_probe -> no hay gadget USB ni adb.
    mkdir -p "$BOOT_DIR/usr/lib/systemd/system/sysinit.target.wants"
    ln -sf ../init_gfs.service \
        "$BOOT_DIR/usr/lib/systemd/system/sysinit.target.wants/init_gfs.service"
    # usb-moded no encuentra el charger (/sys/class/power_supply/usb: smblite
    # esta fuera del boot) -> cree que no hay cable -> "mode setting failed,
    # fallback to undefined" -> mass storage 18d1:0afe en vez de adb_mode.
    # Con -f/--fallback ("assume always connected") entra en el modo por
    # defecto (adb_mode, dace-defaults.ini).
    mkdir -p $BOOT_DIR/etc/systemd/system/usb-moded.service.d
    printf '%s\n' '[Service]' 'Environment=USB_MODED_ARGS=-f -D' \
        > $BOOT_DIR/etc/systemd/system/usb-moded.service.d/10-dace-fallback.conf
    # La consola USB (ACM) y el adb del rootfs compiten por la UDC: por defecto
    # dejamos el USB al rootfs (adb). Para depurar, 'touch /sdcard/console-debug'.
    # ── LOTE DE DIAGNOSTICO: consola USB + carga de qnoc-monaco (one-shot) ──
    # No usa marcadores en /sdcard: en el rootfs /sdcard NO es accesible (es el
    # punto de montaje del initramfs) y crearlos requeriria otro lote. La marca
    # de "ya hecho" se escribe en el ROOTFS (montado en $BOOT_DIR), que
    # persiste: el PRIMER arranque con este lote hace la prueba y los
    # siguientes arrancan normal -> si el SoC se resetea a EDL no hay boot-loop
    # (basta un apagado/encendido).
    if [ ! -e "$BOOT_DIR/etc/dace-qnoc-test-v7-done" ]; then
        : > "$BOOT_DIR/etc/dace-qnoc-test-v7-done"
        sync
        setup_usb_console
        sleep 3
        mark "TEST: consola arriba, modprobe qnoc-monaco"
        modprobe qnoc-monaco 2>/dev/kmsg
        info "TEST: modprobe qnoc-monaco rc=$?"
        mark "TEST: modprobe hecho (espero 15s)"
        sleep 15
        # Volcado de diagnostico ANTES de switch_root (que es donde el eMMC da
        # ADMA error y el SoC resetea): queremos saber si msm_drm probe y si
        # hay /dev/dri, para no confundir "display no probo" con "crash luego".
        mark "TEST: volcando diagnostico a la consola"
        {
            echo "===== DACE TEST DUMP INICIO ====="
            echo "-- qnoc/icc cargados:"
            grep -E "qnoc_monaco|qnoc_qos_rpm|icc_rpm" /proc/modules | cut -d' ' -f1,2
            echo "-- qnoc provider en /sys/class/interconnect:"
            ls /sys/class/interconnect 2>&1 | sed -n 1,5p
            echo "-- /dev/dri:"; ls -la /dev/dri 2>&1
            echo "-- /dev/fb*:"; ls -la /dev/fb* 2>&1
            echo "-- /sys/class/drm:"; ls /sys/class/drm 2>&1
            echo "-- drm status:"
            cat /sys/class/drm/*/status 2>/dev/null | tr '\n' ' '; echo
            echo "-- diferidos:"
            cat /sys/kernel/debug/devices_deferred 2>&1 | sed -n 1,25p
            echo "-- dmesg (drm/sde/kgsl/smmu):"
            dmesg | grep -iE "msm_drm|msm |sde|drm|kgsl|apps-smmu|SMMUv2|iommu" | tail -30
            echo "===== DACE TEST DUMP FIN ====="
        } > /dev/kmsg 2>&1
        mark "TEST: fin dump, switch_root"
    fi
    if [ -e /sdcard/console-debug ]; then
        setup_usb_console
        mark "console-debug: consola (sin adb)"
    fi
    # Flags activos (POSIX: shell del initramfs es busybox ash, nada de [[ ]])
    DO_CONSOLE=0; DO_NOAUTOLOAD=0; DO_NOLXC=0
    case " $DEBUG_MODE " in *" console "*)    DO_CONSOLE=1 ;; esac
    case " $DEBUG_MODE " in *" noautoload "*) DO_NOAUTOLOAD=1 ;; esac
    case " $DEBUG_MODE " in *" nolxc "*)      DO_NOLXC=1 ;; esac
    grep -q "dace.console=1" /proc/cmdline    && DO_CONSOLE=1
    grep -q "dace.noautoload=1" /proc/cmdline && DO_NOAUTOLOAD=1
    grep -q "dace.nolxc=1" /proc/cmdline      && DO_NOLXC=1
    # 'console': deja la UDC para la consola del kernel enmascarando
    # usb-moded/adbd/init_gfs. Sin esto usb-moded se lleva la UDC a los ~10 s
    # y la consola muere justo donde interesa. La UDC es una: o consola, o adb.
    if [ "$DO_CONSOLE" = "1" ]; then
        for u in init_gfs.service usb-moded.service android-tools-adbd.service adbd-prepare.service; do
            ln -sf /dev/null "$BOOT_DIR/etc/systemd/system/$u"
        done
        setup_usb_console
        mark "console: UDC para la consola del kernel (sin adb del rootfs)"
    fi
    # 'noautoload': el rootfs nuevo carga en systemd-modules-load la cadena
    # WLAN/icnss2 + ASoC + BT (dace-post-rootfs.conf), que en el rootfs viejo
    # NO se cargaba nunca (no esta en modules.load.dace).
    if [ "$DO_NOAUTOLOAD" = "1" ]; then
        : > "$BOOT_DIR/etc/modules-load.d/dace-post-rootfs.conf"
        mark "noautoload: dace-post-rootfs.conf vaciado"
    fi
    # 'nolxc': arranca el rootfs con el contenedor Android enmascarado.
    if [ "$DO_NOLXC" = "1" ]; then
        ln -sf /dev/null "$BOOT_DIR/etc/systemd/system/dace-lxc-android.service"
        mark "nolxc: dace-lxc-android enmascarado"
    fi
    mark "rootfs ok, switch_root"
    # ── CRASHLOG A PRUEBA DE BALAS (opt-in: modo "boot crashlog") ────
    # Solo si el modo lo pide: escribe ~30 KB/s y eso castiga la eMMC si se
    # deja siempre. Lanzado DESDE EL INITRAMFS, no depende de que arranque
    # ningun unit de systemd (el dace-crashlog.service no llegaba a arrancar y
    # se perdio el crash). El proceso sigue vivo tras switch_root y sigue
    # escribiendo en el rootfs (los mounts siguen en la tabla: $BOOT_DIR sigue
    # resolviendo), asi que el ultimo segundo de dmesg queda en disco cuando el
    # SoC resetea a EDL.
    case " $DEBUG_MODE " in *" crashlog "*)
        (
            while true; do
                {
                    echo "########## uptime=$(cut -d' ' -f1 /proc/uptime 2>/dev/null)s ##########"
                    dmesg 2>/dev/null | tail -300
                } > $BOOT_DIR/var/log/dace-crash.tmp 2>/dev/null
                mv $BOOT_DIR/var/log/dace-crash.tmp $BOOT_DIR/var/log/dace-crash.log 2>/dev/null
                sleep 1
            done
        ) &
        mark "crashlog del initramfs lanzado -> $BOOT_DIR/var/log/dace-crash.log"
    ;;
    esac
    [ -e /init.machine ] && /init.machine $BOOT_DIR > /dev/kmsg 2>&1 || true
    setup_devtmpfs $BOOT_DIR
    umount -l /proc 2>/dev/null; umount -l /sys 2>/dev/null
    mount -t proc proc $BOOT_DIR/proc 2>/dev/null
    mount -t sysfs sys $BOOT_DIR/sys 2>/dev/null
    mount -t tmpfs run $BOOT_DIR/run 2>/dev/null
    echo "FIFO $BOOT_DIR/run" > /run/psplash_fifo 2>/dev/null
    exec switch_root -c /dev/console $BOOT_DIR /lib/systemd/systemd
fi

mark "NO rootfs — adb desde ramfs"

# ════════════════════════════════════════════════════════════════════
# VOLCADO DEL JOURNAL DEL ARRANQUE QUE FALLO
# En modo debug el rootfs esta montado en /loop y journald es persistente
# (Storage=persistent en init.sh), asi que los ultimos mensajes del arranque
# que se fue a EDL estan en /loop/var/log/journal. Se vuelca el final del
# journal en texto legible a la consola: asi la evidencia sale SIN depender de
# que haya adb. (El journal es binario: se tira lo no imprimible.)
# ════════════════════════════════════════════════════════════════════
if [ -d /loop/var/log/journal ]; then
    J=$(ls -t /loop/var/log/journal/*/system.journal* 2>/dev/null | sed -n 1p)
    if [ -n "$J" ]; then
        mark "JOURNAL: ultimos mensajes de $(basename $(dirname $J))"
        # /dev/console NO pasa por printk, asi que no hay ratelimiting (por
        # /dev/kmsg ya vimos '9 output lines suppressed' y se perderia el
        # volcado). En segundo plano por si el tty no drena.
        ( tail -c 500000 "$J" 2>/dev/null | tr -c '[:print:]' '\n' \
              | grep -aE '^.{12,}' | tail -n 80 > /dev/console 2>&1 ) &
        sleep 3
        mark "JOURNAL: fin del volcado"
    fi
fi

# ════════════════════════════════════════════════════════════════════
# Sin rootfs: intentar el gadget USB/adb.
# La phy ya completó (PH=43) y el glue G7; si UDC aparece, esto da adb.
# ════════════════════════════════════════════════════════════════════
mkdir -p /sys/kernel/config
mount -t configfs none /sys/kernel/config 2>/dev/null

ZU=.sbu
# Soltar la UDC de CUALQUIER gadget antes de enganchar el de adb. La consola
# ACM (setup_usb_console, arriba) ya la tiene cogida y la UDC es UNA. OJO: hay
# que escribir de verdad algo (un newline); ': > UDC' escribe 0 bytes y el
# store de configfs NO se llama -> la UDC sigue ocupada y adb no engancha
# (era exactamente el fallo: el reloj se quedaba con el gadget de la consola y
# sin adb).
for _u in /sys/kernel/config/usb_gadget/*/UDC; do
    [ -e "$_u" ] || continue
    echo "" > "$_u" 2>/dev/null && mark "release $(basename $(dirname $_u))"
done
sleep 1
/usr/bin/android-gadget-setup adb 2>/dev/null && mark "gadget-setup ok" || mark "gadget-setup fail"
# legacy android_usb (no-op en GKI pero por compat)
echo 18d1 > /sys/class/android_usb/android0/idVendor 2>/dev/null
echo d002 > /sys/class/android_usb/android0/idProduct 2>/dev/null
echo adb  > /sys/class/android_usb/android0/f_ffs/aliases 2>/dev/null
echo ffs  > /sys/class/android_usb/android0/functions 2>/dev/null
echo 1    > /sys/class/android_usb/android0/enable 2>/dev/null

/usr/bin/adbd 2>/dev/null &
mark "adbd start"

UDC=""
i=0
while [ $i -lt 30 ]; do
    UDC=$(cd /sys/class/udc 2>/dev/null && echo *)
    case "$UDC" in '*'|''|'.'|'..') UDC="" ;; esac
    [ -n "$UDC" ] && break
    sleep 1
    i=$((i+1))
done
if [ -n "$UDC" ]; then
    UDC=$(echo "$UDC" | awk '{print $1}')
    ptext "CAN UDC=${UDC} (${i}s)"
    echo "$UDC" > /sys/kernel/config/usb_gadget/adb/UDC 2>/dev/null
    mark "UDC bind ${UDC}"
else
    mark "NO UDC after 30s"
fi

# Respaldo SIEMPRE disponible: una shell interactiva por la consola del kernel
# (/dev/ttyGS0; en el host: 'sudo picocom -b 115200 /dev/ttyACM0'). Sirve
# aunque el adb no enganche, y comparte tty con los mensajes del kernel.
if [ -c /dev/ttyGS0 ]; then
    mark "consola: shell de respaldo en ttyGS0"
    (setsid sh -i </dev/ttyGS0 >/dev/ttyGS0 2>&1 &) 2>/dev/null
fi

# ════════════════════════════════════════════════════════════════════
# bucle de telemetría SIEMPRE (si no hubo switch_root)
# SOLO dmesg con contador, sin hw_status: el driver dace_text pinta solo el
# último string; al congelarse, la pantalla queda en la última línea DM
# (las palabras finales del kernel + el contador de la iteración).
c=0
while true; do
    c=$((c+1))
    ptext "DM ${c}> $(dmesg 2>/dev/null | tail -n 6 | tr '\n' ' ' | cut -c1-140)"
    sleep 1
done