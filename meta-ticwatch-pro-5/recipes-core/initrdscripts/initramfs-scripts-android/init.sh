#!/bin/sh

# TicWatch Pro 5 (dace): flujo USB/adb stock con estado textual temporal.

. /machine.conf

status() {
    [ -e /sys/kernel/dace_text ] && printf '%b\n' "$*" > /sys/kernel/dace_text 2>/dev/null
}

setup_devtmpfs() {
    mount -t devtmpfs -o mode=0755,nr_inodes=0 devtmpfs "$1/dev"
    mkdir -p "$1/dev/pts"
    mount -t devpts none "$1/dev/pts"
    [ -e "$1/dev/fd" ]     || ln -sf /proc/self/fd "$1/dev/fd"
    [ -e "$1/dev/stdin" ]  || ln -sf fd/0 "$1/dev/stdin"
    [ -e "$1/dev/stdout" ] || ln -sf fd/1 "$1/dev/stdout"
    [ -e "$1/dev/stderr" ] || ln -sf fd/2 "$1/dev/stderr"
    mkdir -p "$1/dev/socket"
}

is_bound() {
    for entry in "$1"/*; do
        [ -L "$entry" ] && return 0
    done
    return 1
}

mkdir -p /proc /sys /dev
mount -t proc proc /proc
mount -t sysfs sys /sys
setup_devtmpfs ""
mkdir -p /sys/kernel/debug
mount -t debugfs none /sys/kernel/debug 2>/dev/null || true
status "INIT OK"

KREL=$(uname -r)
[ -e "/lib/modules/$KREL" ] || ln -sf . "/lib/modules/$KREL"

while read -r mod; do
    case "$mod" in ''|\#*) continue ;; esac
    status "LOAD\n$mod"
    modprobe "${mod%.ko}" 2>/dev/null || true
done < /lib/modules/modules.load

status "MODULES LOADED\nSETUP GADGET"
mkdir -p /sys/kernel/config
mount -t configfs none /sys/kernel/config 2>/dev/null || true
/usr/bin/android-gadget-setup adb 2>/dev/null || true
/usr/bin/adbd &

TRACE_I=0
while true; do
    CHG=0; PHY=0; GLUE=0; CORE=0
    is_bound /sys/bus/platform/drivers/qcom,qpnp-smblite && CHG=1
    is_bound /sys/bus/platform/drivers/msm-usb-hsphy && PHY=1
    is_bound /sys/bus/platform/drivers/msm-dwc3 && GLUE=1
    is_bound /sys/bus/platform/drivers/dwc3 && CORE=1

    UDC=$(cd /sys/class/udc 2>/dev/null && echo *)
    case "$UDC" in '*'|''|'.'|'..') UDC="" ;; *) UDC=$(echo "$UDC" | awk '{print $1}') ;; esac

    if [ -z "$UDC" ]; then
        if [ "$CORE" = 0 ]; then
            REASON=$(grep -E 'dwc3|4e00000' /sys/kernel/debug/devices_deferred 2>/dev/null | tail -1 | cut -c1-58)
            if [ -n "$REASON" ]; then
                status "D0 $REASON"
            else
                # paginado RAW: ultimas 120 lineas, 10 por pantalla, 8s
                dmesg 2>/dev/null | sed 's/^.*] //' | grep -v '^$' | tail -n 120 > /tmp/dm.txt
                TOTAL=$(wc -l < /tmp/dm.txt)
                if [ "$TOTAL" -gt 0 ]; then
                    PAGE=$(( (TRACE_I % ((TOTAL+9)/10)) + 1 ))
                    TRACE_I=$((TRACE_I+1))
                    INI=$(( (PAGE-1)*10 + 1 ))
                    TXT=$(sed -n "${INI},$((INI+9))p" /tmp/dm.txt | cut -c1-38)
                    status "PAGE $PAGE/$(( (TOTAL+9)/10 )) (final del log)\n$TXT"
                    sleep 8
                    continue
                fi
                status "D0 sin dmesg"
            fi
        else
            status "C$CHG P$PHY G$GLUE D$CORE U0"
        fi
        sleep 2
        continue
    fi

    status "UDC=$UDC\nBIND ADB"
    BOUND=0
    for gadget in /sys/kernel/config/usb_gadget/*; do
        [ -e "$gadget/UDC" ] || continue
        if echo "$UDC" > "$gadget/UDC" 2>/dev/null; then
            BOUND=1
            break
        fi
    done
    status "UDC=$UDC\nADB bound=$BOUND"
    break
done

while true; do sleep 3600; done
