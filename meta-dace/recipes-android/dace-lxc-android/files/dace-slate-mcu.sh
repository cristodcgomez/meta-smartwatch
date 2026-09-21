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

log() { echo "$(date '+%H:%M:%S') dace-slate-mcu: $*" >> /run/dace-slate-mcu.log; }

# NOTA CRITICA (20-09-2026): este servicio NO escribe a journald ni a la consola
# (StandardOutput=null en el unit). Medido: con journald/logd atascados (pasa en
# arranques cargados) cualquier escritura a journald BLOQUEA, y el script se
# quedaba colgado en su primer mensaje -> 'start operation timed out' y el MCU
# nunca arrancaba. El log va a /run (tmpfs, sin desgaste) y se puede leer luego:
#   cat /run/dace-slate-mcu.log
# Por el mismo motivo ya no se usa lxc-attach en la ruta critica (se cuelga
# cuando lo lanza un unit): pss arranca por la linea 'interface' del .rc y el
# HAL/bluebinder se relanzan matandolos por /proc.

# 2) powerstateservice (vendor.qti.hardware.powerstateservice@1.0).
#    Es el PEER de estado del MCU slate (TWM/deep-sleep): /dev/power_state y
#    /dev/slate_com_dev. Lo arranca el init del contenedor GRACIAS a la linea
#    'interface' que dace-lxc-android-start.sh le añade a su .rc (su .rc original
#    no la trae y por eso nunca arrancaba: 'Could not find
#    ...IPowerStateService/default' cada 60 s).
#    TIENE QUE ESTAR ARRANCADO ANTES DE LEVANTAR EL MCU: sin el, el MCU se queda
#    sin quien le conteste los cambios de estado y el SoC acaba en Oops.
#    AQUI NO SE USA lxc-attach (se cuelga desde un unit): solo se comprueba que
#    el servicio haya abierto /dev/power_state.
for _i in 1 2 3 4 5 6; do
    [ -c /dev/power_state ] && break
    sleep 2
done
if [ -c /dev/power_state ]; then
    log "pss OK (/dev/power_state presente)"
else
    log "AVISO: /dev/power_state ausente: pss no arranco (mirar el .rc/overlay)"
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
    # El HAL de BT se rinde tras ~3 intentos (uno por minuto) si BTSS aun no
    # estaba listo, y NO reintenta solo (el proceso queda vivo pero idle). Con
    # el MCU ya arriba hay que relanzarlo: es exactamente la secuencia verificada
    # en vivo (bring-up completo -> hci0 UP RUNNING con su BD Address).
    # Alimentar (ciclar) el chip de BT: con soc=slate el HAL no vota
    # reguladores y los rieles pm5100_l13/l17 se quedan APAGADOS -> chip mudo.
    # Es lo que hace aurora via /dev/btpower. El ciclo 0->1 ademas resetea el
    # chip, que vuelve a arrancar a 2400 bps (estado que espera el HAL).
    if [ -x /usr/libexec/dace-bt-power.pl ]; then
        if /usr/bin/perl /usr/libexec/dace-bt-power.pl cycle >> /run/dace-slate-mcu.log 2>&1; then
            log "chip BT alimentado (BT_CMD_PWR_CTRL cycle)"
        else
            log "AVISO: fallo el power del chip BT (/dev/btpower)"
        fi
    fi
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
# OJO: el bring-up REAL tarda ~100 s desde aqui: el HAL esta relanzado pero su
# primer intento con el chip ya alimentado llega en el siguiente ciclo (~60 s) y
# la descarga del patch+NVM son unos segundos mas (medido 21-09-2026: hci0 sube
# a los ~90-110 s). El tope anterior (40 x 2 s = 80 s) se quedaba corto y el log
# escupia un AVISO enganoso aunque todo acabara bien: por eso 150 x 2 s = 300 s.
i=0
while [ $i -lt 150 ]; do
    if hciconfig 2>/dev/null | grep -qE "BD Address: ([0-9A-Fa-f]{2}:){5}" && \
       ! hciconfig 2>/dev/null | grep -q "BD Address: 00:00:00:00:00:00"; then
        log "hci0 LISTO: $(hciconfig 2>/dev/null | sed -n 2p | tr -s " ")"
        break
    fi
    i=$((i + 1))
    sleep 2
done
[ $i -ge 150 ] && log "AVISO: hci0 no subio en ~300 s (mirar logcat del contenedor)"
exit 0