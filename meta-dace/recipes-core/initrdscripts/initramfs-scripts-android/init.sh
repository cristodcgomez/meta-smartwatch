#!/bin/sh
# v70: stock USB bring-up; reader mode is an explicit build-time choice.
DACE_MODE=usb
PATH=/sbin:/bin:/usr/sbin:/usr/bin
DC=/sys/kernel/dace_core
DG=/sys/kernel/dace_glue
dace_status() {
    c=$(cat "$DC" 2>/dev/null)
    g=$(cat "$DG" 2>/dev/null)
    if [ -w /sys/kernel/dace_text ]; then
        printf '\n\nCORE %s\nGLUE %s\n' "${c:-?}" "${g:-?}" > /sys/kernel/dace_text 2>/dev/null
    fi
    log "core=${c:-?} glue=${g:-?} $*"
}
export PATH
mkdir -p /proc /sys /dev /tmp
LOG=/tmp/dace-init.log
: > "$LOG"
mount -t proc proc /proc >> "$LOG" 2>&1
mount -t sysfs sysfs /sys >> "$LOG" 2>&1
mount -t devtmpfs devtmpfs /dev >> "$LOG" 2>&1
mkdir -p /dev/pts /sys/kernel/config /sys/fs/pstore /dev/usb-ffs/adb
mount -t devpts devpts /dev/pts >> "$LOG" 2>&1

log() {
    printf 'dace-v70: %s\n' "$*" >> "$LOG"
    if [ -c /dev/kmsg ]; then
        printf '<6>dace-v70: %s\n' "$*" > /dev/kmsg 2>/dev/null
    fi
    return 0
}
run() {
    "$@" >> "$LOG" 2>&1
    RUN_RC=$?
    [ "$RUN_RC" -eq 0 ] || log "rc=$RUN_RC: $*"
    return "$RUN_RC"
}
put() {
    { printf '%s\n' "$2" > "$1"; } 2>> "$LOG"
    PUT_RC=$?
    [ "$PUT_RC" -eq 0 ] || log "write rc=$PUT_RC: $1"
    return "$PUT_RC"
}
mounted() { grep -Fq " $1 $2 " /proc/mounts; }
log "mode=$DACE_MODE kernel=$(uname -r)"
log "cmdline=$(cat /proc/cmdline)"
mkdir -p /tmp/pstore
PS_RC=0
if ! mounted /sys/fs/pstore pstore; then
    run mount -t pstore pstore /sys/fs/pstore
    PS_RC=$?
fi
for psfile in /sys/fs/pstore/*; do
    [ -f "$psfile" ] && run cp "$psfile" /tmp/pstore/
done

if [ "$DACE_MODE" = forensic ]; then
    dmesg > /tmp/reader-dmesg.txt 2>> "$LOG"
    : > /tmp/reader-text.txt
    for psfile in /tmp/pstore/console-*; do
        [ -f "$psfile" ] && cat "$psfile" >> /tmp/reader-text.txt
    done
    if [ ! -s /tmp/reader-text.txt ]; then
        printf 'NO CONSOLE\nmount rc=%s\n%s\n' "$PS_RC" "$(uname -r)" > /tmp/reader-text.txt
        grep -iE 'pstore|ramoops|persistent_ram' /tmp/reader-dmesg.txt >> /tmp/reader-text.txt
        ls -l /tmp/pstore >> /tmp/reader-text.txt 2>&1
    fi
    cut -c1-36 /tmp/reader-text.txt > /tmp/reader-pages.txt
    lines=$(wc -l < /tmp/reader-pages.txt)
    pages=$(( (lines + 5) / 6 )); [ "$pages" -gt 0 ] || pages=1
    page=1
    while true; do
        first=$(( (page - 1) * 6 + 1 ))
        text=$(sed -n "${first},$((first + 5))p" /tmp/reader-pages.txt)
        if [ -w /sys/kernel/dace_text ]; then
            printf 'ps %s/%s\n\n\n%s\n' "$page" "$pages" "$text" > /sys/kernel/dace_text
        fi
        sleep 12
        page=$(( page % pages + 1 ))
    done
fi
if [ "$DACE_MODE" != usb ]; then
    log "invalid mode; stopped safely"
    while true; do sleep 3600; done
fi

load_mod() {
    mod_path=$1
    mod_name=${mod_path##*/}; mod_name=${mod_name%.ko}
    mod_sys=$(printf '%s' "$mod_name" | tr '-' '_')
    [ -d "/sys/module/$mod_sys" ] && return 0
    [ -f "$mod_path" ] || { log "missing module $mod_path"; return 1; }
    insmod "$mod_path" > /tmp/insmod-last.err 2>&1
    mod_rc=$?
    if [ "$mod_rc" -ne 0 ]; then
        log "insmod $mod_name rc=$mod_rc"
        cat /tmp/insmod-last.err >> "$LOG"
        head -n 3 /tmp/insmod-last.err | while IFS= read -r errline; do log "$mod_name: $errline"; done
    fi
    return "$mod_rc"
}
if [ -f /lib/modules/modules.load ]; then
    while IFS= read -r module || [ -n "$module" ]; do
        case "$module" in ''|\#*) continue ;; esac
        load_mod "/lib/modules/$module"
    done < /lib/modules/modules.load
else
    log 'missing modules.load'
fi
for module in eud.ko usb_bam.ko phy-generic.ko phy-msm-snps-hs.ko \
              dwc3-msm.ko qpnp-smblite-main.ko qti_battery_charger.ko; do
    load_mod "/lib/modules/$module"
done
for pass in 1 2; do
    for module in /lib/modules/*.ko; do load_mod "$module"; done
done
log 'module loading complete'

G=/sys/kernel/config/usb_gadget/g1
FFS=/dev/usb-ffs/adb
setup_gadget() {
    mounted /sys/kernel/config configfs || run mount -t configfs configfs /sys/kernel/config || return 1
    run mkdir -p "$G/strings/0x409" "$G/configs/c.1/strings/0x409" "$G/functions/ffs.adb" || return 1
    put "$G/idVendor" 0x18d1 && put "$G/idProduct" 0xd002 || return 1
    put "$G/strings/0x409/manufacturer" asteroid || return 1
    put "$G/strings/0x409/product" ticwatch-pro-5 || return 1
    put "$G/strings/0x409/serialnumber" 0123456789 || return 1
    put "$G/configs/c.1/strings/0x409/configuration" adb || return 1
    [ -L "$G/configs/c.1/f1" ] || run ln -s "$G/functions/ffs.adb" "$G/configs/c.1/f1" || return 1
    # The function instance MUST exist before FunctionFS acquires device "adb".
    mounted "$FFS" functionfs || run mount -t functionfs adb "$FFS" -o uid=2000,gid=2000 || return 1
    [ -e "$FFS/ep0" ] || return 1
    return 0
}
ready=0; adbd_pid=; starts=0; last_start=0; last_setup=0
start=$(date +%s); last_status=0; warned=0; previous=
while true; do
    now=$(date +%s)
    if [ "$ready" -eq 0 ] && [ $((now - last_setup)) -ge 10 ]; then
        last_setup=$now
        if setup_gadget; then ready=1; log 'FunctionFS ready'; fi
    fi
    if [ "$ready" -eq 1 ] && { [ -z "$adbd_pid" ] || ! kill -0 "$adbd_pid" 2>/dev/null; }; then
        if [ "$starts" -lt 3 ] && [ $((now - last_start)) -ge 10 ]; then
            # A previous daemon may have closed its descriptors while still bound.
            bound=$(cat "$G/UDC" 2>/dev/null)
            [ -z "$bound" ] || put "$G/UDC" ''
            /bin/adbd >> /tmp/adbd.log 2>&1 &
            adbd_pid=$!; starts=$((starts + 1)); last_start=$now
            log "adbd start=$starts pid=$adbd_pid"
        fi
    fi
    udc=
    for device in /sys/class/udc/*; do
        [ -d "$device" ] || continue
        udc=${device##*/}; break
    done
    alive=0; endpoints=0
    if [ -n "$adbd_pid" ] && kill -0 "$adbd_pid" 2>/dev/null; then alive=1; fi
    if [ -e "$FFS/ep1" ] && [ -e "$FFS/ep2" ]; then endpoints=1; fi
    bound=$(cat "$G/UDC" 2>/dev/null)
    if [ -n "$udc" ] && [ "$alive" -eq 1 ] && [ "$endpoints" -eq 1 ] && [ "$bound" != "$udc" ]; then
        if put "$G/UDC" "$udc"; then bound=$udc; log "bound $udc (host ADB unverified)"; fi
    fi
    state="udc=${udc:-none} ffs=$ready adbd=$alive ep=$endpoints bound=${bound:-none}"
    if [ "$state" != "$previous" ] || [ $((now - last_status)) -ge 30 ]; then
        log "$state"; previous=$state; last_status=$now
        dace_status "$state"
    fi
    if [ "$warned" -eq 0 ] && [ $((now - start)) -ge 120 ] && [ -z "$bound" ]; then
        warned=1
        mkdir -p /sys/kernel/debug
        mounted /sys/kernel/debug debugfs || run mount -t debugfs debugfs /sys/kernel/debug
        [ ! -r /sys/kernel/debug/devices_deferred ] || cp /sys/kernel/debug/devices_deferred /tmp/devices_deferred.txt
        dmesg > /tmp/usb-dmesg.txt 2>> "$LOG"
        log 'not bound after 120s; snapshots saved; no automatic reboot'
    fi
    sleep 3
done
