#!/bin/sh
# init dace #3 — telemetria FINA por pantalla en cada etapa de carga.
# Logica: cada etapa pinta su estado en dace_text ANTES de ejecutar, asi si
# cuelga, la pantalla se queda con el ultimo mensaje.
info() { echo "minit3: $1" > /dev/kmsg 2>/dev/null; }
ptext() { [ -w /sys/kernel/dace_text ] && printf '%s\n' "$1" > /sys/kernel/dace_text; }

info "MINIT3: inicio"
mount -t proc proc /proc 2>/dev/null
mount -t sysfs sysfs /sys 2>/dev/null
mount -t devtmpfs devtmpfs /dev 2>/dev/null
mkdir -p /dev/pts /sys/kernel/config /dev/usb-ffs/adb
mount -t devpts devpts /dev/pts 2>/dev/null

ptext "PASO 0: mounts OK; cargando shim..."
KREL=$(uname -r)
[ ! -e "/lib/modules/$KREL" ] && ln -sf . "/lib/modules/$KREL" 2>/dev/null

# modprobe existe?
if ! command -v modprobe >/dev/null 2>&1; then
    ptext "NO modprobe binary!"
    while true; do sleep 60; done
else
    ptext "modprobe existe; comprobando /etc/modules.load.dace"
fi

# existe modules.load.dace?
if [ ! -f /etc/modules.load.dace ]; then
    ptext "NO /etc/modules.load.dace"
    ls /etc > /dev/kmsg 2>&1 || true
    while true; do sleep 60; done
fi
NL=$(wc -l < /etc/modules.load.dace)
ptext "modules.load.dace: $NL lineas; shim..."

modprobe google-extcon-usb-shim usb_force_disable_boot=0 2>/dev/kmsg
ptext "shim rc=$?; bucle modulos..."

N=0
if [ -f /etc/modules.load.dace ]; then
    while read mod; do
        case "$mod" in ''|\#*) continue ;; esac
        mod="${mod%.ko}"
        N=$((N+1))
        # pintar CADA modulo antes de cargarlo (si cuelga, queda el nombre)
        [ -w /sys/kernel/dace_text ] && \
            printf 'MOD %03d/%03d %s\n' "$N" "$NL" "$mod" > /sys/kernel/dace_text
        modprobe "$mod" 2>/dev/kmsg
    done < /etc/modules.load.dace
fi
ptext "BUCLE MODULOS TERMINADO ($N cargados)"

while true; do
    ptext "MODS TERMINADO $N VIVO"
    sleep 3
done