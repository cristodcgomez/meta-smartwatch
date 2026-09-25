#!/bin/sh
# dace: bring-up de la WLAN (qcacld/icnss2) estilo aurora.
#
# QUE HACE (y por que en este orden):
#   1) ADSP arriba. El firmware del modem (WPSS) y el del WLAN esperan al ADSP
#      vivo (via tmr_slave2). dace-vendor-mount ya lo arranca; aqui solo se
#      comprueba.
#   2) Cadena WLAN del rootfs (qcacld + cnss glue). dace-modules-load.service
#      ya la carga; aqui se re-fuerza de forma idempotente por si el orden o un
#      fallo puntual la dejaron a medias. El .ko `wlan` es el driver qcacld y
#      `icnss2` el subsistema integrado que hace de puente QMI (WLFW) con el
#      firmware del modem.
#   3) Esperar al MCU del slate. En dace el nodo icnss trae `qcom,is_slate_rfa`
#      (la RFA del WLAN vive en el MCU slate): icnss2 BLOQUEA su conectividad
#      hasta el SSR AFTER_POWERUP de "slatefw". El MCU lo arranca
#      dace-slate-mcu.service (tarde, ~60 s); aqui esperamos.
#   4) cnss-daemon dentro del contenedor. Necesita /data/vendor/wifi/sockets
#      (lo crea dace-lxc-android-start.sh ANTES de lanzar el init de Android,
#      si no `Fail to bind user socket`). Si no ha arrancado, se lanza con
#      ctl.start (con timeout: lxc-attach se cuelga desde un unit).
#   5) Arrancar el modem (remoteproc1). El servicio WLFW (QMI 0x45) que espera
#      icnss2 lo sirve el firmware del WPSS del modem; sin modem no hay `wlan0`.
#      GATEADO tras /etc/dace-kick-modem: hoy el firmware del modem muere con
#      `DOG detects stalled initialization` a los ~40 s (AGENTS, PLAN-WLAN) y
#      con recovery=enabled NO tumba el reloj, pero tampoco da WLAN. Cuando el
#      bloqueo del modem se resuelva, basta con crear ese fichero.
#   6) Esperar `wlan0` y volcar un diagnostico a /var/log/dace-wlan.log.
#
# AURORA: su aurora-vendor-mount.sh arranca el modem sin gate (y convive con
# sus crashes: "modem perpetually crashes & recovers"). Nosotros lo dejamos
# gateado para no meter un crash-loop en un reloj que hoy es estable, pero la
# cadena (modulos + ADSP + cnss + firmware_mnt) es exactamente la suya.
set -u

LOG=/var/log/dace-wlan.log
log() {
    _l="$(date '+%H:%M:%S') dace-wlan: $*"
    echo "$_l" >> /run/dace-wlan.log
    echo "$_l" >> "$LOG" 2>/dev/null
    sync 2>/dev/null
}

# NO escribir a journald/consola (StandardOutput=null): con journald atascado la
# escritura BLOQUEA y el unit muere por timeout (misma leccion que dace-slate-mcu).

log "=== bring-up WLAN ==="

# 1) ADSP -------------------------------------------------------------------
i=0
while [ $i -lt 60 ]; do
    [ "$(cat /sys/class/remoteproc/remoteproc0/state 2>/dev/null)" = "running" ] && break
    i=$((i + 1)); sleep 1
done
log "adsp=$(cat /sys/class/remoteproc/remoteproc0/state 2>/dev/null)"

# 2) cadena WLAN ------------------------------------------------------------
# google_wlan_mac lee la MAC del DT (/chosen/config, que el ABL de Mobvoi no
# crea) y puede fallar: es inocuo, qcacld cae a la MAC de WCNSS_qcom_cfg.ini.
for _m in cfg80211 cnss_utils google_wlan_mac cnss_prealloc cnss_nl \
          wlan_firmware_service cnss_plat_ipc_qmi_svc icnss2 wlan; do
    modprobe "$_m" 2>/dev/null
done
_n=$(lsmod 2>/dev/null | grep -cE '^(wlan|icnss2|cnss_utils|cnss_prealloc|cnss_nl|wlan_firmware_service|cnss_plat_ipc_qmi_svc) ')
log "cadena WLAN cargada ($_n modulos)"

# 3) MCU slate --------------------------------------------------------------
i=0
while [ $i -lt 300 ]; do
    [ "$(cat /sys/kernel/slate_bt_state/slate_bt_state 2>/dev/null)" = "ready" ] && break
    i=$((i + 1)); sleep 1
done
log "slate_bt_state=$(cat /sys/kernel/slate_bt_state/slate_bt_state 2>/dev/null) (esperado ready)"

# 4) cnss-daemon en el contenedor ------------------------------------------
if ! grep -ql cnss-daemon /proc/[0-9]*/comm 2>/dev/null; then
    # /data/vendor/wifi/sockets ya existe (lo crea dace-lxc-android-start.sh):
    # cnss-daemon bindea su user socket y luego wlfw_start.
    timeout 15 lxc-attach -n android -- /system/bin/setprop ctl.start cnss-daemon 2>/dev/null
    sleep 3
fi
if grep -ql cnss-daemon /proc/[0-9]*/comm 2>/dev/null; then
    log "cnss-daemon corriendo"
else
    log "AVISO: cnss-daemon NO corre (¿/data/vendor/wifi/sockets?)"
fi

# 5) arrancar el modem (gate) ----------------------------------------------
if [ -e /etc/dace-kick-modem ]; then
    if [ "$(cat /sys/class/remoteproc/remoteproc1/state 2>/dev/null)" = "offline" ]; then
        log "arrancando el modem (remoteproc1)..."
        echo start > /sys/class/remoteproc/remoteproc1/state 2>/dev/null
    fi
    log "mss=$(cat /sys/class/remoteproc/remoteproc1/state 2>/dev/null)"
else
    log "modem NO arrancado (crear /etc/dace-kick-modem para intentar la WLAN)"
fi

# 6) esperar wlan0 ----------------------------------------------------------
i=0
while [ $i -lt 75 ]; do
    if ip -o link 2>/dev/null | grep -q "wlan0"; then
        log "wlan0 ARRIBA: $(ip -o link show wlan0 2>/dev/null)"
        break
    fi
    i=$((i + 1)); sleep 2
done
[ $i -ge 75 ] && log "AVISO: wlan0 no aparece"

# Diagnostico para la proxima sesion (se puede leer sin adb).
{
    echo "=== wlan report $(date) ==="
    echo "-- interfaces --"; ip -o link 2>/dev/null | grep -iE "wlan|wifi" || echo "(sin wlan)"
    echo "-- rprocs --"; for r in /sys/class/remoteproc/remoteproc*; do
        echo "  $(basename $r)=$(cat $r/state 2>/dev/null)"; done
    echo "-- slate --"; cat /sys/kernel/slate_bt_state/slate_bt_state 2>/dev/null; echo
    echo "-- cnss-daemon --"; grep -l cnss-daemon /proc/[0-9]*/comm 2>/dev/null
    echo "-- services QRTR del modem (0x45=WLFW) --"
    grep -aoE "service_announce_new: \[0x[0-9a-f]+:0x[0-9a-f]+\]@\[0x[0-9a-f]+:0x[0-9a-f]+\]" \
        /sys/kernel/debug/ipc_logging/qrtr_ns/log 2>/dev/null | sort -u
    echo "-- icnss (WLFW/MSA) --"
    grep -iE "WLFW|server arrive|MSA|FW is ready|FW Initialization" \
        /sys/kernel/debug/ipc_logging/icnss/log 2>/dev/null | tail -15
} >> "$LOG" 2>/dev/null
sync
exit 0
