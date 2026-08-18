FILESEXTRAPATHS:prepend:ticwatch-pro-5 := "${THISDIR}/${PN}:"

SRC_URI:append:ticwatch-pro-5 = " file://nonplat_property_contexts \
    file://plat_property_contexts \
    file://default.prop"

do_install:append:ticwatch-pro-5() {
    install -m 0644 ${UNPACKDIR}/nonplat* ${D}/
    install -m 0644 ${UNPACKDIR}/plat* ${D}/
    install -m 0644 ${UNPACKDIR}/default.prop ${D}/
}

FILES:${PN}:append:ticwatch-pro-5 = " /nonplat* /plat* /default.prop"