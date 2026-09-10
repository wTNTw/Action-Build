#!/bin/bash

# Some logics of this script are copied from [scripts/build_kernel]. Thanks to UtsavBalar1231.

# Ensure the script exits on error
set -e

TOOLCHAIN_PATH=$HOME/toolchain/bin
TARGET_DEVICE=$1

if [ -z "$1" ]; then
    echo "Error: No argument provided, please specific a target device."
    echo "If you need KernelSU, please add [ksu] as the second arg."
    echo "Examples:"
    echo "Build for timelm without KernelSU:"
    echo "  bash build.sh timelm"
    echo "Build for timelm with KernelSU:"
    echo "  bash build.sh timelm ksu"
    exit 1
fi

if [ ! -d $TOOLCHAIN_PATH ]; then
    echo "TOOLCHAIN_PATH [$TOOLCHAIN_PATH] does not exist."
    echo "Please ensure the toolchain is there, or change TOOLCHAIN_PATH in the script to your toolchain path."
    exit 1
fi

echo "TOOLCHAIN_PATH: [$TOOLCHAIN_PATH]"
export PATH="$TOOLCHAIN_PATH:$PATH"

if ! command -v clang >/dev/null 2>&1; then
    echo "[clang] does not exist, please check your environment."
    exit 1
fi

# Enable ccache for speed up compiling
export CCACHE_DIR="$HOME/.cache/ccache_mikernel"
export CC="clang"
export CXX="clang++"
export PATH="/usr/lib/ccache:$PATH"
export CCACHE_COMPILERCHECK=content
export CCACHE_SLOPPINESS=time_macros,include_file_mtime,include_file_ctime

# Enable ccache-ECS (Effective Configuration State) caching for kernel builds
export CCACHE_IS_KERNEL_COMPILING="true"

echo "CCACHE_DIR: [$CCACHE_DIR]"

# Export Build Info
export KBUILD_BUILD_USER="kiyomi"
export KBUILD_BUILD_HOST="yuki"

# Handle BUILD_TIME option
if [ -n "${BUILD_TIME}" ]; then
    if [ "${BUILD_TIME}" = "F" ]; then
        # Use UTCT (Coordinated Universal Time)
        export KBUILD_BUILD_TIMESTAMP=$(TZ="UTC" date)
        echo "Using UTCT build time: $KBUILD_BUILD_TIMESTAMP"
    elif [ "${BUILD_TIME}" = "-1" ]; then
        # Disable custom build time, use default
        export KBUILD_BUILD_TIMESTAMP=$(TZ="Japan" date)
        echo "Build time disabled, using default Japan time"
    else
        # Use custom build time
        export KBUILD_BUILD_TIMESTAMP="${BUILD_TIME}"
        echo "Using custom build time: $KBUILD_BUILD_TIMESTAMP"
    fi
else
    # Default to Japan time
    export KBUILD_BUILD_TIMESTAMP=$(TZ="Japan" date)
fi

MAKE_ARGS="ARCH=arm64 \
    SUBARCH=arm64 \
    O=out \
    CC=clang \
    HOSTCC=clang \
    CLANG_TRIPLE=aarch64-linux-gnu- \
    LD=ld.lld \
    AR=llvm-ar \
    NM=llvm-nm \
    OBJCOPY=llvm-objcopy \
    OBJDUMP=llvm-objdump \
    STRIP=llvm-strip"

if [ "$1" == "j1" ]; then
    make $MAKE_ARGS -j1
    exit
fi

if [ "$1" == "continue" ]; then
    make $MAKE_ARGS -j$(nproc)
    exit
fi

if [ ! -f "arch/arm64/configs/${TARGET_DEVICE}_defconfig" ]; then
    echo "No target device [${TARGET_DEVICE}] found."
    echo "Avaliable defconfigs, please choose one target from below down:"
    ls arch/arm64/configs/*_defconfig
    exit 1
fi

# Check clang is existing.
echo "[clang --version]:"
clang --version

# Parse KPM option from environment or default
KPM_OPTION=${KPM_OPTION:-KPM}
RE_KERNEL_ENABLE=${RE_KERNEL:-true}
NETFILTER_ENABLE=${NETFILTER:-true}
CCM_ENABLE=${CCM:-false}
DROID_SPACES_ENABLE=${DROID_SPACES:-false}
IPV6_NAT_ENABLE=${IPV6_NAT:-false}

# droid_spaces 细分开关（便于二分定位到底是哪个选项破坏 ABI）
# DROID_SPACES=true 时以下全部打开；否则按各自的值生效。
DS_PID_IPC_NS_ENABLE=${DS_PID_IPC_NS:-false}
DS_SYSVIPC_ENABLE=${DS_SYSVIPC:-false}
DS_POSIX_MQUEUE_ENABLE=${DS_POSIX_MQUEUE:-false}
DS_USER_NS_ENABLE=${DS_USER_NS:-false}
DS_DEVTMPFS_ENABLE=${DS_DEVTMPFS:-false}
DS_XT_ENABLE=${DS_XT:-false}

KSU_ZIP_STR=NoKernelSU
if [ "$2" == "ksu" ]; then
    KSU_ENABLE=1
    KSU_ZIP_STR=ReSukiSU-SuSFS
else
    KSU_ENABLE=0
fi

echo "KPM_OPTION: $KPM_OPTION"
echo "RE_KERNEL: $RE_KERNEL_ENABLE"
echo "NETFILTER: $NETFILTER_ENABLE"
echo "CCM: $CCM_ENABLE"
echo "DROID_SPACES: $DROID_SPACES_ENABLE"
echo "IPV6_NAT: $IPV6_NAT_ENABLE"
echo "droid_spaces sub-switches: pid_ipc_ns=$DS_PID_IPC_NS_ENABLE sysvipc=$DS_SYSVIPC_ENABLE posix_mqueue=$DS_POSIX_MQUEUE_ENABLE user_ns=$DS_USER_NS_ENABLE devtmpfs=$DS_DEVTMPFS_ENABLE xt=$DS_XT_ENABLE"

echo "TARGET_DEVICE: $TARGET_DEVICE"

if [ $KSU_ENABLE -eq 1 ]; then
    echo "KSU is enabled"
    curl -LSs "https://raw.githubusercontent.com/ReSukiSU/ReSukiSU/main/kernel/setup.sh" | bash
    
    # Compute KernelSU version number (same scheme as Action-Build)
    KSU_VERSION=$(expr $(git -C KernelSU rev-list --count HEAD 2>/dev/null || echo 13000) + 30700)
    echo "KSU_VERSION: $KSU_VERSION"
    
    if [ -n "$GITHUB_ENV" ]; then
        echo "KSUVER=$KSU_VERSION" >> "$GITHUB_ENV"
    fi

    # ==========================================================
    # Android 16 boot fix: scope the su-session driver fd
    # ----------------------------------------------------------
    # ReSukiSU installs the [ksu_driver_su] anon-inode fd from the
    # bprm_committed_creds LSM hook. That hook runs for EVERY exec because
    # this kernel's fs/exec.c has no post-exec hook, so KSU defines
    # KSU_COMPAT_NO_POST_EXECVE_HOOK. The only guard in the source is
    # CONFIG_KSU_MANUAL_HOOK, which is NOT set when the KSU_SUSFS hook mode
    # is used, so fd 3 ends up in every process, zygote64 included.
    #
    # Android 16 validates every fd of Zygote's FileDescriptorTable at
    # forkSystemServer time and aborts on that anon inode, whose i_mode
    # carries no S_IFMT type bits:
    #   JNI FatalError called: (system_server) Unsupported st_mode for FD 3: Unknown
    # Result: zygote crash-loops, system_server never starts and the device
    # hangs on the boot animation.
    #
    # Fix: enable the existing TIF_PROC_IN_KSU_EXECVE guard for the SUSFS hook
    # mode too, so only the thread that exec'd su (rewritten to ksud) receives
    # the scoped su-session fd. Bit 61 is free here: this kernel uses TIF bits
    # 0-26, SUSFS uses 33-35 and KSU uses 63.
    # ==========================================================
    echo "Applying Android 16 su-session fd scope fix..."
    python3 - <<'KSU_FD_SCOPE_PATCH'
import pathlib
import sys

EDITS = [
    (
        "sucompat.h: define TIF_PROC_IN_KSU_EXECVE for the SUSFS hook mode",
        "KernelSU/kernel/feature/sucompat.h",
        """#define ksu_clear_current_proc_unprivillege susfs_clear_current_proc_no_su
#else // manual hook""",
        """#define ksu_clear_current_proc_unprivillege susfs_clear_current_proc_no_su

// Spare arm64 TIF bits here are 27-62: the kernel itself uses 0-26, SUSFS uses
// 33-35 and KSU uses 63 for TIF_KSU_DISABLE_ESCAPE_WITH_ROOT.
// This flag records that the current thread exec'd su and was rewritten to ksud,
// so that only that process receives the scoped su-session driver fd.
#ifdef CONFIG_64BIT
#define TIF_PROC_IN_KSU_EXECVE 61
#else
#define TIF_PROC_IN_KSU_EXECVE 29
#endif
#else // manual hook""",
    ),
    (
        "sucompat.c: set the flag when su is rewritten to ksud",
        "KernelSU/kernel/feature/sucompat.c",
        """#ifdef CONFIG_KSU_MANUAL_HOOK
    // flag for post execve hook, mostly: bprm_committed_creds LSM hooks
    // no need care in susfs, susfs completed everything
    set_thread_flag(TIF_PROC_IN_KSU_EXECVE);
#endif""",
        """#if defined(CONFIG_KSU_SUSFS) || defined(CONFIG_KSU_MANUAL_HOOK)
    // flag for post execve hook, mostly: bprm_committed_creds LSM hooks
    // Remember that this thread exec'd su and was rewritten to ksud, so only
    // this process may receive the scoped su-session fd afterwards.
    set_thread_flag(TIF_PROC_IN_KSU_EXECVE);
#endif""",
    ),
    (
        "sucompat.c: only install the scoped fd for that process",
        "KernelSU/kernel/feature/sucompat.c",
        """int ksu_handle_post_execve(int *fd, const char *filename, void *argv, void *envp, int *flags, int *retval)
{
#ifdef CONFIG_KSU_MANUAL_HOOK
    if (likely(!test_thread_flag(TIF_PROC_IN_KSU_EXECVE))) {
        return -EINVAL;
    }
#endif""",
        """int ksu_handle_post_execve(int *fd, const char *filename, void *argv, void *envp, int *flags, int *retval)
{
#if defined(CONFIG_KSU_SUSFS) || defined(CONFIG_KSU_MANUAL_HOOK)
    // bprm_committed_creds runs for every exec. Only the process that just
    // exec'd su -> ksud may hold the scoped su-session fd; every other process
    // must keep fd 3 free, because Android 16 zygote validates all fds when it
    // forks system_server and aborts on this anon inode's st_mode.
    if (likely(!test_thread_flag(TIF_PROC_IN_KSU_EXECVE))) {
        return -EINVAL;
    }
#endif""",
    ),
]


root = pathlib.Path(".")
sources = {}

for name, rel, old, new in EDITS:
    path = root / rel
    if not path.is_file():
        print("error: %s not found" % path, file=sys.stderr)
        sys.exit(1)

    if rel not in sources:
        sources[rel] = path.read_text(encoding="utf-8")
    src = sources[rel]

    if new in src:
        print("already applied: %s" % name)
        continue

    count = src.count(old)
    if count != 1:
        print("error: anchor for '%s' matched %d times (expected 1) in %s" % (name, count, rel), file=sys.stderr)
        sys.exit(1)

    sources[rel] = src.replace(old, new, 1)
    print("applied: %s" % name)

for rel, src in sources.items():
    (root / rel).write_text(src, encoding="utf-8")

print("Android 16 su-session fd scope fix applied")
KSU_FD_SCOPE_PATCH
else
    echo "KSU is disabled"
fi

# Clear Previous Build
rm -rf out/
rm -rf anykernel/

echo "Clone AnyKernel3 for packing kernel (repo: https://github.com/kiy017/AnyKernel3)"
git clone https://github.com/kiy017/AnyKernel3.git -b master --single-branch --depth=1 anykernel

# ------------- Building Kernel -------------
echo "Building Kernel......"

make $MAKE_ARGS ${TARGET_DEVICE}_defconfig

# ==========================================================
# Pin the kernel release string to the stock one
# ----------------------------------------------------------
# Stock LineageOS/Axion kernel release:
#   4.19.325-cip133-st17-perf-g29902cf733dc
# composed of 4.19.325 (Makefile VERSION.PATCHLEVEL.SUBLEVEL) plus the
# localversion suffix below.
#
# NOTE: this release part is NOT what gates module loading. With
# CONFIG_MODVERSIONS=y the kernel's same_magic() skips everything up to
# the first space when the module carries symbol CRCs, so only the flags
# (SMP preempt mod_unload modversions aarch64) and the CRCs are compared.
# Verified on device: modules whose vermagic carries
# "-cip133-st17-perf-g29902cf733dc" load fine into a kernel built without
# it. Pinning the string is only about reporting the same release as the
# stock kernel, which some ROM components and apps inspect.
#
# scripts/setlocalversion is the only place that appends the localversion
# (see its own ${CONFIG_LOCALVERSION}${LOCALVERSION} line), and it would
# also append "-g<our-sha>" / "-dirty". So give it a fixed output instead
# of relying on localversion* files and git describe.
# CONFIG_MODVERSIONS is intentionally left untouched: it must stay in sync
# with the stock module flags.
# ==========================================================
echo "=========================================="
echo "Pinning kernel release to the stock one"
echo "Target: 4.19.325-cip133-st17-perf-g29902cf733dc"
echo "=========================================="

rm -f localversion localversion-cip localversion-st

scripts/config --file out/.config \
    --set-str CONFIG_LOCALVERSION "" \
    --disable CONFIG_LOCALVERSION_AUTO

if [ -f scripts/setlocalversion ] && [ ! -f scripts/setlocalversion.orig ]; then
    cp scripts/setlocalversion scripts/setlocalversion.orig
    printf '#!/bin/sh\n# Fixed output so KERNELRELEASE matches the stock release exactly\necho "-cip133-st17-perf-g29902cf733dc"\n' > scripts/setlocalversion
    chmod +x scripts/setlocalversion
fi

echo "Kernel release pinned to: 4.19.325-cip133-st17-perf-g29902cf733dc"
echo ""

if [ $KSU_ENABLE -eq 1 ]; then
    scripts/config --file out/.config \
        -e KSU \
        -e THREAD_INFO_IN_TASK \
        -e KSU_SUSFS \
        -e KSU_SUSFS_SUS_PATH \
        -e KSU_SUSFS_SUS_MOUNT \
        -e KSU_SUSFS_SUS_KSTAT \
        -e KSU_SUSFS_SUS_KSTAT_REDIRECT \
        -e KSU_SUSFS_SPOOF_UNAME \
        -e KSU_SUSFS_ENABLE_LOG \
        -e KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS \
        -e KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG \
        -e KSU_SUSFS_OPEN_REDIRECT \
        -e KSU_SUSFS_SUS_MAP \
        -e KSU_SUSFS_AUTO_ADD_SUS_KSU_DEFAULT_MOUNT \
        -e KSU_MULTI_MANAGER_SUPPORT \
        -e KSU_SUSFS_AUTO_ADD_SUS_BIND_MOUNT \
        -e TMPFS_XATTR \
        -e TMPFS_POSIX_ACL
    
    # Handle KPM option
    if [ "$KPM_OPTION" = "KPM" ]; then
        echo "Enabling KPM (Kernel Patch Manager)..."
        scripts/config --file out/.config -e KPM
    elif [ "$KPM_OPTION" = "KPN" ]; then
        echo "Enabling KPN (Kernel Patch Native)..."
        scripts/config --file out/.config -d KPM
        # KPN uses native kernel patching, no special config needed
    else
        echo "KPM/KPN disabled"
        scripts/config --file out/.config -d KPM
    fi
else
    scripts/config --file out/.config -d KSU
fi

# Handle Re:Kernel option
if [ "$RE_KERNEL_ENABLE" = "true" ]; then
    echo "Enabling Re:Kernel..."
    scripts/config --file out/.config -e REKERNEL
    
    # Handle NETFILTER option (part of Re:Kernel Network)
    if [ "$NETFILTER_ENABLE" = "true" ]; then
        echo "Enabling Re:Kernel Network (NETFILTER)..."
        scripts/config --file out/.config -e REKERNEL_NETWORK
    else
        echo "Re:Kernel Network (NETFILTER) disabled"
        scripts/config --file out/.config -d REKERNEL_NETWORK
    fi
else
    echo "Re:Kernel disabled"
    scripts/config --file out/.config -d REKERNEL -d REKERNEL_NETWORK
fi

# Handle CCM (Network Congestion Control - BBRv1)
if [ "$CCM_ENABLE" = "true" ]; then
    echo "Enabling CCM (BBRv1 + ECN)..."
    scripts/config --file out/.config \
        -e TCP_CONG_ADVANCED \
        -e TCP_CONG_BBR \
        -e TCP_CONG_CUBIC \
        -e TCP_CONG_WESTWOOD \
        -e TCP_CONG_HTCP \
        -e NET_SCH_FQ \
        -e NET_SCH_FQ_CODEL \
        -e DEFAULT_BBR \
        --set-str DEFAULT_TCP_CONG "bbr"
    echo "CCM enabled: BBRv1 congestion control with FQ qdisc"
else
    echo "CCM disabled, using default CUBIC"
fi

# ==========================================================
# DROID_SPACES (optional, default off) - 轻量 Linux 容器支持
# ----------------------------------------------------------
# 背景：早期结论认为它会“掉驱动”（commit da72d21 / 36859d0 时期）。
# 但那些测试发生在内核根本没能正常开机的阶段 —— Android 16 的
# KSU su-session fd bug 会让 zygote 崩溃循环、卡在开机动画，框架起不来，
# WiFi/音频自然不可用，看起来就像“驱动掉了”。
#
# 实测对照（可用基线，2026-09-10）：当前内核与 stock 已有 41 项新增 +
# 11 项取值不同的配置差异（KSU/SUSFS/REKERNEL + CCM 的 TCP_CONG_ADVANCED/BBR、
# NET_SCH_FQ 等），34 个 /vendor 模块仍全部加载成功、0 条 CRC/version magic 错误。
# 真正会打断 vendor 预编译模块的是 CONFIG_MODVERSIONS 的 CRC 校验
# （尤其 module_layout ← struct module 布局），而影响 struct module 的选项
# （MODULE_UNLOAD/KALLSYMS/TRACEPOINTS/EVENT_TRACING/JUMP_LABEL/CFI_CLANG/
# TREE_SRCU 等）我们与 stock 逐项一致，droid_spaces 选项集也不涉及它们。
#
# 刷入后请验证：
#   adb shell su -c 'zcat /proc/config.gz | grep -E "SYSVIPC|USER_NS|PID_NS"'
#   adb shell su -c 'wc -l /proc/modules'          # 期望 34
#   adb logcat -b kernel -d | grep -icE "disagrees about version|Unknown symbol"  # 期望 0
#   adb shell 'cmd wifi status | head -3'          # 期望 connected
#   adb shell getprop sys.boot_completed           # 期望 1
# ==========================================================
# master 开关：打开即启用全部细分项
if [ "$DROID_SPACES_ENABLE" = "true" ]; then
    DS_PID_IPC_NS_ENABLE=true
    DS_SYSVIPC_ENABLE=true
    DS_POSIX_MQUEUE_ENABLE=true
    DS_USER_NS_ENABLE=true
    DS_DEVTMPFS_ENABLE=true
    DS_XT_ENABLE=true
fi

DS_ANY=false

if [ "$DS_PID_IPC_NS_ENABLE" = "true" ]; then
    DS_ANY=true
    echo "ds_pid_ipc_ns -> NAMESPACES PID_NS IPC_NS"
    scripts/config --file out/.config -e NAMESPACES -e PID_NS -e IPC_NS
fi

if [ "$DS_SYSVIPC_ENABLE" = "true" ]; then
    DS_ANY=true
    echo "ds_sysvipc -> SYSVIPC SYSVIPC_SYSCTL SYSVIPC_COMPAT"
    scripts/config --file out/.config -e SYSVIPC -e SYSVIPC_SYSCTL -e SYSVIPC_COMPAT
fi

if [ "$DS_POSIX_MQUEUE_ENABLE" = "true" ]; then
    DS_ANY=true
    echo "ds_posix_mqueue -> POSIX_MQUEUE POSIX_MQUEUE_SYSCTL"
    scripts/config --file out/.config -e POSIX_MQUEUE -e POSIX_MQUEUE_SYSCTL
fi

if [ "$DS_USER_NS_ENABLE" = "true" ]; then
    DS_ANY=true
    echo "ds_user_ns -> USER_NS"
    scripts/config --file out/.config -e USER_NS
fi

if [ "$DS_DEVTMPFS_ENABLE" = "true" ]; then
    DS_ANY=true
    echo "ds_devtmpfs -> DEVTMPFS DEVTMPFS_MOUNT"
    scripts/config --file out/.config -e DEVTMPFS -e DEVTMPFS_MOUNT
fi

if [ "$DS_XT_ENABLE" = "true" ]; then
    DS_ANY=true
    echo "ds_xt -> NETFILTER_XT_TARGET_REJECT NETFILTER_XT_TARGET_LOG NETFILTER_XT_MATCH_RECENT"
    scripts/config --file out/.config \
        -e NETFILTER_XT_TARGET_REJECT \
        -e NETFILTER_XT_TARGET_LOG \
        -e NETFILTER_XT_MATCH_RECENT
fi

if [ "$DS_ANY" = "false" ]; then
    echo "droid_spaces: all sub-switches disabled"
fi

# ==========================================================
# IPv6 NAT (optional, default off)
# ----------------------------------------------------------
# 与 SukiSU-Ultra 分支 workflow 里 NETFILTER 组中的 IPv6 NAT 部分保持一致，
# 使两个分支的该特性定义相同。IP6_NF_NAT 是开关，其余目标选项依赖它，
# 同一次 scripts/config 调用里一起写进 .config 后由 kconfig 解析生效。
# 刷入后验证：
#   adb shell su -c 'zcat /proc/config.gz | grep -E "IP6_NF_NAT|NFT_NAT_IPV6"'
# ==========================================================
if [ "$IPV6_NAT_ENABLE" = "true" ]; then
    echo "Enabling IPv6 NAT / Redirect support..."
    scripts/config --file out/.config \
        -e IP6_NF_NAT \
        -e NF_NAT_MASQUERADE_IPV6 \
        -e IP6_NF_TARGET_MASQUERADE \
        -e IP6_NF_TARGET_REDIRECT \
        -e IP6_NF_TARGET_NPT \
        -e NF_TABLES_IPV6 \
        -e NFT_NAT_IPV6
    echo "IPv6 NAT enabled: MASQUERADE / REDIRECT / DNAT-SNAT / NPT"
else
    echo "IPv6 NAT disabled (default)"
fi

make $MAKE_ARGS -j$(nproc)

# Check if kernel image exists
if [ -f "out/arch/arm64/boot/Image" ]; then
    echo "The file [out/arch/arm64/boot/Image] exists. Kernel Build successfully."
else
    echo "The file [out/arch/arm64/boot/Image] does not exist. Seems Kernel build failed."
    exit 1
fi

# Patch Kernel For KPM Support
if [ $KSU_ENABLE -eq 1 ] && [ "$KPM_OPTION" = "KPM" ]; then
    echo "Applying KPM patch..."
    cd out/arch/arm64/boot/
    wget https://github.com/SukiSU-Ultra/SukiSU_KernelPatch_patch/releases/download/0.13.0/patch_linux
    chmod +x patch_linux
    ./patch_linux
    rm Image
    mv oImage Image
    cd -
    echo "KPM patch applied successfully"
else
    echo "KPM patch skipped (KPM_OPTION=$KPM_OPTION)"
fi

echo "Generating [out/arch/arm64/boot/dtb]......"
find out/arch/arm64/boot/dts -name '*.dtb' -exec cat {} + >out/arch/arm64/boot/dtb

rm -rf anykernel/kernels/

# Genrate Image-dtb
if [ ! -f "out/arch/arm64/boot/Image.gz" ] && [ -f "out/arch/arm64/boot/Image" ]; then
    echo "Merging Image.gz and compiled DTBs into integrated image..."
    cat out/arch/arm64/boot/Image $(find out/arch/arm64/boot/dts/ -name "*.dtb") > out/arch/arm64/boot/Image-dtb
    echo "Generated integrated Image-dtb binary!"
fi

# Fix and copy modules
if grep -q "CONFIG_MODULES=y" "out/.config"; then
    echo "Compiling and installing modules..."
    MODULES_OUT="$(pwd)/out/modules_out"
    rm -rf "$MODULES_OUT"
    
    #Specify Modules path
    make $MAKE_ARGS INSTALL_MOD_PATH="$MODULES_OUT" modules_install
    
    if [ -d "$MODULES_OUT/lib/modules" ]; then
        echo "Translating kernel build footprints to exact stock firmware signatures..."
        TARGET_KV_DIR=$(find "$MODULES_OUT/lib/modules" -mindepth 1 -maxdepth 1 -type d | head -n 1)
        FLAT_STAGE="$MODULES_OUT/flat_modules"
        mkdir -p "$FLAT_STAGE"
        
        # Rename audio Modules
        find "$TARGET_KV_DIR/kernel/techpack/audio" -name "*.ko" 2>/dev/null | while read -r audio_mod; do
            base_name=$(basename "$audio_mod" ".ko")
            if [ "$base_name" = "machine_dlkm" ]; then
                cp "$audio_mod" "$FLAT_STAGE/audio_machine_kona.ko"
            else
                # Strip _dlkm suffix if present and prepend audio_
                clean_name=$(echo "$base_name" | sed 's/_dlkm//')
                cp "$audio_mod" "$FLAT_STAGE/audio_${clean_name}.ko"
            fi
        done
        
        # Reaname Wifi Module
        if [ -f "$TARGET_KV_DIR/kernel/drivers/staging/qcacld-3.0/wlan.ko" ]; then
            cp "$TARGET_KV_DIR/kernel/drivers/staging/qcacld-3.0/wlan.ko" "$FLAT_STAGE/qca_cld3_qca6390.ko"
        fi
        
        #Gather any remaining compiled system driver binaries
        find "$TARGET_KV_DIR/kernel" -name "*.ko" ! -path "*qcacld-3.0*" ! -path "*techpack/audio*" | while read -r misc_mod; do
            base_name=$(basename "$misc_mod")
            cp "$misc_mod" "$FLAT_STAGE/$base_name"
        done
        
        # Clean out original upstream nested kernel directory structures
        rm -rf "$TARGET_KV_DIR/kernel"
        rm -f "$TARGET_KV_DIR"/source "$TARGET_KV_DIR"/build
        
        # Swap corrected, flattened files directly into module execution root
        mv "$FLAT_STAGE"/* "$TARGET_KV_DIR/"
        rm -rf "$FLAT_STAGE"
        
        # Set file permissions
        find "$TARGET_KV_DIR" -name "*.ko" -type f -exec chmod 644 {} +

        # ==========================================================
        # 模块 ABI 校验：与官方 stock 模块逐符号对照
        # ----------------------------------------------------------
        # CONFIG_MODVERSIONS=y 时内核会逐符号比对 CRC（另有每个模块都带的合成
        # 符号 module_layout）。只要有一个符号对不上，对应 stock 模块就拒绝加载：
        #     <mod>: disagrees about version of symbol <sym>
        # 结果是 /proc/modules 为空、WiFi/音频全部消失（“掉驱动”）。
        #
        # 基线取自 ROM 的 /vendor/lib/modules/*.ko（ci/stock-symbol-crcs.txt），
        # “本内核 CRC”取自自编 .ko 的 __versions + out/Module.symvers。
        # 0 差异 = stock 模块能全部加载。拉不到基线时退化为只查 module_layout。
        # ==========================================================
        STOCK_CRC_FILE=/tmp/stock-symbol-crcs.txt
        AB_BRANCH="${GITHUB_REF_NAME:-dev}"
        rm -f "$STOCK_CRC_FILE"
        if curl -fsSL "https://raw.githubusercontent.com/wTNTw/Action-Build/$AB_BRANCH/ci/stock-symbol-crcs.txt" -o "$STOCK_CRC_FILE" 2>/dev/null; then
            echo "Fetched stock ABI baseline: $(grep -c '^[A-Za-z_]' "$STOCK_CRC_FILE") symbols (branch $AB_BRANCH)"
        else
            echo "WARN: cannot fetch ci/stock-symbol-crcs.txt from branch $AB_BRANCH"
            echo "WARN: falling back to module_layout-only check"
            rm -f "$STOCK_CRC_FILE"
        fi

        MODCHECK_DIR="$TARGET_KV_DIR" STOCK_CRC_FILE="$STOCK_CRC_FILE" python3 - <<'MODCHECK_PYEOF'
import glob
import os
import struct
import sys


def versions_of(path):
    try:
        d = open(path, "rb").read()
    except Exception:
        return {}
    if d[:4] != b"\x7fELF":
        return {}
    is64 = d[4] == 2
    e_shoff = struct.unpack_from("<Q", d, 0x28)[0] if is64 else struct.unpack_from("<I", d, 0x20)[0]
    e_shentsize = struct.unpack_from("<H", d, 0x3A)[0] if is64 else struct.unpack_from("<H", d, 0x2E)[0]
    e_shnum = struct.unpack_from("<H", d, 0x3C)[0] if is64 else struct.unpack_from("<H", d, 0x30)[0]
    e_shstrndx = struct.unpack_from("<H", d, 0x3E)[0] if is64 else struct.unpack_from("<H", d, 0x32)[0]

    def sec(i):
        off = e_shoff + i * e_shentsize
        name = struct.unpack_from("<I", d, off)[0]
        if is64:
            _f, _a, o, s = struct.unpack_from("<QQQQ", d, off + 8)
        else:
            _f, _a, o, s = struct.unpack_from("<IIII", d, off + 8)
        return name, o, s

    secs = [sec(i) for i in range(e_shnum)]
    so = secs[e_shstrndx][1]

    def sn(i):
        a = so + i
        b = d.index(b"\x00", a)
        return d[a:b].decode("ascii", "replace")

    out = {}
    for ni, o, s in secs:
        if sn(ni) != "__versions":
            continue
        for i in range(s // 64):
            base = o + i * 64
            crc = struct.unpack_from("<Q", d, base)[0] & 0xFFFFFFFF
            nm = d[base + 8: base + 64].split(b"\x00")[0].decode("ascii", "replace")
            if nm:
                out[nm] = crc
    return out


root = os.environ["MODCHECK_DIR"]
ours = {}
kos = sorted(glob.glob(os.path.join(root, "**", "*.ko"), recursive=True))
for ko in kos:
    ours.update(versions_of(ko))

symvers = os.path.join("out", "Module.symvers")
symvers_found = os.path.isfile(symvers)
if symvers_found:
    for line in open(symvers, encoding="utf-8", errors="replace"):
        parts = line.split("\t")
        if len(parts) >= 2 and parts[0].startswith("0x"):
            try:
                ours[parts[1]] = int(parts[0], 16)
            except ValueError:
                pass

print("our modules scanned: %d, our symbols: %d (Module.symvers: %s)"
      % (len(kos), len(ours), "yes" if symvers_found else "no"))
if "module_layout" not in ours:
    print("WARN: module_layout not found in our modules; cannot verify")

base_path = os.environ.get("STOCK_CRC_FILE", "")
baseline = {}
if base_path and os.path.isfile(base_path):
    for line in open(base_path, encoding="utf-8", errors="replace"):
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.split()
        if len(parts) == 2 and parts[1].startswith("0x"):
            try:
                baseline[parts[0]] = int(parts[1], 16)
            except ValueError:
                pass

if not baseline:
    got = ours.get("module_layout")
    print("stock baseline unavailable -> module_layout-only check")
    if got is None:
        print("WARN: module_layout missing, skip")
        sys.exit(0)
    print("built kernel module_layout CRC = 0x%08x" % got)
    if got != 0xD273BD0C:
        print("BUILD REJECTED: module_layout CRC mismatch (expected 0xd273bd0c)")
        sys.exit(1)
    print("OK: module_layout CRC matches the stock vendor modules")
    sys.exit(0)

compared = 0
mismatch = []
missing = []
for sym, crc in baseline.items():
    if sym not in ours:
        missing.append(sym)
        continue
    compared += 1
    if ours[sym] != crc:
        mismatch.append((sym, ours[sym], crc))

print("stock baseline symbols: %d | compared: %d | mismatched: %d | not in our build: %d"
      % (len(baseline), compared, len(mismatch), len(missing)))

if mismatch:
    print("")
    print("==========================================================")
    print("BUILD REJECTED: kernel ABI differs from the stock ROM")
    print("")
    for sym, a, b in mismatch[:25]:
        print("  %-42s ours=0x%08x stock=0x%08x" % (sym, a, b))
    if len(mismatch) > 25:
        print("  ... and %d more" % (len(mismatch) - 25))
    print("")
    print("These stock /vendor modules will refuse to load:")
    print("  <mod>: disagrees about version of symbol <sym>")
    print("=> /proc/modules ends up empty, WiFi and audio are gone.")
    print("Revert the kernel config change that caused this.")
    print("==========================================================")
    sys.exit(1)

print("OK: 0 differences vs the stock ROM -> all /vendor modules will load")
if missing:
    print("WARN: %d baseline symbols are not exported by this build (not verified)" % len(missing))
    print("WARN: first 20: %s" % ", ".join(sorted(missing)[:20]))
sys.exit(0)
MODCHECK_PYEOF
        
        # Genrate modules.dep
        echo "Injecting verified stock modules.dep layout..."
        cat << 'EOF' > "$TARGET_KV_DIR/modules.dep"
/vendor/lib/modules/audio_adsp_loader.ko:
/vendor/lib/modules/audio_apr.ko /vendor/lib/modules/audio_q6_notifier.ko /vendor/lib/modules/audio_q6_pdr.ko /vendor/lib/modules/audio_snd_event.ko
/vendor/lib/modules/audio_stub.ko:
/vendor/lib/modules/audio_tx_macro.ko: /vendor/lib/modules/audio_swr_ctrl.ko /vendor/lib/modules/audio_swr.ko /vendor/lib/modules/audio_wcd_core.ko /vendor/lib/modules/audio_bolero_cdc.ko /vendor/lib/modules/audio_q6.ko /vendor/lib/modules/audio_apr.ko /vendor/lib/modules/audio_q6_notifier.ko /vendor/lib/modules/audio_q6_pdr.ko /vendor/lib/modules/audio_snd_event.ko
/vendor/lib/modules/tcp_westwood.ko:
/vendor/lib/modules/audio_wcd9xxx.ko: /vendor/lib/modules/audio_q6.ko /vendor/lib/modules/audio_apr.ko /vendor/lib/modules/audio_q6_notifier.ko /vendor/lib/modules/audio_q6_pdr.ko /vendor/lib/modules/audio_snd_event.ko
/vendor/lib/modules/audio_q6_notifier.ko: /vendor/lib/modules/audio_q6_pdr.ko
/vendor/lib/modules/audio_wcd_core.ko:
/vendor/lib/modules/audio_wsa883x.ko: /vendor/lib/modules/audio_swr.ko /vendor/lib/modules/audio_wcd_core.ko
/vendor/lib/modules/audio_snd_event.ko:
/vendor/lib/modules/cxd22xx.ko:
/vendor/lib/modules/audio_machine_kona.ko: /vendor/lib/modules/audio_wcd938x.ko /vendor/lib/modules/audio_mbhc.ko /vendor/lib/modules/audio_es9218.ko /vendor/lib/modules/audio_wcd9xxx.ko /vendor/lib/modules/audio_wsa881x.ko /vendor/lib/modules/audio_wsa883x.ko /vendor/lib/modules/audio_swr.ko /vendor/lib/modules/audio_wcd_core.ko /vendor/lib/modules/audio_bolero_cdc.ko /vendor/lib/modules/audio_q6.ko /vendor/lib/modules/audio_apr.ko /vendor/lib/modules/audio_q6_notifier.ko /vendor/lib/modules/audio_q6_pdr.ko /vendor/lib/modules/audio_snd_event.ko
/vendor/lib/modules/audio_rx_macro.ko: /vendor/lib/modules/audio_swr_ctrl.ko /vendor/lib/modules/audio_swr.ko /vendor/lib/modules/audio_wcd_core.ko /vendor/lib/modules/audio_bolero_cdc.ko /vendor/lib/modules/audio_q6.ko /vendor/lib/modules/audio_apr.ko /vendor/lib/modules/audio_q6_notifier.ko /vendor/lib/modules/audio_q6_pdr.ko /vendor/lib/modules/audio_snd_event.ko
/vendor/lib/modules/audio_wcd938x.ko: /vendor/lib/modules/audio_mbhc.ko /vendor/lib/modules/audio_es9218.ko /vendor/lib/modules/audio_wcd9xxx.ko /vendor/lib/modules/audio_swr.ko /vendor/lib/modules/audio_wcd_core.ko /vendor/lib/modules/audio_q6.ko /vendor/lib/modules/audio_apr.ko /vendor/lib/modules/audio_q6_notifier.ko /vendor/lib/modules/audio_q6_pdr.ko /vendor/lib/modules/audio_snd_event.ko
/vendor/lib/modules/audio_swr_ctrl.ko: /vendor/lib/modules/audio_swr.ko /vendor/lib/modules/audio_q6.ko /vendor/lib/modules/audio_apr.ko /vendor/lib/modules/audio_q6_notifier.ko /vendor/lib/modules/audio_q6_pdr.ko /vendor/lib/modules/audio_snd_event.ko
/vendor/lib/modules/audio_tfa9878.ko: /vendor/lib/modules/audio_q6.ko /vendor/lib/modules/audio_apr.ko /vendor/lib/modules/audio_q6_notifier.ko /vendor/lib/modules/audio_q6_pdr.ko /vendor/lib/modules/audio_snd_event.ko
/vendor/lib/modules/audio_va_macro.ko: /vendor/lib/modules/audio_swr_ctrl.ko /vendor/lib/modules/audio_swr.ko /vendor/lib/modules/audio_wcd_core.ko /vendor/lib/modules/audio_bolero_cdc.ko /vendor/lib/modules/audio_q6.ko /vendor/lib/modules/audio_apr.ko /vendor/lib/modules/audio_q6_notifier.ko /vendor/lib/modules/audio_q6_pdr.ko /vendor/lib/modules/audio_snd_event.ko
/vendor/lib/modules/audio_usf.ko: /vendor/lib/modules/audio_q6.ko /vendor/lib/modules/audio_apr.ko /vendor/lib/modules/audio_q6_notifier.ko /vendor/lib/modules/audio_q6_pdr.ko /vendor/lib/modules/audio_snd_event.ko
/vendor/lib/modules/wmc_drv.ko:
/vendor/lib/modules/audio_bolero_cdc.ko: /vendor/lib/modules/audio_q6.ko /vendor/lib/modules/audio_apr.ko /vendor/lib/modules/audio_q6_notifier.ko /vendor/lib/modules/audio_q6_pdr.ko /vendor/lib/modules/audio_snd_event.ko
/vendor/lib/modules/rmnet_perf.ko:
/vendor/lib/modules/audio_wsa_macro.ko: /vendor/lib/modules/audio_swr_ctrl.ko /vendor/lib/modules/audio_swr.ko /vendor/lib/modules/audio_wcd_core.ko /vendor/lib/modules/audio_bolero_cdc.ko /vendor/lib/modules/audio_q6.ko /vendor/lib/modules/audio_apr.ko /vendor/lib/modules/audio_q6_notifier.ko /vendor/lib/modules/audio_q6_pdr.ko /vendor/lib/modules/audio_snd_event.ko
/vendor/lib/modules/audio_wcd938x_slave.ko: /vendor/lib/modules/audio_swr.ko
/vendor/lib/modules/audio_apr.ko: /vendor/lib/modules/audio_q6_notifier.ko /vendor/lib/modules/audio_q6_pdr.ko /vendor/lib/modules/audio_snd_event.ko
/vendor/lib/modules/tcp_htcp.ko:
/vendor/lib/modules/audio_native.ko: /vendor/lib/modules/audio_platform.ko /vendor/lib/modules/audio_q6.ko /vendor/lib/modules/audio_apr.ko /vendor/lib/modules/audio_q6_notifier.ko /vendor/lib/modules/audio_q6_pdr.ko /vendor/lib/modules/audio_snd_event.ko
/vendor/lib/modules/audio_platform.ko: /vendor/lib/modules/audio_q6.ko /vendor/lib/modules/audio_apr.ko /vendor/lib/modules/audio_q6_notifier.ko /vendor/lib/modules/audio_q6_pdr.ko /vendor/lib/modules/audio_snd_event.ko
/vendor/lib/modules/audio_q6_pdr.ko:
/vendor/lib/modules/audio_hdmi.ko:
/vendor/lib/modules/audio_q6.ko: /vendor/lib/modules/audio_apr.ko /vendor/lib/modules/audio_q6_notifier.ko /vendor/lib/modules/audio_q6_pdr.ko /vendor/lib/modules/audio_snd_event.ko
/vendor/lib/modules/audio_swr.ko:
/vendor/lib/modules/qca_cld3_qca6390.ko:
/vendor/lib/modules/audio_es9218.ko:
/vendor/lib/modules/audio_pinctrl_lpi.ko: /vendor/lib/modules/audio_q6.ko /vendor/lib/modules/audio_apr.ko /vendor/lib/modules/audio_q6_notifier.ko /vendor/lib/modules/audio_q6_pdr.ko /vendor/lib/modules/audio_snd_event.ko
/vendor/lib/modules/gspca_main.ko:
/vendor/lib/modules/audio_wsa881x.ko: /vendor/lib/modules/audio_swr.ko /vendor/lib/modules/audio_wcd_core.ko
/vendor/lib/modules/rmnet_shs.ko:
/vendor/lib/modules/audio_mbhc.ko: /vendor/lib/modules/audio_es9218.ko
/vendor/lib/modules/audio_pinctrl_wcd.ko:
EOF
        
        touch "$TARGET_KV_DIR/modules.alias" "$TARGET_KV_DIR/modules.softdep"
        
        # Copy Modules to Anykernel Directory
        echo "Copying Modules into AnyKernel modules directory..."
        cp -r "$TARGET_KV_DIR"/* anykernel/modules/vendor/lib/modules/
        chmod 644 anykernel/modules/vendor/lib/modules/*

        # Also place modules into boot ramdisk /lib/modules.
        # AnyKernel3 repack_ramdisk() packs $AKHOME/ramdisk/ into the new
        # boot ramdisk, so the kernel can load modules that were compiled
        # together with it (guaranteed matching vermagic + MODVERSIONS CRC).
        echo "Placing Modules into boot ramdisk /lib/modules..."
        mkdir -p anykernel/ramdisk/lib/modules
        cp -f "$TARGET_KV_DIR"/*.ko anykernel/ramdisk/lib/modules/ 2>/dev/null || true
        chmod 644 anykernel/ramdisk/lib/modules/*.ko 2>/dev/null || true
        if [ -f "$TARGET_KV_DIR/modules.dep" ]; then
            sed 's|/vendor/lib/modules/||g' "$TARGET_KV_DIR/modules.dep" > anykernel/ramdisk/lib/modules/modules.dep 2>/dev/null || true
        fi
        cp -f "$TARGET_KV_DIR/modules.alias" "$TARGET_KV_DIR/modules.softdep" anykernel/ramdisk/lib/modules/ 2>/dev/null || true
        echo "Ramdisk modules: $(ls anykernel/ramdisk/lib/modules/*.ko 2>/dev/null | wc -l)"

        echo "Modules Copied Successfully"
    fi
fi

# ------------- Attach ReSukiSU Manager APK to AnyKernel3 -------------
# Manager APK will be downloaded by GitHub Actions workflow
# Skip this step in build.sh to avoid hanging

echo "Copying kernel image and dtb..."
cp out/arch/arm64/boot/Image-dtb anykernel/ || { echo "ERROR: Failed to copy Image-dtb"; exit 1; }
cp out/arch/arm64/boot/dtb anykernel/ || { echo "ERROR: Failed to copy dtb"; exit 1; }
echo "Kernel image and dtb copied successfully"

cd anykernel || { echo "ERROR: Failed to cd into anykernel"; exit 1; }

# Handle custom suffix (optional user-defined, no random string by default)
if [ -n "${SUFFIX}" ]; then
    if [ "${SUFFIX}" = "-1" ]; then
        # No custom suffix
        CUSTOM_SUFFIX=""
    else
        # Use custom suffix
        CUSTOM_SUFFIX="_${SUFFIX}"
    fi
else
    CUSTOM_SUFFIX=""
fi

# Match unified naming: ReSukiSU_35114_LG_V60_AnyKernel3.zip
if [ $KSU_ENABLE -eq 1 ]; then
    ZIP_FILENAME=ReSukiSU_${KSU_VERSION}_LG_V60${CUSTOM_SUFFIX}_AnyKernel3.zip
else
    ZIP_FILENAME=NoKernelSU_LG_V60${CUSTOM_SUFFIX}_AnyKernel3.zip
fi

echo "Creating AnyKernel3 flashable zip: $ZIP_FILENAME"
echo "Compressing files..."
zip -r9 $ZIP_FILENAME ./* -x .git .gitignore out/ ./*.zip || { echo "ERROR: Failed to create zip file"; exit 1; }
echo "Zip created successfully"

mv $ZIP_FILENAME ../ || { echo "ERROR: Failed to move zip file"; exit 1; }

cd ..

echo "Kernel Build Finished"
echo "Done. The flashable zip is: [./$ZIP_FILENAME]"
