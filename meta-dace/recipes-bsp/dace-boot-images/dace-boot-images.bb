SUMMARY = "Dace flashable boot artifacts: boot.img, vendor_kernel_boot.img, init_boot.img"
DESCRIPTION = "\
Builds the three .img files dace's bootloader expects, end-to-end from \
bitbake-built inputs: \
\
 - boot.img            = our linux-dace kernel Image, empty ramdisk, \
                         mkbootimg header v4 \
 - vendor_kernel_boot  = ramdisk (kernel modules per dace-vkb-modules.lst, \
                         KMI-CRC-gated against this kernel) + DTB with \
                         ramoops node injected, mkbootimg header v4 \
 - init_boot.img       = initramfs-android-image's cpio.gz, repacked as \
                         lz4, mkbootimg header v4 \
\
The base DTB is shipped as a static input (vkb-base.dtb) -- the kernel \
doesn't build dtbs from gki_defconfig, and dace's runtime DT is the \
bootloader-assembled one anyway."

LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

# Los DTBs vienen de ota-stock/blobs: monaco-real.dtb + monacop.dtb son los
# que el ABL del T5 espera (board-id T5). vkb-base.dtb (aurora) fue rechazado
# por el ABL (EDL 05c6:900e). monaco-real ya trae ramoops@9ff00000 y splash.
SRC_URI = "\
    file://dace-vkb-assemble.py \
    file://dace-vkb-modules.lst \
    file://static/modules.alias \
    file://static/modules.softdep \
    file://static/modules.load.charger \
    file://static/modules.dep \
    file://static/bootconfig \
    file://static/monaco-real.dtb \
    file://static/monacop.dtb \
"
S = "${UNPACKDIR}"

COMPATIBLE_MACHINE = "dace"

# DEPENDS:
#  - virtual/kernel: provides Image + Module.symvers + kernel-built .ko's
#                    (we read them out of the linux-dace workdir).
#  - linux-dace-modules: techpack .ko's; we read its deploy ipk.
#  - initramfs-android-image: init_boot.img ramdisk content (cpio.gz).
#  - mkbootimg-tools-native: provides ${STAGING_BINDIR_NATIVE}/mkbootimg
#  - dtc-native: provides ${STAGING_BINDIR_NATIVE}/fdtput
DEPENDS = "\
    virtual/kernel \
    linux-dace-modules \
    initramfs-android-image \
    mkbootimg-tools-native \
    dtc-native \
    clang-native \
"
do_compile[depends] += "\
    virtual/kernel:do_compile \
    virtual/kernel:do_install \
    linux-dace-modules:do_package_write_ipk \
    initramfs-android-image:do_image_complete \
"

PACKAGES = ""
inherit deploy nopackages

# ─── Kernel artifact paths ───
# linux-dace builds out-of-tree: source in STAGING_KERNEL_DIR,
# .config/Image/Module.symvers in STAGING_KERNEL_BUILDDIR. .ko's install into
# the recipe's package/ via kernel.bbclass.
# layer.conf appends ${LAYERDIR} to BBPATH, so this layer-root-relative
# require resolves from any recipe in meta-dace.
require recipes-kernel/linux/linux-dace-version.inc
KMODVER ?= "${DACE_KERNEL_VERSION}"
# KREL del kernel: DACE_KERNEL_VERSION + EXTRAVERSION del vendorkernel
# (5.15.144 + -g7f9d6c16b5cd-ab151). La carpeta /lib/modules/<KREL> del
# workdir del kernel usa este nombre, no el DACE_KERNEL_VERSION pelado.
DACE_KREL ?= "${DACE_KERNEL_VERSION}-g7f9d6c16b5cd-ab151"
# linux-dace's workdir uses ${MACHINE}${TARGET_VENDOR}-${TARGET_OS}
# (= dace-oe-linux-gnueabi). do_install drops .ko's into package/.
LINUX_DACE_WORKDIR ?= "${TMPDIR}/work/${MACHINE}${TARGET_VENDOR}-${TARGET_OS}/linux-dace/${KMODVER}+git"
LINUX_DACE_PKGDIR  ?= "${LINUX_DACE_WORKDIR}/package/usr/lib/modules/${DACE_KREL}/kernel"
# linux-dace keeps its build artifacts in its own workdir's build/
# (out-of-tree B != S). STAGING_KERNEL_BUILDDIR is empty because we don't go
# through the standard kernel.bbclass staging for these.
LINUX_DACE_KIMG    ?= "${LINUX_DACE_WORKDIR}/build/arch/arm64/boot/Image"
LINUX_DACE_SYMVERS ?= "${LINUX_DACE_WORKDIR}/build/Module.symvers"

# Techpack ipk path. armv7vehf-neon is dace's userspace PKGARCH.
LINUX_DACE_MODULES_IPK ?= "${DEPLOY_DIR_IPK}/armv7vehf-neon/linux-dace-modules_${KMODVER}-r0_armv7vehf-neon.ipk"

# ─── mkbootimg v4 geometry ───
MKBOOTIMG_BASE          ?= "0x10000000"
MKBOOTIMG_KERNEL_OFFSET ?= "0x00008000"
MKBOOTIMG_RAMDISK_OFFSET ?= "0x01000000"
MKBOOTIMG_TAGS_OFFSET   ?= "0x00000100"
MKBOOTIMG_DTB_OFFSET    ?= "0x01f00000"
MKBOOTIMG_PAGESIZE      ?= "4096"

# ─── Hard ceilings -- match flash-slotB sanity check + deviceinfo. ───
BOOT_IMG_CAP                   ?= "67108864"
VENDOR_KERNEL_BOOT_IMG_CAP     ?= "67108864"
INIT_BOOT_IMG_CAP              ?= "8388608"

# ─── Ramoops region (matches stock dtbo) ───
RAMOOPS_BASE      ?= "0x61f00000"
RAMOOPS_SIZE      ?= "0x400000"
RAMOOPS_RECORD    ?= "0x40000"
RAMOOPS_CONSOLE   ?= "0x200000"
RAMOOPS_PMSG      ?= "0x100000"

do_compile() {
    set -e

    # ─── Step 1: extract techpack ipk so dace-vkb-assemble.py can find .ko's ───
    if [ ! -f "${LINUX_DACE_MODULES_IPK}" ]; then
        bbfatal "linux-dace-modules ipk not at ${LINUX_DACE_MODULES_IPK} -- check linux-dace-modules:do_deploy"
    fi
    rm -rf ${WORKDIR}/tpmod
    mkdir -p ${WORKDIR}/tpmod
    ( cd ${WORKDIR}/tpmod && ar x "${LINUX_DACE_MODULES_IPK}" && tar -xf data.tar.* )

    # ─── Step 2: assemble ramdisk dir via the python helper ───
    if [ ! -d "${LINUX_DACE_PKGDIR}" ]; then
        bbfatal "linux-dace kernel modules not at ${LINUX_DACE_PKGDIR} -- check virtual/kernel build"
    fi
    if [ ! -f "${LINUX_DACE_SYMVERS}" ]; then
        bbfatal "Module.symvers not at ${LINUX_DACE_SYMVERS}"
    fi
    rm -rf ${WORKDIR}/vkb_ramdisk
    python3 ${S}/dace-vkb-assemble.py \
        --manifest      ${S}/dace-vkb-modules.lst \
        --kernel-pkgdir "${LINUX_DACE_PKGDIR}" \
        --techpack-dir  ${WORKDIR}/tpmod \
        --symvers       "${LINUX_DACE_SYMVERS}" \
        --static-dir    ${S}/static \
        --out           ${WORKDIR}/vkb_ramdisk

    # ─── Step 2.5: strip debug info from aarch64 kernel modules ───
    # This recipe runs in an armv7 context but the vendor kernel modules
    # are aarch64 ELF. The default strip tool silently does nothing on a
    # foreign ELF target, leaving full debug info in every .ko file.
    # llvm-strip from clang-native is architecture-agnostic and correctly
    # strips aarch64 ELF from any build context.
    LLVM_STRIP=$(find ${STAGING_BINDIR_NATIVE} -name "llvm-strip" | head -1)
    if [ -z "$LLVM_STRIP" ]; then
        bbfatal "llvm-strip not found in ${STAGING_BINDIR_NATIVE} -- check clang-native is in DEPENDS"
    fi
    find ${WORKDIR}/vkb_ramdisk -name "*.ko" -exec "$LLVM_STRIP" --strip-debug {} \;
    bbnote "stripped debug info from aarch64 kernel modules"

    # ─── Step 3: DTB T5. monaco-real.dtb (de ota-stock/blobs) ya trae el
    #     nodo ramoops@9ff00000 y splash_region@5c000000 — NO hay que inyectarlos
    #     (el ABL del T5 rechazó el vkb-base.dtb de aurora con EDL 05c6:900e;
    #     los DTBs T5 son los únicos con board-id/msm-id que el ABL acepta).
    #     Usamos monaco-real.dtb tal cual; el second DTB monacop.dtb se queda
    #     en static/ por si un ABL con msm-id diverge lo pidiera. ───
    cp ${S}/static/monaco-real.dtb ${WORKDIR}/dtb-monaco-real.dtb
    bbnote "usando monaco-real.dtb (T5) como DTB del vendor_kernel_boot"

    # ─── Step 4: cpio + gzip the vkb ramdisk ───
    # El ABL del T5 espera el ramdisk como gzip -> cpio-newc plano con
    # lib/modules/*.ko (formato del vendor_boot STOCK Mobvoi). lz4 NO lo
    # descomprime -> EDL 05c6:900e directo.
    ( cd ${WORKDIR}/vkb_ramdisk && find . | sort | \
        cpio -o -H newc --owner root:root 2>/dev/null ) > ${WORKDIR}/vkb_rd.cpio
    gzip -9 -c ${WORKDIR}/vkb_rd.cpio > ${WORKDIR}/vkb_rd.gz

    MKBOOTIMG=${STAGING_BINDIR_NATIVE}/mkbootimg

    # ─── Step 5: mkbootimg vendor_kernel_boot.img (v4) ───
    # vendor_cmdline + vendor_bootconfig replican los del vendor_boot STOCK T5
    # (extraídos de ota-stock/blobs): cmdline inline con lpm_levels/video=vfb/…
    # y bootconfig con androidboot.hardware=dace. Sin ellos el ABL deja de
    # aceptar el vendor_boot ("Invalid Parameter").
    "${MKBOOTIMG}" \
        --header_version 4 --pagesize ${MKBOOTIMG_PAGESIZE} \
        --vendor_boot ${WORKDIR}/vendor_kernel_boot.img \
        --vendor_ramdisk ${WORKDIR}/vkb_rd.gz \
        --dtb ${WORKDIR}/dtb-monaco-real.dtb \
        --base ${MKBOOTIMG_BASE} \
        --kernel_offset ${MKBOOTIMG_KERNEL_OFFSET} \
        --ramdisk_offset ${MKBOOTIMG_RAMDISK_OFFSET} \
        --tags_offset ${MKBOOTIMG_TAGS_OFFSET} \
        --dtb_offset ${MKBOOTIMG_DTB_OFFSET} \
        --vendor_cmdline 'lpm_levels.sleep_disabled=1 video=vfb:640x400,bpp=32,memsize=3072000 msm_rtb.filter=0x237 service_locator.enable=1 swiotlb=noforce kpti=off cgroup.memory=nokmem,nosocket loop.max_part=7 bootconfig qcom_geni_serial.con_enabled=0' \
        --vendor_bootconfig ${S}/static/bootconfig

    # ─── Step 6: mkbootimg boot.img (v4): our kernel + empty ramdisk ───
    if [ ! -f "${LINUX_DACE_KIMG}" ]; then
        bbfatal "Kernel Image not at ${LINUX_DACE_KIMG}"
    fi
    : > ${WORKDIR}/empty_kernel
    : > ${WORKDIR}/empty_ramdisk
    "${MKBOOTIMG}" \
        --header_version 4 \
        --kernel "${LINUX_DACE_KIMG}" \
        --ramdisk ${WORKDIR}/empty_ramdisk \
        --cmdline '' \
        -o ${WORKDIR}/boot.img

    # ─── Step 7: mkbootimg init_boot.img (v4): asteroid initramfs as lz4 ───
    CPIO_GZ=$(ls -t ${DEPLOY_DIR_IMAGE}/initramfs-android-image-${MACHINE}-*.cpio.gz 2>/dev/null | grep -v debug | head -1)
    if [ -z "$CPIO_GZ" ] || [ ! -f "$CPIO_GZ" ]; then
        CPIO_GZ=${DEPLOY_DIR_IMAGE}/initramfs-android-image-${MACHINE}.cpio.gz
    fi
    if [ ! -f "$CPIO_GZ" ]; then
        bbfatal "initramfs-android-image cpio.gz not found in ${DEPLOY_DIR_IMAGE}"
    fi
    gunzip -c "$CPIO_GZ" | lz4 -l -9 > ${WORKDIR}/init_boot_rd.lz4
    "${MKBOOTIMG}" \
        --header_version 4 \
        --kernel ${WORKDIR}/empty_kernel \
        --ramdisk ${WORKDIR}/init_boot_rd.lz4 \
        --cmdline '' \
        -o ${WORKDIR}/init_boot.img

    # ─── Step 8: size-cap sanity check ───
    check_cap() {
        local f=$1 cap=$2
        local sz=$(stat -c%s "$f")
        if [ "$sz" -gt "$cap" ]; then
            bbfatal "$(basename $f) is ${sz}B > cap ${cap}B"
        fi
        bbnote "$(basename $f): ${sz}B (cap ${cap}B) OK"
    }
    check_cap ${WORKDIR}/boot.img                ${BOOT_IMG_CAP}
    check_cap ${WORKDIR}/vendor_kernel_boot.img  ${VENDOR_KERNEL_BOOT_IMG_CAP}
    check_cap ${WORKDIR}/init_boot.img           ${INIT_BOOT_IMG_CAP}
}

do_deploy() {
    install -d ${DEPLOYDIR}
    for f in boot.img vendor_kernel_boot.img init_boot.img; do
        install -m 0644 ${WORKDIR}/$f ${DEPLOYDIR}/$f
    done
    ( cd ${DEPLOYDIR} && sha256sum boot.img vendor_kernel_boot.img init_boot.img > SHA256SUMS-dace )
    bbnote "Dace boot artifacts deployed: ${DEPLOYDIR}/{boot,vendor_kernel_boot,init_boot}.img"
}
addtask deploy after do_compile before do_build
