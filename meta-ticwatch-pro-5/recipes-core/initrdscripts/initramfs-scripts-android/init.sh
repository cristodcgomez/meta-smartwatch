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
MODOUT="none"; MODRC=-1
KREL=$(uname -r)
# La cadena EXACTA del modules.load del vendor_boot stock. El init binario
# de Android first-stage los carga EN ESTE ORDEN para que el SoC llegue a
# userspace (clocks, smem, crypto/hwkm, proxy-consumer, reguladores,
# arm_smmu/iommu, sdhci, scm, glink, qrtr). Nuestro kernel muere antes de
# userspace si esta cadena no se carga. smem.ko lo tenemos built-in (=y).
# dwc3-msm NO esta en el modules.load del stock (se carga despues); lo
# cargamos al final para el UDC/adb.
# La cadena first-stage COMPLETA del stock son 178 módulos en orden
# (modules.load del vendor ramdisk stock): incluye pm8008-regulator,
# pinctrl-spmi-gpio/mpp, clk-rpmh, eud, phys y dwc3-msm. Nuestra selección
# manual de ~70 dejaba fuera suppliers que el qmp-phy necesita (probe defer).
# Como el init first-stage de Android: iterar modules.load en orden.
if [ -d /lib/modules ]; then
    # Layout FLAT (estilo stock/aurora): los .ko estan en /lib/modules/X.ko.
    # busybox modprobe espera /lib/modules/$(uname -r)/ -> symlink a la raiz.
    [ ! -e "/lib/modules/$KREL" ] && ln -sf . "/lib/modules/$KREL" 2>/dev/null
    # shim: abre la puerta USB (el DT del monaco la fuerza off en boot)
    modprobe google-extcon-usb-shim usb_force_disable_boot=0 2>/dev/kmsg && \
        info "dace-init: usb_shim + usb_force_disable_boot=0" || \
        info "dace-init: usb_shim FAILED/no-op"
    info "dace-init: cargando cadena first-stage (modules.load; 2 pasadas por dependencias)..."
    NMODS=0
    for PASS in 1 2; do
        while read -r m; do
            case "$m" in ''|\#*) continue ;; esac
            [ -d "/sys/module/${m%.ko}" ] && continue   # ya cargado
            modprobe "${m%.ko}" 2>/dev/kmsg || \
                info "dace-init: pass$PASS modprobe $m FAILED"
            NMODS=$((NMODS+1))
        done < /lib/modules/modules.load
    done
    info "dace-init: $NMODS intentos de carga first-stage completados"
    # EUD: su extcon (EXTCON_USB=true, spoof de attach) es lo que lleva al
    # glue dwc3-msm a modo peripheral y registra el UDC. Ya viene en
    # modules.load; el parche eud-secure-fail-nonfatal evita que el rechazo
    # de TZ aborte antes del extcon_set_state_sync, y el glue tolera el
    # extcon del charger (smblite, sin modulo) vía skip-deferred-extcon.
    EUD_OK=0
    [ -d /sys/module/eud ] && EUD_OK=1
    info "dace-init: eud cargado → EUD_OK=$EUD_OK"
    # Glue dwc3-msm explícito (2ª pasada por si gdsc-regulator/clk-qcom se
    # cargaron después en el orden alfabético de modules.load):
    if [ ! -d /sys/module/dwc3-msm ]; then
        MODOUT=$(modprobe dwc3-msm 2>&1)
        MODRC=$?
        info "dace-init: modprobe dwc3-msm rc=$MODRC out='$MODOUT'"
        [ -n "$MODOUT" ] && printf '%s\n' "$MODOUT" > /dev/kmsg
    else
        MODOUT="already-loaded"; MODRC=0
        info "dace-init: dwc3-msm ya estaba cargado"
    fi
    sleep 2   # dejar correr el deferred-probe workqueue
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
echo 0x0000ff80 > /sys/kernel/dace_color 2>/dev/null  # TEAL: gadget configurado (pre-adbd)

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
echo 0x0080ffff > /sys/kernel/dace_color 2>/dev/null  # AZUL CLARO: esperando UDC (30s)
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
    echo 0x000000aa > /sys/kernel/dace_color 2>/dev/null  # AZUL OSCURO: rama no-UDC
    info "dace-init: NO UDC after 30s — dwc3 no probeó o sin drivers. /sys/class/udc = '$(cd /sys/class/udc 2>/dev/null && echo *)'"
    # Fallback: si el glue registró un role-switch, forzar rol device a mano
    for rs in /sys/class/usb_role/*/role; do
        [ -e "$rs" ] && echo device > "$rs" 2>/dev/null && \
            info "dace-init: forced role=device via $rs"
    done
    sleep 3
    UDC=$(cd /sys/class/udc 2>/dev/null && echo *)
    case "$UDC" in '*'|''|'.'|'..') UDC="" ;; esac
    if [ -n "$UDC" ]; then
        info "dace-init: UDC apareció tras forzar role: $UDC"
        echo "$UDC" > /sys/kernel/config/usb_gadget/*/UDC 2>/dev/null && \
            stage 4 "udc-bound" 0x00ff00ff
    else
        info "dace-init: sigue sin UDC tras forzar role"
    fi
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

# ── CÓDIGO DE BARRAS de diagnóstico USB (pantalla final) ──
# Dos RONDAS alternas (8s cada una): elijo cuál veo por la franja superior.
# RONDA 1 (arriba F): 1=modprobe eud | 2=módulo eud | 3=msm-eud bound |
#   4=msm-dwc3 bound | 5=dwc3 bound | 6=UDC | 7=dmesg dwc3 | 8=extcon
# RONDA 1 (abajo B): 1=/sys/module/dwc3-msm | 2=/sys/kernel/dace_glue |
#   3-5=step bits 2,1,0 | 6=bit err(step&16) | 7=INIT falló(step&32) | 8=módulo descargado(step&64)
# RONDA 2 (arriba C): 1=dir driver msm-dwc3 existe | 2=device hsusb existe |
#   3=modprobe rc=0 | 4=MODOUT 'Unknown symbol' | 5=MODOUT 'disagrees' |
#   6=MODOUT 'exists' | 7=MODOUT vacío/silencioso | 8=dmesg msm-dwc3
# RONDA 2 (abajo D): 1=dmesg 'already registered' | 2=dmesg 'Unable to handle' |
#   3=dmesg 'Call trace' | 4=dmesg 'disagrees about version' |
#   5=dmesg 'Unknown symbol' | 6=nº módulos cargados >=170 | 7=/lib/modules existe | 8=1 (marca de ronda)
F1=${EUD_OK:-0}
# hechos SIN AMBIGÜEDAD:
# 2 = módulo eud cargado | 3 = msm-eud con device bound | 4 = msm-dwc3 bound
# 5 = dwc3 (core) bound | 6 = UDC | 7 = dmesg dwc3 | 8 = extcon presente
bound() { # $1 = dir driver; 0 si tiene algún device bound
    local b f
    for f in "$1"/*; do
        [ -e "$f" ] || continue
        b=$(basename "$f")
        case "$b" in bind|unbind|module|uevent) ;; *) return 0 ;; esac
    done
    return 1
}
[ -d /sys/module/eud ] && F2=1 || F2=0
bound /sys/bus/platform/drivers/msm-eud && F3=1 || F3=0
bound /sys/bus/platform/drivers/msm-dwc3 && F4=1 || F4=0
bound /sys/bus/platform/drivers/dwc3 && F5=1 || F5=0
F6=0; for f in /sys/class/udc/*; do [ -e "$f" ] && F6=1; done
dmesg 2>/dev/null | grep -qi "dwc3" && F7=1 || F7=0
F8=0; for f in /sys/class/extcon/extcon*; do [ -e "$f" ] && F8=1; done
info "dace-init: BARCODE F1..F8 = $F1 $F2 $F3 $F4 $F5 $F6 $F7 $F8"
# ── Barcode B v36: estado del glue dwc3-msm ──
# B1=módulo dwc3-msm cargado | B2=/sys/kernel/dace_glue existe |
# B3-B5=step bits 2,1,0 | B6=bit err (step&16) | B7=INIT FALLÓ (step&32) |
# B8=módulo descargado/exit (step&64)
GLUE_STEP=0; GLUE_RET=0; MOD=0; SYSFS=0
[ -d /sys/module/dwc3-msm ] && MOD=1
if [ -e /sys/kernel/dace_glue ]; then
    SYSFS=1
    read -r GLUE_STEP GLUE_RET < /sys/kernel/dace_glue 2>/dev/null
fi
info "dace-init: GLUE mod=$MOD sysfs=$SYSFS step=$GLUE_STEP ret=$GLUE_RET"
CODE2="$MOD$SYSFS$(( (GLUE_STEP >> 2) & 1 ))$(( (GLUE_STEP >> 1) & 1 ))$(( GLUE_STEP & 1 ))$(( (GLUE_STEP >> 4) & 1 ))$(( (GLUE_STEP >> 5) & 1 ))$(( (GLUE_STEP >> 6) & 1 ))"
info "dace-init: BARCODE2 = $CODE2"
# dmesg completo a console (→ console-ramoops) y a pmsg (→ pstore pmsg-ramoons)
dmesg 2>/dev/null > /dev/console 2>/dev/null || true
dmesg 2>/dev/null > /dev/pmsg0 2>/dev/null || true
stage 9 "init-alive" 0x00ffffff         # BLANCO: init vivo en el loop final
sleep 3
# ── Diagnóstico USB: BARCODE + canal de PARPADEOS redundante ──
# Canal A (barcode): pintado por el kernel vía /sys/kernel/dace_barcode.
#   MORADO 0xaa00aa  = el atributo no existe (initcall no se registró)
#   ROSA   0xff00aa  = el atributo existe pero el write falló
# Canal B (parpadeos, solo con dace_color que SABEMOS que funciona):
#   AMARILLO 2s = inicio; luego 8 pulsos: BLANCO 1s = hecho OK,
#   GRIS OSCURO 1s = hecho FALLO, con 0.5s de negro entre pulsos;
#   MORADO 2s = fin. Se repite en bucle.
CODE="$F1$F2$F3$F4$F5$F6$F7$F8"
BARCODE_OK=0
if [ -e /sys/kernel/dace_barcode ]; then
    if echo "$CODE $CODE2" > /sys/kernel/dace_barcode 2>/dev/null; then
        info "dace-init: BARCODE pintado por el kernel ($CODE)"
        BARCODE_OK=1
    else
        info "dace-init: write a dace_barcode FALLÓ — ROSA"
        echo 0x00ff00aa > /sys/kernel/dace_color 2>/dev/null
    fi
else
    info "dace-init: sin /sys/kernel/dace_barcode — MORADO"
    [ -e /sys/kernel/dace_color ] && echo 0x00aa00aa > /sys/kernel/dace_color
fi
# ── TELEMETRÍA v5 (v50): los booleans de la cadena RPM viajan en BARCODE ──
# v49 demostró que el texto pequeño no se transcribe bien en el panel redondo.
# v50: cadena RPM → barcode R-chain (ARRIBA los 8 datos, ABAJO marca 10101010
# para identificar la ronda); se deja UNA sola página de texto (dmesg) y los
# barcodes R1/R2 de siempre. Fuera: P0 (control), P1 (página deferidos),
# P2 (texto booleans), P4 (dmesg-2). Menos pantallas, dato decisivo en franjas.
mount -t debugfs none /sys/kernel/debug 2>/dev/null
wrap33() {
    local l
    while IFS= read -r l || [ -n "$l" ]; do
        while [ ${#l} -gt 33 ]; do
            printf '%s\n' "${l:0:33}"
            l="${l:33}"
        done
        printf '%s\n' "$l"
    done
}
firstlines() {
    local n=$1 l c=0
    while IFS= read -r l; do
        [ "$c" -ge "$n" ] && break
        printf '%s\n' "$l"
        c=$((c+1))
    done
}
drv_of() { # $1 = device platform; driver bound o '-'
    local d
    d=$(readlink "/sys/bus/platform/devices/$1/driver" 2>/dev/null)
    if [ -n "$d" ]; then echo "${d##*/}"; else echo "-"; fi
}

# ── hechos de la cadena RPM (bits del barcode R-chain) ──
MBOX_D=$(drv_of f111000.mailbox)         # bit1 mb: qcom_apcs_ipc
GLK_D=$(drv_of rpm-glink)                # bit2 gl: qcom_glink_rpm
RSD_D=$(drv_of qcom,rpm-smd)             # bit3 rs: rpm-smd (platform)
PSCI_D=$(drv_of psci)                    # bit4 ps: genpd psci/cluster-pd0
GCC_D=$(drv_of 1410000.clock-controller) # bit5 gcc: gcc-monaco
[ "$GCC_D" = "-" ] && GCC_D=$(drv_of soc:clock-controller)
[ "$GCC_D" = "-" ] && for f in /sys/bus/platform/drivers/gcc-monaco/*; do
    case "${f##*/}" in bind|unbind|module|uevent) ;; *) [ -e "$f" ] && GCC_D="${f##*/}" ;; esac
done
EUD_D=$(drv_of 1610000.qcom,msm-eud)     # bit6 eud: msm-eud
[ "$EUD_D" = "-" ] && EUD_D=$(drv_of eud)
[ "$EUD_D" = "-" ] && for f in /sys/bus/platform/drivers/msm-eud/*; do
    case "${f##*/}" in bind|unbind|module|uevent) ;; *) [ -e "$f" ] && EUD_D="${f##*/}" ;; esac
done
RQ=N                                     # bit7 rq: existe rpmsg rpm_requests
for f in /sys/bus/rpmsg/devices/*rpm_requests*; do
    [ -e "$f" ] && RQ=Y
done
CX=0                                     # bit8 cx: VDD_CX (pm5100_s1_level) registrado
for rn in /sys/class/regulator/regulator*/name; do
    [ -e "$rn" ] || continue
    read -r nm < "$rn" 2>/dev/null
    [ "$nm" = "pm5100_s1_level" ] && CX=1
done

B_MB=0; [ "$MBOX_D" != "-" ] && B_MB=1
B_GL=0; [ "$GLK_D" != "-" ] && B_GL=1
B_RS=0; [ "$RSD_D" != "-" ] && B_RS=1
B_PS=0; [ "$PSCI_D" != "-" ] && B_PS=1
B_GCC=0; [ "$GCC_D" != "-" ] && B_GCC=1
B_EUD=0; [ "$EUD_D" != "-" ] && B_EUD=1
B_RQ=0; [ "$RQ" = "Y" ] && B_RQ=1
CHAIN="$B_MB$B_GL$B_RS$B_PS$B_GCC$B_EUD$B_RQ$CX"

# contador de deferidos (solo para la cabecera de la página dmesg)
DFN=0
if [ -e /sys/kernel/debug/devices_deferred ]; then
    while IFS= read -r l; do
        [ -n "$l" ] && DFN=$((DFN+1))
    done < /sys/kernel/debug/devices_deferred
else
    DFN=-1
fi

# ── única página de texto: dmesg filtrado ──
DMF=$(dmesg 2>/dev/null | grep -iE "glink|rpm|smd|mbox|mailbox|psci|domain|genpd|defer|regulat|gdsc|proxy|eud|dwc3|oops|warn|fail" | tail -c 1100 | wrap33)
P3=$(printf '%s\n%s\n' "dmesg DFR=$DFN cx=$CX" "$(printf '%s\n' "$DMF" | firstlines 12)" | firstlines 13)
[ -z "$P3" ] && P3="dmesg vacio DFR=$DFN"

info "dace-init: v50 CHAIN=$CHAIN mb=$B_MB gl=$B_GL rs=$B_RS ps=$B_PS gcc=$B_GCC eud=$B_EUD rq=$B_RQ cx=$CX DFN=$DFN"
# ── RONDA 2: hechos estructurales (franja 8 inferior = 1 → es la ronda 2) ──
[ -d /sys/bus/platform/drivers/msm-dwc3 ] && C1=1 || C1=0
C2=0
for p in /sys/bus/platform/devices/*hsusb* /sys/bus/platform/devices/*4e00000*; do
    [ -e "$p" ] && C2=1
done
[ "$MODRC" = "0" ] && C3=1 || C3=0
echo "$MODOUT" | grep -q "Unknown symbol" && C4=1 || C4=0
echo "$MODOUT" | grep -q "disagrees" && C5=1 || C5=0
echo "$MODOUT" | grep -q "exists" && C6=1 || C6=0
[ -z "$MODOUT" ] && C7=1 || C7=0
dmesg 2>/dev/null | grep -q "msm-dwc3" && C8=1 || C8=0
DMESG_ALL=$(dmesg 2>/dev/null)
echo "$DMESG_ALL" | grep -q "already registered" && D1=1 || D1=0
echo "$DMESG_ALL" | grep -q "Unable to handle" && D2=1 || D2=0
echo "$DMESG_ALL" | grep -q "Call trace" && D3=1 || D3=0
echo "$DMESG_ALL" | grep -q "disagrees about version" && D4=1 || D4=0
echo "$DMESG_ALL" | grep -q "Unknown symbol" && D5=1 || D5=0
NLOADED=$(ls /sys/module 2>/dev/null | wc -l)
[ "$NLOADED" -ge 170 ] && D6=1 || D6=0
[ -d /lib/modules ] && D7=1 || D7=0
D8=1   # marca de ronda (ronda 2)
CODE_R2="$C1$C2$C3$C4$C5$C6$C7$C8"
CODE2_R2="$D1$D2$D3$D4$D5$D6$D7$D8"
info "dace-init: BARCODE R2 = $CODE_R2 $CODE2_R2"
if [ "$BARCODE_OK" = "1" ]; then
    # bucle v50: dmesg (14s) → R-chain (12s) → R1 (8s) → R2 (8s) = 42s
    while true; do
        [ -e /sys/kernel/dace_text ] && \
            printf '%s\n' "$P3" > /sys/kernel/dace_text 2>/dev/null
        sleep 14
        echo "$CHAIN 10101010" > /sys/kernel/dace_barcode 2>/dev/null; sleep 12
        echo "$CODE $CODE2" > /sys/kernel/dace_barcode 2>/dev/null; sleep 8
        echo "$CODE_R2 $CODE2_R2" > /sys/kernel/dace_barcode 2>/dev/null; sleep 8
    done
fi
if [ "$BARCODE_OK" != "1" ] && [ -e /sys/kernel/dace_color ]; then
    # Canal B: parpadeos (funciona aunque el barcode esté roto)
    while true; do
        echo 0x00ffff00 > /sys/kernel/dace_color 2>/dev/null; sleep 2
        for v in $F1 $F2 $F3 $F4 $F5 $F6 $F7 $F8; do
            if [ "$v" = "1" ]; then
                echo 0x00ffffff > /sys/kernel/dace_color 2>/dev/null
            else
                echo 0x00202020 > /sys/kernel/dace_color 2>/dev/null
            fi
            sleep 1
            echo 0x00000000 > /sys/kernel/dace_color 2>/dev/null
            sleep 0.5 2>/dev/null || sleep 1
        done
        echo 0x00aa00aa > /sys/kernel/dace_color 2>/dev/null; sleep 2
        info "dace-init: ciclo parpadeos completado ($CODE)"
    done
fi
while true; do sleep 3600; done