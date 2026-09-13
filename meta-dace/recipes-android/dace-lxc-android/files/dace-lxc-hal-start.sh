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
modprobe raydium_i2c_ts 2>/dev/null && echo "dace-lxc-hal-start: tactil Raydium RM32380 cargado" \
    || echo "dace-lxc-hal-start: aviso, no se pudo cargar raydium_i2c_ts"
sleep 3
grep -q "Raydium" /proc/bus/input/devices 2>/dev/null && echo "dace-hal: táctil Raydium PRESENTE" \
    || echo "dace-hal: táctil Raydium AUSENTE (revisar dmesg: raydium/rgpio)

# Comprobacion: que el servicio responda (el cliente lo pide por el bus)
sleep 5
lxc-attach -n android -- /system/bin/sh -c '
    for s in allocator composer; do
        if ps -A 2>/dev/null | grep -q "$s-service"; then echo "dace-hal: $s-service RUNNING"; else echo "dace-hal: $s-service MISSING"; fi
    done' 2>/dev/null
