SUMMARY = "Modulos vendor stock (Mobvoi) para el tactil Zinitix y la pila slate de eventos"
DESCRIPTION = "Los .ko prebuilt del OTA stock, ya PARCHEADOS para nuestro kernel \
(SIN __versions: carga forzada; SCS NOPeado y reloc de exit recolocado, ver \
files/README.txt y patch-stock-module.py). Sin el parche SCS, el boot del rootfs \
crashea (x18 es basura en nuestro kernel: no tiene SHADOW_CALL_STACK). Requieren \
el slot ABI de cfi_check en struct module (dace-module-cfi-abi-slot.patch). Se \
instalan FUERA de /lib/modules para que udev/depmod no los autoloade: los carga \
dace-lxc-hal-start.sh tras los HAL de display, en orden, ver AGENTS.md §5."
LICENSE = "GPL-2.0-only"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/GPL-2.0-only;md5=801f80980d171dd6425610833a22dbe6"

SRC_URI = "file://slate_events_bridge.ko \
           file://slate_events_bridge_rpmsg.ko \
           file://slate_mobvoi_rpc.ko \
           file://slate_mobvoi_rpc_rpmsg.ko \
           file://zinitix-i2c.ko"

S = "${UNPACKDIR}"

# Destino deliberadamente FUERA de /lib/modules: sin depmod, sin autoload de
# udev (el coldplug de modulos vendor dejaba el SoC en reset, AGENTS §7/§11).
# Orden de carga exacto (dace-lxc-hal-start.sh):
#   slate_events_bridge_rpmsg -> slate_events_bridge ->
#   slate_mobvoi_rpc_rpmsg -> slate_mobvoi_rpc -> zinitix-i2c
do_install() {
    install -d ${D}${nonarch_base_libdir}/dace-vendor-modules
    for f in slate_events_bridge.ko slate_events_bridge_rpmsg.ko \
             slate_mobvoi_rpc.ko slate_mobvoi_rpc_rpmsg.ko zinitix-i2c.ko; do
        install -m 0644 ${UNPACKDIR}/${f} \
            ${D}${nonarch_base_libdir}/dace-vendor-modules/${f}
    done
}

FILES:${PN} = "${nonarch_base_libdir}/dace-vendor-modules/*"
# Sin strip ni split de debug: son prebuilts del stock, no tocar los binarios.
INHIBIT_PACKAGE_STRIP = "1"
INHIBIT_PACKAGE_DEBUG_SPLIT = "1"
# Los .ko son del KERNEL (aarch64); el userland del paquete es ARM32: el QA de
# arch siempre fallaria. Son modulos de kernel, no binarios de userspace.
INSANE_SKIP:${PN} = "arch"
# Nada que stagear al sysroot: evita que el strip del sysroot (crosstool) intente
# procesar los .ko aarch64 ("file format not recognized").
SYSROOT_DIRS = ""
PACKAGE_ARCH = "${MACHINE_ARCH}"
