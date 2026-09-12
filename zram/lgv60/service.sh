#!/system/bin/sh
# ZRAM for LG V60 (timelm)
# 开机后重建 zram0（算法/大小可配）。由 KernelSU/Magisk 以 root 身份在 late_start
# service 阶段执行；也可用 `sh service.sh --now` 立即执行（模块的“操作”按钮走这条）。
#
# 与内核无关：V60 的 zram 是内建的，不能 rmmod/insmod，所以这里只做
#   swapoff → reset → max_comp_streams → comp_algorithm → disksize → mkswap → swapon
# 顺序不能变：comp_algorithm 必须在 disksize 仍为 0 时写入才有效。

MODDIR=${0%/*}
# 兼容以相对路径调用（sh service.sh）：此时 ${0%/*} 等于 $0 本身
[ "$MODDIR" = "$0" ] && MODDIR=.
CONFIG_FILE="$MODDIR/config.prop"
LOG="$MODDIR/zram.log"
TAG=zram-lgv60
ZRAM_DEV=/dev/block/zram0
SYS=/sys/block/zram0

# 注意：函数名不能叫 log —— 那会遮蔽 /system/bin/log 并导致递归调用
zlog() {
  echo "$(date '+%m-%d %H:%M:%S') $*" >>"$LOG"
  # 用绝对路径调 logcat 二进制：mksh 的 `command` 不绕过同名函数，
  # 而函数名若与二进制同名会自我递归
  [ -x /system/bin/log ] && /system/bin/log -t "$TAG" "$*"
}

[ -f "$CONFIG_FILE" ] || { zlog "config.prop 不存在，退出"; exit 1; }
. "$CONFIG_FILE"

ZRAM_ALGO=${ZRAM_ALGO:-lz4kd}
ZRAM_SIZE=${ZRAM_SIZE:-}
SWAP_PRIORITY=${SWAP_PRIORITY:--2}
MAX_COMP_STREAMS=${MAX_COMP_STREAMS:-8}
BOOT_WAIT_SECONDS=${BOOT_WAIT_SECONDS:-120}

cur_algo() { sed -n 's/.*\[\(.*\)\].*/\1/p' "$SYS/comp_algorithm" 2>/dev/null; }
cur_size() { cat "$SYS/disksize" 2>/dev/null; }
algo_supported() { grep -qw "$ZRAM_ALGO" "$SYS/comp_algorithm" 2>/dev/null; }

wait_boot() {
  [ "$1" = "--now" ] && return 0
  i=0
  while [ "$(getprop sys.boot_completed 2>/dev/null)" != "1" ]; do
    i=$((i + 1))
    if [ "$i" -ge "$BOOT_WAIT_SECONDS" ]; then
      zlog "等待开机完成超时（${BOOT_WAIT_SECONDS}s），退出"
      return 1
    fi
    sleep 2
  done
  return 0
}

apply_zram() {
  [ -e "$ZRAM_DEV" ] || { zlog "找不到 $ZRAM_DEV"; return 1; }

  if ! algo_supported; then
    zlog "内核不支持算法 '$ZRAM_ALGO'。当前可用: $(cat "$SYS/comp_algorithm")"
    zlog "→ 先刷含该算法的内核，或把 config.prop 改回 zstd/lz4hc"
    return 1
  fi

  size="$ZRAM_SIZE"
  if [ -z "$size" ]; then
    size="$(cur_size)"
    zlog "ZRAM_SIZE 留空 → 沿用当前大小 $size"
  fi
  case "$size" in
    ''|*[!0-9]*|0) zlog "无法确定 zram 大小（ZRAM_SIZE='$ZRAM_SIZE'）"; return 1 ;;
  esac

  prio="$SWAP_PRIORITY"
  if [ -z "$prio" ]; then
    prio=$(awk '$1 ~ /zram0/ {print $5}' /proc/swaps 2>/dev/null)
    [ -n "$prio" ] || prio=-2
    zlog "SWAP_PRIORITY 留空 → 沿用 $prio"
  fi

  zlog "重建 zram0: 算法 ${ZRAM_ALGO}（原 $(cur_algo)），大小 $size 字节，优先级 $prio"

  swapoff "$ZRAM_DEV" 2>/dev/null
  echo 1 >"$SYS/reset" 2>/dev/null
  echo 0 >"$SYS/disksize" 2>/dev/null
  echo "$MAX_COMP_STREAMS" >"$SYS/max_comp_streams" 2>/dev/null

  if ! echo "$ZRAM_ALGO" >"$SYS/comp_algorithm" 2>/dev/null; then
    zlog "写入 comp_algorithm 失败（zram 可能仍被占用）"
    return 1
  fi
  if ! echo "$size" >"$SYS/disksize" 2>/dev/null; then
    zlog "写入 disksize 失败"
    return 1
  fi

  mkswap "$ZRAM_DEV" >>"$LOG" 2>&1
  if swapon -p "$prio" "$ZRAM_DEV" >>"$LOG" 2>&1; then
    zlog "已启用: 算法 $(cur_algo)，大小 $(cur_size) 字节，$(awk '$1 ~ /zram0/ {print "优先级 " $5}' /proc/swaps)"
    return 0
  fi
  zlog "swapon 失败，详见 $LOG"
  return 1
}

wait_boot "$1" || exit 1
[ "$1" = "--now" ] || sleep 5
apply_zram

# LG 的 mmd 可能在之后重新初始化 zram；15s 后复核一次，被改回就再应用一次。
sleep 15
if [ "$(cur_algo)" != "$ZRAM_ALGO" ]; then
  zlog "发现 zram 被其他组件重置（当前算法 $(cur_algo)），再应用一次"
  apply_zram
fi
