FILESEXTRAPATHS:prepend:dace := "${THISDIR}/${PN}:"
COMPATIBLE_MACHINE:dace = "dace"

# Dace uses an early modprobe loop from /etc/modules.load.dace. The loop is
# required because dace's eMMC driver (sdhci_msm.ko) and ~85 other vendor
# drivers are =m on this GKI kernel.
SRC_URI:append:dace = " file://init.sh file://modules.load.dace file://google-extcon-usb-shim.conf file://dace-syncfs"

do_install:append:dace() {
    install -m 0755 ${UNPACKDIR}/init.sh ${D}/init

    # Dependency-ordered module list (msm_geni_serial -> q6v5_pas chain -> ADSP
    # audio chain -> nanohub MCU -> WLAN), matching what UBPorts uses.
    install -m 0644 -D ${UNPACKDIR}/modules.load.dace ${D}/etc/modules.load.dace

    # google-extcon-usb-shim defaults to USB force-disable=1 from DT ("USB
    # force-disable:1 changeable:1 dt-support:1 disable-param:0x1"), which
    # prevents dwc3-msm from ever creating a UDC -> no USB peripheral, no adb.
    # Override via modprobe.d so the param applies the moment the busybox
    # modprobe loop loads the shim module.
    install -m 0644 -D ${UNPACKDIR}/google-extcon-usb-shim.conf ${D}/etc/modprobe.d/google-extcon-usb-shim.conf

    # dace-syncfs: forces the F2FS checkpoint (syncfs) on /sdcard. Needed
    # because busybox sync does NOT checkpoint and a 'reboot -f' from the
    # initramfs leaves F2FS dirty -> recovery -> the freshly written files (e.g.
    # /sdcard/dace-mode) are reverted. Usage:  dace-syncfs
    install -m 0755 -D ${UNPACKDIR}/dace-syncfs ${D}/usr/bin/dace-syncfs
}

FILES:${PN}:append:dace = " /etc/modules.load.dace /etc/modprobe.d/google-extcon-usb-shim.conf /usr/bin/dace-syncfs"

# dace-syncfs is a prebuilt static ARM ELF (syncfs syscall): do_package's debug
# split leaves /usr/bin/.debug/dace-syncfs, and since this recipe only has ${PN}
# (PACKAGES="${PN}", no -dbg) the installed-vs-shipped QA fires. In the initramfs
# we do not want symbols or strip.
INHIBIT_PACKAGE_DEBUG_SPLIT = "1"
INHIBIT_PACKAGE_STRIP = "1"
