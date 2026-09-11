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

echo "dace-vendor-mount: OK"
