#!/bin/sh
# dace: carga EXPLICITA de la cadena vendor de /etc/modules-load.d/dace-post-rootfs.conf
#
# ¿Por que no basta systemd-modules-load? Porque kmod aplica el blacklist de
# /etc/modprobe.d/00-dace-vendor-blacklist.conf como *deny-list* tambien al
# `modprobe` que hace systemd-modules-load: en el journal sale
#     Module 'wlan' is deny-listed (by kmod)
# y NO lo carga. En cambio un `modprobe` explicito desde un shell/script SI
# ignora la deny-list (el blacklist solo afecta al autoload por alias).
# Por eso este servicio hace el modprobe a mano, en orden, tolerando fallos.
#
# El blacklist SIGUE siendo necesario: es lo que impide que udev cargue los 76
# .ko vendor por modalias en el coldplug (eso tumbaba el SoC a EDL).

CONF=/etc/modules-load.d/dace-post-rootfs.conf
[ -r "$CONF" ] || exit 0

# Dependencias que viven en el initramfs pero que por orden pueden no estar
# (cfg80211 lo arrastra wlan por dep, no hace falta forzarlo).
# OJO: algun modprobe se queda BLOQUEADO (visto con pmw5100-spmi_dlkm, que no
# tiene device en este DT): sin timeout el servicio se queda en 'activating'
# para siempre. timeout evita ese cuelgue (TMOUT no aplica a modprobe).
rc=0
while IFS= read -r line; do
    case "$line" in
        ''|\#*) continue ;;
    esac
    # por si la linea trae comentario al final
    mod=${line%%#*}
    mod=$(echo "$mod" | tr -d ' \t')
    [ -n "$mod" ] || continue
    if timeout 20 modprobe "$mod" 2>/dev/null; then
        echo "dace-modules-load: $mod OK"
    else
        echo "dace-modules-load: $mod FAIL (o timeout)"
        rc=1
    fi
done < "$CONF"

exit $rc
