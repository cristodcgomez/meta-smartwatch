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

# ── modprobe vendor ──
KREL=$(uname -r)
[ ! -e "/lib/modules/$KREL" ] && ln -sf . "/lib/modules/$KREL"
mark "krel ${KREL}"
modprobe google-extcon-usb-shim usb_force_disable_boot=0 2>/dev/kmsg
MI=0
while read mod; do
    case "$mod" in ''|\#*) continue ;; esac
    MI=$((MI+1))
    ptext "CAN M${MI} ${mod%.ko}"
    modprobe "${mod%.ko}" 2>/dev/kmsg
done < /etc/modules.load.dace
mark "modprobe done ${MI}"

# USB gate open
for fd in /sys/devices/platform/soc/soc:extcon_usb_shim/force_disable \
          /sys/bus/platform/devices/soc:extcon_usb_shim/force_disable; do
    [ -e "$fd" ] && echo 0 > "$fd" 2>/dev/kmsg
done
mount -t debugfs none /sys/kernel/debug 2>/dev/null || true
mark "usb gate + debugfs"

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
    /sbin/fsck.ext4 -p /dev/$sdcard_partition 2>/dev/null
    mount -t auto -o rw,noatime,nodiratime /dev/$sdcard_partition /sdcard 2>/dev/null
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
    mount -o noatime,nodiratime,sync,rw,loop $ANDROID_MEDIA_DIR/asteroidos.ext4 /loop 2>/dev/null \
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
# ¿Hay systemd real? → switch_root (señal de boot completo, watchdog off)
# ════════════════════════════════════════════════════════════════════
if [ -x "$BOOT_DIR/lib/systemd/systemd" ]; then
    mark "rootfs ok, switch_root"
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
# Sin rootfs: intentar el gadget USB/adb.
# La phy ya completó (PH=43) y el glue G7; si UDC aparece, esto da adb.
# ════════════════════════════════════════════════════════════════════
mkdir -p /sys/kernel/config
mount -t configfs none /sys/kernel/config 2>/dev/null

ZU=.sbu
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