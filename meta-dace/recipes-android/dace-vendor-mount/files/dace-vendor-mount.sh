#!/bin/sh
# Recreate the dm-linear mappings for the TicWatch Pro 5's (monaco/SW5100)
# stock Wear OS-13 partitions, which live inside the dynamic partition
# "super" (/dev/mmcblk0p7, 4 GiB), and mount them so libhybris can load the
# Android graphics HALs (gralloc, Adreno EGL) and android-init can start.
#
# Tables read straight from the super's LP metadata (lpdump on a dump of the
# first 256 KiB of mmcblk0p7). Metadata geometry sits at offset 4096 and every
# partition is a SINGLE extent (unlike the Pixel Watch 2, whose system is
# fragmented in 4 pieces):
#
#   system       0 .. 2710904  linear super 2048       (1.29 GiB)
#   vendor       0 ..  580783  linear super 2712952    (283 MiB)
#   product      0 ..  705423  linear super 3293736    (344 MiB)
#   system_ext   0 ..  296631  linear super 3999160    (145 MiB)
#   vendor_dlkm  0 ..  124783  linear super 4295792
#   system_dlkm  0 ..     679  linear super 4420576
#
# NOTE: /dev/mmcblk0p7's first 4096 bytes are zero, which is why an LP magic
# check at offset 0 fails; the geometry is at 4096 (LP_PARTITION_RESERVED_BYTES).

set -e

SUPER="/dev/mmcblk0p7"

if [ ! -b "$SUPER" ]; then
    echo "dace-vendor-mount: $SUPER not present, aborting" >&2
    exit 1
fi

# Sin datos en el super no hay Wear OS que mapear: no es un error fatal.
if [ "$(dd if=$SUPER bs=1 skip=4096 count=4 2>/dev/null | od -An -tx4 | tr -d ' ')" != "67446c61" ]; then
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

# IMPORTANTE: libhybris busca los HALs en /system/lib, /vendor/lib y
# /vendor/lib/egl (paths compilados en libhybris/linker/*.so), asi que los
# mappings tienen que estar en la RAIZ, no solo bajo /android/.
mount_if_unmounted /dev/mapper/system      /system
mount_if_unmounted /dev/mapper/vendor      /vendor
mount_if_unmounted /dev/mapper/product     /product
mount_if_unmounted /dev/mapper/system_ext  /system_ext
mount_if_unmounted /dev/mapper/vendor_dlkm /vendor_dlkm

echo "dace-vendor-mount: OK"
