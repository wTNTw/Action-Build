# ZRAM for LG V60（timelm）

开机后把 `zram0` 配上你指定的压缩算法与大小。**不改内核、不替换内核模块**——
V60 的 zram 是内建的（`=y`），不能 rmmod/insmod，所以本模块只做运行时配置。

默认配置：**算法 `lz4kd`、大小 4 GiB（4294967296）、优先级 -2、压缩流 8**。

## 装机与使用

1. 在 KernelSU 管理器里安装 `ZRAM_LGV60.zip`，重启。
2. 想改配置：编辑 `/data/adb/modules/zram-lgv60/config.prop` 后重启；
   或点模块的**操作**按钮立即应用（走 `service.sh --now`）。
3. 查日志：`/data/adb/modules/zram-lgv60/zram.log`，或 `logcat -s zram-lgv60`。
4. 核查现状：
   ```text
   sed -n 's/.*\[\(.*\)\].*/\1/p' /sys/block/zram0/comp_algorithm   # 当前算法
   cat /sys/block/zram0/disksize                                    # 大小（字节）
   cat /proc/swaps                                                  # 是否在用
   awk '{print "换出页", $1, "压缩后", $2, "实占内存", $3}' /sys/block/zram0/mm_stat
   ```

## config.prop

| 键 | 含义 | 默认 |
|---|---|---|
| `ZRAM_ALGO` | 压缩算法，需内核支持（`cat /sys/block/zram0/comp_algorithm` 可见） | `lz4kd` |
| `ZRAM_SIZE` | zram 大小（字节）；留空 = 沿用 ROM 当前大小（V60 原值约 3.73 GiB） | `4294967296`（4 GiB） |
| `SWAP_PRIORITY` | swap 优先级；留空 = 沿用当前 | `-2` |
| `MAX_COMP_STREAMS` | 压缩流数量 | `8` |
| `BOOT_WAIT_SECONDS` | `service.sh` 等待 `sys.boot_completed=1` 的上限 | `120` |

大小参考（8 GB 内存的 V60）：4 GiB（默认，够用）／`6442450944`（6 GiB）／`8589934592`（8 GiB，上限）。
zram 是惰性的——内存只花在实际存进去的压缩页上，改大上限本身不占内存。

## 执行时机与两条路径

- **快路径**（`post-fs-data.sh` → `service.sh --fast`）：开机早期若 zram 还没被 ROM/mmd
  初始化（`disksize==0`），直接把算法/大小设好，**零打扰**（不关 swap）。
- **慢路径**（`service.sh`，late_start）：开机完成后检查，若与目标不符则
  `swapoff → reset → 写算法 → 写大小 → mkswap → swapon`。
  `swapoff` 必须把 zram 里的压缩页全部读回内存，**实测 V60 上 236 MB 用量耗 53 秒**（与用量成正比）；
  期间会临时把 `vm.swappiness` 设为 0，避免“边读回边换出”的抖动，完成后恢复原值。
  若 `swapoff` 失败，脚本中止并**保持原状**（不动现有 swap）。
- **优先级注意**：toybox 的 `swapon` 不接受负优先级（`-p -2` 会报 `swapon: -p < 0`）。
  脚本先试 `-p`，失败则改用不带 `-p` 的默认优先级——实测该默认值落地就是 `-2`，与 ROM 一致。
  单个 swap 设备时优先级本就无实际影响。
- 幂等：若已是目标算法+大小且 swap 在用，脚本直接跳过，不会每次开机重复重建。
- 开机后 15s 复核一次：若发现被 mmd 重置，再处理一次。

## 前置条件（lz4kd）

`lz4kd`（华为）需要内核侧存在：内核 fork 提交 `wTNTw/Resukisu-LG_V60@24882a81`
（`lib/lz4kd/` + `crypto/lz4kd.c` + `zram/zcomp.c` 的 backends 项）＋仓库侧
`build.sh` 的 `CONFIG_CRYPTO_LZ4KD=y`。刷了不含该算法的内核时，本模块会在日志里
明确报“内核不支持算法 lz4kd”并保持原状（不会破坏已有 swap）；此时把 `ZRAM_ALGO`
改成 `zstd` / `lz4hc` 即可。

## 风险提示

- 重建 zram 期间（数十秒）系统处于“无 swap”状态，内存吃紧时可能触发 LMK 回收；
  因此脚本优先走快路径，慢路径也只在必要时才做。
- 若同时装了别的 zram 调优模块，可能互相重建；以日志为准，二选一保留。
