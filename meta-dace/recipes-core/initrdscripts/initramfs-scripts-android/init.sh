#! /bin/sh

. /machine.conf

# ════════════════════════════════════════════════════════════════════
#  CANARY-B INIT — full flow (rootfs/adb) + telemetry (2026-09-08)
# ════════════════════════════════════════════════════════════════════
# Known data: phy fully probed (PHY=43), glue G7, core D0. The ~30 s freeze is
# the boot watchdog without root/Adbize. Here:
#   1) modprobe (like canary) — the system loads the chain.
#   2) brief telemetry on screen.
#   3) mount the sdcard (userdata) and look for a rootfs on it; if there is an
#      asteroidos.ext4 → switch_root to systemd (full-boot signal → watchdog off).
#   4) IF there is NO rootfs → bring up the USB gadget (adb) from the initramfs:
#      configfs + android-gadget-setup adb + adbd + poll UDC + bind.
#   5) telemetry loop ALWAYS at the end (if switch_root was not possible).
# ════════════════════════════════════════════════════════════════════

info() { echo "init: $1" > /dev/kmsg 2>/dev/null; }
ptext() { [ -w /sys/kernel/dace_text ] && printf '%s\n' "$1" > /sys/kernel/dace_text 2>/dev/null; }
# ── Bring-up telemetry by COLOR on the panel ─────────────────────────────
# /dev/fb0 = /cont-splash-fb node injected into the DTB (AURORA-STYLE, same as
# aurora-boot-images Step 3b): the continuous-splash region that the SDE keeps
# scanning until the composer starts. Painting a SOLID color leaves that color
# on the panel even if the SoC later hangs (no USB, no console) -> the final
# color identifies the last step reached. It is the same trick as
# dace_smmu_mark() in arm-smmu.c, but from userspace. Usage:
#   fbmark R G B          dtrace "label" R G B
fbmark() {
    [ -c /dev/fb0 ] || return 0
    _b=$(printf '%03o' $(( $3 & 255 ))); _g=$(printf '%03o' $(( $2 & 255 ))); _r=$(printf '%03o' $(( $1 & 255 )))
    printf '%b' "\\$_b\\$_g\\$_r\\000" > /tmp/dace-fb.bin 2>/dev/null || return 0
    dd if=/tmp/dace-fb.bin of=/dev/fb0 bs=4 count=262144 2>/dev/null
}
# dtrace: log to kmsg/console + color on the panel (1 MB = covers 466x466x4)
dtrace() { info "$1"; fbmark "$2" "$3" "$4"; }
SP=0
mark() { SP=$((SP+1)); ptext "CAN S${SP} $*"; info "CAN S${SP} $*"; }

hw_status() {
    local C=0 P=0 D=0 G="?" PHY="?" CORE="?"
    [ -n "$(ls /sys/bus/platform/drivers/qpnp-smblite/* 2>/dev/null | head -1)" ] && C=1
    [ -n "$(ls /sys/bus/platform/drivers/msm-usb-hsphy/* 2>/dev/null | head -1)" ] && P=1
    [ -n "$(ls /sys/bus/platform/drivers/dwc3/* 2>/dev/null | head -1)" ] && D=1
    [ -e /sys/kernel/dace_glue ] && G=$(tr -d '\n' < /sys/kernel/dace_glue 2>/dev/null)
    [ -e /sys/kernel/dace_phy ] && PHY=$(tr -d '\n' < /sys/kernel/dace_phy 2>/dev/null)
    [ -e /sys/kernel/dace_core ] && CORE=$(tr -d '\n' < /sys/kernel/dace_core 2>/dev/null)
    ptext "HW C${C} P${P} D${D} G=${G} PHY=${PHY} CORE=${CORE}"
    info "HW C${C} P${P} D${D} G=${G} PHY=${PHY} CORE=${CORE}"
}

setup_devtmpfs() {
    mount -t devtmpfs -o mode=0755,nr_inodes=0 devtmpfs $1/dev
    mkdir $1/dev/pts
    mount -t devpts none $1/dev/pts/
    test -c $1/dev/fd     || ln -sf /proc/self/fd $1/dev/fd
    test -c $1/dev/stdin  || ln -sf fd/0 $1/dev/stdin
    test -c $1/dev/stdout || ln -sf fd/1 $1/dev/stdout
    test -c $1/dev/stderr || ln -sf fd/2 $1/dev/stderr
    test -c $1/dev/socket || mkdir -m 0775 $1/dev/socket
}

mkdir -m 0755 /proc;  mount -t proc proc /proc
mkdir -m 0755 /sys;   mount -t sysfs sys /sys
mkdir -p /dev;        setup_devtmpfs ""
mark "mounts"

# ── arm_smmu: do NOT disable bypass (dace bring-up) ──
# CONFIG_ARM_SMMU_DISABLE_BYPASS_BY_DEFAULT=y in GKI makes
# arm_smmu_device_reset() set sCR0.USFCFG: streams NOT matched in the SMR table
# FAIL instead of bypassing. The firmware/TZ left the apps-smmu with only the
# handoff SMR (qcom,handoff-smrs = <0x420 0x02>), so with USFCFG the eMMC (and
# other masters already programmed by the bootloader) start failing translation
# -> 'mmc0: ADMA error: 0x02000000' and, depending on the master, a hard reset
# to EDL. The Mobvoi stock kernel uses the default (bypass); we replicate it
# with the module param (arm_smmu is =m, so modprobe.d applies it).
mkdir -p /etc/modprobe.d
printf '%s\n' 'options arm_smmu disable_bypass=0' \
    > /etc/modprobe.d/dace-smmu.conf
info "modprobe.d/arm_smmu disable_bypass=0"

# ── USB console (ACM) ── (defined BEFORE the module loop:
# the loop uses it as soon as dwc3-msm loads, to capture the
# display bring-up)
setup_usb_console() {
    G=/sys/kernel/config/usb_gadget
    # Idempotent: if the console is already attached, do not recreate it (each
    # recreation re-enumerates the USB and we would lose console lines).
    if [ -n "$(cat $G/console/UDC 2>/dev/null)" ]; then
        return 0
    fi
    mkdir -p /sys/kernel/config
    mount -t configfs none /sys/kernel/config 2>/dev/null
    for u in $G/*/UDC; do
        [ -e "$u" ] || continue
        [ -n "$(cat $u 2>/dev/null)" ] && echo "" > "$u" 2>/dev/null
    done
    mkdir -p $G/console
    cd $G/console 2>/dev/null || return
    echo 0x18d1 > idVendor
    echo 0x4ee7 > idProduct
    mkdir -p strings/0x409
    echo "dace-console" > strings/0x409/serialnumber
    echo "AsteroidOS"   > strings/0x409/manufacturer
    echo "dace-console" > strings/0x409/product
    mkdir -p configs/c.1/strings/0x409
    echo "acm" > configs/c.1/strings/0x409/configuration
    mkdir -p functions/acm.usb0
    ln -sf functions/acm.usb0 configs/c.1/acm.usb0
    UDC=$(ls /sys/class/udc 2>/dev/null | sed -n 1p)
    [ -n "$UDC" ] && echo "$UDC" > UDC
    cd /
    ptext "console: UDC=${UDC:-none}"
    info "console: UDC=${UDC:-none}"
}

# dace (2026-09-20): with `dace-iommu-defer.patch` the USB also waits for the
# apps-smmu (its dwc3@4e00000 node carries iommus=<&apps_smmu 0x120>), and the
# SMMU does not register until qnoc-monaco loads in the DISPLAY stage -- AFTER
# this setup_usb_console. Result without this wait: the gadget is created but
# there is no UDC to attach -> neither console nor adb (it looked like a hang).
# wait_udc: BOUNDED wait (20 s) for /sys/class/udc to appear.
wait_udc() {
    _w=0
    while [ $_w -lt 20 ]; do
        _u=$(ls /sys/class/udc 2>/dev/null | sed -n 1p)
        [ -n "$_u" ] && { info "UDC available: $_u (after ${_w}s)"; return 0; }
        _w=$((_w+1)); sleep 1
    done
    info "UDC ABSENT after 20s (USB is still deferred)"
    return 1
}

# ── modprobe vendor ──
KREL=$(uname -r)
[ ! -e "/lib/modules/$KREL" ] && ln -sf . "/lib/modules/$KREL"
mark "krel ${KREL}"
modprobe google-extcon-usb-shim usb_force_disable_boot=0 2>/dev/kmsg
MI=0
while read mod; do
    case "$mod" in ''|\#*) continue ;; esac
    name="${mod%.ko}"
    # qnoc-monaco / msm_drm / msm_kgsl are loaded FURTHER BELOW, after mounting
    # the USB console: msm_smmu_probe() (driver of smmu_sde_unsec_cb, inside
    # msm_drm.ko) requires the apps-smmu to already be there to get an IOMMU
    # domain, and we want the console capturing the display bring-up.
    # msm_gpi / i2c-msm-geni / spi-msm-geni: SAME reason. The QUP wrapper
    # (4ac0000, iommus=<&apps_smmu 0xe3>, qcom,iommu-dma="fastmap") is the one
    # that maps the buffers: geni_se_tx_dma_prep() calls
    # dma_map_single(wrapper->dev, ...). If its driver (geni_se_qup) or those of
    # its children (i2c/spi/uart) probe BEFORE the apps-smmu is registered,
    # of_iommu_xlate() does not find the ops and driver_deferred_probe_check_state()
    # returns -ETIMEDOUT (modules load after the initcalls) -> the device is left
    # WITHOUT an iommu_group/domain -> dma_map_single() returns the PHYSICAL
    # address without touching the context bank -> the GPI/GSI engine (0xf6)
    # blows up ("Unhandled interrupt status:0x40", spi_gsi_ch_cb status 2) and
    # the SoC resets. Measured live: 4ac0000/4a90000/4a00000/4a94000 WITHOUT
    # iommu_group.
    case "$name" in
        qnoc-monaco|msm_drm|msm_kgsl|msm_geni_serial)
            info "M-- ${name} (deferred to display bring-up)"
            continue ;;
    esac
    MI=$((MI+1))
    ptext "CAN M${MI} ${name}"
    info "M${MI} ${name}"
    modprobe "$name" 2>/dev/kmsg
done < /etc/modules.load.dace
mark "modprobe done ${MI}"

# USB gate open
for fd in /sys/devices/platform/soc/soc:extcon_usb_shim/force_disable \
          /sys/bus/platform/devices/soc:extcon_usb_shim/force_disable; do
    [ -e "$fd" ] && echo 0 > "$fd" 2>/dev/kmsg
done
mount -t debugfs none /sys/kernel/debug 2>/dev/null || true
mark "usb gate + debugfs"

# ════════════════════════════════════════════════════════════════════
# USB console + DISPLAY BRING-UP (diagnostics)
# The console is mounted HERE (not earlier): dwc3-msm loads at line 61 but the
# UDC does not exist until later (full extcon/phy chain). With the console up
# we load qnoc-monaco -> msm_drm -> msm_kgsl in order: the apps-smmu must exist
# BEFORE msm_drm or smmu_sde_unsec_cb never gets an IOMMU domain (-EINVAL, not
# EPROBE_DEFER) and msm_drm_bind() does not create /dev/dri.
# ════════════════════════════════════════════════════════════════════
setup_usb_console
sleep 2
dtrace "DISPLAY: console up, loading qnoc-monaco (dark gray color)" 32 32 32
modprobe qnoc-monaco 2>/dev/kmsg ; _rc=$?
dtrace "DISPLAY: qnoc-monaco rc=$_rc (brown color)" 160 82 45
# Console retry: the apps-smmu should now be registered, so the USB chain
# (deferred until now) can bind and the UDC can appear. Without this the
# console gadget stayed UNATTACHED (created, empty UDC).
wait_udc && setup_usb_console
# msm_geni_serial AFTER qnoc: its geni_icc_get("qup-config") must see the qnoc
# nodes already registered. Otherwise of_icc_get returns -EINVAL (provider up
# but node not yet) and the UART probe FAILS without retrying -> /dev/ttyHS0
# (BT) never appears.
modprobe msm_geni_serial 2>/dev/kmsg ; _rc=$?
dtrace "DISPLAY: msm_geni_serial rc=$_rc (khaki color)" 240 230 140
# Informational (dace, 2026-09-20): with dace-iommu-defer.patch ONLY the QUP
# streams (0xe3 wrapper, 0xf6 GPI) must end up WITH an IOMMU domain; the rest
# (eMMC, USB, qcrypto, tmc...) must stay WITHOUT one (the firmware already
# translates them; if Linux attaches them it changes their CB and the boot
# hangs).
# The QUP drivers load in the early loop and stay deferred until the apps-smmu
# registers, so we wait (bounded) for their re-probe.
_i=0
while [ $_i -lt 15 ]; do
    [ -e /sys/bus/platform/devices/4ac0000.qcom,qupv3_0_geni_se/iommu_group ] && \
    [ -e /sys/bus/platform/devices/4a00000.qcom,gpi-dma/iommu_group ] && break
    _i=$((_i+1)); sleep 1
done
info "IOMMU: waiting for QUP domains: ${_i}s"
for _d in 4ac0000.qcom,qupv3_0_geni_se 4a00000.qcom,gpi-dma 4a90000.spi 4a94000.qcom,qup_uart; do
    if [ -e /sys/bus/platform/devices/$_d/iommu_group ]; then
        info "IOMMU: $_d WITH group ($(readlink /sys/bus/platform/devices/$_d/iommu_group))"
    else
        info "IOMMU: $_d WITHOUT group"
    fi
done
if [ -e /sys/bus/platform/devices/4744000.sdhci/iommu_group ]; then
    info "IOMMU: eMMC (4744000.sdhci) WITH group -- NOTE: it should not (the firmware already translates it)"
else
    info "IOMMU: eMMC (4744000.sdhci) WITHOUT group (correct: the firmware translates it)"
fi
dtrace "DISPLAY: end of pre-DRM load (light blue color = LAST visible color)" 176 196 222
modprobe msm_drm 2>/dev/kmsg     ; _rc=$?
# NOTE: from here on the SDE/DRM takes over the screen and stops scanning the
# continuous-splash -> colors we paint are NO LONGER visible. The last visible
# color on the panel is always the one from the previous line (light blue).
dtrace "DISPLAY: msm_drm rc=$_rc (light green; no longer visible)" 100 200 100
modprobe msm_kgsl 2>/dev/kmsg    ; _rc=$?
dtrace "DISPLAY: msm_kgsl rc=$_rc (blue-white; no longer visible)" 210 220 255
info "DISPLAY: end of load (if you still see this, there was no reset)"
sleep 2

# ── short status window (2s) ──
i=0
while [ $i -lt 2 ]; do hw_status; sleep 1; i=$((i+1)); done

# ════════════════════════════════════════════════════════════════════
# sdcard/userdata + rootfs
# ════════════════════════════════════════════════════════════════════
mark "sdcard wait"
mkdir -m 0777 /sdcard /loop
# Wait for the partition with a timeout: if it does not appear, list which
# partitions exist (the real partition numbers and whether the sdhci eMMC
# loaded). This shows the difference between "the number is not p82" vs "the
# eMMC did not load".
w=0
while [ ! -e /dev/$sdcard_partition ] && [ $w -lt 15 ]; do
    info "Waiting for $sdcard_partition..."
    sleep 1
    w=$((w+1))
    if [ $w -eq 15 ]; then
        # diagnostic moment: list what is there
        PARTS=$(ls /dev/ 2>/dev/null | grep -E '^mmcblk[0-9]' | tr '\n' ' ')
        ptext "PROBE: /dev=${PARTS:-NONE}"
        ptext "PROBE: block=$(ls /sys/block 2>/dev/null | tr '\n' ' ' | cut -c1-60)"
        ptext "PROBE: sdhci=$(ls /sys/bus/platform/drivers/ 2>/dev/null | grep -i sdhci | tr '\n' ' ' | cut -c1-60)"
        ptext "PROBE: mmc=$(ls /sys/bus/mmc/devices 2>/dev/null | tr '\n' ' ' | cut -c1-60)"
        # give it an extra moment and retry (the eMMC can be slow)
    fi
    if [ $w -ge 30 ]; then
        # forced: continue even if it does not appear (do not block boot)
        ptext "CAN no ${sdcard_partition} after ${w}s — continuing"
        break
    fi
done
mark "sdcard post-wait (w=${w})"

if [ -e /dev/$sdcard_partition ]; then
    FSTYPE=${sdcard_fstype:-auto}
    # NOTE: do NOT run fsck.ext4 on the userdata: in dace.conf it is declared as
    # F2FS (sdcard_fstype=f2fs). With -p (preen) e2fsck TRIES TO REPAIR and would
    # write ext4 metadata over an F2FS partition. fsck is only run if the fstype
    # really is ext4.
    if [ "$FSTYPE" = "ext4" ]; then
        mark "fsck ext4..."
        /sbin/fsck.ext4 -p /dev/$sdcard_partition 2>/dev/null
        mark "fsck ext4 done"
    fi
    mark "mounting $FSTYPE $sdcard_partition"
    mount -t $FSTYPE -o rw,noatime,nodiratime /dev/$sdcard_partition /sdcard 2>/dev/null
    mark "mount sdcard rc=$?"
else
    mark "NO ${sdcard_partition} — sdcard not mountable"
    touch /tmp/NO_SDCARD
fi
[ -d /sdcard/media/0 ] && ANDROID_MEDIA_DIR="/sdcard/media/0" || ANDROID_MEDIA_DIR="/sdcard"
mark "after sdcard "

BOOT_DIR="/sdcard"
if [ -e $ANDROID_MEDIA_DIR/asteroidos.ext4 ] ; then
    mark "rootfs found"
    /sbin/fsck.ext4 -p $ANDROID_MEDIA_DIR/asteroidos.ext4 2>/dev/null
    # NOTE: NO 'sync' on the mount. With sync every write goes synchronously to
    # the eMMC via loop+f2fs and systemd ends up blocked on an inode lock
    # (`locks_lock_inode_wait`): systemctl stops responding. It was detected
    # when starting the LXC container with a crashlog writing 20 KB/s.
    mount -o noatime,nodiratime,rw,loop $ANDROID_MEDIA_DIR/asteroidos.ext4 /loop 2>/dev/null \
      && BOOT_DIR="/loop"
fi

# system/vendor/firmware (Android mounts them, optional here)
if [ ! -e $system_partition ] && [ -n "$system_partition" ] && [ -e /dev/$system_partition ]; then
    mkdir -m 0777 $BOOT_DIR/system
    mount -t auto -o ro /dev/$system_partition $BOOT_DIR/system 2>/dev/null && mount --bind $BOOT_DIR/system /system 2>/dev/null
fi
if [ ! -e $vendor_partition ] && [ -n "$vendor_partition" ] && [ -e /dev/$vendor_partition ]; then
    mkdir -m 0777 $BOOT_DIR/vendor
    mount -t auto -o ro /dev/$vendor_partition $BOOT_DIR/vendor 2>/dev/null && mount --bind $BOOT_DIR/vendor /vendor 2>/dev/null
fi

# ════════════════════════════════════════════════════════════════════
# Kernel console over USB (configfs ACM). The kernel already has
# CONFIG_USB_CONFIGFS_ACM=y + CONFIG_U_SERIAL_CONSOLE=y and the cmdline carries
# "console=ttyGS0,115200": an ACM gadget on port 0 creates /dev/ttyGS0 and the
# host sees /dev/ttyACM0 with the kernel log. Useful to see the rootfs boot
# (the journal does not get time to sync if there is a hard reset to EDL).
# ════════════════════════════════════════════════════════════════════

# ════════════════════════════════════════════════════════════════════
# Is there a real systemd? → switch_root (full-boot signal, watchdog off)
# ════════════════════════════════════════════════════════════════════
# debug-ramdisk (cmdline): stay in the initramfs with adb instead of
# switch_root. The rootfs stays mounted at /loop, so from the adb shell one can
# read /loop/var/log (journal + android-tools-adbd.log) and patch it.
# Gate ONLY by file. NOTE: 'debug-ramdisk' does NOT come from vendor_cmdline but
# from CONFIG_CMDLINE of the kernel (linux-dace), i.e. it is ALWAYS in
# /proc/cmdline and checking it would keep the boot always in the initramfs.
# To debug: 'touch /sdcard/debug-ramfs' + reboot (adb from the initramfs,
# rootfs mounted at /loop). For a normal boot: 'rm /sdcard/debug-ramfs'.
DEBUG_RAMFS=0
[ -e /sdcard/debug-ramfs ] && DEBUG_RAMFS=1
# ── DEBUG MODE ────────────────────────────────────────────────────
# The vendor_boot bootconfig does NOT reach /proc/cmdline (verified: neither
# androidboot.memcg=1 nor the dace.* flags appear), so the only reliable channel
# is --vendor_cmdline (that is where lpm_levels.sleep_disabled,
# fw_devlink=permissive, etc. come from). With 'dace.debug=1' in the cmdline the
# initramfs decides the mode by reading /sdcard/dace-mode (the userdata root,
# which the initramfs CAN write) and DELETING it right after: so, if the rootfs
# boots and falls to EDL, the next boot no longer finds the file and returns by
# itself to safe mode with adb (impossible to get stuck in a loop).
#
#   no file            -> ramfs + adb + rootfs at /loop   (SAFE)
#   boot               -> boot the rootfs
#   boot noautoload    -> + empty modules-load.d/dace-post-rootfs.conf
#   boot nolxc         -> + mask dace-lxc-android
#   boot console       -> + UDC for the kernel console (no adb)
#   boot crashlog      -> + dmesg snapshot to /var/log/dace-crash.log every
#                         second (survives a hard reset to EDL)
#   boot noautoload nolxc crashlog   (combinable)
#
#   adb shell 'echo "boot noautoload nolxc" > /sdcard/dace-mode; reboot'
#
# ⚠️ BEFORE REBOOTING: 'dace-syncfs' (forces the F2FS checkpoint).
# busybox sync does NOT checkpoint and a 'reboot -f' leaves F2FS dirty: on boot,
# F2FS recovery may not see the freshly written file and the boot falls to safe
# mode (it cost us a long while: it looked like the flag "got lost"). The right
# thing from the initramfs:
#   echo boot > /sdcard/dace-mode; dace-syncfs; reboot -f
# (dace-syncfs is installed at /usr/bin/dace-syncfs of the initramfs; there is
#  also a rescue copy at /sdcard/dace-syncfs.)
DEBUG_MODE=""
if grep -q "dace.debug=1" /proc/cmdline; then
    DEBUG_MODE=$(cat /sdcard/dace-mode 2>/dev/null | tr '\n' ' ')
    rm -f /sdcard/dace-mode; sync
    mark "dace-mode: '${DEBUG_MODE:-ramfs}' (file consumed)"
    [ -n "$DEBUG_MODE" ] || DEBUG_MODE="ramfs"
    DEBUG_RAMFS=1
    case " $DEBUG_MODE " in *" boot "*) DEBUG_RAMFS=0 ;; esac
fi
# Compatibility: loose flags in the cmdline.
grep -q "dace.ramfs=1" /proc/cmdline && DEBUG_RAMFS=1
[ -e /sdcard/debug-ramfs ] && DEBUG_RAMFS=1
[ "$DEBUG_RAMFS" = "1" ] && mark "debug-ramfs: no switch_root (adb)"

if [ -x "$BOOT_DIR/lib/systemd/systemd" ] && [ "$DEBUG_RAMFS" = "0" ]; then
    # qnoc-monaco is NO LONGER blacklisted: it is loaded in the initramfs (see
    # modules.load.dace) because msm_smmu_probe() needs the apps-smmu up to get
    # an IOMMU domain. If a blacklist is left over from a previous boot, remove
    # it (the module is already loaded, but the file is confusing).
    rm -f $BOOT_DIR/etc/modprobe.d/00-dace-no-qnoc.conf
    # Touch: udev must NOT load touch drivers on coldplug. The touch goes AFTER
    # the display HALs (dace-lxc-hal-start.sh loads the vendor chain:
    # slate_events_bridge/slate_mobvoi_rpc/zinitix-i2c from
    # /usr/lib/dace-vendor-modules, outside /lib/modules -> udev does not see
    # them). blacklist zinitix for backwards compatibility (the .ko no longer
    # exists in the kernel).
    BL="$BOOT_DIR/etc/modprobe.d/00-dace-vendor-blacklist.conf"
    if ! grep -qs '^blacklist zinitix' "$BL"; then
        mkdir -p "$BOOT_DIR/etc/modprobe.d"
        printf '\n# touch: loaded after the display HALs (vendor chain in dace-lxc-hal-start.sh)\nblacklist zinitix\n' >> "$BL"
        info "blacklist zinitix added (touch is loaded after the HALs)"
    fi
    # mce: remove the light sensor (ALS) brightness filter. The T5 has no
    # functional ALS (sensorfwd crash-loops and the proximity sensor gives
    # garbage over evdev), and with the filter active mce falls to the darkest
    # profile (LevelsProfile0 starts at 1%) -> it could force brightness to ~0.
    if [ -f "$BOOT_DIR/etc/mce/10mce.ini" ] && grep -q "filter-brightness-als" "$BOOT_DIR/etc/mce/10mce.ini"; then
        sed -i 's/filter-brightness-als;//; s/;filter-brightness-als//' "$BOOT_DIR/etc/mce/10mce.ini"
        info "mce: ALS filter removed (T5 without functional ALS)"
    fi
    # ── PROXIMITY CHURN -> SUSPEND (2026-09-24) ──────────────────────
    # sensorfwd crash-loops (hw_get_module fails; measured restart counter
    # ~8300) and MCE receives garbage proximity over libhybris every ~5 s.
    # Effect: `mce_proximity_stm` holds a wakelock and the screen turns back on
    # -> autosleep NEVER suspends. MEASURED: with sensorfwd stopped, 0 proximity
    # events in 60 s, no wakelocks, and the only active wakeup_source was USB
    # (`4e00000.hsusb`). It is masked (the sensors do not work today anyway).
    # Reversible: rm the symlink.
    ln -sf /dev/null "$BOOT_DIR/etc/systemd/system/sensorfwd.service"
    info "sensorfwd masked (proximity churn -> enables suspend)"
    # Unmask the rootfs USB (a previous debug boot may have masked it to protect
    # the console). With this the rootfs usb-moded brings up adb (fix
    # PREFERRED_PROVIDER android-tools-conf-configfs).
    for u in init_gfs.service usb-moded.service android-tools-adbd.service adbd-prepare.service dace-lxc-android.service; do
        f="$BOOT_DIR/etc/systemd/system/$u"
        if [ -L "$f" ] && [ "$(readlink $f 2>/dev/null)" = "/dev/null" ]; then
            rm -f "$f"
            info "unmasked $u"
        fi
    done
    # Restore the init_gfs enable symlink: without it /config/usb_gadget/g1 does
    # not exist and usb-moded (triggered by dsme/usbtracker via D-Bus) aborts in
    # configfs_probe -> no USB gadget and no adb.
    mkdir -p "$BOOT_DIR/usr/lib/systemd/system/sysinit.target.wants"
    ln -sf ../init_gfs.service \
        "$BOOT_DIR/usr/lib/systemd/system/sysinit.target.wants/init_gfs.service"
    # usb-moded cannot find the charger (/sys/class/power_supply/usb: smblite is
    # out of the boot) -> it thinks there is no cable -> "mode setting failed,
    # fallback to undefined" -> mass storage 18d1:0afe instead of adb_mode.
    # With -f/--fallback ("assume always connected") it enters the default mode
    # (adb_mode, dace-defaults.ini).
    mkdir -p $BOOT_DIR/etc/systemd/system/usb-moded.service.d
    printf '%s\n' '[Service]' 'Environment=USB_MODED_ARGS=-f -D' \
        > $BOOT_DIR/etc/systemd/system/usb-moded.service.d/10-dace-fallback.conf
    # The USB console (ACM) and the rootfs adb compete for the UDC: by default we
    # leave the USB to the rootfs (adb). To debug, 'touch /sdcard/console-debug'.
    # ── DIAGNOSTIC BATCH: USB console + qnoc-monaco load (one-shot) ──
    # It does not use markers in /sdcard: in the rootfs /sdcard is NOT accessible
    # (it is the initramfs mount point) and creating them would require another
    # batch. The "already done" mark is written into the ROOTFS (mounted at
    # $BOOT_DIR), which persists: the FIRST boot with this batch runs the test
    # and the following ones boot normally -> if the SoC resets to EDL there is
    # no boot-loop (a power cycle is enough).
    if [ ! -e "$BOOT_DIR/etc/dace-qnoc-test-v7-done" ]; then
        : > "$BOOT_DIR/etc/dace-qnoc-test-v7-done"
        sync
        setup_usb_console
        sleep 3
        mark "TEST: console up, modprobe qnoc-monaco"
        modprobe qnoc-monaco 2>/dev/kmsg
        info "TEST: modprobe qnoc-monaco rc=$?"
        mark "TEST: modprobe done (waiting 15s)"
        sleep 15
        # Diagnostic dump BEFORE switch_root (which is where the eMMC gives an
        # ADMA error and the SoC resets): we want to know whether msm_drm probed
        # and whether /dev/dri exists, to avoid confusing "display did not probe"
        # with "crash later".
        mark "TEST: dumping diagnostics to the console"
        {
            echo "===== DACE TEST DUMP START ====="
            echo "-- qnoc/icc loaded:"
            grep -E "qnoc_monaco|qnoc_qos_rpm|icc_rpm" /proc/modules | cut -d' ' -f1,2
            echo "-- qnoc provider in /sys/class/interconnect:"
            ls /sys/class/interconnect 2>&1 | sed -n 1,5p
            echo "-- /dev/dri:"; ls -la /dev/dri 2>&1
            echo "-- /dev/fb*:"; ls -la /dev/fb* 2>&1
            echo "-- /sys/class/drm:"; ls /sys/class/drm 2>&1
            echo "-- drm status:"
            cat /sys/class/drm/*/status 2>/dev/null | tr '\n' ' '; echo
            echo "-- deferred:"
            cat /sys/kernel/debug/devices_deferred 2>&1 | sed -n 1,25p
            echo "-- dmesg (drm/sde/kgsl/smmu):"
            dmesg | grep -iE "msm_drm|msm |sde|drm|kgsl|apps-smmu|SMMUv2|iommu" | tail -30
            echo "===== DACE TEST DUMP END ====="
        } > /dev/kmsg 2>&1
        mark "TEST: dump done, switch_root"
    fi
    if [ -e /sdcard/console-debug ]; then
        setup_usb_console
        mark "console-debug: console (no adb)"
    fi
    # Active flags (POSIX: the initramfs shell is busybox ash, no [[ ]])
    DO_CONSOLE=0; DO_NOAUTOLOAD=0; DO_NOLXC=0
    case " $DEBUG_MODE " in *" console "*)    DO_CONSOLE=1 ;; esac
    case " $DEBUG_MODE " in *" noautoload "*) DO_NOAUTOLOAD=1 ;; esac
    case " $DEBUG_MODE " in *" nolxc "*)      DO_NOLXC=1 ;; esac
    grep -q "dace.console=1" /proc/cmdline    && DO_CONSOLE=1
    grep -q "dace.noautoload=1" /proc/cmdline && DO_NOAUTOLOAD=1
    grep -q "dace.nolxc=1" /proc/cmdline      && DO_NOLXC=1
    # 'console': leaves the UDC for the kernel console by masking
    # usb-moded/adbd/init_gfs. Without this usb-moded takes the UDC at ~10 s and
    # the console dies right where it matters. The UDC is one: either console, or
    # adb.
    if [ "$DO_CONSOLE" = "1" ]; then
        for u in init_gfs.service usb-moded.service android-tools-adbd.service adbd-prepare.service; do
            ln -sf /dev/null "$BOOT_DIR/etc/systemd/system/$u"
        done
        setup_usb_console
        mark "console: UDC for the kernel console (no rootfs adb)"
    fi
    # 'noautoload': the new rootfs loads the WLAN/icnss2 + ASoC + BT chain in
    # systemd-modules-load (dace-post-rootfs.conf), which in the old rootfs was
    # NEVER loaded (it is not in modules.load.dace).
    if [ "$DO_NOAUTOLOAD" = "1" ]; then
        : > "$BOOT_DIR/etc/modules-load.d/dace-post-rootfs.conf"
        mark "noautoload: dace-post-rootfs.conf emptied"
    fi
    # 'nolxc': boot the rootfs with the Android container masked.
    if [ "$DO_NOLXC" = "1" ]; then
        ln -sf /dev/null "$BOOT_DIR/etc/systemd/system/dace-lxc-android.service"
        mark "nolxc: dace-lxc-android masked"
    fi
    mark "rootfs ok, switch_root"
    # ── BULLETPROOF CRASHLOG (opt-in: "boot crashlog" mode) ────
    # Only if the mode asks for it: it writes ~30 KB/s and that punishes the eMMC
    # if left on always. Launched FROM THE INITRAMFS, it does not depend on any
    # systemd unit starting (dace-crashlog.service never got to start and the
    # crash was lost). The process stays alive after switch_root and keeps
    # writing to the rootfs (the mounts stay in the table: $BOOT_DIR still
    # resolves), so the last second of dmesg is left on disk when the SoC resets
    # to EDL.
    case " $DEBUG_MODE " in *" crashlog "*)
        (
            while true; do
                {
                    echo "########## uptime=$(cut -d' ' -f1 /proc/uptime 2>/dev/null)s ##########"
                    dmesg 2>/dev/null | tail -300
                } > $BOOT_DIR/var/log/dace-crash.tmp 2>/dev/null
                mv $BOOT_DIR/var/log/dace-crash.tmp $BOOT_DIR/var/log/dace-crash.log 2>/dev/null
                sleep 1
            done
        ) &
        mark "initramfs crashlog launched -> $BOOT_DIR/var/log/dace-crash.log"
    ;;
    esac
    [ -e /init.machine ] && /init.machine $BOOT_DIR > /dev/kmsg 2>&1 || true
    setup_devtmpfs $BOOT_DIR
    umount -l /proc 2>/dev/null; umount -l /sys 2>/dev/null
    mount -t proc proc $BOOT_DIR/proc 2>/dev/null
    mount -t sysfs sys $BOOT_DIR/sys 2>/dev/null
    mount -t tmpfs run $BOOT_DIR/run 2>/dev/null
    echo "FIFO $BOOT_DIR/run" > /run/psplash_fifo 2>/dev/null
    exec switch_root -c /dev/console $BOOT_DIR /lib/systemd/systemd
fi

mark "NO rootfs — adb from ramfs"

# ════════════════════════════════════════════════════════════════════
# DUMP OF THE JOURNAL OF THE BOOT THAT FAILED
# In debug mode the rootfs is mounted at /loop and journald is persistent
# (Storage=persistent in init.sh), so the last messages of the boot that went to
# EDL are in /loop/var/log/journal. The end of the journal is dumped as readable
# text to the console: this way the evidence comes out WITHOUT depending on adb
# being available. (The journal is binary: non-printable bytes are dropped.)
# ════════════════════════════════════════════════════════════════════
if [ -d /loop/var/log/journal ]; then
    J=$(ls -t /loop/var/log/journal/*/system.journal* 2>/dev/null | sed -n 1p)
    if [ -n "$J" ]; then
        mark "JOURNAL: last messages of $(basename $(dirname $J))"
        # /dev/console does NOT go through printk, so there is no ratelimiting
        # (via /dev/kmsg we already saw '9 output lines suppressed' and the dump
        # would be lost). In the background in case the tty does not drain.
        ( tail -c 500000 "$J" 2>/dev/null | tr -c '[:print:]' '\n' \
              | grep -aE '^.{12,}' | tail -n 80 > /dev/console 2>&1 ) &
        sleep 3
        mark "JOURNAL: end of dump"
    fi
fi

# ════════════════════════════════════════════════════════════════════
# No rootfs: try the USB/adb gadget.
# The phy already completed (PH=43) and glue G7; if a UDC appears, this gives adb.
# ════════════════════════════════════════════════════════════════════
mkdir -p /sys/kernel/config
mount -t configfs none /sys/kernel/config 2>/dev/null

ZU=.sbu
# Release the UDC from ANY gadget before attaching the adb one. The ACM console
# (setup_usb_console, above) already holds it and the UDC is ONE. NOTE: you must
# actually write something (a newline); ': > UDC' writes 0 bytes and the
# configfs store is NOT called -> the UDC stays busy and adb does not attach
# (this was exactly the failure: the watch kept the console gadget and had no
# adb).
for _u in /sys/kernel/config/usb_gadget/*/UDC; do
    [ -e "$_u" ] || continue
    echo "" > "$_u" 2>/dev/null && mark "release $(basename $(dirname $_u))"
done
sleep 1
/usr/bin/android-gadget-setup adb 2>/dev/null && mark "gadget-setup ok" || mark "gadget-setup fail"
# legacy android_usb (no-op on GKI but for compatibility)
echo 18d1 > /sys/class/android_usb/android0/idVendor 2>/dev/null
echo d002 > /sys/class/android_usb/android0/idProduct 2>/dev/null
echo adb  > /sys/class/android_usb/android0/f_ffs/aliases 2>/dev/null
echo ffs  > /sys/class/android_usb/android0/functions 2>/dev/null
echo 1    > /sys/class/android_usb/android0/enable 2>/dev/null

/usr/bin/adbd 2>/dev/null &
mark "adbd start"

UDC=""
i=0
while [ $i -lt 30 ]; do
    UDC=$(cd /sys/class/udc 2>/dev/null && echo *)
    case "$UDC" in '*'|''|'.'|'..') UDC="" ;; esac
    [ -n "$UDC" ] && break
    sleep 1
    i=$((i+1))
done
if [ -n "$UDC" ]; then
    UDC=$(echo "$UDC" | awk '{print $1}')
    ptext "CAN UDC=${UDC} (${i}s)"
    echo "$UDC" > /sys/kernel/config/usb_gadget/adb/UDC 2>/dev/null
    mark "UDC bind ${UDC}"
else
    mark "NO UDC after 30s"
fi

# Fallback ALWAYS available: an interactive shell over the kernel console
# (/dev/ttyGS0; on the host: 'sudo picocom -b 115200 /dev/ttyACM0'). It works
# even if adb does not attach, and shares the tty with the kernel messages.
if [ -c /dev/ttyGS0 ]; then
    mark "console: fallback shell on ttyGS0"
    (setsid sh -i </dev/ttyGS0 >/dev/ttyGS0 2>&1 &) 2>/dev/null
fi

# ════════════════════════════════════════════════════════════════════
# telemetry loop ALWAYS (if there was no switch_root)
# ONLY dmesg with a counter, no hw_status: the dace_text driver paints only the
# last string; when it freezes, the screen keeps the last DM line
# (the final kernel words + the iteration counter).
c=0
while true; do
    c=$((c+1))
    ptext "DM ${c}> $(dmesg 2>/dev/null | tail -n 6 | tr '\n' ' ' | cut -c1-140)"
    sleep 1
done
