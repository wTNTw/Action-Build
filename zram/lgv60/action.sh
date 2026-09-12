#!/system/bin/sh
# KernelSU 管理器里点模块的“操作”按钮时执行：立即重建 zram0（不等待开机完成）。
MODDIR=${0%/*}
# 兼容以相对路径调用（sh service.sh）：此时 ${0%/*} 等于 $0 本身
[ "$MODDIR" = "$0" ] && MODDIR=.
exec sh "$MODDIR/service.sh" --now
