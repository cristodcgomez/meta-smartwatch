#!/bin/sh
# dace: arranca el MCU del slate (remoteproc2) -- de el cuelgan la CORONA y el
# BLUETOOTH (en el reloj, persist.vendor.qcom.bluetooth.soc=slate: el HAL no
# habla con el chip por la UART del AP, sino por el transporte MCT a traves del
# enlace glink del MCU).
#
# EL ORDEN ES CRITICO (medido 20-09-2026):
#   1) los .ko del slate tienen que estar cargados ANTES de arrancar el MCU,
#      porque el notifier SSR se registra en el probe del modulo;
#   2) al hacer `echo start` en el rproc, el subdev SSR de qcom_rproc_slate
#      notifica "slatefw" QCOM_SSR_AFTER_POWERUP y eso dispara:
#        - slatecom_interface: slatecom_set_spi_state(SLATECOM_SPI_FREE), que
#          pide la IRQ "qcom-slate_spi"; su tasklet LEE los registros de estado
#          del MCU por SPI (el camino que antes abortaba el SMMU) y con eso
#          levanta el enlace glink (canales slate-ctrl/slate-event/slate-rsb-ctl)
#          y publica slate_bt_state=ready / slate_dsp_state=ready;
#        - slate_rsb: manda SLATERSB_CONFIGR_RSB al MCU.
#   3) el `enable` del RSB (corona) se pide ANTES a proposito: si el driver aun
#      no esta configurado guarda el pedido en pending_enable y lo aplica solo
#      en cuanto llega el CONFIGR (el write devuelve ENOMEDIUM, es normal).
#
# Sin todo esto el MCU se quedaba OFFLINE y el enlace glink "channel connection
# time out" -> ni rueda ni BT. Cargar los .ko del slate a mano y arrancar el MCU
# un dia cualquiera no basta: los notifiers nunca se disparan.
set -u

log() { echo "dace-slate-mcu: $*"; }

# 1) Drivers del RSB: no se autocargan por udev (el resto de la pila slate si).
modprobe slate_rsb       2>/dev/null && log "slate_rsb cargado"
modprobe slatersb_rpmsg  2>/dev/null && log "slatersb_rpmsg cargado"

# 2) Esperar a que exista el remoteproc del MCU (qcom_rproc_slate lo crea al
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
        # 3) Corona: pedir el enable (queda pendiente hasta el CONFIGR_RSB)
        if [ -w /sys/devices/platform/soc/soc:qcom,slate-rsb/enable ]; then
            echo 1 > /sys/devices/platform/soc/soc:qcom,slate-rsb/enable 2>/dev/null \
                && log "RSB enable=1" \
                || log "RSB enable: pedido encolado (ENOMEDIUM = aun sin CONFIGR_RSB, normal)"
        fi
        # 4) Arrancar el MCU -> notificacion SSR -> SPI FREE + CONFIGR_RSB + glink
        log "arrancando el MCU (remoteproc2)..."
        if echo start > /sys/class/remoteproc/remoteproc2/state 2>/dev/null; then
            log "MCU state=$(cat /sys/class/remoteproc/remoteproc2/state 2>/dev/null)"
        else
            log "AVISO: fallo el arranque del MCU (firmware? ver dace-vendor-mount)"
        fi
        ;;
esac

# 5) Esperar (max ~10 s) a que el enlace quede util: BT ready y canal del RSB.
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