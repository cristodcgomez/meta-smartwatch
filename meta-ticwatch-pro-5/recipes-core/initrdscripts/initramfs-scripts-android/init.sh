#! /bin/sh

# TicWatch Pro 5 (dace) initramfs init — v55 SLIM + FORENSE
#
# Pantalla: solo CYAN al arrancar (señal de "estamos dentro") y MAGENTA si el
# gadget USB llega a bindear (adb). Todo lo demás: páginas de texto con el log
# del boot ANTERIOR (pstore console-ramoops: sobrevive a los freezes) y el
# estado del boot actual + un único barcode R-chain.
#
# Estrategia: el freeze congela el boot actual, pero console-ramoops conserva
# el log del kernel hasta el instante del freeze. En el boot siguiente se
# muestra en pantalla. Después se reproduce el freeze (rebind rpmcc/gcc/gdsc/
# eud; el glue se reprueba solo vía deferred-probe al registrarse gcc).

. /machine.conf

info() { echo "init-dace: $1" > /dev/kmsg 2>/dev/null; echo "init-dace: $1" > /dev/console 2>/dev/null; }

# helpers de texto (solo bash)
wrap33() {
    local l
    while IFS= read -r l || [ -n "$l" ]; do
        while [ ${#l} -gt 33 ]; do
            printf '%s\n' "${l:0:33}"
            l="${l:33}"
        done
        printf '%s\n' "$l"
    done
}
firstlines() {
    local n=$1 l c=0
    while IFS= read -r l; do
        [ "$c" -ge "$n" ] && break
        printf '%s\n' "$l"
        c=$((c+1))
    done
}
drv_bound() { # $1 = nombre de driver platform; Y si tiene algún device bindeado
    local f
    for f in "/sys/bus/platform/drivers/$1/"*; do
        case "${f##*/}" in bind|unbind|module|uevent) ;; *) [ -e "$f" ] && { echo Y; return; } ;; esac
    done
    echo N
}

setup_devtmpfs() {
    mount -t devtmpfs -o mode=0755,nr_inodes=0 devtmpfs $1/dev
    mkdir $1/dev/pts
    mount -t devpts none $1/dev/pts/
    test -c $1/dev/fd     || ln -sf /proc/self/fd $1/dev/fd
    test -c $1/dev/stdin  || ln -sf fd/0 $1/dev/stdin
    test -c $1/dev/stdout || ln -sf fd/1 $1/dev/stdout
    test -c $1/dev/stderr || ln -sf fd/2 $1/dev/stderr
    test -c $1/dev/socket || mkdir -m 0755 $1/dev/socket
}

info "dace-init: v55 mounting proc/sys/devtmpfs ..."
mkdir -m 0755 /proc;  mount -t proc proc /proc
mkdir -m 0755 /sys;   mount -t sysfs sys /sys
mkdir -p /dev;        setup_devtmpfs ""

# ── CYAN: única señal de color de arranque (init vivo) ──
[ -e /sys/kernel/dace_color ] && echo 0x0000ffff > /sys/kernel/dace_color 2>/dev/null
mount -t debugfs none /sys/kernel/debug 2>/dev/null

# ── FORENSE: log del boot ANTERIOR vía pstore (sobrevive al freeze) ──
mount -t pstorefs pstore /sys/fs/pstore 2>/dev/null
PLOG=$(cat /sys/fs/pstore/console-ramoops-0 2>/dev/null | tail -c 1400)
PLEN=${#PLOG}
PMLOG=$(cat /sys/fs/pstore/pmsg-ramoops-0 2>/dev/null | tail -c 350)
info "dace-init: pstore console-ramoops bytes=$PLEN"
# snapshot temprano del dmesg actual a pmsg (sobrevive si este boot congela)
dmesg 2>/dev/null > /dev/pmsg0 2>/dev/null

# ── módulos (cadena probada v31+: shim + modules.load en 2 pasadas) ──
KREL=$(uname -r)
if [ -d /lib/modules ]; then
    [ ! -e "/lib/modules/$KREL" ] && ln -sf . "/lib/modules/$KREL" 2>/dev/null
    modprobe google-extcon-usb-shim usb_force_disable_boot=0 2>/dev/kmsg && \
        info "dace-init: usb_shim OK" || info "dace-init: usb_shim FAILED/no-op"
    NMODS=0
    for PASS in 1 2; do
        while read -r m; do
            case "$m" in ''|\#*) continue ;; esac
            [ -d "/sys/module/${m%.ko}" ] && continue
            modprobe "${m%.ko}" 2>/dev/kmsg || \
                info "dace-init: pass$PASS modprobe $m FAILED"
            NMODS=$((NMODS+1))
        done < /lib/modules/modules.load
    done
    info "dace-init: $NMODS intentos de carga completados"
fi

# ── gadget adb preparado (por si el UDC llega a existir) ──
mkdir -p /sys/kernel/config
mount -t configfs none /sys/kernel/config 2>/dev/null
if [ -x /usr/bin/android-gadget-setup ]; then
    /usr/bin/android-gadget-setup adb 2>/dev/kmsg
fi
/usr/bin/adbd &
info "dace-init: adbd lanzado"

# ── trybind: bind de probe en subshell + timeout (el stdout del subshell va a
#    /dev/null para no retener la pipe de la sustitución; bug corregido v54) ──
trybind() { # $1=compatible $2=driver [$3=regulator-name opcional]
    local d dev="" pid t rc
    for d in /sys/bus/platform/devices/*; do
        [ -e "$d/of_node/compatible" ] || continue
        grep -qa "$1" "$d/of_node/compatible" 2>/dev/null || continue
        if [ -n "$3" ]; then
            [ "$(cat "$d/of_node/regulator-name" 2>/dev/null)" = "$3" ] || continue
        fi
        dev="${d##*/}"
    done
    [ -z "$dev" ] && { echo N; return; }
    [ -e "/sys/bus/platform/devices/$dev/driver" ] && { echo Y; return; }
    rm -f /tmp/rb_rc
    ( echo "$dev" > "/sys/bus/platform/drivers/$2/bind" 2>/dev/kmsg
      echo $? > /tmp/rb_rc ) >/dev/null 2>&1 &
    pid=$!; t=0
    while [ "$t" -lt 12 ] && kill -0 "$pid" 2>/dev/null; do
        sleep 1; t=$((t+1))
    done
    if kill -0 "$pid" 2>/dev/null; then
        info "v55: bind $2 <- $dev COLGADO >12s"
        echo H; return
    fi
    rc=$(cat /tmp/rb_rc 2>/dev/null)
    info "v55: bind $2 <- $dev rc=$rc"
    echo "${rc:-X}"
}

# ── REPRODUCCIÓN del freeze: rpmcc/gcc/gdsc/eud. El glue NO se bindea a mano:
#    al registrarse gcc, deferred-probe reprueba el glue solo (pasó en v52-v54
#    y apareció UDC). Si el freeze se reproduce, el SIGUIENTE boot muestra el
#    log de hasta dónde llegó el kernel (página PREV). ──
RBCC=$(trybind "qcom,rpmcc-monaco" qcom-clk-smd-rpm)
RBGCC=$(trybind "qcom,monaco-gcc" gcc-monaco)
RBGD=$(trybind "qcom,gdsc" gdsc gcc_usb20_prim_gdsc)
RBEU=$(trybind "qcom,msm-eud" msm-eud)
sleep 3
# segundo snapshot a pmsg (post-rebind; si el freeze viene ahora, queda cerca)
dmesg 2>/dev/null > /dev/pmsg0 2>/dev/null

# ── estado de la cadena (bits del barcode R-chain) ──
MB=$(drv_bound qcom_apcs_ipc)
GL=$(drv_bound qcom_glink_rpm)
RS=$(drv_bound rpm-smd)
GCC=$(drv_bound gcc-monaco)
EUD=$(drv_bound msm-eud)
GLUE=$(drv_bound msm-dwc3)
RQ=N
for f in /sys/bus/rpmsg/devices/*rpm_requests*; do [ -e "$f" ] && RQ=Y; done
CX=0; U3=0
for rn in /sys/class/regulator/regulator*/name; do
    [ -e "$rn" ] || continue
    read -r nm < "$rn" 2>/dev/null
    case "$nm" in
        pm5100_s1_level) CX=1 ;;
        gcc_usb20_prim_gdsc) U3=1 ;;
    esac
done
B_MB=0; [ "$MB" = Y ] && B_MB=1
B_GL=0; [ "$GL" = Y ] && B_GL=1
B_RS=0; [ "$RS" = Y ] && B_RS=1
B_GCC=0; [ "$GCC" = Y ] && B_GCC=1
B_EUD=0; [ "$EUD" = Y ] && B_EUD=1
B_RQ=0; [ "$RQ" = Y ] && B_RQ=1
CHAIN="$B_MB$B_GL$B_RS$B_GCC$B_EUD$B_RQ$CX$U3"

UDC=$(cd /sys/class/udc 2>/dev/null && echo *)
case "$UDC" in '*'|''|'.'|'..') UDC="" ;; esac
UDCBIND="?"
if [ -n "$UDC" ]; then
    UDC=$(echo "$UDC" | awk '{print $1}')
    info "v55: UDC=$UDC; bind gadget en background c/timeout"
    rm -f /tmp/udc_rc
    ( echo "$UDC" > /sys/kernel/config/usb_gadget/*/UDC 2>/dev/kmsg
      echo $? > /tmp/udc_rc ) >/dev/null 2>&1 &
    UDCPID=$!; j=0
    while [ "$j" -lt 15 ] && kill -0 "$UDCPID" 2>/dev/null; do
        sleep 1; j=$((j+1))
    done
    if kill -0 "$UDCPID" 2>/dev/null; then
        UDCBIND=H
        info "v55: gadget bind COLGADO >15s"
    else
        UDCBIND=$(cat /tmp/udc_rc 2>/dev/null)
        info "v55: gadget bind rc=$UDCBIND"
        [ "$UDCBIND" = "0" ] && [ -e /sys/kernel/dace_color ] && \
            echo 0x00ff00ff > /sys/kernel/dace_color  # MAGENTA: adb vivo
    fi
fi

# ── páginas ──
# PREV-1/PREV-2: log del boot anterior (console-ramoops, tail 1400B en 2 mitades)
PT1=$(printf '%s\n' "$PLOG" | tail -c 700)
PT2=$(printf '%s\n' "$PLOG" | tail -c 1400 | head -c 700)
PG1=$(printf '%s\n%s\n' "PREV-BOOT LOG b=$PLEN" "$(printf '%s\n' "$PT1" | wrap33 | firstlines 12)" | wrap33 | firstlines 13)
PG2=$(printf '%s\n%s\n' "PREV-LOG (cont) pmsg:" "$(printf '%s\n%s\n' "$PT2" "$PMLOG" | wrap33 | firstlines 11)" | wrap33 | firstlines 13)
# NOW: estado de este boot
DFN=0
if [ -e /sys/kernel/debug/devices_deferred ]; then
    while IFS= read -r l; do [ -n "$l" ] && DFN=$((DFN+1)); done < /sys/kernel/debug/devices_deferred
else
    DFN=-1
fi
DMF=$(dmesg 2>/dev/null | grep -iE "dwc3|hsusb|usb|eud|phy|fail|error|warn|gdsc|clk|probe of|bug|oops|panic" | grep -viE "usb_f_|configfs" | tail -c 500)
PG3=$(cat <<EOFNOW | wrap33 | firstlines 13
NOW v55 DFR=$DFN ub=$UDCBIND
cc=$RBCC gcc=$RBGCC gd=$RBGD eu=$RBEU
glue=$GLUE udc=$UDC
$(cat /sys/kernel/debug/devices_deferred 2>/dev/null | tr '\t' ' ' | head -c 120)
$DMF
EOFNOW
)

info "dace-init: v55 CHAIN=$CHAIN DFN=$DFN ub=$UDCBIND"

# ── bucle: PREV-1(20s) PREV-2(20s) NOW(14s) R-chain(10s) ──
while true; do
    [ -e /sys/kernel/dace_text ] && printf '%s\n' "$PG1" > /sys/kernel/dace_text 2>/dev/null
    sleep 20
    [ -e /sys/kernel/dace_text ] && printf '%s\n' "$PG2" > /sys/kernel/dace_text 2>/dev/null
    sleep 20
    [ -e /sys/kernel/dace_text ] && printf '%s\n' "$PG3" > /sys/kernel/dace_text 2>/dev/null
    sleep 14
    echo "$CHAIN 10101010" > /sys/kernel/dace_barcode 2>/dev/null
    sleep 10
done
