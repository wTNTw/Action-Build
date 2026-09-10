# LG V60（timelm）模块 ABI 约束的根治方案

本文与 [`docs/LG_V60_FEATURES_AND_ABI.md`](LG_V60_FEATURES_AND_ABI.md) 配套：那份文档记录**哪些开关可以安全打开**（ABI 中性），本文回答**如果要彻底摆脱 ABI 约束该怎么做**——即让运行内核与它加载的模块同源，从根本上消除 CRC 失配。

- 目标设备：LG V60 ThinQ 5G（`timelm`），Android 16
- 内核源：`wTNTw/Resukisu-LG_V60`，`lineage-23.2`
- 现网内核：`4.19.325-cip133-st17-perf-g29902cf733dc`（对应 ABI 中性构建，守卫判定 `mismatched: 0 / 1327`）
- 勘察与预检时间：2026-09-10

**当前定位**：设备所有者已确认 droid_spaces 容器可以接受 host IPC（不创建独立 IPC namespace），因此**方案 0（保持已验证 ABI 中性的配置）目前已经足够，不需要立即执行任何刷写**。本文的价值在于：一旦确实需要 IPC namespace / SysV IPC，可以直接按 §六的路线实施，无需重新勘察。

本文所有结论均来自**只读勘察**（未 insmod、未写分区、未改 SELinux 状态），关键结论附有可复核的命令与输出。

---

## 一、问题定义

- 目标：内核配置自由（`IPC_NS` / `SYSVIPC` / `POSIX_MQUEUE` 等），用于 droid_spaces 一类需要 IPC namespace 的容器。
- 约束：不破坏 ROM 的 `/vendor` 模块功能（WiFi、音频 30 个、`rmnet_*`、`wmc_drv` 等共 34 个已加载模块）。
- 已证结论：`IPC_NS` 依赖 `(SYSVIPC || POSIX_MQUEUE)`，两者任一打开都会改变 `task_struct` / `nsproxy` 布局 → 数百个导出符号 CRC 变化 → stock 模块拒绝加载。
  - 实测：`ds_sysvipc=true` → `mismatched 710 / 1327`；`ds_posix_mqueue=true` → `577 / 1327`；两者都是 `BUILD REJECTED`。
  - 关键证据：`POSIX_MQUEUE` 差异清单直接包含 `__put_task_struct`（ours `0xe4ac453e` vs stock `0xe90c1f43`）→ 变化来自结构体字段位移，不是校验噪声。
- 因此「根治」= 让设备**加载自编模块**（与内核同源、同配置构建），从根本上消掉 CRC 失配；而不是放宽校验。

---

## 二、结论摘要

1. **ABI 约束确实由设备强制**，且已用字节级证据钉死：现网 34 个已加载模块 100% 来自 ROM 的 `/vendor/lib/modules/*.ko`；自编 36 个 `.ko` 躺在 boot ramdisk 的 `/lib/modules/` 里，**一个都没被加载**。
2. 原因不是权限、不是 verity，而是 **AOSP 首阶段 init 的加载清单机制**：首阶段只加载 `/lib/modules/modules.load` 中列出的模块，AOSP 没有「全部加载」的回退。自编 ramdisk 缺这个清单，ROM 的 rc 也从不引用 ramdisk，于是加载数为 0。
3. ROM 的模块加载路径**只有 `/vendor`**（`/vendor/etc/init/*.rc` 里写死的 `modprobe -a -d /vendor/lib/modules <名字列表>`），`/vendor` 是 **EROFS 只读**，运行期 `/lib` 不存在（switch_root 后 ramdisk 被丢弃）。
4. 因此「让设备加载自编模块」的**唯一早期注入点 = boot ramdisk 的 `/lib/modules/` + 新增 `modules.load`**（方案 A）；`/vendor` 改写（方案 D）语义最干净但在本机有硬约束（逻辑分区、无 `fastbootd`、AVB 状态未知）；KSU magic mount（方案 C）时序只够覆盖 `on boot` 及之后的动态重载，救不了 `early-init` 的音频模块。
5. **推荐：A + C 组合（先 A、后 C），D 作为可选收尾**；两者都不写只读分区，回滚只需重刷 boot / 停用一个 KSU 模块。
6. **方案 A 最大的未知量（首阶段 `/vendor` 未挂载 → 驱动可能取不到固件）已在零设备改动的前提下预检完毕**，结论见 §四：音频模块不受影响（它们的 DSP 固件本来就是在用户空间触发、且位于 second-stage 才挂载的 modem 分区）；只有 WiFi 板级数据确实放在 vendor 镜像里，因此建议把 `qca_cld3_qca6390` 交给方案 C 而不是 A。
7. 只要内核与模块同源，ABI 约束就整体消失；代价是 **CI 的 ABI 守卫必须重新定义**（当前是「与 stock 全量符号并集比对」，在根治方案下会永远拒绝；应改为「ROM 会加载的每个模块，要么由我们的 ramdisk 提供，要么其导入符号与我们的内核 CRC 全兼容」，见 §六 Phase 4）。

---

## 三、事实基础

### 3.1 ROM 如何加载模块

全部来自 `/vendor/etc/init/*.rc` 的显式命令：

```text
init.target.rc   on early-init:
  exec u:r:vendor_modprobe:s0 -- /vendor/bin/modprobe -a -d /vendor/lib/modules \
      audio_q6_pdr audio_q6_notifier audio_snd_event audio_apr audio_adsp_loader audio_q6 \
      audio_native audio_usf audio_pinctrl_wcd audio_pinctrl_lpi audio_swr audio_platform \
      audio_hdmi audio_stub audio_wcd_core audio_wsa881x audio_bolero_cdc audio_wsa_macro \
      audio_va_macro audio_rx_macro audio_tx_macro audio_wcd938x audio_wcd938x_slave audio_machine_kona
init.target.rc   on boot:
  exec_background u:r:vendor_modprobe:s0 -- /vendor/bin/modprobe -a -d /vendor/lib/modules/ qca_cld3_qca6390 qca_cld3_qca6490
init.lge.rc      on early-init:
  exec ... modprobe -a -d /vendor/lib/modules audio_tfa9878
init.lge.rc      on property:vendor.lge.nfc_vendor=sony:
  modprobe -a -d /vendor/lib/modules cxd22xx          # 本机 NFC=nxp → 不触发
init.lge.vendor.rc  on init:
  insmod vendor/lib/modules/wmc_drv.ko
init.axion.modules.rc on early-init:
  exec_background ... modprobe -a -d /vendor/lib/modules ax_thread_snooper ax_affinity_guard ...  # ROM 自带模块，本内核树不存在 → 静默失败
netmgrd.rc       on boot:
  rmnet_ctl / rmnet_core（/vendor 无这两个文件 → 失败）
  property 触发：rmnet_perf（perf_ko_load）、rmnet_shs（shs_ko_load）、rmnet_offload（offload_ko_load），
                 带参数加载，并支持 modprobe -r 卸载后重载
init.qcom.rc     on property:vendor.wifi.ftmd.load=true:
  insmod /system/lib/modules/pronto/pronto_wlan.ko con_mode=5    # FTM 工厂模式，不触发
```

- `/vendor/lib/modules/` 内容：36 个 `.ko` + `modules.alias`(4086B) + `modules.dep`(5729B，**绝对路径形式**) + `modules.softdep`(仅注释)。**没有 `modules.load`**（全盘 `find /vendor /odm /system /product -maxdepth 5 -name 'modules.load*'` 为空）。
- 现网 34 个已加载模块 = 上述 rc 名单 + `modules.dep` 依赖自动带入（`es9218_dlkm`、`mbhc_dlkm`、`wcd9xxx_dlkm`、`wsa883x_dlkm`、`swr_ctrl_dlkm` 等）。未加载的只有 `cxd22xx`（NFC 分支不触发）与 `gspca_main`（无任何 rc 引用，stock 也不加载）。
- rmnet 的 `persist.vendor.data.{shs,perf,offload}_ko_load` 现值 `1 / 3 / 0` → `rmnet_shs`、`rmnet_perf` 已加载（带参数），`rmnet_offload` 处于卸载态。

### 3.2 为什么自编模块从未被加载（决定性）

以 AOSP `system/core/first_stage_init.cpp`（`aosp-mirror/platform_system_core` @ `android-14.0.0_r1`，模块加载库位于仓库根下的 `libmodprobe/`）为准：

- `GetModuleLoadList()` 返回固定文件名 **`modules.load`**；`#define MODULE_BASE_DIR "/lib/modules"`。
- `LoadKernelModules` 先扫 `/lib/modules/<major.minor>*` 子目录，否则用 `/lib/modules` 本身，然后 `m.LoadListedModules(!want_console)`；`/lib/modules` 不存在时只打一行日志并 **return true**（不报错）。
- **调用点（`first_stage_init.cpp:331`）早于 `DoFirstStageMount()`（`:403`）** → 首阶段加载模块时 `/vendor` 尚未挂载。
- 严格模式：正常开机 `want_console == DISABLED` → strict=true → 清单里任一模块 insmod 失败即 `LOG(FATAL)` → **首阶段中止，无法开机**。
- `libmodprobe.cpp`：`LoadListedModules` 只遍历由 `modules.load` 填充的列表，**缺清单 → 加载 0 个，无任何回退**；`modules.dep` 里的相对路径会自动加 `base_path + "/"` 前缀（绝对路径原样使用）；`modules.load` 中的名字必须存在于 `modules.dep`，否则失败。
- `libmodprobe_ext.cpp`：`modules.options` 与内核 cmdline 的 `<module>.<option>=<value>` 都会在 insmod 时与参数拼接后交给 `finit_module`；**`errno == EEXIST` 视为成功**（已加载，不计入计数）。

### 3.3 字节级实证

- 现网 boot（当前刷入版本）ramdisk 内 `/lib/modules` 存在：**37 个 `.ko`** + `modules.dep`(2639B，相对路径形式) + `modules.alias`(3981B) + `modules.softdep`(55B)，**没有 `modules.load`**。
- stock ROM 的 boot ramdisk（`rom_boot.img`）**根本没有 `lib/modules`** → ROM 从来没用过 ramdisk 模块加载。
- 运行期 `/lib` 不存在（switch_root 后 ramdisk 被丢弃）。
- `/sys/module/q6_dlkm/notes/.note.gnu.build-id` = `04 00 00 00 14 00 00 00 … 35 7e be 73 2c 35 ce 50 b1 aa ec c9 4f 82 70 48 16 f1 20 fa`（20 字节 build-id），**逐字节等于 ROM 的 `/vendor/lib/modules/audio_q6.ko`**；自编 `audio_q6.ko` 是 8 字节（`… 5e 5c 3e 7b 38 92 d9 31`）。`wmc_drv` 同样命中 ROM 版本。
- 结论：加载的是 ROM 的 `/vendor/*.ko`，自编模块从未生效——ABI 守卫拦的正是这条真实生效路径。

### 3.4 ABI 守卫的语义边界

`build.sh` 的 abicheck（约 596–770 行）：

- 基线 `ci/stock-symbol-crcs.txt`（1327 条）= **ROM 各 stock 模块 `__versions` 段的并集**（符号名 + stock CRC）。
- 「我们的值」= 自编 `.ko` 的 `__versions` 并集 ∪ `out/Module.symvers`。
- 逐符号比对，**任一不同即 `BUILD REJECTED`**，只打印前 25 条差异。

要点：这是**并集级（保守）判定**，不是「逐模块」判定。真实生效的规则是内核逐个模块校验它**自己导入**的符号 CRC：

- 若某模块导入的符号恰好全部未变，即便全局有 710 条差异，该模块仍能加载。
- 但实测差异占并集的 710/1327 ≈ **53%**，而自编模块的导入符号数中位数在 60–90（`qca_cld3_qca6390` 455、`audio_platform` 385、`rmnet_shs` 112 … 最小 `audio_stub` 5、`tcp_bic` 8）。按 53% 独立失配率估算，导入数 ≥5 的模块「一条都不中」的概率已低于 5% → **实际会受影响的就是（几乎）全部 34 个已加载模块**，这正是「掉驱动」现象的来源。
- 若要换成精确判定（方案 G）：让守卫打印**完整**差异清单，再与 ROM 各模块的 `__versions` 求交。

### 3.5 存储、分区与权限约束

| 事实 | 证据 |
| --- | --- |
| `/vendor` 是 EROFS **只读** | `mount` 输出 `dm-4 /vendor erofs ro,…`；`touch /vendor/lib/modules/.wtest` → `Read-only file system` |
| `/vendor` 无 verity 设备叠加 | 挂载源就是 `/dev/block/dm-4`；`/dev/block/mapper/` 只有 `system_b/system_ext_b/product_b/odm_b/vendor_b/userdata` + APEX，无任何 `*-verity` 条目 |
| fstab 对 vendor/system/product/odm 均带 `avb` 标志 | `/vendor/etc/fstab.timelm`：`vendor /vendor erofs ro wait,slotselect,avb,logical,first_stage_mount` |
| 真实 bootloader 状态 = 解锁 | `/proc/cmdline` 有 `androidboot.verifiedbootstate=orange`；而 ROM 伪造了 `ro.boot.flash.locked=1`、`ro.boot.verifiedbootstate=green`、`ro.boot.veritymode=enforcing`、`ro.boot.vbmeta.device_state=locked`（cmdline 中并无对应 key）→ **AVB/verity 是否真的强制校验仍未知** |
| 无法直读 vbmeta | `dd if=/dev/block/sde42`（vbmeta_b）→ `Permission denied`；设备上无 vbmeta 转储；`/proc/bootconfig` 不存在 |
| **无 `fastbootd`** | `/system/bin/fastbootd`、`/vendor/bin/fastbootd` 均不存在 → bootloader 的 fastboot 只能刷**物理**分区，不能直接刷 `super` 内的逻辑分区 |
| 我们的 root 受 SELinux 限制 | `su` 上下文 = `u:r:ksu:s0`；可列目录（`ls -a /vendor/lib/modules` 成功）但**读不了 `/vendor` 内的文件**（`cp`/`cat` → `Permission denied`），也读不了 `vbmeta`/`vendor_b` 块设备；`boot_b`(sde36) 可读 |
| 回滚资产齐备 | `/data/local/tmp/`：`boot_b_backup.img`、`orig_boot_backup.img`、`rom_boot.img`、`rom_vendor.img`(398,938,112B, sha256 `1e0911ff…`)、`rom_dtbo.img`；`/data/media/0/flasher/{boot_b.img,dtbo_b.img}` |
| boot 分区容量 | 100,663,296 B（96 MiB）；现网 boot 镜像 kernel 50,418,567B + ramdisk 23,373,568B ≈ 73 MB → 余量约 23 MB |

**一处重要修正**：不能由「没有 verity dm 设备」推出「没有启用 verity」。Android 的 AVB 校验是 `avb_slot_verify()` 直读分区校验哈希树，**不创建 dm-verity 设备**（dm-verity 是旧的 `verity` 机制）。verity 是否生效仍未确定，只能靠一次可回滚的刷写实验判定（§七）。

---

## 四、固件时序预检（零设备改动，已完成）

方案 A 会把模块加载提前到**首阶段**（`/vendor` 尚未挂载），所以必须确认：这些驱动在 probe 期是否需要落在 `/vendor` 镜像内的固件。预检完全在本地进行，未改动设备状态。

### 4.1 方法

1. 从设备取出既有的 vendor 转储：`adb pull /data/local/tmp/rom_vendor.img`（398,938,112 B，sha256 `1e0911ffb182c87b9a5b53a576c852bdc61b8cae069dba01105772c13e09176e`）。
2. 本地解包 EROFS：`fsck.erofs --extract=… rom_vendor.img`（Linux / WSL，erofs-utils）。
3. 校验转储真实性：解出的 `lib/modules/audio_q6.ko` sha256 `5f770d016717327ae02c2e8a24ad40f369b80870db9ade184ff62cdf92abf853`，与从**现网设备**直接取出的同名文件完全一致 → 该转储可同时作为方案 D 的基线与回滚资产。
4. 清点镜像内固件、核对内核固件搜索路径、确认固件加载的实际触发点。

### 4.2 vendor 镜像内的固件清单（全量）

`/vendor/firmware` 共 13 个文件 + 1 个目录，总计 4.3 MB：

| 文件 | 大小 | 所属驱动 | 与本次改动的关系 |
| --- | --- | --- | --- |
| `tfa98xx.cnt` / `tfa98xx_reva.cnt` | 28,563 / 27,010 | `audio_tfa9878`（扬声器功放） | **在 vendor 镜像内**（首阶段不可见） |
| `wlan/qca_cld/{bdwlan.elf,bdwlan_ch0.elf,bdwlan_ch1.elf,WCNSS_qcom_cfg.ini,wlan_mac.bin}` | 各 57,836（符号链接） | `qca_cld3_qca6390` | **在 vendor 镜像内**（真实文件在 `/vendor/etc/wifi/GLOBAL/`，`wlan_mac.bin` 在 `/mnt/vendor/persist-lg/`） |
| `CAMERA_ICP.elf`、`a650_gmu.bin`、`a650_sqe.fw`、`a650_zap.*` | 3.87 MB 等 | 相机 / GPU | 无关 |
| `cxd225x_firmware.bin` | 196,624 | `cxd22xx`（NFC，本机不加载） | 无关 |
| `htbtfw20.tlv`、`htnv20.bin` | 202,300 / 5,775 | 触摸控制器 | 无关 |

**镜像内没有 adsp / wcd 固件**：全镜像搜索 `adsp*`、`wcd*`、`*.mbn`、`*.mdt` 只命中 GPU 的 `a650_zap.mdt` 与 `/vendor/lib/rfsa/adsp`（DSP 侧用户库）。音频编解码器（`audio_wcd9xxx`、`audio_mbhc`、`audio_adsp_loader`、`audio_q6` 等）的固件不在这里。

### 4.3 内核固件搜索路径

本内核树 `drivers/base/firmware_loader/main.c`：

```c
static char fw_path_para[256];
static const char * const fw_path[] = {
	fw_path_para,
	"/lib/firmware/updates/" UTS_RELEASE,
	"/lib/firmware/updates",
	"/lib/firmware/" UTS_RELEASE,
	"/lib/firmware"
};
```

- 路径**不包含 `/vendor/firmware`**，且 `/proc/cmdline` 里**没有** `firmware_class.path=`。
- 运行期根目录下 `/lib` 不存在 → **内核根本找不到 `/vendor/firmware/*`**。因此 `tfa98xx`/`wcd9xxx`/`mbhc` 的内核侧 `request_firmware*` 调用在本机属于「不可达路径」，实际由 HAL / 用户空间负责（`.cnt` 由音频 HAL 读入并下发给功放）。
- 对方案 A 有用的推论：首阶段根就是 ramdisk，若某个驱动**确实**需要在首阶段取固件，把文件放进 ramdisk 的 `lib/firmware/` 就能被内核命中（`tfa98xx*.cnt` 合计 55 KB，`bdwlan*.elf` 合计 173 KB，代价可忽略）。这是一条低成本的兜底手段。

### 4.4 固件加载的真实触发点：用户空间

- `init.qcom.rc` 的 `on early-boot` 段有：
  ```text
  write /sys/kernel/boot_adsp/boot 1
  write /sys/kernel/boot_cdsp/boot 1
  write /sys/devices/virtual/npu/msm_npu/boot 1
  write /sys/devices/virtual/cvp/cvp/boot 1
  ```
- init 触发顺序为 `early-init` → … → `fs`（`mount_all` 挂载 fstab，含 `/vendor/firmware_mnt` = modem 分区）→ `post-fs-data` → `early-boot` → `boot`。**ADSP 固件位于 modem 分区，只有在 `mount_all` 之后才可见**。
- 也就是说：ROM 在 `early-init` 加载音频模块时，ADSP 固件同样不可用——音频 DSP 的固件加载本来就是**更晚的用户空间触发步骤**。
- 模块导入符号侧的旁证：20 个音频 `.ko` 中只有 `audio_adsp_loader`（`subsystem_get_with_fwname`）、`audio_mbhc`/`audio_wcd9xxx`（`request_firmware`）、`audio_tfa9878`（`request_firmware_nowait`）有固件相关导入，其余全部没有；而其中只有 `audio_tfa9878` 的固件确实存在于 vendor 镜像中。

### 4.5 结论：方案 A 的固件风险已被压缩到 WiFi 一处

| 模块组 | 固件来源 | 首阶段加载是否更差 | 处置 |
| --- | --- | --- | --- |
| 音频编解码器 24 个（含 `audio_adsp_loader`、`audio_q6`、`audio_apr`…） | ADSP 固件在 **modem 分区**，由用户空间在 `early-boot` 触发加载 | **不会**——现状下 `early-init` 同样取不到，加载时机差异不影响 | 交给方案 A |
| `audio_tfa9878`（扬声器功放） | `tfa98xx*.cnt` 在 **vendor 镜像内**，实际由 HAL 在播放时下发 | 模块 insmod 本身不受影响；若驱动真在 probe 期请求，可把 55 KB 固件放进 ramdisk `lib/firmware/` 兜底 | 交给方案 A，**刷机档 2 重点验证扬声器** |
| `qca_cld3_qca6390`（WiFi） | `bdwlan*.elf` 在 **vendor 镜像内**（`/vendor/etc/wifi/GLOBAL/`） | **可能更差**：板级数据首阶段不可见 | **交给方案 C**（`on boot` 阶段由 KSU 覆盖 `/vendor/lib/modules` 后由 ROM 自行加载），不承担这次不确定性 |
| `rmnet_perf` / `rmnet_shs` | 无固件 | 不会 | 交给方案 C（需要带参数、且支持动态重载） |
| `wmc_drv` | 无固件 | 不会 | A 或 C 均可 |

补充说明：即使某个驱动的 probe 期固件请求失败，`finit_module` 仍会成功（模块已加载、依赖已满足），因此**不会触发首阶段的 `LOG(FATAL)`、不会导致无法开机**——最坏情况只是该功能降级（例如喇叭无声），可用重刷 boot 立即恢复。方案 A 的「砖机风险」与「功能风险」是两件独立的事，档位验证就是为了区分它们。

---

## 五、方案矩阵

约定：**「早期」= `on early-init`（音频 24 个 + `tfa9878`）**，**「后期」= `on boot` 及 property 触发（`qca_cld3_qca6390`、`rmnet_*`、`wmc_drv`）**。

### 方案 0（零成本对照）：不动内核，容器侧回避 IPC ns

保持当前已验证 ABI 中性的配置，让 droid_spaces 使用 host IPC（例如 `--ipc=host`，不创建独立 IPC namespace）。

- 优点：零风险、零刷写。缺点：失去 IPC 隔离与 SysV IPC。
- 状态：**设备所有者已确认这是可接受的方案**，因此当前无需任何改动。只有在确实需要独立 IPC namespace 时，才进入 A/C/D。
- 落地方式：CI 的 `droid_spaces` 主开关已改为只展开上面这四个 ABI 中性开关（不再包含 `SYSVIPC`/`POSIX_MQUEUE`），所以「启用 droid_spaces」就是方案 0 —— 构建能正常出可刷入产物，容器侧配 `--ipc=host`。

### 方案 A（推荐主路径）：ramdisk 首阶段 `modules.load`

- 机制：在 boot ramdisk 的 `/lib/modules/` 增加 `modules.load`（列出要让内核在首阶段加载的模块；名字必须存在于同目录的 `modules.dep`），必要时加 `modules.options`（传参）。现有 ramdisk 已有正确的**相对路径** `modules.dep`(2639B)、`modules.alias`、`modules.softdep` 与 37 个自编 `.ko`——**只缺 `modules.load`**。
- 覆盖：早期模块（音频组、`tfa9878`）✓ 这是 A 的**独特价值**（C 无法覆盖 `early-init`）。
- 硬约束：
  1. strict 语义：清单里任一模块 insmod 失败 → `LOG(FATAL)` → 无法开机 ⇒ 清单必须精确（排除 `cxd22xx`、`gspca_main`、`qca_cld3_qca6490`、`rmnet_offload` 这类本机不加载或不需要加载的项）。
  2. 首阶段 `/vendor` 未挂载 → 依赖 vendor 镜像内固件的驱动可能取不到固件（§四已量化，只剩 WiFi）。
  3. 后期动态重载会回落到 `/vendor`：`rmnet_*` 由 persist 属性触发 `modprobe -r` + `modprobe`（带参数）。属性稳定时不会发生；一旦发生，ABI 已分叉的内核会拒绝加载 stock 副本 → 该功能丢失（用方案 C 覆盖）。
  4. 与 ROM 后续 `modprobe` 同一模块：AOSP `libmodprobe` 把 `EEXIST` 视为成功，无副作用。
- 风险等级：**低**（不写只读分区；最坏情况是刷回 boot）。
- 验证：刷机后读 `/sys/module/<mod>/notes/.note.gnu.build-id` 与自编 `.ko` 的 note 比对（关键在于自编是 8 字节 build-id、ROM 是 20 字节），再看 `/proc/modules` 计数。

### 方案 B（否决）：`ro.boot.init_rc` 注入

- 机制：用 cmdline/属性指定单一 init.rc 替代标准 rc 目录。
- 否决理由：`init.cpp` 中该属性非空时会**替代全部标准 rc 路径**（`/system/etc/init`、`/vendor/etc/init` …），等于自建整套 init.rc 树，成本远高于收益。

### 方案 C（推荐，与 A 互补）：KSU magic mount 覆盖 `/vendor/lib/modules/*.ko`

- 机制：KSU 模块在 `post-fs-data` 阶段把自编 `.ko` 覆盖到 `/vendor/lib/modules/` 对应路径；ROM 后续 `on boot` 的 `modprobe` 与属性触发的动态重载就会加载**我们的**模块。
- 时序优势：`post-fs-data` 早于 `boot` 触发 ⇒ 覆盖后期模块与动态重载都有救。
- 时序劣势：**晚于 `early-init`** ⇒ 救不了音频模块（这也是必须同时用 A 的原因）。
- 现成资产：AnyKernel3 产物里已经有 `modules/vendor/lib/modules/*` 这份载荷（36 个 `.ko` + `tcp_bic.ko` + `modules.*`），只是当前 `do.systemless=0` 使其未安装——可以直接改造成 KSU 模块。
- 风险：低（不写分区；停用 KSU 模块即回滚）。SELinux 上下文需与 `vendor_file` 一致（KSU magic mount 默认处理）。

### 方案 D（语义最干净，本机应用受限，可作收尾）：重写 `/vendor` 镜像

- 机制：用 `mkfs.erofs` 重建 vendor 镜像（替换 `lib/modules/*.ko`，重新生成 `modules.dep/alias`），写回 `vendor_b` 逻辑分区。此后 ROM 自己的 `modprobe` 加载的就是我们的模块，时序、参数、卸载/重载语义 100% 保留。
- 容量核算（已实测）：镜像内 `lib/modules` 18,823,558 B（18.0 MiB）；自编 37 个 `.ko` 为 19,372,504 B（18.5 MiB）→ 增量约 **0.5 MiB**，不构成约束。
- 本机硬约束：
  1. **写通道**：无 `fastbootd` ⇒ bootloader 的 fastboot 不能刷逻辑分区；从 Android 内 `dd` 到 `/dev/block/dm-4` 需要写权限（`ksu` 上下文连读都被拒，写权限未验证），且 `/vendor` 正在使用中。可行替代只有 recovery（TWRP）环境或改造整个 super（不现实）。
  2. **AVB/verity 状态未知**（fstab 带 `avb`，bootloader 实际解锁但 ROM 伪造 locked/green）→ 改内容可能校验失败不启动。需先判定，可用一次可回滚刷写实验，或先解决「从 ramdisk 覆盖 fstab 去掉 `avb`」。
  3. **镜像工具**：需在 Linux 环境跑 erofs-utils（WSL 可用；本次预检已用它成功解包）。
- 风险：中高（分区级操作，但回滚资产齐备）。建议**等 A+C 验证后**再决定是否需要。

### 方案 E（不建议）：把驱动编进内核（`=y`）

- 否决理由：(a) 这些驱动 probe 发生在内核初始化期，**比 A 更早**，固件依赖更硬；(b) 失去 `module_param`（`rmnet_perf` 的参数就是模块参数）与 rmmod 能力；(c) boot 镜像余量约 23 MB，全部模块约 50 MB 未压缩，吃不下；(d) 需要逐个驱动改树，维护成本高、覆盖不全。

### 方案 F（否决）：放宽/绕过 ABI 校验

- 形式：`CONFIG_MODVERSIONS=n`、强制加载、批量改写 stock `.ko` 的 `__versions`、放宽守卫阈值。
- 否决理由：CRC 变化是 `task_struct` / `nsproxy` **字段真位移**的表现（差异清单包含 `__put_task_struct`），不是无意义的校验噪声。绕过校验等于让 stock 模块按错位偏移访问内核结构，属于静默内存破坏。

### 方案 G（补充手段）：逐模块精确判定

- 机制：让守卫打印完整差异清单 + 取 ROM 各模块 `__versions` 求交，得到「真正会挂的模块」精确清单。
- 价值：区分「全量替换」与「只替换 N 个」；也是 Phase 4 新守卫的基础。

---

## 六、实施路线

### Phase 1 — 预检（零设备改动）——**已完成**

1. 取出 `rom_vendor.img` 并校验真实性（sha256 `1e0911ff…`，关键 `.ko` 与现网一致）。✅
2. 解包 EROFS，清点 `/vendor/firmware`、`/vendor/etc/wifi`，确认哪些模块的固件确实位于 vendor 镜像内。✅ 结论见 §四：只剩 WiFi（`bdwlan*.elf`）需要回避，音频组与 `tfa9878` 可控。
3. 核实内核固件搜索路径（不含 `/vendor/firmware`）与 ADSP 固件的用户空间触发点（`on early-boot`）。✅
4. 记录 `/vendor/lib/modules` 清单与体积（为方案 D 估算：增量 0.5 MiB）。✅

### Phase 2 — 实现 A（先小步验证，ABI 保持中性）

5. 在 `build.sh` 的 ramdisk 打包逻辑里生成 `modules.load`，并按 §四结论编排清单：**音频 24 个 + `tfa9878`（+ 可选 `wmc_drv`）**；排除 `qca_cld3_qca6390`（留给 C）、`qca_cld3_qca6490`、`cxd22xx`、`gspca_main`、`rmnet_offload`。保留现有相对路径 `modules.dep`；`rmnet_perf` 如需 A 覆盖则用 `modules.options` 传参。
6. **分三档刷机验证**（每档都保持当前 ABI 中性配置，行为等价，风险仅为重刷 boot）：
   - 档 1：只放 `tcp_bic`（无依赖、无固件）→ 验证首阶段机制本身（`/proc/modules` + build-id）。
   - 档 2：加入音频 24 个 + `tfa9878` → 验证固件时序（开机后测外放/通话/耳机，看 `logcat -b kernel -d`）。
   - 档 3：在 A 的清单基础上验证其余模块，或直接转入 C 覆盖 `qca_cld3_qca6390`/`wmc_drv`/`rmnet_*` → 验证 WiFi 与网络。
7. 若档 2 外放异常，把 `tfa98xx*.cnt` 放进 ramdisk 的 `lib/firmware/` 重测；若仍不行，把 `tfa9878` 也交给方案 D。

### Phase 3 — 实现 C（补后期与动态重载）

8. 把自编 `modules/vendor/lib/modules/*.ko` 做成 KSU 模块，在 `post-fs-data` 覆盖 `/vendor/lib/modules/`，覆盖 `on boot` 加载的 `qca_cld3_qca6390`、`wmc_drv` 与属性触发的 `rmnet_*`（含参数）。
9. 与 A 的重叠模块以 A 为准（首阶段先加载，后续 insmod = `EEXIST`）。

### Phase 4 — 放开配置 + 重定义守卫

10. 打开 `SYSVIPC`（或 `POSIX_MQUEUE`），验证 `unshare -i`、`/proc/self/ns/ipc`、droid_spaces 容器正常。
11. **替换 abicheck 策略**：从「与 stock 全量并集比对」改为「ROM 会加载的每个模块，要么由我们的 `modules.load`（=我们的构建）提供，要么其导入符号与我们内核的 CRC 全兼容」；不满足即拒绝构建。这样既保留「掉驱动」防护，又允许受控的 ABI 分叉。
12. 文档化：哪一档对应哪个 `modules.load` 清单、如何用 build-id 判定、如何回滚。

### Phase 5 — 可选收尾：D

13. 只有当（i）动态重载被证实会发生，或（ii）需要 `/vendor` 语义完全干净时才做；前置条件见 §五方案 D。

---

## 七、验证方法（权威判定）

| 目的 | 方法 |
| --- | --- |
| 判定「加载的是自编还是 ROM 模块」 | `ls -a /sys/module/<mod>/notes/` → `od -An -tx1 …/.note.gnu.build-id`：自编 = 8 字节 build-id，ROM = 20 字节，逐字节比对。**不要**用 `coresize` 单独判定（模型有 ≤1 页系统偏差，仅作旁证） |
| 判定模块是否加载 | `cat /proc/modules`（用模块内部名，不是文件名） |
| 内核侧错误 | `logcat -b kernel -d`（**不要用 `dmesg`**，本机为空） |
| 命名空间能力 | `unshare -U/-m/-p/-n/-u/-i` 逐个试；`ls /proc/self/ns/` |
| ABI 是否中性 | CI 守卫输出 `mismatched: N / 1327` |
| verity 是否强制（方案 D 前置） | 一次可回滚实验：只改 vendor 镜像里某个非关键文件 → 刷 → 能开机即未强制；不能开机则用 `rom_vendor.img` 刷回，并先解决 fstab `avb` / vbmeta |

---

## 八、回滚方案

| 改动 | 回滚 |
| --- | --- |
| ramdisk `modules.load`（方案 A） | 重刷 boot：`/data/local/tmp/boot_b_backup.img`（ROM + 旧内核）或 `rom_boot.img`（原 ROM），再刷回已验证的 ABI 中性内核包 |
| KSU 模块（方案 C） | 在 KSU 管理器里停用/删除该模块，重启即恢复 |
| 内核配置放开（Phase 4） | 重刷回 ABI 中性构建（`mismatched: 0 / 1327` 的那一版产物） |
| `/vendor` 改写（方案 D） | `rom_vendor.img`（398 MB，sha256 `1e0911ff…`）+ recovery/fastboot 写回 |
| SELinux / verity 实验 | 不改持久状态；如临时 `setenforce 0` 必须立刻恢复 |

---

## 九、未决问题

1. ~~droid_spaces 是否必须 IPC ns？~~ **已决策**：可以接受 host IPC → 方案 0 已经够用，本文暂不触发实施。
2. 若将来需要 IPC ns：是否接受 **A + C** 这条「不写只读分区」的路线（Phase 2/3 需要至少一次刷机做分档验证）？
3. 是否需要 **Phase 4 的守卫重定义**（并集保守判定 → 按模块判定）？它决定后续 ABI 分叉是否可控。
4. 方案 D 是否需要：取决于是否出现 `rmnet_*` 动态重载的真实需求，以及 `tfa9878` 在 Phase 2 档 2 的表现。

---

## 十、附录：复现实验的关键命令

```bash
# 设备侧（只读）
adb shell su -c 'ls -a /vendor/lib/modules'
adb shell su -c 'dd if=/dev/block/by-name/boot_b of=/data/local/tmp/cur_boot.img bs=1048576'
adb shell su -c 'cat /proc/cmdline'                      # androidboot.verifiedbootstate=orange
adb shell su -c 'ls -la /dev/block/mapper/ | grep -v com.android'
adb shell su -c 'cat /proc/self/attr/current'            # u:r:ksu:s0；读 /vendor 内文件被拒

# 取 vendor 转储并本地解包（Linux / WSL）
adb pull /data/local/tmp/rom_vendor.img
sha256sum rom_vendor.img                                  # 1e0911ff…
fsck.erofs --extract=./vex --no-preserve rom_vendor.img

# 判定模块来源（build-id 比对）
ls -a /sys/module/<mod>/notes/
od -An -tx1 /sys/module/<mod>/notes/.note.gnu.build-id
```

相关文档：[`docs/LG_V60_FEATURES_AND_ABI.md`](LG_V60_FEATURES_AND_ABI.md)（ABI 实验矩阵与可安全打开的开关）。
