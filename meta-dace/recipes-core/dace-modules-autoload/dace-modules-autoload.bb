SUMMARY = "dace: modulos post-rootfs (lista de autoload + blacklist de vendor)"
DESCRIPTION = "Los .ko de /lib/modules/<krel>/vendor/ (linux-dace-modules) \
solo son alcanzables DESPUES del switch_root al rootfs (el ramdisk del VKB \
solo lleva los criticos del boot), asi que su carga va por \
systemd-modules-load.d/dace-post-rootfs.conf. \
OJO: ese fichero se entrega CON LA LISTA COMENTADA porque esa cadena de \
modulos (WLAN/icnss2 + ASoC + BT) tumba el SoC a EDL a los ~10 s: el \
disparador real es el coldplug de udev por modalias, pero \
systemd-modules-load hace 'modprobe <modulo>' explicito y 'blacklist' NO \
bloquea eso (solo los alias). De ahi que ademas se instale \
/etc/modprobe.d/00-dace-vendor-blacklist.conf (76 modulos, bloquea a udev) y \
que la lista de autoload tenga que quedar comentada hasta bisecar el culpable: \
descomentar lineas es la forma de bisecarlo."
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"
COMPATIBLE_MACHINE = "dace"

SRC_URI = "file://dace-post-rootfs.conf \
           file://dace-vendor-blacklist.conf"

do_install() {
    install -d -m 0755 ${D}${sysconfdir}/modules-load.d
    install -m 0644 ${UNPACKDIR}/dace-post-rootfs.conf ${D}${sysconfdir}/modules-load.d/dace-post-rootfs.conf
    # Los modulos vendor los carga udev (no modules-load) y tumban el SoC: se
    # bloquean con modprobe.d (ver el comentario del propio fichero).
    install -d -m 0755 ${D}${sysconfdir}/modprobe.d
    install -m 0644 ${UNPACKDIR}/dace-vendor-blacklist.conf ${D}${sysconfdir}/modprobe.d/00-dace-vendor-blacklist.conf
}

FILES:${PN} = "${sysconfdir}/modules-load.d/dace-post-rootfs.conf \
               ${sysconfdir}/modprobe.d/00-dace-vendor-blacklist.conf"

RDEPENDS:${PN} = "linux-dace-modules"
