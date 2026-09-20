#!/bin/sh
# dace: arranca el MCU del slate (remoteproc2) para el BLUETOOTH.
#
# En el reloj, persist.vendor.qcom.bluetooth.soc=slate: el HAL de BT no habla
# con el chip por la UART del AP, sino por el transporte MCT a traves del
# enlace glink del MCU, y el MCU es quien alimenta/relojea el chip. Sin MCU el
# chip esta MUDO (Get Version nunca contesta).
#
# EL ORDEN Y EL MOMENTO IMPORTAN (medido 20-09-2026):
#   1) los .ko del slate ya estan cargados (udev) cuando corre esto;
#   1b) `powerstateservice-hal-1-0` (pss) tiene que estar ARRANCADO: es el peer
#      de estado del MCU. Su .rc NO trae linea 'interface' -> ctl.start.
#      Sin el, el MCU se queda sin quien le conteste y el SoC acaba en un Oops
#      (salto a la direccion 0) a los pocos segundos;
#   2) al hacer `echo start` en el rproc, el subdev SSR de qcom_rproc_slate
#      notifica "slatefw" QCOM_SSR_AFTER_POWERUP -> slatecom_set_spi_state(
#      SLATECOM_SPI_FREE) pide la IRQ "qcom-slate_spi" y su tasklet lee los
#      registros de estado del MCU por SPI (el camino que abortaba el SMMU) ->
#      levanta el enlace glink y publica slate_bt_state=ready;
#   3) el MCU NO se arranca al principio del boot: arrancarlo a los ~23 s
#      (mientras el contenedor levanta sus HALs) acababa en ese mismo Oops.
#      Arrancado con el sistema ya arriba (unidad Ordered after graphical.target
#      + margen) es estable y es cuando el HAL lo aprovecha.
#
# CORONA (pendiente, NO en este servicio): el RSB (slate_rsb/slatersb_rpmsg +
# el `enable` de /sys/.../slate-rsb/enable) se probo en vivo y TUMBA el SoC
# (reset a fastboot) incluso con el MCU ya arrancado y pss en marcha, asi que
# queda fuera hasta arreglarlo aparte (ver AGENTS.md).
set -u

log() { echo "dace-slate-mcu: $*"; }

# 2) powerstateservice (vendor.qti.hardware.powerstateservice@1.0).
#    Es el PEER de estado del MCU slate (TWM/deep-sleep): el fichero power_state
#    y /dev/slate_com_dev. Su .rc NO trae linea 'interface' -> igual que
#    allocator/composer, hay que arrancarlo con ctl.start (dace-lxc-android-start
#    ademas le añade la linea 'interface' al .rc, asi init tambien lo arranca
#    solo si algun cliente lo pide).
#    TIENE QUE ESTAR ARRANCADO ANTES DE LEVANTAR EL MCU: sin el, el MCU se queda
#    sin quien le conteste los cambios de estado y el SoC se RESETEA ~8 s despues
#    de subir el enlace glink (medido 20-09-2026). El container pide este
#    servicio a gritos ('Could not find ...IPowerStateService/default').
#    OJO: todos los lxc-attach van con `timeout`: en 2 de 3 arranques se quedo
#    colgado indefinidamente y el servicio nunca llegaba a arrancar el MCU.
#    Y solo 3 intentos (8 s): mas intentos = cada uno consume el timeout del
#    unit y acababamos en 'start operation timed out' sin arrancar el MCU.
i=0
while [ $i -lt 3 ]; do
    timeout 8 lxc-attach -n android -- /system/bin/getprop 2>/dev/null | grep -q . && break
    i=$((i + 1))
    sleep 2
done
if timeout 8 lxc-attach -n android -- /system/bin/setprop ctl.start powerstateservice-hal-1-0 2>/dev/null; then
    log "powerstateservice-hal-1-0 ctl.start enviado"
else
    log "AVISO: ctl.start de pss no respondio (el .rc con 'interface' deberia arrancarlo solo)"
fi
# Comprobar por sysfs/proc, sin lxc-attach: el fichero /dev/power_state y
# /dev/slate_com_dev los abre el propio servicio.
for _i in 1 2 3 4 5; do
    [ -c /dev/power_state ] && break
    sleep 2
done
log "pss: /dev/power_state $([ -c /dev/power_state ] && echo presente || echo ausente)"

# 3) Esperar a que exista el remoteproc del MCU (qcom_rproc_slate lo crea al
#    probe; su .ko tambien lo pide udev, pero puede ir con retraso).
i=0
while [ $i -lt 20 ]; do
    [ -e /sys/class/remoteproc/remoteproc2/state ] && break
    i=$((i + 1))
    sleep 1
done
if [ ! -e /sys/class/remoteproc/remoteproc2/state ]; then
    log "AVISO: no existe /sys/class/remoteproc/remoteproc2/state (pila slate no cargada)"
    exit 0
fi
case "$(cat /sys/class/remoteproc/remoteproc2/state 2>/dev/null)" in
    running)
        log "el MCU ya estaba arrancado"
        ;;
    *)
        # CORONA (pendiente): aqui iba el enable del RSB
        #   echo 1 > /sys/devices/platform/soc/soc:qcom,slate-rsb/enable
        # Va desactivado: el RSB tumba el SoC. Ver la cabecera.
        # 5) Arrancar el MCU -> notificacion SSR -> SPI FREE + glink -> BT listo
        log "arrancando el MCU (remoteproc2)..."
        if echo start > /sys/class/remoteproc/remoteproc2/state 2>/dev/null; then
            log "MCU state=$(cat /sys/class/remoteproc/remoteproc2/state 2>/dev/null)"
        else
            log "AVISO: fallo el arranque del MCU (firmware? ver dace-vendor-mount)"
        fi
        ;;
esac

# 6) Esperar (max ~10 s) a que el enlace quede util: BT ready y canal del RSB.
i=0
while [ $i -lt 20 ]; do
    bt="$(cat /sys/kernel/slate_bt_state/slate_bt_state 2>/dev/null)"
    [ "$bt" = "ready" ] && break
    i=$((i + 1))
    sleep 1
done
log "slate_bt_state=${bt:-?} dsp_state=$(cat /sys/kernel/slate_dsp_state/slate_dsp_state 2>/dev/null)"
if [ "$(cat /sys/kernel/slate_bt_state/slate_bt_state 2>/dev/null)" = "ready" ]; then
    # El HAL de BT se rinde tras ~3 intentos (uno por minuto) si BTSS aun no
    # estaba listo, y NO reintenta solo (el proceso queda vivo pero idle). Con
    # el MCU ya arriba hay que relanzarlo: es exactamente la secuencia verificada
    # en vivo (bring-up completo -> hci0 UP RUNNING con su BD Address).
    # HAL de BT y su CLIENTE, relanzados SIN lxc-attach (medido 20-09-2026:
    # `lxc-attach` se cuelga cuando lo lanza un unit de systemd con el sistema
    # cargado -- dbus/systemd saturados: desde el shell funciona, desde un
    # service no). En su lugar los matamos por /proc: el init del contenedor
    # relanza el HAL (esta verificado: cambia de pid) y systemd relanza
    # bluebinder (Restart=always). Sin un bluebinder FRESCO el HAL no llega a
    # inicializar ("Waiting for bluetooth service" para siempre) y hci0 se
    # queda sin BD address. Con ambos frescos + slate listo -> hci0 UP RUNNING.
    for _p in /proc/[0-9]*; do
        _c=$(cat "$_p/comm" 2>/dev/null)
        case "$_c" in
            *bluetooth@1.0*) kill -9 "${_p#/proc/}" 2>/dev/null && log "HAL BT relanzado (kill ${_p#/proc/})" ;;
            bluebinder)      kill -9 "${_p#/proc/}" 2>/dev/null && log "bluebinder relanzado (kill ${_p#/proc/})" ;;
        esac
    done
    log "slate OK (BT listo)"
else
    log "AVISO: slate_bt_state no esta ready (revisar el enlace glink)"
fi

# 7) Esperar a que el controlador quede operativo (hci0 con BD address).
i=0
while [ $i -lt 40 ]; do
    if hciconfig 2>/dev/null | grep -qE "BD Address: ([0-9A-Fa-f]{2}:){5}"; then
        log "hci0 LISTO: $(hciconfig 2>/dev/null | sed -n 2p | tr -s " ")"
        break
    fi
    i=$((i + 1))
    sleep 2
done
[ $i -ge 40 ] && log "AVISO: hci0 no subio en ~80 s (mirar logcat del contenedor)"
exit 0