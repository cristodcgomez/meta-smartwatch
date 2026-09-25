#!/bin/sh
# Recreate the dm-linear mappings for the TicWatch Pro 5's (monaco/SW5100)
# stock Wear OS 13 partitions, which live inside the dynamic partition
# "super" (/dev/mmcblk0p7, 4 GiB), and mount them so the LXC container can
# bind them into its rootfs and libhybris can load the Android HALs.
#
# Tables read from the super's LP metadata with lpdump on a dump of the first
# 256 KiB of mmcblk0p7. The metadata geometry is at offset 4096 (NOT 0 --
# LP_PARTITION_RESERVED_BYTES), which is why an LP-magic check at offset 0
# fails. Every partition is a SINGLE extent (the Pixel Watch 2, aurora, had
# system_b fragmented in four pieces):
#
#   system       0 .. 2710904  linear super 2048       (1.29 GiB)
#   vendor       0 ..  580783  linear super 2712952    (283 MiB)
#   product      0 ..  705423  linear super 3293736    (344 MiB)
#   system_ext   0 ..  296631  linear super 3999160    (145 MiB)
#   vendor_dlkm  0 ..  124783  linear super 4295792
#   system_dlkm  0 ..     679  linear super 4420576
#
# The T5 is a single-slot device, so the devices have NO _b suffix.

set -e

SUPER="/dev/mmcblk0p7"

if [ ! -b "$SUPER" ]; then
    echo "dace-vendor-mount: $SUPER not present, aborting" >&2
    exit 1
fi

# Sin metadata LP no hay Wear OS que mapear: no es un error fatal (permite
# arrancar en un T5 con el super vacio).
# OJO: comparar con los BYTES ("gDla"), no con od -tx4 (que los da al reves
# en little-endian: 616c4467, no 67446c61). Con la comparacion mala el script
# hacia exit 0 SIN CREAR NADA y el servicio parecia OK (bug real, cazado en
# el reloj: /dev/mapper vacio y /android sin montar tras 'active (exited)').
if [ "$(dd if=$SUPER bs=1 skip=4096 count=4 2>/dev/null)" != "gDla" ]; then
    echo "dace-vendor-mount: $SUPER sin metadata LP (geometria ausente), nada que hacer"
    exit 0
fi

dm_create_if_missing() {
    name=$1; shift
    table=$1
    if [ -b /dev/mapper/$name ]; then
        echo "dace-vendor-mount: /dev/mapper/$name already exists, skipping dm setup"
    else
        printf "%s" "$table" | dmsetup create $name
        echo "dace-vendor-mount: created /dev/mapper/$name"
    fi
}

dm_create_if_missing system      "0 2710904 linear $SUPER 2048"
dm_create_if_missing vendor      "0 580784 linear $SUPER 2712952"
dm_create_if_missing product     "0 705424 linear $SUPER 3293736"
dm_create_if_missing system_ext  "0 296632 linear $SUPER 3999160"
dm_create_if_missing vendor_dlkm "0 124784 linear $SUPER 4295792"
dm_create_if_missing system_dlkm "0 680 linear $SUPER 4420576"

mount_if_unmounted() {
    src=$1; dst=$2
    mkdir -p $dst
    if mountpoint -q $dst; then
        echo "dace-vendor-mount: $dst already mounted"
    else
        mount -o ro,nosuid,nodev $src $dst
        echo "dace-vendor-mount: $dst mounted from $src"
    fi
}

# /android/* es lo que el contenedor LXC bind-montea dentro de su rootfs
# (dace-lxc-android-start.sh hace bind de /android/vendor -> $ROOTFS/vendor).
mount_if_unmounted /dev/mapper/system      /android/system
mount_if_unmounted /dev/mapper/vendor      /android/vendor
mount_if_unmounted /dev/mapper/product     /android/product
mount_if_unmounted /dev/mapper/system_ext  /android/system_ext
mount_if_unmounted /dev/mapper/vendor_dlkm /android/vendor_dlkm
mount_if_unmounted /dev/mapper/system_dlkm /android/system_dlkm

# Symlinks de compatibilidad: /vendor y /system son donde Halium / libhybris
# esperan encontrar los HAL .so y las libs Android. Sin ellos, cada daemon
# (sensorfwd, ngfd-droid-vibrator, bluebinder, el QPA hwcomposer del launcher)
# necesitaria su propio HYBRIS_LD_LIBRARY_PATH.
#
#   /vendor -> /android/vendor (el vendor_b ext4 del T5)
#   /system -> el system del CONTENEDOR (/var/lib/lxc/android/rootfs/system),
#              NO /android/system: el system stock del T5 es un mirror ext4
#              crudo, mientras que el del contenedor ya tiene el layout AOSP
#              con los apex resueltos (libhardware.so, sensors*.so, ...).
#
# OJO: el paquete android-system deja /system -> /usr/libexec/hal-droid/system.
# Si existe ese symlink lo sustituimos (por eso lo comprobamos antes).
if [ -L /system ] && [ "$(readlink /system)" = "/usr/libexec/hal-droid/system" ]; then
    rm -f /system
fi
[ -L /vendor ] || { rm -rf /vendor 2>/dev/null; ln -sf /android/vendor /vendor; }
[ -L /system ] || { rm -rf /system 2>/dev/null; ln -sf /var/lib/lxc/android/rootfs/system /system; }

# ─ Firmware del modem/WLAN (como aurora) ────────────────────────────────
# El firmware del subsystem modem (modem.mdt + modem.b00..b29), el del WLAN
# (wlanmdsp.mbn) y los BDF (bdwlan.*) viven en /vendor/firmware_mnt/image, pero
# firmware_class.path por defecto apunta a /vendor/firmware (que no llega ahi).
# Sin el path, remoteproc-mss no encuentra modem.mdt (ENOENT) y queda offline,
# lo que rompe WLAN (icnss espera el WLFW del modem) y BT (la init del QCA SoC
# necesita el blob del modem). Aurora lo hace asi en su aurora-vendor-mount.sh.
if [ -b /dev/mmcblk0p14 ] && ! mountpoint -q /vendor/firmware_mnt 2>/dev/null; then
    mkdir -p /vendor/firmware_mnt 2>/dev/null || true
    mount -t vfat -o ro,uid=1000,gid=1000,fmask=0337,dmask=0227 \
        /dev/mmcblk0p14 /vendor/firmware_mnt 2>/dev/null || true
fi
if [ -f /vendor/firmware_mnt/image/modem.mdt ]; then
    echo /vendor/firmware_mnt/image > /sys/module/firmware_class/parameters/path && \
        echo "dace-vendor-mount: firmware_class.path -> /vendor/firmware_mnt/image"
fi
# Este servicio corre muy pronto (Before=local-fs.target); el adsp_loader y los
# nodos remoteproc pueden aparecer despues. Esperar (max ~30 s) a que existan
# para no saltarnos el arranque del ADSP/modem (le pasaba: adsp=mss=offline).
i=0
while [ $i -lt 150 ] && [ ! -e /sys/kernel/boot_adsp/boot ]; do
    sleep 0.2; i=$((i+1))
done
while [ $i -lt 150 ] && [ ! -e /sys/class/remoteproc/remoteproc0 ]; do
    sleep 0.2; i=$((i+1))
done
while [ $i -lt 150 ] && [ ! -e /sys/class/remoteproc/remoteproc1 ]; do
    sleep 0.2; i=$((i+1))
done

# ─ Habilitar RECOVERY en los remoteproc (clave para el DOG del modem) ──────
# qcom_q6v5_pas hard-codea rproc->recovery_disabled = true (linea 1047 del
# source). Con recovery deshabilitado, un fatal error del firmware (p.ej. el
# DOG "stalled initialization" del modem, que dispara a los ~40 s) NO se
# recupera: el kernel hace panic y el SoC se resetea
# ("rproc recovery state: disabled -> device crash"). aurora CONVIVE con los
# crashes del modem (su propia nota: "modem perpetually crashes & recovers").
# Habilitando recovery desde sysfs, el mismo DOG pasa a
# "recovery state: enabled and kick recovery process" y el reloj sobrevive;
# el modem se relanza solo. Verificado 19-09-2026: crash #1/#2 cada ~40 s con
# el reloj estable y adb vivo (antes, reset inmediato).
for r in /sys/class/remoteproc/remoteproc*; do
    [ -e "$r/recovery" ] || continue
    [ "$(cat "$r/recovery" 2>/dev/null)" = "enabled" ] && continue
    echo enabled > "$r/recovery" 2>/dev/null && \
        echo "dace-vendor-mount: $(basename $r) recovery -> enabled" > /dev/kmsg || true
done
# OJO: el modem (remoteproc1) tambien queda con recovery=enabled: el DOG de su
# firmware (si algun dia se arranca para la WLAN) NO resetea el SoC; el driver
# lo relanza solo (fue el fix del 19-09-2026).

# ─ Arrancar el ADSP (el fw del modem/WLAN lo espera vivo) ───────────────────
# El MODEM (remoteproc1) ya NO se arranca aqui. En dace el WLAN necesita al
# menos el orden: cadena qcacld/icnss2 cargada -> MCU slate UP (icnss2 usa
# qcom,is_slate_rfa y espera el SSR de "slatefw") -> modem. Arrancarlo tan
# temprano (antes del slate y de la cadena WLAN) solo alimentaba el crash-loop
# `DOG detects stalled initialization`. El arranque del modem vive ahora en
# dace-wlan.sh (gateado tras /etc/dace-kick-modem, ver PLAN-WLAN.md).
# El fw del modem espera al ADSP vivo via tmr_slave2; sin ADSP el watchdog del
# modem cuelga con "DOG detects stalled initialization" y se resetea en bucle.
# OJO: monaco_adsp_resource NO tiene .auto_boot, asi que el ADSP no arranca
# solo: hay que escribir en /sys/kernel/boot_adsp/boot (sysfs que crea
# adsp_loader_dlkm). El contenedor tambien lo hace, pero TARDE.
if [ -e /sys/kernel/boot_adsp/boot ] && \
   [ "$(cat /sys/class/remoteproc/remoteproc0/state 2>/dev/null)" != "running" ]; then
    echo 1 > /sys/kernel/boot_adsp/boot 2>/dev/null || true
    i=0
    while [ $i -lt 100 ] && \
          [ "$(cat /sys/class/remoteproc/remoteproc0/state 2>/dev/null)" != "running" ]; do
        sleep 0.2; i=$((i+1))
    done
    echo "dace-vendor-mount: ADSP (remoteproc0) state=$(cat /sys/class/remoteproc/remoteproc0/state 2>/dev/null)" > /dev/kmsg || true
fi

# Vigia: durante 90 s registra en /dev/kmsg el estado de adsp/mss cada 5 s.
# Asi el stall del modem (DOG a los ~40 s) queda fechado en la consola aunque
# el journal se pierda en el reset.
(
    i=0
    while [ $i -lt 18 ]; do
        sleep 5; i=$((i+1))
        echo "dace-vendor-mount: WATCH t=$((i*5))s adsp=$(cat /sys/class/remoteproc/remoteproc0/state 2>/dev/null) mss=$(cat /sys/class/remoteproc/remoteproc1/state 2>/dev/null)" > /dev/kmsg || true
    done
) &


echo "dace-vendor-mount: OK"
