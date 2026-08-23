#! /bin/sh

# TicWatch Pro 5 (dace) initramfs init — DEBUG BUILD
#
# Forza ADB SIEMPRE (no depende de `debug-ramdisk` en cmdline, porque el
# bootloader del dace pincha su propio cmdline y pisa el nuestro).
#
# Basado en el init.sh de aurora (Pixel Watch 2, mismo kernel GKI 5.15):
#  - log a /dev/kmsg (el GKI tiene CONFIG_PRINTK, no ttyprintk)
#  - monta configfs + android-gadget-setup para el gadget USB (el kernel GKI
#    5.15 NO tiene el legacy /sys/class/android_usb/i0)
#  - espera el UDC (dwc3-msm) hasta 30s y bindea
#  - si NO aparece UDC, deja constancia en kmsg y se queda en loop igualmente
#    (para poder hacer adb cuando el dwc3 aparezca / o depurar)
#
# Este init NO hace switch_root: se queda en el initramfs con adb para
# diagnosticar hardware (dmesg, /proc/partitions, etc.).

. /machine.conf

info() { echo "init-dace: $1" > /dev/kmsg 2>/dev/null; echo "init-dace: $1" > /dev/console 2>/dev/null; }

# ── TELEMETRÍA sin adb ──
# Vibración haptic (si el driver está) + iProduct del gadget USB (si hay
# configfs) para saber desde el host en qué paso quedó el boot.
# Patrones de vibración: 1=init empezó, 2=módulos cargados, 3=gadget ok,
# 4=UDC encontrado, 9=loop final (init vivo).
VIB_NODES="/sys/class/leds/vibrator/activate /sys/class/leds/vibrator/duration /sys/class/input/*/device/vibrate /sys/devices/virtual/timed_output/vibrator/enable"
vibrate() {
    # $1 = duración ms
    for n in $VIB_NODES; do
        [ -w "$n" ] && echo "$1" > "$n" 2>/dev/null && return 0
    done
    return 1
}
burst() {
    # $1 = número de pulsos; $2 = duración por pulso
    i=0
    while [ $i -lt ${1:-1} ]; do
        vibrate ${2:-150}
        sleep 0.2
        i=$((i+1))
    done
}
set_usb_string() {
    # $1 = string iProduct; lo pone en configfs gadget (y legacy)
    for g in /sys/kernel/config/usb_gadget/*; do
        [ -d "$g/strings/0x409" ] && echo "$1" > "$g/strings/0x409/iProduct" 2>/dev/null
    done
    echo "$1" > /sys/class/android_usb/android0/iProduct 2>/dev/null
}
stage() {
    # $1 = nº de vibraciones; $2 = mensaje; $3 = color ARGB opcional (pintado
    # en el splash via /sys/kernel/dace_color para telemetría visual por etapa)
    burst "$1" 120
    info "STAGE $2"
    set_usb_string "dace:${2}"
    [ -n "$3" ] && [ -e /sys/kernel/dace_color ] && echo "$3" > /sys/kernel/dace_color 2>/dev/null
}

setup_devtmpfs() {
    mount -t devtmpfs -o mode=0755,nr_inodes=0 devtmpfs $1/dev
    mkdir $1/dev/pts
    mount -t devpts none $1/dev/pts/
    test -c $1/dev/fd     || ln -sf /proc/self/fd $1/dev/fd
    test -c $1/dev/stdin  || ln -sf fd/0 $1/dev/stdin
    test -c $1/dev/stdout || ln -sf fd/1 $1/dev/stdout
    test -c $1/dev/stderr || ln -sf fd/2 $1/dev/stderr
    test -c $1/dev/socket || mkdir -m 0755 $1/dev/socket
}

info "dace-init: mounting proc/sys/devtmpfs ..."
mkdir -m 0755 /proc;  mount -t proc proc /proc
mkdir -m 0755 /sys;   mount -t sysfs sys /sys
mkdir -p /dev;        setup_devtmpfs ""

# ── VERDE: si llegamos aquí, PID 1 (init) corre ──
# El kernel pinta ROJO (start_kernel), AZUL (initcalls) y AMARILLO
# (kernel_init). Si el init corre, pintamos VERDE vía /sys/kernel/dace_color
# (hook inyectado por dace-bootcolor.py v2). Fallback: /dev/mem directo.
if [ -e /sys/kernel/dace_color ]; then
    echo 0x0000ff00 > /sys/kernel/dace_color 2>/dev/null && \
        info "dace-init: VERDE pintado via /sys/kernel/dace_color" || \
        info "dace-init: fallo al escribir dace_color"
elif [ -c /dev/mem ]; then
    # fallback: 1024000 bytes de verde ARGB 0x0000FF00 (LE: 00 FF 00 00)
    # al fb cont-splash @0x5c000000 (seek en bloques 4K: 0x5c000000/4096=376832)
    ( printf '\x00\xff\x00\x00%.0s' $(seq 1 1024) 2>/dev/null || \
      busybox printf '\x00\xff\x00\x00%.0s' $(busybox seq 1 1024) 2>/dev/null ) > /tmp/.gb 2>/dev/null
    if [ -s /tmp/.gb ]; then
        i=0; while [ $i -lt 250 ]; do cat /tmp/.gb; i=$((i+1)); done > /tmp/.green 2>/dev/null
        dd if=/tmp/.green of=/dev/mem bs=4096 seek=376832 conv=notrunc 2>/dev/null && \
            info "dace-init: VERDE pintado en fb (init corriendo)" || \
            info "dace-init: fallo al pintar VERDE"
        rm -f /tmp/.green /tmp/.gb 2>/dev/null
    else
        info "dace-init: no pude generar buffer verde"
    fi
else
    info "dace-init: ni dace_color ni /dev/mem; no puedo pintar VERDE"
fi

CMDLINE=$(cat /proc/cmdline 2>/dev/null)
info "dace-init: cmdline = $CMDLINE"
stage 1 "init-start"

info "dace-init: loading kernel modules (FIRST-STAGE stock: los 67 que el init ELF carga) ..."
KREL=$(uname -r)
# La cadena EXACTA del modules.load del vendor_boot stock. El init binario
# de Android first-stage los carga EN ESTE ORDEN para que el SoC llegue a
# userspace (clocks, smem, crypto/hwkm, proxy-consumer, reguladores,
# arm_smmu/iommu, sdhci, scm, glink, qrtr). Nuestro kernel muere antes de
# userspace si esta cadena no se carga. smem.ko lo tenemos built-in (=y).
# dwc3-msm NO esta en el modules.load del stock (se carga despues); lo
# cargamos al final para el UDC/adb.
STOCK_MODS="qcom_ipc_logging qcom-mpm pinctrl-msm pinctrl-monaco \
clk-qcom clk-dummy gdsc-regulator clk-smd-rpm dispcc-monaco gcc-monaco \
mdt_loader smem soc_sleep_stats boot_stats smp2p glink_probe secure_buffer \
mem_buf mem_buf_dev socinfo \
qcom_wdt_core qcom_soc_wdt memory_dump_v2 dcc_v2 qcom-pmu-lib qcom-dcvs \
bwmon qcom_cpu_vendor_hooks crypto-qti-common hwkm_v1 crypto-qti-hwkm \
minidump qcom_logbuf_vh qti-fixed-regulator proxy-consumer rpm-smd-regulator \
stub-regulator debug-regulator arm_smmu msm_dma_iommu_mapping qcom_iommu_util \
iommu-logger regmap-spmi qti-regmap-debugfs qcom-spmi-pmic qcom_dma_heaps \
spmi-pmic-arb rtc-pm8xxx qcom-dload-mode qcom-reboot-reason cpu_hotplug \
qcom-cpufreq-hw sdhci-msm cqhci qcom-scm qcom-apcs-ipc-mailbox qcom_hwspinlock \
rproc_qcom_common qcom_glink qcom_glink_rpm rpm-smd qcom_glink_smem qcom_smd \
nvmem_qcom-spmi-sdam qnoc-monaco icc-rpm qnoc-qos-rpm qrtr"
# (smem.ko y sdhci-msm-scaling.ko omitidos: smem es =y built-in; scaling no
# existe en este build y no es critico para llegar a userspace/adb)
if [ -d /lib/modules ]; then
    # Layout FLAT (estilo stock/aurora): los .ko estan en /lib/modules/X.ko.
    # busybox modprobe espera /lib/modules/$(uname -r)/ -> symlink a la raiz.
    [ ! -e "/lib/modules/$KREL" ] && ln -sf . "/lib/modules/$KREL" 2>/dev/null
    # shim: abre la puerta USB (el DT del monaco la fuerza off en boot)
    modprobe google-extcon-usb-shim usb_force_disable_boot=0 2>/dev/kmsg && \
        info "dace-init: usb_shim + usb_force_disable_boot=0" || \
        info "dace-init: usb_shim FAILED/no-op"
    info "dace-init: cargando cadena first-stage stock (67 mods) con modprobe..."
    for m in $STOCK_MODS; do
        modprobe "$m" 2>/dev/kmsg || info "dace-init: modprobe $m FAILED"
    done
    info "dace-init: first-stage cargado. Ahora phy + dwc3-msm para el UDC..."
    for m in phy-msm-snps-hs phy-msm-ssusb-qmp dwc3-msm; do
        modprobe "$m" 2>/dev/kmsg || info "dace-init: modprobe $m FAILED"
    done
    # Belt-and-braces: abrir la puerta USB por si el shim la anclo via DT
    for fd in /sys/devices/platform/soc/soc:extcon_usb_shim/force_disable \
              /sys/bus/platform/devices/soc:extcon_usb_shim/force_disable; do
        [ -e "$fd" ] && echo 0 > "$fd" 2>/dev/kmsg && \
            info "dace-init: USB gate opened via $fd"
    done
    info "dace-init: modulos cargados. UDC ahora: $(cd /sys/class/udc 2>/dev/null && echo *)"
    stage 2 "mods-loaded" 0x0000ffff   # CIAN: módulos cargados
else
    info "dace-init: no /lib/modules — no SoC drivers to load; UDC likely absent"
    stage 2 "no-modules" 0x00008080    # GRIS: sin módulos
fi

# ─── ADB: configfs gadget (GKI kernels) ───
info "dace-init: setting up adbd via configfs..."
mkdir -p /sys/kernel/config
mount -t configfs none /sys/kernel/config 2>/dev/null || info "dace-init: configfs mount (already mounted?)"

# android-gadget-setup adb crea el gadget configfs + ffs y lo monta
if [ -x /usr/bin/android-gadget-setup ]; then
    /usr/bin/android-gadget-setup adb 2>/dev/kmsg
else
    info "dace-init: android-gadget-setup NOT FOUND"
fi

# Legacy android_usb: no-op en GKI, por compatibilidad
echo 0 > /sys/class/android_usb/android0/enable 2>/dev/null
echo 18d1 > /sys/class/android_usb/android0/idVendor 2>/dev/null
echo d002 > /sys/class/android_usb/android0/idProduct 2>/dev/null
echo adb > /sys/class/android_usb/android0/f_ffs/aliases 2>/dev/null
echo ffs > /sys/class/android_usb/android0/functions 2>/dev/null
echo AsteroidOS > /sys/class/android_usb/android0/iManufacturer 2>/dev/null
echo InitRamDisk > /sys/class/android_usb/android0/iProduct 2>/dev/null
serial="$(cat /proc/cmdline | sed 's/.*androidboot.serialno=//' | sed 's/ .*//')"
[ -n "$serial" ] && echo "$serial" > /sys/class/android_usb/android0/iSerial 2>/dev/null

# adbd nuestro (5.1.1, parcheado sin SELinux) — compatible CONFIG_COMPAT arm32
/usr/bin/adbd &
stage 3 "adbd-launched" 0x00ff8000     # NARANJA: adbd lanzado

UDC=""
i=0
while [ $i -lt 30 ]; do
    UDC=$(cd /sys/class/udc 2>/dev/null && echo *)
    case "$UDC" in '*'|''|'.'|'..') UDC="" ;; esac
    [ -n "$UDC" ] && break
    sleep 1
    i=$((i+1))
done

if [ -n "$UDC" ]; then
    UDC=$(echo "$UDC" | awk '{print $1}')
    info "dace-init: UDC=$UDC after ~${i}s"
    # Bound configfs gadget UDC
    echo "$UDC" > /sys/kernel/config/usb_gadget/*/UDC 2>/dev/kmsg && \
        info "dace-init: UDC bound" || \
        info "dace-init: UDC bind FAILED (write error)"
    stage 4 "udc-bound" 0x00ff00ff # MAGENTA: gadget activo (adb debería verse)
else
    info "dace-init: NO UDC after 30s — dwc3 no probeó o sin drivers. /sys/class/udc = '$(cd /sys/class/udc 2>/dev/null && echo *)'"
    info "dace-init: dmesg tail:"
    dmesg 2>/dev/null | tail -30 > /dev/kmsg 2>/dev/null || true
    info "dace-init: (see kmsg)"
fi

info "dace-init: staying in initramfs with adb (debug). Never switching to rootfs."
info "dace-init: available devices: $(ls /dev/ 2>/dev/null | tr '\n' ' ')"
info "dace-init: partitions: $(cat /proc/partitions 2>/dev/null | tr '\n' ' ')"

# ── DEBUG-PURO: NO switch_root (prueba aislada) ──
# El init.machine monta userdata y hace switch_root si hay rootfs. Si ese
# switch_root cuelga (rootfs presente pero /sbin/init no arranca), perdemos
# adb y vibraciones -> logo estático. Para discriminar "kernel no arranca"
# de "switch_root cuelga", en esta prueba NO llamamos a init.machine: nos
# quedamos SIEMPRE en el initramfs con adb. Si así vuelve adb -> el problema
# es el switch_root a userdata, no el kernel.
info "dace-init: DEBUG-PURO — NO switch_root; quedando en initramfs con adb"

# Sticky: si init.machine no switch_root (no hay rootfs), adb de rescate
stage 9 "init-alive" 0x00ffffff         # BLANCO: init vivo en el loop final
while true; do sleep 3600; done