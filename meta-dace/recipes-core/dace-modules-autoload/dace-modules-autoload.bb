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

# 18-09-2026: la lista ya NO va comentada. Se comprobo que kmod aplica el
# blacklist como *deny-list* tambien al `modprobe` de systemd-modules-load
# ("Module 'wlan' is deny-listed (by kmod)"), por lo que ese servicio no
# sirve para cargar la cadena. La mete a mano dace-modules-load.service, que
# hace `modprobe` explicito (eso SI ignora la deny-list) leyendo el mismo
# /etc/modules-load.d/dace-post-rootfs.conf.
inherit systemd

SRC_URI = "file://dace-post-rootfs.conf \
           file://dace-vendor-blacklist.conf \
           file://dace-modules-load.sh \
           file://dace-modules-load.service"

SYSTEMD_PACKAGES = "${PN}"
SYSTEMD_SERVICE:${PN} = "dace-modules-load.service"
SYSTEMD_AUTO_ENABLE:${PN} = "enable"

do_install() {
    install -d -m 0755 ${D}${sysconfdir}/modules-load.d
    install -m 0644 ${UNPACKDIR}/dace-post-rootfs.conf ${D}${sysconfdir}/modules-load.d/dace-post-rootfs.conf
    # Los modulos vendor los carga udev (no modules-load) y tumban el SoC: se
    # bloquean con modprobe.d (ver el comentario del propio fichero).
    install -d -m 0755 ${D}${sysconfdir}/modprobe.d
    install -m 0644 ${UNPACKDIR}/dace-vendor-blacklist.conf ${D}${sysconfdir}/modprobe.d/00-dace-vendor-blacklist.conf
    # Carga explicita (la deny-list del blacklist bloquea a systemd-modules-load).
    install -d -m 0755 ${D}${libexecdir}
    install -m 0755 ${UNPACKDIR}/dace-modules-load.sh ${D}${libexecdir}/dace-modules-load.sh
    install -d -m 0755 ${D}${systemd_system_unitdir}
    install -m 0644 ${UNPACKDIR}/dace-modules-load.service ${D}${systemd_system_unitdir}/dace-modules-load.service
}

FILES:${PN} = "${sysconfdir}/modules-load.d/dace-post-rootfs.conf \
               ${sysconfdir}/modprobe.d/00-dace-vendor-blacklist.conf \
               ${libexecdir}/dace-modules-load.sh \
               ${systemd_system_unitdir}/dace-modules-load.service"

RDEPENDS:${PN} = "linux-dace-modules"
