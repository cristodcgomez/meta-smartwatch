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

/* Barcode de diagnóstico USB: pitch 466 (panel RM69090 466x466, calibrado
 * en v24). 8 franjas verticales: BLANCA=1, ROJA=0, franja 1 = izquierda,
 * con separadores NEGROS de 4px entre franjas para leer límites sin
 * ambigüedad. Si el buffer contiene "XXXXXXXX YYYYYYYY" (espacio), la mitad
 * superior pinta el primer grupo y la inferior el segundo. */
static void dace_paint_half(u32 *fb, int r0, int r1, const char *bits)
{
	const int P = 466, W = P / 8;
	int r, s, i;

	for (r = r0; r < r1; r++) {
		u32 *row = fb + r * P;

		for (s = 0; s < 8; s++) {
			u32 c = (bits[s] == '1') ? 0x00ffffff : 0x00ff0000;

			for (i = 0; i < W - 4; i++)
				row[s * W + i] = c;
			for (; i < W; i++)
				row[s * W + i] = 0;	 /* separador negro */
		}
	}
}

static void dace_barcode(const char *bits)
{
	u32 *fb = (u32 *)phys_to_virt((phys_addr_t)DACE_SPLASH_PHYS);
	const char *spc;
	int i;

	if (!fb)
		return;
	for (i = 0; i < DACE_FB_NPIX; i++)
		fb[i] = 0;					 /* fondo negro */
	spc = strchr(bits, ' ');
	if (spc && strlen(spc + 1) >= 8)
		dace_paint_half(fb, 233, 466, spc + 1);
	dace_paint_half(fb, 0, spc ? 233 : 466, bits);
	dsb(sy);
}

static ssize_t dace_barcode_store(struct kobject *k, struct kobj_attribute *a,
				  const char *buf, size_t n)
{
	char bits[18] = {0};
	size_t len = n < 17 ? n : 17;

	memcpy(bits, buf, len);
	dace_barcode(bits);
	return n;
}
static struct kobj_attribute dace_barcode_attr =
	__ATTR(dace_barcode, 0200, NULL, dace_barcode_store);

/* ---- dace_text: pinta texto ASCII con fuente 5x7 sobre el splash ----
 * Útil para volcar dmesg por pantalla (sin UART ni adb). 466/6 = 77
 * caracteres por línea, 466/8 = 58 líneas. */
static const unsigned char dace_font5x7[] = {
0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x5F,0x00,0x00,0x00,0x07,0x00,0x07,0x00,
	0x14,0x7F,0x14,0x7F,0x14,0x24,0x2A,0x7F,0x2A,0x12,0x23,0x13,0x08,0x64,0x62,
	0x36,0x49,0x56,0x20,0x50,0x00,0x08,0x07,0x03,0x00,0x00,0x1C,0x22,0x41,0x00,
	0x00,0x41,0x22,0x1C,0x00,0x2A,0x1C,0x7F,0x1C,0x2A,0x08,0x08,0x3E,0x08,0x08,
	0x00,0x80,0x70,0x30,0x00,0x08,0x08,0x08,0x08,0x08,0x00,0x00,0x60,0x60,0x00,
	0x20,0x10,0x08,0x04,0x02,0x3E,0x51,0x49,0x45,0x3E,0x00,0x42,0x7F,0x40,0x00,
	0x72,0x49,0x49,0x49,0x46,0x21,0x41,0x49,0x4D,0x33,0x18,0x14,0x12,0x7F,0x10,
	0x27,0x45,0x45,0x45,0x39,0x3C,0x4A,0x49,0x49,0x31,0x41,0x21,0x11,0x09,0x07,
	0x36,0x49,0x49,0x49,0x36,0x46,0x49,0x49,0x29,0x1E,0x00,0x00,0x14,0x00,0x00,
	0x00,0x40,0x34,0x00,0x00,0x00,0x08,0x14,0x22,0x41,0x14,0x14,0x14,0x14,0x14,
	0x00,0x41,0x22,0x14,0x08,0x02,0x01,0x59,0x09,0x06,0x3E,0x41,0x5D,0x59,0x4E,
	0x7C,0x12,0x11,0x12,0x7C,0x7F,0x49,0x49,0x49,0x36,0x3E,0x41,0x41,0x41,0x22,
	0x7F,0x41,0x41,0x41,0x3E,0x7F,0x49,0x49,0x49,0x41,0x7F,0x09,0x09,0x09,0x01,
	0x3E,0x41,0x41,0x51,0x73,0x7F,0x08,0x08,0x08,0x7F,0x00,0x41,0x7F,0x41,0x00,
	0x20,0x40,0x41,0x3F,0x01,0x7F,0x08,0x14,0x22,0x41,0x7F,0x40,0x40,0x40,0x40,
	0x7F,0x02,0x1C,0x02,0x7F,0x7F,0x04,0x08,0x10,0x7F,0x3E,0x41,0x41,0x41,0x3E,
	0x7F,0x09,0x09,0x09,0x06,0x3E,0x41,0x51,0x21,0x5E,0x7F,0x09,0x19,0x29,0x46,
	0x26,0x49,0x49,0x49,0x32,0x03,0x01,0x7F,0x01,0x03,0x3F,0x40,0x40,0x40,0x3F,
	0x1F,0x20,0x40,0x20,0x1F,0x3F,0x40,0x38,0x40,0x3F,0x63,0x14,0x08,0x14,0x63,
	0x03,0x04,0x78,0x04,0x03,0x61,0x59,0x49,0x4D,0x43,0x00,0x7F,0x41,0x41,0x41,
	0x02,0x04,0x08,0x10,0x20,0x00,0x41,0x41,0x41,0x7F,0x04,0x02,0x01,0x02,0x04,
	0x40,0x40,0x40,0x40,0x40,0x00,0x03,0x07,0x08,0x00,0x20,0x54,0x54,0x78,0x40,
	0x7F,0x28,0x44,0x44,0x38,0x38,0x44,0x44,0x44,0x28,0x38,0x44,0x44,0x28,0x7F,
	0x38,0x54,0x54,0x54,0x18,0x00,0x08,0x7E,0x09,0x02,0x18,0xA4,0xA4,0x9C,0x78,
	0x7F,0x08,0x04,0x04,0x78,0x00,0x44,0x7D,0x40,0x00,0x20,0x40,0x40,0x3D,0x00,
	0x7F,0x10,0x28,0x44,0x00,0x00,0x41,0x7F,0x40,0x00,0x7C,0x04,0x78,0x04,0x78,
	0x7C,0x08,0x04,0x04,0x78,0x38,0x44,0x44,0x44,0x38,0xFC,0x18,0x24,0x24,0x18,
	0x18,0x24,0x24,0x18,0xFC,0x7C,0x08,0x04,0x04,0x08,0x48,0x54,0x54,0x54,0x24,
	0x04,0x04,0x3F,0x44,0x24,0x3C,0x40,0x40,0x20,0x7C,0x1C,0x20,0x40,0x20,0x1C,
	0x3C,0x40,0x30,0x40,0x3C,0x44,0x28,0x10,0x28,0x44,0x4C,0x90,0x90,0x90,0x7C,
	0x44,0x64,0x54,0x4C,0x44,0x00,0x08,0x36,0x41,0x00,0x00,0x00,0x77,0x00,0x00,
	0x00,0x41,0x36,0x08,0x00,0x02,0x01,0x02,0x04,0x02,
};

static void dace_draw_char2x(u32 *fb, int x0, int y0, char c)
{
	const unsigned char *g;
	int i, j, sx, sy;

	if (c < 32 || c > 126)
		c = '?';
	g = &dace_font5x7[(c - 32) * 5];
	for (i = 0; i < 5; i++) {
		unsigned char col = g[i];

		for (j = 0; j < 7; j++) {
			u32 v = (col & (1 << j)) ? 0x00ffffff : 0;

			for (sx = 0; sx < 2; sx++)
				for (sy = 0; sy < 2; sy++) {
					int px = x0 + i * 2 + sx;
					int py = y0 + j * 2 + sy;

					if (px >= 0 && px < 466 && py >= 0 && py < 466)
						fb[py * 466 + px] = v;
				}
		}
	}
}

static unsigned int dace_isqrt(unsigned int n)
{
	unsigned int x = n, y = (x + 1) >> 1;

	while (y < x) {
		x = y;
		y = (x + n / x) >> 1;
	}
	return x;
}

/* caracteres por línea en la fila y (celda 12x16, círculo R=233 con 2px
 * de margen) */
static int dace_line_cap(int y)
{
	int yc = y + 8, dy = yc - 233;
	unsigned int sq;

	if (dy < 0)
		dy = -dy;
	if (dy >= 231)
		return 0;
	sq = 231u * 231u - (unsigned int)dy * (unsigned int)dy;
	return (int)((2 * dace_isqrt(sq)) / 12);
}

static void dace_text(const char *t)
{
	u32 *fb = (u32 *)phys_to_virt((phys_addr_t)DACE_SPLASH_PHYS);
	int pass, y0 = 0, y, x, cap, i;
	const char *p;
	size_t k;

	if (!fb)
		return;
	for (i = 0; i < DACE_FB_NPIX; i++)
		fb[i] = 0;

	/* layout en 2 pasadas: contar líneas y centrar verticalmente */
	for (pass = 0; pass < 2; pass++) {
		int lines = 0;

		p = t;
		y = y0;
		while (*p && y <= 466 - 16) {
			cap = dace_line_cap(y);
			if (cap <= 0) {
				y += 16;
				continue;
			}
			lines++;
			x = 0;
			while (*p && *p != '\\n' && x < cap) {
				p++;
				x++;
			}
			if (*p == '\\n')
				p++;
			y += 16;
		}
		y0 = 233 - (lines * 16) / 2;
		if (y0 < 0)
			y0 = 0;
	}

	/* pintado */
	p = t;
	y = y0;
	while (*p && y <= 466 - 16) {
		cap = dace_line_cap(y);

		if (cap <= 0) {
			y += 16;
			continue;
		}
		x = 0;
		while (*p && *p != '\\n' && x < cap) {
			int xpix = 233 - (cap * 12) / 2 + x * 12;

			dace_draw_char2x(fb, xpix, y, *p);
			p++;
			x++;
		}
		if (*p == '\\n')
			p++;
		y += 16;
	}
	dsb(sy);
}

static ssize_t dace_text_store(struct kobject *k, struct kobj_attribute *a,
			       const char *buf, size_t n)
{
	static char tb[4096];
	size_t l = n < 4095 ? n : 4095;

	memcpy(tb, buf, l);
	tb[l] = 0;
	dace_text(tb);
	return n;
}
static struct kobj_attribute dace_text_attr =
	__ATTR(dace_text, 0200, NULL, dace_text_store);

static int __init dace_color_init(void)
{
	sysfs_create_file(kernel_kobj, &dace_color_attr.attr);
	sysfs_create_file(kernel_kobj, &dace_barcode_attr.attr);
	return sysfs_create_file(kernel_kobj, &dace_text_attr.attr);
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
    # CYAN: wait_for_initramfs() completado (el kernel ya no espera al initrd).
    # Si el AZUL aparece pero el CYAN no, el hang esta en kunit/wait_for_initramfs.
    cyan_anchor = '\twait_for_initramfs();\n'
    cyan_inject = ('\twait_for_initramfs();\n'
                   '\tdace_boot_color(0x00ff00ff); /* CYAN: wait_for_initramfs done */\n'
                   '\tpr_err("dace-bootcolor: CYAN (wait_for_initramfs done)\n");\n')
    if cyan_anchor not in src:
        sys.exit("bootcolor: no anchor CYAN")
    src = src.replace(cyan_anchor, cyan_inject, 1)
    # VERDE: vamos a execve del /init del initramfs (run_init_process).
    green_anchor = '\tif (ramdisk_execute_command) {\n'
    green_inject = ('\tif (ramdisk_execute_command) {\n'
                    '\tdace_boot_color(0x0000ff00); /* VERDE: exec /init */\n')
    if green_anchor not in src:
        sys.exit("bootcolor: no anchor GREEN")
    src = src.replace(green_anchor, green_inject, 1)
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
