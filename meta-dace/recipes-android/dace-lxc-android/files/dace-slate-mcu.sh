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
#    allocator/composer, hay que arrancarlo con ctl.start.
#    TIENE QUE ESTAR ARRANCADO ANTES DE LEVANTAR EL MCU: sin el, el MCU se queda
#    sin quien le conteste los cambios de estado y el SoC se RESETEA ~8 s despues
#    de subir el enlace glink (medido 20-09-2026: con pss antes del MCU el
#    sistema aguanta; sin el, reset duro a fastboot). El container pide este
#    servicio a gritos ('Could not find ...IPowerStateService/default').
i=0
while [ $i -lt 60 ]; do
    lxc-attach -n android -- /system/bin/getprop 2>/dev/null | grep -q . && break
    i=$((i + 1))
    sleep 2
done
if lxc-attach -n android -- /system/bin/setprop ctl.start powerstateservice-hal-1-0 2>/dev/null; then
    sleep 2
    log "powerstateservice-hal-1-0 init.svc=$(lxc-attach -n android -- /system/bin/getprop init.svc.powerstateservice-hal-1-0 2>/dev/null)"
else
    log "AVISO: no se pudo arrancar powerstateservice-hal-1-0 (el MCU puede resetear el SoC)"
fi

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
    log "slate OK (BT listo; el HAL del contenedor puede arrancar)"
else
    log "AVISO: slate_bt_state no esta ready (revisar el enlace glink)"
fi
exit 0