# -*- coding: utf-8 -*-
"""
把"工作工程"同步到"交付源镜像"，让两边永远一致。

用法（在 Git Bash 里）：
    cd /c/FPGA/billboard_prj
    python tools/sync_delivery.py            # 实际同步
    python tools/sync_delivery.py --dry-run  # 只看差异，不动文件

工作工程： C:\\FPGA\\billboard_prj\\          （TD 实际打开的那份）
交付源：   ...\\output\\20261009-fpga-spec\\fpga_billboard\\   （打包/存档那份）

同步范围（白名单）：billboard.al / 两个 hex / README-工程总目录.md
                    docs\\  scripts\\  src\\  sim\\  tools\\  assets\\
不同步（故意的）：
    log\\  build_logs\\  billboard_Runs\\   ← TD 运行时产物，可再生
    sim\\ivlogs\\  sim\\ivl_tmp\\  sim\\logs\\  sim\\work\\  ← 仿真临时产物
    sim\\transcript  sim\\*.wlf  sim\\modelsim.ini  ← ModelSim 运行时产物
    manual_template.md                      ← 只放交付源（手册拼装模板）
"""
import os, sys, shutil, filecmp, io

sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8', errors='replace')

WORK = r"C:\FPGA\billboard_prj"
DELIV = r"C:\Users\asus\WorkBuddy\2026-10-09-22-03-51\output\20261009-fpga-spec\fpga_billboard"

ROOT_FILES = ["billboard.al", "audio_rom.hex", "banner_rom.hex", "README-工程总目录.md"]
KEEP_DIRS = ["docs", "scripts", "src", "sim", "tools", "assets", "port_ac201", "bit"]
SKIP_DIR_NAMES = {"ivlogs", "ivl_tmp", "logs", "work", "__pycache__", ".git",
                  "hdmi_test_Runs", "billboard_Runs"}   # TD 运行产物不同步
SKIP_SUFFIX = (".pyc", ".bak", ".tmp", ".wlf", ".vstf", ".log", ".logw")
# ModelSim 波形临时盘文件：wlft + 随机字符，没有后缀（如 wlftw75t3f）
SKIP_PREFIX = ("wlft",)
# ModelSim 运行时产物（每次跑 vsim 都会重建）
SKIP_FILES = {"transcript", "modelsim.ini", "vsim.wlf", "vsim_stacktrace.vstf"}


def walk(rel_root):
    """列出工作工程里该同步的相对路径集合"""
    out = set()
    for f in ROOT_FILES:
        if os.path.isfile(os.path.join(WORK, f)):
            out.add(f)
    for d in KEEP_DIRS:
        base = os.path.join(WORK, d)
        if not os.path.isdir(base):
            continue
        for cur, dirs, files in os.walk(base):
            dirs[:] = [x for x in dirs if x not in SKIP_DIR_NAMES]
            for fn in files:
                if fn.endswith(SKIP_SUFFIX) or fn.startswith(SKIP_PREFIX) or fn in SKIP_FILES:
                    continue
                p = os.path.join(cur, fn)
                rel = os.path.relpath(p, WORK).replace("\\", "/")
                # 素材目录只同步说明文件：用户自己的图片/音频体积大，不进交付包
                if rel.startswith(("assets/img/", "assets/audio/")) and fn != "README.md":
                    continue
                out.add(rel)
    return out


def main():
    dry = "--dry-run" in sys.argv
    files = sorted(walk(""))
    new = upd = same = 0
    changed = []
    for rel in files:
        src = os.path.join(WORK, rel.replace("/", os.sep))
        dst = os.path.join(DELIV, rel.replace("/", os.sep))
        if not os.path.exists(dst):
            new += 1; changed.append(("新增", rel))
        elif not filecmp.cmp(src, dst, shallow=False):
            upd += 1; changed.append(("更新", rel))
        else:
            same += 1
            continue
        if not dry:
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            shutil.copy2(src, dst)

    print(f"\n工作工程 -> 交付源{'（预演，未改动）' if dry else ''}")
    print("-" * 56)
    for tag, rel in changed:
        print(f"  {tag}  {rel}")
    print("-" * 56)
    print(f"  一致 {same} 个 | 新增 {new} 个 | 更新 {upd} 个 | 共 {len(files)} 个文件")
    if dry and changed:
        print("\n  去掉 --dry-run 即可实际同步。")
    elif not changed:
        print("\n  两边已经完全一致 ✅")

    # 交付源里应该只有这些顶层条目
    if not dry:
        allowed = set(ROOT_FILES) | {"docs", "scripts", "src", "sim", "tools", "assets", "manual_template.md", "port_ac201", "bit"}
        extra = sorted(set(os.listdir(DELIV)) - allowed)
        if extra:
            print(f"\n  [提示] 交付源有其他顶层条目：{extra}")


if __name__ == "__main__":
    main()
