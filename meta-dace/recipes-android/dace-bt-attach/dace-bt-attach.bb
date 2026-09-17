SUMMARY = "Attach del BT WCN3988 por UART (btattach -P qca) para dace"
DESCRIPTION = "El BT del T5 (WCN3988) va por /dev/ttyHS0 con la linea QCA del \
kernel (hci_uart + btqca). El driver btqca descarga el firmware qca/apbtfw*.tlv \
+ qca/apnv*.bin (receta dace-bt-firmware). El soc_type WCN3988 se fuerza en la \
ruta LDISC con wcn3988-bt.patch. Servicio antes de bluetooth.service."
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"
COMPATIBLE_MACHINE = "dace"

SRC_URI = "file://dace-btattach.service"

S = "${WORKDIR}"

do_install() {
    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${UNPACKDIR}/dace-btattach.service \
        ${D}${systemd_system_unitdir}/dace-btattach.service
}

FILES:${PN} = "${systemd_system_unitdir}/dace-btattach.service"

inherit systemd
SYSTEMD_SERVICE:${PN} = "dace-btattach.service"
SYSTEMD_AUTO_ENABLE:${PN} = "enable"

RDEPENDS:${PN} += "bluez5"
