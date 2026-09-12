#!/system/bin/sh
# ZRAM for LG V60 (timelm)
#
# 用法：
#   service.sh            开机后（等 sys.boot_completed=1）应用一次配置
#   service.sh --now      立即应用（模块“操作”按钮 / action.sh 走这条）
#   service.sh --fast     只做“快路径”：仅当 zram 尚未初始化（disksize==0）时才配置，
#                         不做任何 swapoff（post-fs-data.sh 用，零打扰）
#
# 关于 swapoff：zram 上的 swap 关闭时必须把压缩页全部读回内存，实测在 V60 上
# 需要数十秒（与 swap 用量成正比）。慢路径会临时把 vm.swappiness 设为 0，
# 避免“一边读回一边又换出”的抖动；失败则中止并保留原状（不动 swap）。

MODDIR=${0%/*}
# 兼容以相对路径调用（sh service.sh）：此时 ${0%/*} 等于 $0 本身
[ "$MODDIR" = "$0" ] && MODDIR=.
CONFIG_FILE="$MODDIR/config.prop"
LOG="$MODDIR/zram.log"
TAG=zram-lgv60
ZRAM_DEV=/dev/block/zram0
SYS=/sys/block/zram0

# 函数名不可叫 log：mksh 的 `command` 不绕过同名函数，会自我递归
zlog() {
  echo "$(date '+%m-%d %H:%M:%S') $*" >>"$LOG"
  [ -x /system/bin/log ] && /system/bin/log -t "$TAG" "$*"
}

[ -f "$CONFIG_FILE" ] || { zlog "config.prop 不存在，退出"; exit 1; }
. "$CONFIG_FILE"

ZRAM_ALGO=${ZRAM_ALGO:-lz4kd}
ZRAM_SIZE=${ZRAM_SIZE:-}
SWAP_PRIORITY=${SWAP_PRIORITY:--2}
MAX_COMP_STREAMS=${MAX_COMP_STREAMS:-8}
BOOT_WAIT_SECONDS=${BOOT_WAIT_SECONDS:-120}

MODE="$1"

cur_algo() { sed -n 's/.*\[\(.*\)\].*/\1/p' "$SYS/comp_algorithm" 2>/dev/null; }
cur_size() { cat "$SYS/disksize" 2>/dev/null; }
algo_supported() { grep -qw "$ZRAM_ALGO" "$SYS/comp_algorithm" 2>/dev/null; }
swap_active() { grep -q "zram0" /proc/swaps 2>/dev/null; }

# 大小校验：不用 [ -gt ]，mksh 的大整数比较不可靠（4GiB=4294967296 会判失败）
size_ok() {
  case "$1" in
    ''|*[!0-9]*|0) return 1 ;;
  esac
  return 0
}

# 解析目标大小：显式配置优先，否则沿用当前（ROM）值
target_size() {
  if [ -n "$ZRAM_SIZE" ]; then
    echo "$ZRAM_SIZE"
    return 0
  fi
  cur_size
}

# 解析目标优先级：显式配置优先，否则沿用当前 swap 的优先级
target_prio() {
  if [ -n "$SWAP_PRIORITY" ]; then
    echo "$SWAP_PRIORITY"
    return 0
  fi
  p=$(awk '$1 ~ /zram0/ {print $5}' /proc/swaps 2>/dev/null)
  echo "${p:--2}"
}

# 写入算法/大小并启用 swap（调用前必须已确保 disksize==0 或已完成 reset）
setup_and_swapon() {
  size="$1"; prio="$2"
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
    zlog "已启用: 算法 $(cur_algo)，大小 $(cur_size) 字节，优先级 $prio"
    return 0
  fi
  # toybox 的 swapon 不接受负优先级（<0 直接报错）。单 swap 设备时优先级无意义，
  # 故退化为不带 -p 的默认优先级。
  if swapon "$ZRAM_DEV" >>"$LOG" 2>&1; then
    zlog "已启用: 算法 $(cur_algo)，大小 $(cur_size) 字节（toybox 不支持负优先级 -p，用默认优先级）"
    return 0
  fi
  zlog "swapon 失败，详见 $LOG"
  return 1
}

# ---------- 快路径：zram 尚未初始化时直接配置，无 swapoff ----------
fast_path() {
  [ "$(cur_size)" = "0" ] || return 1
  algo_supported || {
    zlog "内核不支持算法 '$ZRAM_ALGO'。当前可用: $(cat "$SYS/comp_algorithm")"
    return 1
  }
  size="$(target_size)"; prio="$(target_prio)"
  size_ok "$size" || { zlog "无法确定 zram 大小（ZRAM_SIZE='$ZRAM_SIZE'）"; return 1; }
  zlog "快路径: zram 未初始化 → 算法 ${ZRAM_ALGO}，大小 $size 字节，优先级 $prio"
  setup_and_swapon "$size" "$prio"
}

# ---------- 慢路径：已被占用 → 关 swap（swappiness=0 防抖）后重建 ----------
slow_path() {
  algo_supported || {
    zlog "内核不支持算法 '$ZRAM_ALGO'。当前可用: $(cat "$SYS/comp_algorithm")"
    return 1
  }
  size="$(target_size)"; prio="$(target_prio)"
  size_ok "$size" || { zlog "无法确定 zram 大小（ZRAM_SIZE='$ZRAM_SIZE'）"; return 1; }

  zlog "重建 zram0: 算法 ${ZRAM_ALGO}（原 $(cur_algo)），大小 $size 字节，优先级 $prio，当前 swap 用量 $(awk '$1 ~ /zram0/ {print $4 " kB"}' /proc/swaps)"

  old_sw="$(cat /proc/sys/vm/swappiness 2>/dev/null)"
  [ -n "$old_sw" ] && echo 0 >/proc/sys/vm/swappiness

  t0="$(date +%s)"
  if ! swapoff "$ZRAM_DEV" >>"$LOG" 2>&1; then
    zlog "swapoff 失败（用时 $(( $(date +%s) - t0 ))s）→ 保持原状不动"
    [ -n "$old_sw" ] && echo "$old_sw" >/proc/sys/vm/swappiness
    return 1
  fi
  zlog "swapoff 完成，用时 $(( $(date +%s) - t0 ))s"

  echo 1 >"$SYS/reset" 2>/dev/null
  echo 0 >"$SYS/disksize" 2>/dev/null
  rc=0
  setup_and_swapon "$size" "$prio" || rc=1

  if [ -n "$old_sw" ]; then
    echo "$old_sw" >/proc/sys/vm/swappiness
    zlog "vm.swappiness 已恢复为 $old_sw"
  fi
  return $rc
}

wait_boot() {
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

# ---------- 主流程 ----------
if [ "$MODE" = "--fast" ]; then
  fast_path
  exit $?
fi

[ "$MODE" = "--now" ] || wait_boot || exit 1
[ "$MODE" = "--now" ] || sleep 5

size="$(target_size)"; [ -n "$size" ] || size=0
if [ "$(cur_algo)" = "$ZRAM_ALGO" ] && [ "$(cur_size)" = "$size" ] && swap_active; then
  zlog "已是目标配置（算法 $ZRAM_ALGO，大小 $size），无需重建"
  exit 0
fi

if ! fast_path; then
  slow_path || exit 1
fi

# LG 的 mmd 可能在之后重新初始化 zram；15s 后复核一次，被改回就再处理一次。
sleep 15
size="$(target_size)"; [ -n "$size" ] || size=0
if [ "$(cur_algo)" != "$ZRAM_ALGO" ] || [ "$(cur_size)" != "$size" ]; then
  zlog "发现 zram 被其他组件重置（算法 $(cur_algo)，大小 $(cur_size)），再处理一次"
  if ! fast_path; then
    slow_path
  fi
fi
