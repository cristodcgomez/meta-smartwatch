SUMMARY = "Firmware QCA del BT del TicWatch Pro 5 (dace): familia 'ap' y 'sl'"
DESCRIPTION = "Extraido de la particion stock 'bluetooth' (/dev/mmcblk0p18, FAT16): \
/image/apbtfw11.tlv + apnv11.bin (familia 'ap' del WCN3988) y \
/image/slbtfw20.mbn + slnv20.bin (familia 'sl'). \
OJO (20-09-2026): con el SOC en modo **slate** (DT compatible qcom,qcc5100, que es \
lo que hay en stock) el HAL de Qualcomm pide la familia **sl**: \
  File open /vendor/firmware/slbtfw20.mbn succeeded   <- parche (376 segmentos)
  File open /vendor/firmware/slnv20.bin succeeded     <- NVM (17 segmentos)
Sin esos dos ficheros el chip arranca (contesta Get Version) pero no recibe \
el patch y el HAL muere con 'Controller Init failed'. La familia 'ap' se deja \
por si algun dia se usa la ruta btattach/btqca (soc cherokee)."
LICENSE = "CLOSED"
COMPATIBLE_MACHINE = "dace"

SRC_URI = "file://qca/apbtfw11.tlv \
           file://qca/apnv11.bin \
           file://qca/slbtfw20.mbn \
           file://qca/slnv20.bin"

S = "${UNPACKDIR}"

do_install() {
    install -d ${D}${nonarch_base_libdir}/firmware/qca
    install -m 0644 ${UNPACKDIR}/qca/apbtfw11.tlv ${D}${nonarch_base_libdir}/firmware/qca/
    install -m 0644 ${UNPACKDIR}/qca/apnv11.bin  ${D}${nonarch_base_libdir}/firmware/qca/
    install -m 0644 ${UNPACKDIR}/qca/slbtfw20.mbn ${D}${nonarch_base_libdir}/firmware/qca/
    install -m 0644 ${UNPACKDIR}/qca/slnv20.bin  ${D}${nonarch_base_libdir}/firmware/qca/
}

FILES:${PN} = "${nonarch_base_libdir}/firmware/qca/*"
