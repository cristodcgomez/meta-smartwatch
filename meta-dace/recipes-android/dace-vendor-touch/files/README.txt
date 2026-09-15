Modulos stock del vendor (Mobvoi msm-5.15 g7f9d6c16b5cd) PARCHEADOS para
nuestro kernel (dace). Origen: ota-stock/extracted/modules-stripped/*.ko
(ya sin la seccion __versions -> cargan con taint forzado).

PARCHES APLICADOS (ver patch-stock-module.py en la raiz del repo):
1. SCS (shadow call stack): los .ko stock guardan x30 via x18
   (str x30,[x18],#8 / ldr x30,[x18,#-8]!). Nuestro kernel NO tiene
   CONFIG_SHADOW_CALL_STACK (sw5100.fragment lo pide pero Kconfig lo
   descarta), asi que x18 es basura y esas escrituras corrompen memoria ->
   el rootfs arrancaba, petaba y volvia al modo seguro. Se NOPean las
   parejas push/pop en .text/.init.text/.exit.text.
2. Reloc de exit en .gnu.linkonce.this_module: 0x378 (stock) -> 0x3a8
   (nuestro kernel). El de init NO se toca: nuestro layout lo pone en
   0x178, igual que el stock (gracias al slot ABI
   dace-module-cfi-abi-slot.patch). Solo afecta al rmmod.

Regenerar:
  python3 patch-stock-module.py <in.ko> <out.ko>
  (por defecto: init 0x178->0x178, exit 0x378->0x3a8, NOP SCS)
Si el layout de struct module cambia (medirlo compilando un modulo de prueba
contra el build dir y volcando los relocs de this_module), pasar los offsets
nuevos como 3er/4o argumento.
