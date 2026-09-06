#!/bin/sh
# init minimal de PRUEBA — discrimina:
#   (a) exec /init funciona pero el script aurora cuelga
#   (b)though el initramfs ni se monta (exec falla)
# Pinta /sys/kernel/dace_text (si el kernel lo expone) y listado de lo que ve.
info() { echo "minit: $1" > /dev/kmsg 2>/dev/null; }

info "MINIT: init inicio"
mount -t proc proc /proc 2>/dev/null
mount -t sysfs sysfs /sys 2>/dev/null
mount -t devtmpfs devtmpfs /dev 2>/dev/null

# 1. Pinta telemetria en la pantalla si el kernel la expone
if [ -w /sys/kernel/dace_text ]; then
    printf 'MINIT OK\nroot=%s\n' "$(ls / | tr '\n' ' ')" > /sys/kernel/dace_text
fi

# 2. Lista lo que ve (para diagnosticar la raiz y los modulos)
{
    echo "=== raiz ==="
    ls -la /
    echo "=== /lib/modules ($(ls /lib/modules/*.ko 2>/dev/null | wc -l) .ko) ==="
    ls /lib/modules/ 2>/dev/null | head -5
    echo "=== cmdline ==="
    cat /proc/cmdline 2>/dev/null
    echo "=== uname ==="
    uname -a 2>/dev/null
} > /dev/kmsg 2>&1 || true

# 3. Bonito color VERDE sostenido (0x0000ff00) via dace_text + loop
if [ -w /sys/kernel/dace_text ]; then
    while true; do
        printf 'MINIT VIVO %s\n' "$(date +%s 2>/dev/null)" > /sys/kernel/dace_text
        sleep 2
    done
fi

# fallback: si no hay dace_text, bucle infinito sin hacer nada (evita EDL)
while true; do sleep 60; done