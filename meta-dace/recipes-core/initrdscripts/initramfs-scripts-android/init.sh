#!/bin/sh
# init dace #2 — carga SOLO los modulos first-stage (sin adb, sin gadget, sin
# switch_root). Divide el aurora en piezas: si esto cuelga, son los modulos.
info() { echo "minit2: $1" > /dev/kmsg 2>/dev/null; }

info "MINIT2: inicio"
mount -t proc proc /proc 2>/dev/null
mount -t sysfs sysfs /sys 2>/dev/null
mount -t devtmpfs devtmpfs /dev 2>/dev/null
mkdir -p /dev/pts /sys/kernel/config /dev/usb-ffs/adb
mount -t devpts devpts /dev/pts 2>/dev/null

KREL=$(uname -r)
[ ! -e "/lib/modules/$KREL" ] && ln -sf . "/lib/modules/$KREL" 2>/dev/null

# 1. intentar cargar el shim (si existe)
if command -v modprobe >/dev/null 2>&1; then
    modprobe google-extcon-usb-shim usb_force_disable_boot=0 2>/dev/kmsg
    info "shim modprobe rc=$?"
fi

# 2. loop de modulos desde modules.load.dace (si existe)
N_OK=0; N_FAIL=0; N_TOT=0
if [ -f /etc/modules.load.dace ]; then
    while read mod; do
        case "$mod" in ''|\#*) continue ;; esac
        mod="${mod%.ko}"
        N_TOT=$((N_TOT+1))
        if modprobe "$mod" 2>/dev/kmsg; then
            N_OK=$((N_OK+1))
        else
            N_FAIL=$((N_FAIL+1))
        fi
    done < /etc/modules.load.dace
fi
info "MINIT2: modulos tot=$N_TOT ok=$N_OK fail=$N_FAIL"

# 3. pintar en pantalla
if [ -w /sys/kernel/dace_text ]; then
    printf 'MODS tot=%s ok=%s fail=%s\nuname=%s\n' "$N_TOT" "$N_OK" "$N_FAIL" "$(uname -r)" > /sys/kernel/dace_text
fi

# 4. loop vivo
while true; do
    if [ -w /sys/kernel/dace_text ]; then
        printf 'MODS tot=%s ok=%s fail=%s VIVO\n' "$N_TOT" "$N_OK" "$N_FAIL" > /sys/kernel/dace_text
    fi
    sleep 3
done