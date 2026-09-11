SUMMARY = "dace: /home/ceres/.cache en tmpfs (el cache de shaders de Qt)"
DESCRIPTION = "Sin esto, un rootfs lleno rompe el render de Qt y el compositor \
arranca con la pantalla negra (ver AGENTS §15)."
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"
COMPATIBLE_MACHINE = "dace"

SRC_URI = "file://home-ceres-.cache.mount"

do_install() {
    install -d ${D}${systemd_unitdir}/system
    install -m 0644 ${UNPACKDIR}/home-ceres-.cache.mount \
        ${D}${systemd_unitdir}/system/home-ceres-.cache.mount
    install -d ${D}${sysconfdir}/systemd/system/local-fs.target.wants
    ln -sf ${systemd_unitdir}/system/home-ceres-.cache.mount \
        ${D}${sysconfdir}/systemd/system/local-fs.target.wants/home-ceres-.cache.mount
}

SYSTEMD_SERVICE:${PN} = "home-ceres-.cache.mount"
FILES:${PN} = "${systemd_unitdir}/system/home-ceres-.cache.mount \
               ${sysconfdir}/systemd/system/local-fs.target.wants/home-ceres-.cache.mount"
