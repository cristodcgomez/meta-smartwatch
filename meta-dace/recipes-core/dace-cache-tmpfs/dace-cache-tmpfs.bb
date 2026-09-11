SUMMARY = "dace: /home/ceres/.cache en tmpfs (el cache de shaders de Qt)"
DESCRIPTION = "Sin esto, un rootfs lleno rompe el render de Qt y el compositor \
arranca con la pantalla negra (ver AGENTS §15)."
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"
COMPATIBLE_MACHINE = "dace"

SRC_URI = "file://home-ceres-.cache.mount \
           file://home-ceres-.config.mount \
           file://home-ceres-.local.mount"

do_install() {
    install -d ${D}${systemd_unitdir}/system
    install -d ${D}${sysconfdir}/systemd/system/local-fs.target.wants
    for m in home-ceres-.cache home-ceres-.config home-ceres-.local; do
        install -m 0644 ${UNPACKDIR}/$m.mount ${D}${systemd_unitdir}/system/$m.mount
        ln -sf ${systemd_unitdir}/system/$m.mount \
            ${D}${sysconfdir}/systemd/system/local-fs.target.wants/$m.mount
    done
}

SYSTEMD_SERVICE:${PN} = "home-ceres-.cache.mount home-ceres-.config.mount home-ceres-.local.mount"
FILES:${PN} = "${systemd_unitdir}/system/home-ceres-.cache.mount \
               ${systemd_unitdir}/system/home-ceres-.config.mount \
               ${systemd_unitdir}/system/home-ceres-.local.mount \
               ${sysconfdir}/systemd/system/local-fs.target.wants/home-ceres-.cache.mount \
               ${sysconfdir}/systemd/system/local-fs.target.wants/home-ceres-.config.mount \
               ${sysconfdir}/systemd/system/local-fs.target.wants/home-ceres-.local.mount"
