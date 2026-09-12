# ZRAM for LG V60（timelm）

开机后重建 `zram0`，让你指定压缩算法与大小。**不改内核、不替换内核模块**——
V60 的 zram 是内建的（`=y`），不能 rmmod/insmod，所以本模块只做运行时配置。

## 装机与使用

1. 在 KernelSU 管理器里安装 `ZRAM_LGV60.zip`，重启。
2. 想换算法/大小，编辑 `/data/adb/modules/zram-lgv60/config.prop` 再重启；
   或直接在管理器里点本模块的**操作**按钮立即应用（走 `service.sh --now`）。
3. 查日志：`/data/adb/modules/zram-lgv60/zram.log`，或 `logcat -s zram-lgv60`。
4. 核查现状：
   ```text
   cat /sys/block/zram0/comp_algorithm     # 方括号里是当前算法
   cat /sys/block/zram0/disksize
   cat /proc/swaps
   ```

## config.prop 说明

| 键 | 含义 | 默认 |
|---|---|---|
| `ZRAM_ALGO` | 压缩算法，需内核支持（`cat /sys/block/zram0/comp_algorithm` 可见） | `lz4kd` |
| `ZRAM_SIZE` | zram 大小（字节）；**留空 = 沿用 ROM 当前大小**（只换算法，最稳） | 空 |
| `SWAP_PRIORITY` | swap 优先级；留空 = 沿用当前 | `-2` |
| `MAX_COMP_STREAMS` | 压缩流数量 | `8` |
| `BOOT_WAIT_SECONDS` | 等待 `sys.boot_completed=1` 的上限 | `120` |

## 前置条件（lz4kd）

`lz4kd`（华为，随 vendor 内核广泛使用）需要在**内核侧**存在。本仓库构建已加入：
内核 fork 提交 `wTNTw/Resukisu-LG_V60@24882a81`（`lib/lz4kd/` + `crypto/lz4kd.c` +
`zram/zcomp.c` 的 backends 项），仓库侧 `build.sh` 打开 `CONFIG_CRYPTO_LZ4KD`。

刷了**不含** lz4kd 的内核时，本模块会在日志里明确报“内核不支持算法 lz4kd”并保持原状
（不会破坏已有 swap）。想直接用 stock 内核试，就把 `ZRAM_ALGO` 改成 `zstd` / `lz4hc`。

## 行为与风险

- 执行顺序固定为 `swapoff → reset → max_comp_streams → comp_algorithm → disksize →
  mkswap → swapon`；`comp_algorithm` 必须在 `disksize` 仍为 0 时写才有效。
- 默认**沿用 ROM 的 zram 大小与优先级**，只换算法——LG 的 `mmd` 负责 writeback 策略，
  大小不变可最大限度避开它的预期。
- `service.sh` 在开机后 5s 应用，并在 15s 后复核一次：若发现算法又被改回（`mmd` 重置），
  会再应用一次并记录日志。
- 极端情况（例如同时有别的 zram 调优模块）可能出现反复重建；此时以日志为准，
  二选一保留一个模块。
