#!/system/bin/sh
# 开机早期（post-fs-data）尝试“快路径”：此时 zram 往往还没被 ROM/mmd 初始化
# （disksize==0），可以零打扰地把压缩算法/大小设好，之后 ROM 直接沿用。
# 若此时 zram 已经被占用，则什么都不做，交给 service.sh（late_start）处理。
MODDIR=${0%/*}
[ "$MODDIR" = "$0" ] && MODDIR=.
exec sh "$MODDIR/service.sh" --fast
