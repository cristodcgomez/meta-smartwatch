#!/bin/sh
# dace: persistent power-state log (to verify suspend without depending on adb:
# usb-moded may switch to mass storage when it detects the usb psy).
# Writes to /var/log/dace-power.log every 30 s: suspend_stats/success,
# autosleep, active wake locks, battery capacity and the active wakeup_sources.
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
        echo "battery_status=$(cat /sys/class/power_supply/battery/status 2>/dev/null) current_now=$(cat /sys/class/power_supply/battery/current_now 2>/dev/null)"
        echo "usb=[online=$(cat /sys/class/power_supply/usb/online 2>/dev/null) present=$(cat /sys/class/power_supply/usb/present 2>/dev/null) icl=$(cat /sys/class/power_supply/usb/input_current_limit 2>/dev/null)]"
        echo "extcon=[$(for e in /sys/class/extcon/extcon*; do printf '%s=%s ' "$(cat $e/name 2>/dev/null | sed 's/.*,//')" "$(cat $e/state 2>/dev/null | tr '\n' ',')"; done)]"
        echo "dwc=\"$(cat /sys/bus/platform/devices/4e00000.hsusb/power/runtime_status 2>/dev/null)/$(cat /sys/bus/platform/devices/4e00000.hsusb/power/control 2>/dev/null)\""
        echo "active_wakeup_sources=[$(awk 'NR>1 && $6>0 {print $1}' /sys/kernel/debug/wakeup_sources 2>/dev/null | tr '\n' ' ')]"
    } >> "$LOG" 2>&1
    # trim: so it does not grow without bound on the eMMC
    [ "$(wc -l < "$LOG" 2>/dev/null)" -gt 4000 ] && tail -n 2000 "$LOG" > "$LOG.tmp" 2>/dev/null && mv "$LOG.tmp" "$LOG" 2>/dev/null
    sync
    sleep 30
done
