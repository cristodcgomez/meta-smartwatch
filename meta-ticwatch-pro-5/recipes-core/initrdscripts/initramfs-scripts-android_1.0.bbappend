FILESEXTRAPATHS:prepend:ticwatch-pro-5 := "${THISDIR}/${PN}:"
COMPATIBLE_MACHINE:ticwatch-pro-5 = "ticwatch-pro-5"
SRC_URI:append:ticwatch-pro-5 = " file://init.machine.sh \
    file://ld.config.28.txt \
    file://init.sh"

do_install:append:ticwatch-pro-5() {
    install -m 0755 ${UNPACKDIR}/init.machine.sh ${D}/init.machine
    install -m 0755 ${UNPACKDIR}/ld.config.28.txt ${D}/ld.config.28.txt
    # Debug init: fuerza adb (configfs) y se queda en initramfs (nunca rootfs)
    install -m 0755 ${UNPACKDIR}/init.sh ${D}/init
}

RDEPENDS:${PN}:append:ticwatch-pro-5 = " msm-fb-refresher"
FILES:${PN}:append:ticwatch-pro-5 = " /ld.config.28.txt /init.machine /init"