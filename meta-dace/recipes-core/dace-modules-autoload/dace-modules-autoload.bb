SUMMARY = "Auto-load post-rootfs dace kernel modules at boot"
DESCRIPTION = "Drops a systemd-modules-load.d config that loads the WLAN, \
ALSA/ASoC machine + codec, and BT slim modules shipped on the rootfs by \
linux-dace-modules. These cannot live in modules.load.dace because \
their .ko files are only reachable AFTER pivot_root to the rootfs (the \
VKB ramdisk holds only the boot-critical modules)."
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"
COMPATIBLE_MACHINE = "dace"

SRC_URI = "file://dace-post-rootfs.conf"

do_install() {
    install -d -m 0755 ${D}${sysconfdir}/modules-load.d
    install -m 0644 ${UNPACKDIR}/dace-post-rootfs.conf ${D}${sysconfdir}/modules-load.d/dace-post-rootfs.conf
}

FILES:${PN} = "${sysconfdir}/modules-load.d/dace-post-rootfs.conf"

RDEPENDS:${PN} = "linux-dace-modules"
