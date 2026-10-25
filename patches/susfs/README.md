# SUSFS 内核侧补丁（LG V60）

把 SUSFS 从"内核仓库自带"里抽出来，做成构建时应用的独立补丁，这样升级 SUSFS
不需要改 `wTNTw/Resukisu-LG_V60`，只在本目录加补丁即可。

## 它怎么生效

1. `Build Kernel LG V60` 工作流在构建前跑 `Download SUSFS Patches`：
   从当前分支的 `patches/susfs/INDEX` 读取清单，把补丁下到 `susfs_patches/`。
2. `build.sh` 在 KSU 集成完成之后、NoMount 之前，按文件名顺序对内核树
   `git apply`；已应用的自动跳过，基线不匹配则直接中止构建。

## 基线

- 内核：`wTNTw/Resukisu-LG_V60` @ `lineage-23.2`（SUSFS 报 `v2.2.0`）
- 上游参照：`simonpunk/susfs4ksu` 分支 `gki-android12-5.10` @ `fb16b41`（v2.3.0）

该树其实已经是 2.3.0 级实现（`fs/susfs.c`、`susfs_def.h`、`fs/proc_namespace.c`、
`fs/proc/task_mmu.c`、`fs/namei.c` 都已同步），只差下面三项，所以补丁很小。

## 补丁

| 文件 | 内容 | 依赖 |
|---|---|---|
| `0001-susfs-v2.3.0-version.patch` | `include/linux/susfs.h` 的 `SUSFS_VERSION` → `v2.3.0` | 无 |
| `0002-susfs-v2.3.0-zygote-next-mnt-hook.patch` | `fs/namespace.c` 的 `__lookup_mnt()` 增加 zygote_next 绕过钩子 | `CONFIG_KSU_SUSFS_SUS_MOUNT`，`susfs_def.h` 里已有 `TIF_PROC_UMOUNTED_FOR_ZYGOTE_NEXT`/`DEFAULT_KSU_MNT_ID` |
| `0003-susfs-v2.3.0-no-su-fastpath.patch` | `fs/exec.c`、`fs/stat.c`、`fs/open.c` 快路径 `susfs_is_current_proc_umounted()` → `susfs_is_current_proc_no_su()` | KSU 必须置位 `TIF_PROC_NO_SU` |

## 0003 为什么要按 KSU 分支决定

`build.sh` 会 grep `KernelSU/` 里有没有 `susfs_set_current_proc_no_su`：

- BakaSU `main`：只有 `susfs_set_current_proc_umounted()` → **跳过 0003**。
  否则 `no_su` 永不为真，stat/faccessat 的 SUSFS 重定向会被整体绕过。
- BakaSU `sync-susfs`（已同步 2.3.0 KSU 侧）：`no_su` 与 `zygote_next` 都有 →
  应用 0003，快路径与上游一致。

所以想吃满 2.3.0（含 zygote_next 隐藏），构建时把 `KSU_META` 的内置分支指向
`sync-susfs`，例如 `main/sync-susfs//`；用 `main/main//` 也能构建，只是
0003 会被跳过、`no_su` 快路径保持旧的 `umounted` 语义。

## 加新补丁

1. 在干净的内核树上改，`git diff -- 路径 > patches/susfs/0004-xxx.patch`；
2. 文件名加入 `INDEX`（顺序即应用顺序）；
3. 更新本 README 的表格与基线说明。
