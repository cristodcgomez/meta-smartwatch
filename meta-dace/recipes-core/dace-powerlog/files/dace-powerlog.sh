#!/bin/sh
# dace: log persistente del estado de energía (para verificar el suspend sin
# depender de adb: usb-moded puede pasar a mass storage al detectar la psy usb).
# Escribe en /var/log/dace-power.log cada 30 s: suspend_stats/success, autosleep,
# wake locks activos, capacidad de batería y las wakeup_sources activas.
LOG=/var/log/dace-power.log
echo "=== dace-powerlog start $(date) ===" >> "$LOG"
while true; do
    {
        echo "--- $(date) up=$(cut -d' ' -f1 /proc/uptime)s ---"
        echo "autosleep=$(cat /sys/power/autosleep 2>/dev/null)"
        echo "suspend_success=$(cat /sys/power/suspend_stats/success 2>/dev/null) fail=$(cat /sys/power/suspend_stats/fail 2>/dev/null)"
        echo "last_failed_dev=$(cat /sys/power/suspend_stats/last_failed_dev 2>/dev/null)"
        echo "wake_lock=[$(cat /sys/power/wake_lock 2>/dev/null | tr '\n' ' ')]"
        echo "battery_capacity=$(cat /sys/class/power_supply/battery/capacity 2>/dev/null)"
        echo "active_wakeup_sources=[$(awk 'NR>1 && $6>0 {print $1}' /sys/kernel/debug/wakeup_sources 2>/dev/null | tr '\n' ' ')]"
    } >> "$LOG" 2>&1
    # recorte: que no crezca sin límite en la eMMC
    [ "$(wc -l < "$LOG" 2>/dev/null)" -gt 4000 ] && tail -n 2000 "$LOG" > "$LOG.tmp" 2>/dev/null && mv "$LOG.tmp" "$LOG" 2>/dev/null
    sync
    sleep 30
done
