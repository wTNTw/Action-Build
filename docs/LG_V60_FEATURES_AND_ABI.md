# LG V60（timelm）特性开关与 ABI 实验记录

本文记录 `dev` 分支上 LG V60 各项可选特性开关的**构建期 ABI 全量对照**结果，以及哪些开关可以安全打开。

- 目标设备：LG V60 ThinQ 5G（`timelm`），Android 16
- 内核源：`wTNTw/Resukisu-LG_V60`，`lineage-23.2`
- 内核版本（本文所有实验共用）：`4.19.325-cip133-st17-perf-g29902cf733dc`
- 实验时间：2026-09-10

## 一、为什么需要这份记录

LG V60 的 vendor 模块（音频 30 个、`wlan`、`rmnet_perf`、`rmnet_shs`、`wmc_drv` …共 34 个）是 ROM 预编译的，位于只读的 `/vendor/lib/modules`，刷机时自编模块不会写入。因此**内核必须与 stock ROM 保持符号 ABI 兼容**，否则 vendor 模块拒绝加载，`/proc/modules` 为空，WiFi 与音频一起消失。

判断标准是 `CONFIG_MODVERSIONS` 的 CRC：内核与模块对同一符号算出的 CRC 必须一致。CRC 由 `genksyms` 从**类型声明**递归计算，所以一个看起来无关的 Kconfig 开关只要改动了 `struct task_struct` 这类被广泛引用的类型，就可能连带改变数百个导出符号的 CRC —— 且这种改动往往同时移动字段偏移，模块即便绕过校验也会读错内存。

构建期 guard（`ci/stock-symbol-crcs.txt` + `cb2b3b2` 引入的全量对照）会在打包前把这件事拦下来，输出一行 `stock baseline symbols: N | compared: M | mismatched: K | not in our build: J`，`K > 0` 即 `BUILD REJECTED`，不产出任何可刷入产物。

## 二、推荐配置（已验证 ABI 中性的组合）

刷 LG V60 时使用以下输入组合，已在真机验证 `mismatched: 0 / 1327`：

| 输入 | 值 | 说明 |
| --- | --- | --- |
| `kernel_repo` | `wTNTw/Resukisu-LG_V60` | |
| `kernel_branch` | `lineage-23.2` | |
| `device` | `timelm` | |
| `ksu` | `true` | ReSukiSU + SUSFS |
| `kpm` | `KPM` | |
| `re_kernel` | `true` | |
| `netfilter` | `true` | |
| `ccm` | `true` | BBRv1 + FQ / FQ_CODEL |
| `ipv6_nat` | `true` | IPv6 NAT / REDIRECT / NPT |
| `suffix` | 自定 | |

> **2026-09-10：`droid_spaces` 主开关与全部六个 `ds_*` 细分开关已从构建中整体移除。** 原因不是它们不安全，而是它们提供不了容器真正需要的东西：容器缺的关键项是 IPC namespace，而在这棵内核树上拿 `IPC_NS` 必须打开 `SYSVIPC` 或 `POSIX_MQUEUE`（见 §四），两者都会破坏 stock 模块 ABI 并被 guard 拒绝；剩下那部分配置（`PID_NS` / `USER_NS` / `DEVTMPFS` / `XT_MATCH_RECENT`）单独存在不构成完整特性。
>
> 这样处理的实际后果：此后构建出的内核**不再额外获得** `PID_NS`、`USER_NS`、`DEVTMPFS`、`NETFILTER_XT_MATCH_RECENT`（stock 自带的 `NAMESPACES` / `UTS_NS` / `NET_NS` 仍在）。需要时按 §五 的 `scripts/config` 行手动加回——那四项是 ABI 中性的，加回后 guard 依然会通过；要 `SYSVIPC` / `POSIX_MQUEUE` 则必须先做根治（`docs/LG_V60_ROOT_FIX_ANALYSIS.md`）。
>
> 开关逻辑的完整版本可用 `git show 163025f:build.sh` 取回（那次提交把主开关收窄为四个 ABI 中性项，其后一次提交整体移除）。

## 三、ABI 实验矩阵

| # | 配置（除基线外） | `mismatched` | 结果 |
| --- | --- | --- | --- |
| 1 | 特性全关 | `0 / 517`（当时口径） | 通过 |
| 2 | `droid_spaces=true` + `ipv6_nat`（**旧语义：主开关全开，含 `SYSVIPC`**） | `253 / 517` → 守卫上线后同配置 `710 / 1327` | 拒绝 |
| 3 | 上表推荐组合 | **`0 / 1327`** | **通过，已刷机验证** |
| 4 | #3 再加上 `ds_sysvipc=true` | **`710 / 1327`** | 拒绝 |
| 5 | #3 再加上 `ds_posix_mqueue=true`（不含 `SYSVIPC`） | **`577 / 1327`** | 拒绝 |

> #2 / #4 / #5 使用的 `ds_*` 开关已按 §二 说明移除；复现这三行需先按 §五 手动写回对应 `scripts/config` 行（`SYSVIPC` / `POSIX_MQUEUE` 本身仍需小心：它们会破坏 ABI，而这正是这三行要记录的事）。

### 集合关系

- `|diff(SYSVIPC)| = 710`
- `|diff(POSIX_MQUEUE)| = 577`
- `|diff(SYSVIPC) ∪ diff(POSIX_MQUEUE)| = 710`（因为 #2 全开也是 710）

→ **`diff(POSIX_MQUEUE) ⊂ diff(SYSVIPC)`**。同一符号在两个配置下的 CRC 值并不相同，例如 `__alloc_skb` 分别是 `0x376daf55` 与 `0xe4b7b2af`（stock 为 `0x2bb0910a`），说明两者各自产生了不同的类型布局状态，但扰动的是同一批符号。

### 差异符号举例

```text
PDE_DATA                  ours=0xa5965bc2 stock=0xe686865f
__alloc_skb               ours=0x376daf55 stock=0x2bb0910a
__init_rwsem              ours=0x32dd9a5f stock=0x6494af09
__napi_schedule           ours=0xd918a3f2 stock=0x5b1a7bdf
__netlink_kernel_create   ours=0x6990bf9e stock=0x6bf35942
__platform_driver_register ours=0x29e84bfb stock=0xb1f1899e
__pm_runtime_resume       ours=0x277c5c8d stock=0x943943f0
__put_task_struct         ours=0xe4ac453e stock=0xe90c1f43
__video_register_device   ours=0x3670f8a4 stock=0xdd2131c1
_dev_err                  ours=0x60b5cfb4 stock=0x6f2cb24b
... and 552 more
```

`__put_task_struct` 直接出现在差异里，说明 `struct task_struct` 本身就在被改动的类型集合中。

### 触发链条

```text
SYSVIPC 或 POSIX_MQUEUE 任一打开
        ↓   init/Kconfig: IPC_NS depends on (SYSVIPC || POSIX_MQUEUE)，且 default y
IPC_NS 自动变为 y
        ↓
struct nsproxy 增加 struct ipc_namespace *ipc_ns
struct task_struct 增加 sysv_sem / sysv_shm（仅 SYSVIPC）
        ↓
genksyms 递归展开 → 数百个引用到这些类型的导出符号 CRC 变化
        ↓
stock /vendor 模块拒绝加载（disagrees about version of symbol ...）
```

这是**推断**，依据三条：`IPC_NS` 的依赖式本身；两个差异集是子集关系（符合"共享同一段 IPC_NS 效果 + `SYSVIPC` 额外贡献约 133 个"的结构）；`__put_task_struct` 出现在差异列表中。

## 四、IPC namespace 为什么拿不到

`IPC_NS` 只依赖 `(SYSVIPC || POSIX_MQUEUE)`，没有第三条路：`ipc/` 下的 `util.o`、`msgutil.o` 只在 `SYSVIPC` 或 `POSIX_MQUEUE` 打开时构建，而 `init_ipc_ns` 定义在 `msgutil.c`，所以单独打开 `IPC_NS` 本身也不成立。

而两条依赖路线都会破坏 ABI（710 / 577）。这也不是"放宽校验"能解决的：改动的是 `task_struct` 这类字段偏移会整体位移的结构，绕过 CRC 校验等于把 vendor 模块绑到语义已变的类型上。

**结论：在必须继续加载 stock `/vendor` 模块的前提下，IPC namespace 不可得。** 容器需要以 `--ipc=host` 语义运行。

要彻底解决只有一条路：让设备加载与内核同源编译的模块（bind-mount 覆盖 `/vendor/lib/modules`，或改写 `modules.dep` 指向别处），此后 ABI 约束消失，全部特性可开。直接以 rw 挂载 `/vendor` 写入会动到 `dm-verity`，风险最高。

## 五、各细分开关的实际效果（历史记录）

这些开关已从构建中移除，本节保留用于说明每个配置项实际写入了什么、会造成什么后果——将来需要时按此表手动加回。

| 开关 | `scripts/config` 写入 | 实际落地 |
| --- | --- | --- |
| `droid_spaces`（主开关） | 不直接写 config | 只把 `ds_pid_ipc_ns`/`ds_user_ns`/`ds_devtmpfs`/`ds_xt` 置为 true；**不再包含** `ds_sysvipc`/`ds_posix_mqueue`，因此不会破坏 ABI |
| `ds_pid_ipc_ns` | `NAMESPACES` `PID_NS` `IPC_NS` | `IPC_NS` 在 `SYSVIPC`/`POSIX_MQUEUE` 都关时不产生 `.config` 条目，`-e IPC_NS` 是空操作；实际得到 mount / PID / net / UTS 命名空间 |
| `ds_sysvipc` | `SYSVIPC` `SYSVIPC_SYSCTL` `SYSVIPC_COMPAT` | 破坏 ABI（710） |
| `ds_posix_mqueue` | `POSIX_MQUEUE` `POSIX_MQUEUE_SYSCTL` | 破坏 ABI（577） |
| `ds_user_ns` | `USER_NS` | 生效，ABI 中性 |
| `ds_devtmpfs` | `DEVTMPFS` `DEVTMPFS_MOUNT` | 生效，ABI 中性 |
| `ds_xt` | `NETFILTER_XT_TARGET_REJECT` `NETFILTER_XT_TARGET_LOG` `NETFILTER_XT_MATCH_RECENT` | **该内核树 `net/netfilter/Kconfig` 中没有 `NETFILTER_XT_TARGET_REJECT` 条目**，`-e` 为空操作；`NETFILTER_XT_TARGET_LOG` stock 本就是 `y`；因此实际只落地 `NETFILTER_XT_MATCH_RECENT` |

## 六、刷机后验证清单

设备侧原始验证记录（2026-09-10，run `34449535618` 产物）：

```bash
adb devices                                     # 期望 LMV600 设备在线
adb shell getprop sys.boot_completed            # 期望 1
adb shell su -c 'wc -l /proc/modules'           # 期望 34
adb shell su -c 'dmesg | grep -ic "disagrees about version"'   # 期望 0
adb shell su -c 'dmesg | grep -ic "Unknown symbol"'            # 期望 0
adb shell su -c 'dmesg | grep -ic "version magic"'             # 期望 0
adb shell 'cmd wifi status | head -3'           # 期望 connected
adb shell su -c 'cat /proc/net/ip6_tables_names'               # 期望含 nat
adb shell su -c 'zcat /proc/config.gz | grep -E "IP6_NF_NAT|USER_NS|DEVTMPFS|XT_MATCH_RECENT"'
```

命名空间功能实测：

```bash
adb shell su -c 'unshare -m -f true'   # mount ns  OK
adb shell su -c 'unshare -p -f true'   # PID ns    OK
adb shell su -c 'unshare -n -f true'   # net ns    OK
adb shell su -c 'unshare -u -f true'   # UTS ns    OK
adb shell su -c 'unshare -U -r -f true'# userns    OK
adb shell su -c 'unshare -i -f true'   # IPC ns    FAIL（Invalid argument）—— 见第四节
adb shell su -c 'ls /proc/self/ns/'    # 含 ipc 表示 IPC ns 可用；当前不含
```

2026-09-10 实测结果：`sys.boot_completed=1`、`/proc/modules` 34、四类 CRC/符号报错计数均为 0、WiFi 已连（11ax / 5240MHz / 1200Mbps）、IPv6 表 `nat/raw/mangle/filter` 齐全、管理器 `com.resukisu.resukisu`、`su -v` = `4.2.0-rc1-66-g23a40c0f:KernelSU`、SELinux `Enforcing`、zygote 与 KSU 崩溃计数 0。

未加载的模块只有 `cxd22xx`（电视调谐器）与 `gspca_main`（USB 摄像头）——stock 原本也不加载，与本内核无关。

## 七、复现实验

```bash
# 触发一次构建（需要 GitHub token，脚本从 .cred 读取，不打印）
# 注意：workflow 已不再有 droid_spaces / ds_* 输入，要复现 §三 的对照实验，
# 须先按 §五 把对应 scripts/config 行写回 build.sh，再触发构建。
python dispatch2.py suffix=-S3

# 拉取构建日志并提取 guard 判定行与差异符号
python fetchlog.py <run_id> <job_id>
```

## 八、相关提交

| 提交 | 内容 |
| --- | --- |
| `cb2b3b2` | 全量 stock ABI 对照 + `droid_spaces` 细分开关 |
| `2b264ef` | `module_layout` CRC 不一致即终止构建 |
| `d159804` | 对照为空（一个符号都没比上）时也拒绝，避免"空比较即通过" |
| `163025f` | `droid_spaces` 主开关收窄为只展开四个 ABI 中性子开关 |
| 本文件所在提交 | 整体移除 `droid_spaces` 与全部 `ds_*` 构建开关（§二） |
| `711b805` | 基线：全部特性关闭 |
| `68996fa` | `droid_spaces` + `ipv6_nat` 可选开关（全开，已被证实破坏 ABI） |
