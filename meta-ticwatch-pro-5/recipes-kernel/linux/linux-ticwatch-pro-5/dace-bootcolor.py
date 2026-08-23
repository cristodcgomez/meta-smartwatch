#!/usr/bin/env python3
# dace kernel source fixes:
#  1. boot-color debug (RED/AZUL/AMARILLO) en init/main.c
#  2. slatecom_interface.c: hacer ssr_register() condicional a que
#     qcom_register_ssr_notifier exista (QCOM_RPROC_COMMON built-in).
#     Es tristate ciego y no se puede forzar =y; sin el stub el link de
#     vmlinux rompe con 'undefined symbol: qcom_register_ssr_notifier'.
#
# ── v2 (2026-08-24): corrección crítica de la telemetría ──
# La v1 usaba ioremap_wc() sobre 0x5c000000. Esa región (splash_region) es
# RAM reservada SIN no-map en el DTB del dace → pfn_valid()=true → el
# __ioremap de arm64 hace WARN_ON y devuelve NULL. Consecuencia: ROJO NUNCA
# se pintó (ni en QEMU ni en el reloj) y además se inyectaba un WARN dentro
# de start_kernel. Todo el diagnóstico "el kernel no llega a start_kernel"
# basado en la ausencia de ROJO queda INVALIDADO.
# La v2 usa phys_to_virt() (la región está en el linear map) sin ninguna
# asignación (kmalloc NO existe aún en start_kernel: slab no está up).
# Añade además /sys/kernel/dace_color para que el init pinte VERDE desde
# userspace, y AMARILLO en kernel_init (justo antes de ejecutar /init).
import sys, os

def patch_bootcolor(path):
    src = open(path).read()
    if 'ioremap_wc(DACE_SPLASH_PHYS' in src:
        sys.exit("bootcolor: código v1 (ioremap, ROTO) presente en %s — "
                 "ejecuta: bitbake -c cleansstate linux-ticwatch-pro-5" % path)
    if 'dace_boot_color' in src:
        print("bootcolor: v2 ya inyectado")
        return
    HELPER = '''
/* ---- dace boot-color debug v2 (continuous-splash fb @ 0x5c000000) ---- */
#define DACE_SPLASH_PHYS  0x5c000000ULL
#define DACE_FB_WIDTH     640
#define DACE_FB_HEIGHT    400
#define DACE_FB_NPIX      (DACE_FB_WIDTH * DACE_FB_HEIGHT)

/* splash_region@5c000000 es RAM reservada SIN no-map en el DTB del dace:
 * está en el linear map. ioremap_wc() sobre ella hace WARN_ON+NULL (la v1
 * nunca pintó nada). phys_to_virt() es aritmética pura: sin page tables,
 * sin asignaciones (en start_kernel el slab NO está disponible). */
static void dace_boot_color(u32 argb)
{
	u32 *fb = (u32 *)phys_to_virt((phys_addr_t)DACE_SPLASH_PHYS);
	size_t i;

	if (!fb)
		return;
	for (i = 0; i < DACE_FB_NPIX; i++)
		fb[i] = argb;
	dsb(sy); /* que el scanout del SDE lo vea */
}

static ssize_t dace_color_store(struct kobject *k, struct kobj_attribute *a,
				const char *buf, size_t n)
{
	u32 v = simple_strtoul(buf, NULL, 0);
	if (v)
		dace_boot_color(v);
	return n;
}
static struct kobj_attribute dace_color_attr =
	__ATTR(dace_color, 0200, NULL, dace_color_store);
static int __init dace_color_init(void)
{
	return sysfs_create_file(kernel_kobj, &dace_color_attr.attr);
}
late_initcall(dace_color_init);

asmlinkage __visible void __init __no_sanitize_address start_kernel(void)
'''
    needle = 'asmlinkage __visible void __init __no_sanitize_address start_kernel(void)\n'
    if needle not in src:
        sys.exit("bootcolor: no start_kernel")
    src = src.replace(needle, HELPER, 1)
    if '#include <linux/sysfs.h>' not in src:
        src = src.replace('#include <linux/io.h>',
                          '#include <linux/io.h>\n#include <linux/sysfs.h>\n#include <linux/kobject.h>', 1)
    red_anchor = '\tearly_security_init();\n\tsetup_arch(&command_line);\n'
    red_inject = ('\tearly_security_init();\n\tsetup_arch(&command_line);\n'
                  '\tdace_boot_color(0x00ff0000); /* ROJO: start_kernel alcanzado */\n'
                  '\tpr_err("dace-bootcolor: RED (setup_arch done)\\n");\n')
    if red_anchor not in src:
        sys.exit("bootcolor: no anchor RED")
    src = src.replace(red_anchor, red_inject, 1)
    blue_anchor = '\tdo_basic_setup();\n'
    blue_inject = ('\tdo_basic_setup();\n\n'
                   '\tdace_boot_color(0x000000ff); /* AZUL: initcalls hechos, a por /init */\n'
                   '\tpr_err("dace-bootcolor: BLUE (kernel up, exec init next)\\n");\n')
    if blue_anchor not in src:
        sys.exit("bootcolor: no anchor BLUE")
    src = src.replace(blue_anchor, blue_inject, 1)
    # AMARILLO: entramos en kernel_init (rest_init funcionó; a continuación
    # se ejecuta /init del initramfs). Distingue "kernel completo OK" de
    # "el exec de /init falla".
    kinit_anchor = 'static int __ref kernel_init(void *unused)\n{\n'
    kinit_inject = ('static int __ref kernel_init(void *unused)\n{\n'
                    '\tdace_boot_color(0x00ffff00); /* AMARILLO: kernel_init */\n'
                    '\tpr_err("dace-bootcolor: YELLOW (kernel_init, exec /init next)\\n");\n')
    if kinit_anchor in src:
        src = src.replace(kinit_anchor, kinit_inject, 1)
    else:
        print("bootcolor: aviso, anchor YELLOW no encontrado (kernel_init)")
    open(path, 'w').write(src)
    print("bootcolor: RED + BLUE + YELLOW + /sys/kernel/dace_color inyectados")

def patch_slatecom(path):
    if not os.path.exists(path):
        print("slatecom: %s no existe, skip" % path)
        return
    src = open(path).read()
    if 'IS_BUILTIN(CONFIG_QCOM_RPROC_COMMON)' in src:
        print("slatecom: ya parcheado")
        return
    # envolver el cuerpo de ssr_register en un if IS_BUILTIN
    old = '''static void ssr_register(void)
{
	int i;

	for (i = 0; i < ARRAY_SIZE(service_data); i++) {'''
    new = '''static void ssr_register(void)
{
	int i;

	/* dace fix: qcom_register_ssr_notifier vive en QCOM_RPROC_COMMON, que es
	 * tristate ciego y no siempre built-in. Si no lo esta, el simbolo no
	 * existe y el link de vmlinux rompe. SSR (subsystem-restart notify) no
	 * es necesario para el funcionamiento base de slate/adb; lo hacemos
	 * condicional a que el provider este built-in. */
	if (!IS_BUILTIN(CONFIG_QCOM_RPROC_COMMON)) {
		pr_info("ssr_register: QCOM_RPROC_COMMON no built-in, skip\\n");
		return;
	}

	for (i = 0; i < ARRAY_SIZE(service_data); i++) {'''
    if old not in src:
        sys.exit("slatecom: no se encontro ssr_register")
    src = src.replace(old, new, 1)
    open(path, 'w').write(src)
    print("slatecom: ssr_register condicional OK")

patch_bootcolor(sys.argv[1])
patch_slatecom(sys.argv[2])
