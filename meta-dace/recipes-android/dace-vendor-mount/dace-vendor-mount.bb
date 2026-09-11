SUMMARY = "Recreate the dm-linear mappings for the T5's /super partitions and mount them"
DESCRIPTION = "El T5 (TicWatch Pro 5, monaco/SW5100) lleva Wear OS 13 con \
particiones dinamicas: system/vendor/product/system_ext/vendor_dlkm/system_dlkm \
viven dentro de /super (/dev/mmcblk0p7, 4 GiB) y Android las expone con \
dm-linear desde su first-stage init. Nuestro initramfs es un shell script que \
no parsea la metadata LP, asi que el servicio recrea las tablas (leidas con \
lpdump de la metadata real del super del T5, geometria en el offset 4096) y \
monta los devices en /android/* -- que es lo que el contenedor LXC bind-montea \
dentro de su rootfs -- mas los symlinks /vendor -> /android/vendor y \
/system -> /var/lib/lxc/android/rootfs/system que esperan Halium y libhybris. \
Sin esto el launcher aborta con 'failed to find/load gralloc'."

LICENSE = "GPL-3.0-only"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/GPL-3.0-only;md5=c79ff39f19dfec6d293b95dea7b07891"

COMPATIBLE_MACHINE = "dace"
PACKAGE_ARCH = "${MACHINE_ARCH}"

inherit systemd

SRC_URI = "file://dace-vendor-mount.sh \
           file://dace-vendor-mount.service"
S = "${UNPACKDIR}"

RDEPENDS:${PN} = "lvm2 util-linux-mount"

do_install() {
    install -d ${D}${libexecdir}
    install -m 0755 ${UNPACKDIR}/dace-vendor-mount.sh ${D}${libexecdir}/dace-vendor-mount.sh

    install -d ${D}${systemd_unitdir}/system
    install -m 0644 ${UNPACKDIR}/dace-vendor-mount.service \
        ${D}${systemd_unitdir}/system/dace-vendor-mount.service

    install -d ${D}${sysconfdir}/systemd/system/local-fs.target.wants
    ln -sf ../../../systemd/system/dace-vendor-mount.service \
        ${D}${sysconfdir}/systemd/system/local-fs.target.wants/dace-vendor-mount.service

}

SYSTEMD_SERVICE:${PN} = "dace-vendor-mount.service"
FILES:${PN} = "${libexecdir}/dace-vendor-mount.sh \
               ${systemd_unitdir}/system/dace-vendor-mount.service \
               ${sysconfdir}/systemd/system/local-fs.target.wants/dace-vendor-mount.service"
