SUMMARY = "dace: persistent power/suspend log (verification without adb)"
DESCRIPTION = "Service that every 30 s writes suspend_stats, autosleep, wake \
locks, battery capacity and active wakeup_sources to \
/var/log/dace-power.log. Needed because when smblite loads the 'usb' psy \
appears and usb-moded may switch the USB mode to mass storage (adb is lost), \
so suspend verification cannot depend on a live adb session."
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