SUMMARY = "dace: log persistente de energia/suspend (verificacion sin adb)"
DESCRIPTION = "Servicio que cada 30 s escribe suspend_stats, autosleep, wake \
locks, capacidad de bateria y wakeup_sources activas a \
/var/log/dace-power.log. Necesario porque al cargar el smblite aparece la psy \
'usb' y usb-moded puede cambiar el modo USB a mass storage (se pierde adb), \
asi que la verificacion del suspend no puede depender de una sesion adb viva."
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"
COMPATIBLE_MACHINE = "dace"

inherit systemd

SRC_URI = "file://dace-powerlog.sh \
           file://dace-powerlog.service"

SYSTEMD_PACKAGES = "${PN}"
SYSTEMD_SERVICE:${PN} = "dace-powerlog.service"
SYSTEMD_AUTO_ENABLE:${PN} = "enable"

do_install() {
    install -d -m 0755 ${D}${libexecdir}
    install -m 0755 ${UNPACKDIR}/dace-powerlog.sh ${D}${libexecdir}/dace-powerlog.sh
    install -d -m 0755 ${D}${systemd_system_unitdir}
    install -m 0644 ${UNPACKDIR}/dace-powerlog.service ${D}${systemd_system_unitdir}/dace-powerlog.service
}

FILES:${PN} = "${libexecdir}/dace-powerlog.sh \
               ${systemd_system_unitdir}/dace-powerlog.service"