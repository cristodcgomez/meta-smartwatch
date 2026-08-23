#!/bin/sh

# TicWatch Pro 5 (dace) init.machine.sh — monta el rootfs de Asteroid desde
# userdata y switch_root (estilo aurora: el rootfs vive en la partición
# userdata como ext4, no en super/mapper).
#
# Diferencia clave respecto al esquema viejo: NO abrimos super con
# device-mapper (complejo); el rootfs está directamente en userdata
# (mmcblk0p38, confirmado por `fastboot getvar` = 21.4GB). El init ramdisk
# monta esa partición y hace switch_root.
BOOT_DIR=$1

. /machine.conf
USERDATA=/dev/${sdcard_partition}

mkdir -m 0777 $BOOT_DIR/boot

# Montar userdata (rootfs de Asteroid) de solo lectura primero
mount -t auto -o ro $USERDATA $BOOT_DIR/boot 2>/dev/null || {
    echo "init-dace: userdata ($USERDATA) no monta; fallback a adb (debug)" > /dev/kmsg
    # sin rootfs: adb de rescate
    /usr/bin/android-gadget-setup adb 2>/dev/null
    /usr/bin/adbd
    exit 1
}

# Si la userdata contiene el rootfs (etc/asteroid/machine.conf), switch_root.
if [ -e $BOOT_DIR/etc/asteroid/machine.conf ] ; then
    echo "init-dace: rootfs Asteroid encontrado en $USERDATA; switch_root..." > /dev/kmsg
    # Remontar read-write para systemd
    mount -o remount,rw $USERDATA $BOOT_DIR/boot
    exec switch_root $BOOT_DIR/boot /sbin/init
fi

# No hay rootfs válido: adb de rescate (para empujar el rootfs o depurar)
echo "init-dace: sin rootfs en $USERDATA; adb de rescate" > /dev/kmsg
/usr/bin/android-gadget-setup adb 2>/dev/null
/usr/bin/adbd
exit 1
