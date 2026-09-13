#!/bin/sh
# Arranca los servicios HAL de graficos del contenedor Android.
#
# POR QUE HACE FALTA: los .rc del vendor del T5 declaran los servicios
# (vendor.qti.hardware.display.composer / .allocator) pero SIN la linea
# 'interface', asi que el 'ctl.interface_start' que hwservicemanager emite por
# cada getService() no se mapea a ningun servicio y el init NO los arranca.
# Sin ellos, libhybris/lipstick no puede crear el cliente del composer ni
# asignar buffers -> el compositor se bloquea y la pantalla queda negra
# (aunque el CRTC este enabled y wayland-0 exista).
#
# La documentacion de porting lo llama "starting the right android boot
# services". Se lanzan con el mecanismo propio del init de Android (ctl.start),
# que respeta SELinux, via lxc-attach (ruta ABSOLUTA: el contenedor no tiene
# /bin/sh).
set -u
for i in $(seq 1 60); do
    # esperar a que el contenedor tenga hwservicemanager
    if lxc-attach -n android -- /system/bin/getprop 2>/dev/null | grep -q .; then
        break
    fi
    sleep 2
done

for svc in vendor.qti.hardware.display.allocator vendor.qti.hardware.display.composer; do
    lxc-attach -n android -- /system/bin/setprop ctl.start "$svc" 2>/dev/null
    echo "dace-lxc-hal-start: ctl.start $svc"
    sleep 2
done

# TACTIL: cargar el driver del RAYDIUM AHORA (no antes). Con un driver de
# táctil presente desde el arranque, el composer-service de Qualcomm muere con
# SIGSEGV ~0.2 s despues de crear /dev/socket/pps y la UI se queda sin composer
# (el stack de display reacciona al panel/táctil). Se deja para el final.
#
# Tactil Zinitix: CADENA DEL VENDOR (stock .ko, ver AGENTS.md §5). Requiere el
# kernel con el slot ABI de cfi_check + SCS (dace-module-cfi-abi-slot.patch,
# CONFIG_SHADOW_CALL_STACK). Nuestro zinitix mainline ya no existe (=n en el
# fragment). Orden exacto medido en vivo:
#   rpmsg del bridge -> bridge -> mobvoi_rpmsg -> mobvoi -> zinitix-i2c
modprobe panel_event_notifier 2>/dev/null
VD=/usr/lib/dace-vendor-modules
for m in slate_events_bridge_rpmsg slate_events_bridge slate_mobvoi_rpc_rpmsg slate_mobvoi_rpc zinitix-i2c; do
    insmod "$VD/$m.ko" 2>/dev/null \
        && echo "dace-lxc-hal-start: vendor $m cargado" \
        || echo "dace-lxc-hal-start: aviso, no se pudo cargar $m"
done
sleep 3
grep -q "zinitix_ts" /proc/bus/input/devices 2>/dev/null && echo "dace-hal: tactil PRESENTE (zinitix_ts vendor)" \
    || echo "dace-hal: tactil AUSENTE"

# Comprobacion: que el servicio responda (el cliente lo pide por el bus)
sleep 5
lxc-attach -n android -- /system/bin/sh -c '
    for s in allocator composer; do
        if ps -A 2>/dev/null | grep -q "$s-service"; then echo "dace-hal: $s-service RUNNING"; else echo "dace-hal: $s-service MISSING"; fi
    done' 2>/dev/null
