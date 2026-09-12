#!/usr/bin/env python3
"""再生成 LG V60 的 stock ABI 基线（ci/stock-symbol-crcs.txt）与模块→符号映射（ci/stock-module-symbols.txt）。

为什么需要它
------------
build.sh 的 abicheck 段拿 ci/stock-symbol-crcs.txt 当参照物判断“自编内核与 stock
模块的 CRC 是否一致”。这个基线绑定的是**某一版 ROM 的 /vendor/lib/modules**；
一旦 ROM 升级（LG 推 OTA）或换成别的地区固件，基线就过期，守卫会开始误报：
本来合法的配置被拒绝，或反过来放行不该放的。届时用本脚本重新生成即可。

三个数据来源（任选其一）
------------------------
1) 设备（最方便，需要一个已 root 的 V60 连接着 adb）：
     python3 scripts/gen_stock_abi_baseline.py --from-device
     python3 scripts/gen_stock_abi_baseline.py --from-device --serial LMV600TMxxxx
2) 已有的一份 stock 模块目录（例如从镜像里解出来的）：
     python3 scripts/gen_stock_abi_baseline.py --modules-dir /root/vex/lib/modules
3) vendor 镜像（需要 erofs 工具；Windows 上建议在 WSL 里跑）：
     sudo apt-get install -y erofs-utils
     python3 scripts/gen_stock_abi_baseline.py --from-vendor-img rom_vendor.img

它做什么
--------
解析每个 stock .ko 的 __versions 节（MODVERSIONS 生成的符号 CRC 表），然后：

  ci/stock-symbol-crcs.txt        全部 stock 模块导入符号的并集：<symbol> 0x<crc32>
  ci/stock-module-symbols.txt     按模块索引：<module> <symbol>（供守卫给出“哪些模块会挂”）

CRC 取自 stock 模块自身，因此“0 差异”等价于“stock 模块全部能加载”。
两个文件都是 CRLF 行尾，与仓库现有文件一致；写回前会用 --diff 报告相对旧基线的变化。

其它选项
--------
  --out PATH            基线输出路径（默认 ci/stock-symbol-crcs.txt）
  --modules-out PATH    模块映射输出路径（默认 ci/stock-module-symbols.txt）
  --diff                只打印与现有基线的差异，不写文件
  --allow-conflicts     不同模块对同一符号给出不同 CRC 时仍然继续（默认报错）
  --keep-temp           保留 --from-device / --from-vendor-img 产生的临时目录

注意
----
* 设备侧读取 /vendor 需要 root；脚本用 `su -c` 先把模块拷到 /data/local/tmp 再 pull，
  因为 /vendor 是只读 EROFS 且 SELinux 限制直接 adb pull。
* Windows + MSYS/git-bash 下调用 adb 时请加 MSYS_NO_PATHCONV=1（否则设备绝对路径会被改写）；
  用原生 Windows Python 运行本脚本则无此问题。
"""

import argparse
import os
import shutil
import struct
import subprocess
import sys
import tempfile

NL = "\n"
CRLF = "\r\n"
DEVICE_MODULES = "/vendor/lib/modules"
DEVICE_TMP = "/data/local/tmp/abidump"


def versions_of(path):
    """读 ELF 的 __versions 节，返回 {symbol: crc32}。非 ELF 或没有该节时返回 {}。"""
    try:
        with open(path, "rb") as fh:
            d = fh.read()
    except OSError:
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
    if e_shstrndx >= len(secs):
        return {}
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


def run(cmd, **kw):
    print("  $ " + " ".join(cmd), flush=True)
    return subprocess.run(cmd, check=False, **kw)


def collect_from_device(serial, workdir, keep):
    """把设备上的 stock 模块拷到 workdir 并返回目录。"""
    adb = ["adb"] + (["-s", serial] if serial else [])
    print("== 从设备抓取 stock 模块 ==")
    r = run(adb + ["shell", "su", "-c",
                   "rm -rf %s && mkdir -p %s && cp %s/*.ko %s/" % (DEVICE_TMP, DEVICE_TMP, DEVICE_MODULES, DEVICE_TMP)],
            capture_output=True, text=True)
    if r.stdout.strip():
        print(r.stdout.strip())
    if r.stderr.strip():
        print(r.stderr.strip())
    dest = os.path.join(workdir, "device_modules")
    os.makedirs(dest, exist_ok=True)
    r = run(adb + ["pull", DEVICE_TMP, dest], capture_output=True, text=True)
    if r.returncode != 0:
        print(r.stdout.strip())
        print(r.stderr.strip())
        sys.exit("adb pull 失败；确认设备已 root 且 /vendor 可读")
    src = os.path.join(dest, os.path.basename(DEVICE_TMP))
    ver = run(adb + ["shell", "cat", "/proc/version"], capture_output=True, text=True)
    if ver.stdout.strip():
        print("  设备内核: " + ver.stdout.strip())
    if not keep:
        run(adb + ["shell", "su", "-c", "rm -rf %s" % DEVICE_TMP], capture_output=True, text=True)
    return src


def collect_from_image(img, workdir):
    """用 fsck.erofs 解开镜像，返回模块目录。"""
    print("== 从镜像解包 stock 模块 ==")
    tool = shutil.which("fsck.erofs")
    if not tool:
        sys.exit("找不到 fsck.erofs（Debian/Ubuntu: apt-get install -y erofs-utils；"
                 "Windows 建议在 WSL 里运行）")
    out = os.path.join(workdir, "image")
    r = run([tool, "--extract=" + out, "--no-preserve", os.path.abspath(img)],
            capture_output=True, text=True)
    if r.returncode != 0:
        print((r.stdout or "") + (r.stderr or ""))
        sys.exit("erofs 解包失败")
    mods = os.path.join(out, "lib", "modules")
    if not os.path.isdir(mods):
        sys.exit("镜像里没有 lib/modules：%s" % mods)
    return mods


def load_existing(path):
    base = {}
    if not path or not os.path.isfile(path):
        return base
    with open(path, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            parts = line.split()
            if len(parts) == 2 and parts[1].startswith("0x"):
                try:
                    base[parts[0]] = int(parts[1], 16)
                except ValueError:
                    pass
    return base


def write_baseline(path, symbols, source_note):
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    lines = [
        "# Stock LG V60 vendor module symbol CRCs (extracted from %s)" % source_note,
        "# Format: <symbol> 0x<crc32>",
        "# A built kernel whose symbols differ from any entry here will make the",
        "# corresponding stock module refuse to load (module_layout / disagrees about version).",
    ]
    for sym in sorted(symbols):
        lines.append("%s 0x%08x" % (sym, symbols[sym]))
    with open(path, "w", encoding="utf-8", newline="") as fh:
        fh.write(CRLF.join(lines) + CRLF)
    print("  写入 %s（%d 个符号）" % (path, len(symbols)))


def write_module_map(path, per_module):
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    total = 0
    lines = []
    for mod in sorted(per_module):
        for sym in sorted(per_module[mod]):
            lines.append("%s %s" % (mod, sym))
            total += 1
    with open(path, "w", encoding="utf-8", newline="") as fh:
        fh.write(CRLF.join(lines) + CRLF)
    print("  写入 %s（%d 个模块 / %d 条映射）" % (path, len(per_module), total))


def main():
    ap = argparse.ArgumentParser(description="再生成 LG V60 stock ABI 基线与模块→符号映射")
    src = ap.add_mutually_exclusive_group(required=True)
    src.add_argument("--from-device", action="store_true", help="从已 root 的 V60 抓取")
    src.add_argument("--modules-dir", help="已有的 stock 模块目录")
    src.add_argument("--from-vendor-img", metavar="IMG", help="vendor 镜像（erofs）")
    ap.add_argument("--serial", help="adb 设备序列号（多设备时指定）")
    ap.add_argument("--out", default="ci/stock-symbol-crcs.txt")
    ap.add_argument("--modules-out", default="ci/stock-module-symbols.txt")
    ap.add_argument("--diff", action="store_true", help="只报告与现有基线的差异，不写文件")
    ap.add_argument("--allow-conflicts", action="store_true")
    ap.add_argument("--keep-temp", action="store_true")
    args = ap.parse_args()

    tmp = tempfile.mkdtemp(prefix="abi-baseline-")
    try:
        if args.from_device:
            mods_dir = collect_from_device(args.serial, tmp, args.keep_temp)
            note = "/vendor/lib/modules/*.ko (device dump)"
        elif args.modules_dir:
            mods_dir = args.modules_dir
            note = os.path.join(args.modules_dir, "*.ko")
        else:
            mods_dir = collect_from_image(args.from_vendor_img, tmp)
            note = "vendor image %s (erofs)" % args.from_vendor_img

        kos = []
        for root, _dirs, files in os.walk(mods_dir):
            for f in files:
                if f.endswith(".ko"):
                    kos.append(os.path.join(root, f))
        kos.sort()
        if not kos:
            sys.exit("在 %s 里没找到 .ko" % mods_dir)

        print("== 解析 %d 个 stock 模块 ==" % len(kos))
        union = {}
        owner = {}
        per_module = {}
        conflicts = []
        empty = []
        for ko in kos:
            mod = os.path.splitext(os.path.basename(ko))[0]
            vers = versions_of(ko)
            if not vers:
                empty.append(mod)
            per_module[mod] = vers
            for sym, crc in vers.items():
                if sym in union and union[sym] != crc:
                    conflicts.append((sym, owner[sym], union[sym], mod, crc))
                    continue
                union[sym] = crc
                owner[sym] = mod

        print("  模块 %d 个，符号并集 %d 个" % (len(per_module), len(union)))
        if empty:
            print("  WARN: %d 个模块没有 __versions（可能未开 MODVERSIONS）：%s"
                  % (len(empty), ", ".join(sorted(empty)[:10])))
        if conflicts:
            print("  ERROR: %d 个符号在不同模块间 CRC 不一致（基线会有歧义）：" % len(conflicts))
            for sym, m1, c1, m2, c2 in conflicts[:20]:
                print("    %-42s %s=0x%08x  %s=0x%08x" % (sym, m1, c1, m2, c2))
            if not args.allow_conflicts:
                sys.exit("请确认 ROM 是否为混版；确认无误可加 --allow-conflicts")

        old = load_existing(args.out)
        if old:
            added = sorted(set(union) - set(old))
            removed = sorted(set(old) - set(union))
            changed = sorted(s for s in set(union) & set(old) if union[s] != old[s])
            print("== 与现有基线对比（%s，%d 个符号）==" % (args.out, len(old)))
            print("  新增 %d | 删除 %d | CRC 变化 %d" % (len(added), len(removed), len(changed)))
            for label, items in (("新增", added), ("删除", removed), ("变化", changed)):
                for s in items[:25]:
                    if label == "变化":
                        print("    %-42s 0x%08x -> 0x%08x" % (s, old[s], union[s]))
                    elif label == "新增":
                        print("    + %-40s 0x%08x" % (s, union[s]))
                    else:
                        print("    - %-40s 0x%08x" % (s, old[s]))
                if len(items) > 25:
                    print("    ... 另有 %d 条" % (len(items) - 25))
            if not (added or removed or changed):
                print("  与现有基线完全一致（无需更新）")
        else:
            print("== 现有基线不存在（%s），将全量生成 ==" % args.out)

        if args.diff:
            print("--diff：不写文件")
            return

        write_baseline(args.out, union, note)
        write_module_map(args.modules_out, per_module)
    finally:
        if not args.keep_temp:
            shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    main()
