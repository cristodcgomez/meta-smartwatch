SUMMARY = "Recreate the dm-linear mapping for dace's /vendor partition and mount it"
DESCRIPTION = "On stock Android-13/Halium-13, dace's vendor partition is a \
logical partition packed inside /super (/dev/mmcblk0p80 on slot B). Android \
first-stage init parses LP metadata and creates /dev/mapper/vendor_b via dm-linear; \
our shell-script initramfs doesn't, and the Android-9 init we ship at \
/usr/libexec/hal-droid/system/bin/init pre-dates dynamic partitions and \
can't either. Workaround: hardcode the dm table observed from a working \
UBPorts install (dmsetup table | grep vendor_b), recreate it at boot \
before android-init runs. Avoids duplicating ~234 MB of vendor data into \
our rootfs.img."

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

    install -d ${D}/vendor
}

SYSTEMD_SERVICE:${PN} = "dace-vendor-mount.service"
FILES:${PN} = "${libexecdir}/dace-vendor-mount.sh \
               ${systemd_unitdir}/system/dace-vendor-mount.service \
               ${sysconfdir}/systemd/system/local-fs.target.wants/dace-vendor-mount.service \
               /vendor"
