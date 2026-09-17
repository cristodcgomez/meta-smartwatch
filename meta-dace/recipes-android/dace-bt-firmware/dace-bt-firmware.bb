SUMMARY = "Firmware QCA WCN3988 (Bluetooth) del TicWatch Pro 5 (dace)"
DESCRIPTION = "Extraido de la particion stock 'bluetooth' (/dev/mmcblk0p18, FAT16, \
/image/apbtfw11.tlv + apnv11.bin). Es el firmware de la familia 'ap' del WCN3988: \
lo pide el driver btqca al hacer btattach -P qca sobre /dev/ttyHS0."
LICENSE = "CLOSED"
COMPATIBLE_MACHINE = "dace"

SRC_URI = "file://qca/apbtfw11.tlv \
           file://qca/apnv11.bin"

S = "${UNPACKDIR}"

do_install() {
    install -d ${D}${nonarch_base_libdir}/firmware/qca
    install -m 0644 ${UNPACKDIR}/qca/apbtfw11.tlv ${D}${nonarch_base_libdir}/firmware/qca/
    install -m 0644 ${UNPACKDIR}/qca/apnv11.bin  ${D}${nonarch_base_libdir}/firmware/qca/
}

FILES:${PN} = "${nonarch_base_libdir}/firmware/qca/*"
