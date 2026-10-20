#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
check_results.py —— 读仿真日志，打印一张 ASCII 结论表

为什么需要它：
  不管用 ModelSim 还是 iverilog，日志里都可能出现中文乱码：
    * ModelSim 图形界面的 Transcript 窗口在本机 cp936 环境下偶尔把中文显示成乱码；
    * iverilog 把中文通过位向量参数传递时会烧成 0xff。
  但日志**文件本身**都是干净的 UTF-8。这个脚本直接读文件，
  把每个 testbench 的结论、以及每个没通过的检查项，用干净的方式打出来。

用法（在 sim 目录下）：
    python check_results.py                 # 汇总所有日志（两个目录都看）
    python check_results.py tb_ebm_reader   # 只看某一个的详细内容
    python check_results.py --ivl           # 只看 iverilog 的日志（ivlogs/）
    python check_results.py --ms            # 只看 ModelSim 的日志（logs/）
"""

import os
import re
import sys
import glob

# 两个日志目录都扫：ModelSim 写 logs/，iverilog 写 ivlogs/
LOG_DIRS = ['logs', 'ivlogs']
RESULT_RE = re.compile(r'###\s*RESULT\s+(\S+)\s*:\s*(PASS|FAIL)\s*\((.*?)\)\s*###')
FAIL_RE = re.compile(r'###\s*FAIL\s+idx=(\d+)\s*###')

# 检查项标签 -> 中文说明：从 tb 源码的行尾注释里抓（如 chk(x, "C01");  // 说明）
TB_LABEL_RE = re.compile(r'chk\(.*?"C(\d+)"\s*\)\s*;\s*//\s*(.+?)\s*$')


def read_text(path):
    """按 UTF-8 读；万一有坏字节就替换掉，保证不抛异常。"""
    with open(path, 'rb') as f:
        raw = f.read()
    return raw.decode('utf-8', errors='replace')


def load_labels():
    """从同目录的 tb_*.v 里解析 'C01 -> 中文说明' 映射。"""
    labels = {}
    here = os.path.dirname(os.path.abspath(__file__))
    for tb in glob.glob(os.path.join(here, 'tb_*.v')):
        try:
            for line in read_text(tb).splitlines():
                m = TB_LABEL_RE.search(line)
                if m:
                    labels.setdefault(os.path.basename(tb), {})[int(m.group(1))] = m.group(2)
        except OSError:
            pass
    return labels


ALL_LABELS = load_labels()


def label_of(logname, idx, tb_name=None):
    """把 '### FAIL idx=N ###' 里的 N 翻译成中文说明。"""
    # logname 形如 tb_ebm_reader.log
    key = logname[:-4] + '.v' if logname.endswith('.log') else logname
    return ALL_LABELS.get(key, {}).get(idx, '')


def parse_log(path):
    """返回 (结论行dict 或 None, 失败项列表[(idx, 描述)])."""
    text = read_text(path)
    lines = text.splitlines()

    result = None
    for line in lines:
        m = RESULT_RE.search(line)
        if m:
            result = {'tb': m.group(1), 'status': m.group(2),
                      'detail': m.group(3).strip()}

    fails = []
    for i, line in enumerate(lines):
        m = FAIL_RE.search(line)
        if not m:
            continue
        idx = int(m.group(1))
        # 优先用 tb 源码里的中文说明；退回到日志里 ">>> " 上面那行
        desc = label_of(os.path.basename(path), idx)
        if not desc:
            for j in range(i - 1, max(-1, i - 4), -1):
                if '>>>' in lines[j]:
                    desc = lines[j].split('>>>', 1)[1].strip()
                    break
        fails.append((idx, desc))
    return result, fails


def main():
    args = [a for a in sys.argv[1:]]
    only_dirs = LOG_DIRS
    if '--ivl' in args:
        args.remove('--ivl')
        only_dirs = ['ivlogs']
    if '--ms' in args:
        args.remove('--ms')
        only_dirs = ['logs']

    active = [d for d in only_dirs if os.path.isdir(d)]
    if not active:
        print(f'!! 没有找到日志目录（找了 {", ".join(only_dirs)}）。')
        print('   请先跑   ./run_iverilog.sh   或   ./run_all.sh')
        return 1

    # 指定了某个测试名 -> 打印它的详细过程
    if args:
        want = args[0]
        if not want.endswith('.log'):
            want += '.log'
        found = False
        for d in active:
            path = os.path.join(d, want)
            if os.path.isfile(path):
                print(f'===== {path} 完整内容 =====')
                print(read_text(path))
                found = True
        if not found:
            print(f'!! 找不到日志 {want}')
            return 1
        return 0

    print('=' * 72)
    print(' 仿真结果汇总（iverilog 日志在 ivlogs/，ModelSim 日志在 logs/）')
    print('=' * 72)

    n_pass = n_fail = 0
    detail_blocks = []

    for d in active:
        logs = sorted(glob.glob(os.path.join(d, '*.log')))
        if not logs:
            continue
        print(f'\n[{d}/]')
        for path in logs:
            name = os.path.basename(path)
            # ModelSim 的 .vlog（编译输出）不是仿真日志，跳过
            result, fails = parse_log(path)

            if result is None:
                print(f'  FAIL   {name:<26} 日志里没有结论行（可能卡住或没跑到结尾）')
                n_fail += 1
                continue

            tag = 'PASS' if result['status'] == 'PASS' else 'FAIL'
            line = f'  {tag}   {name:<26} {result["detail"]}'
            print(line)

            if result['status'] == 'PASS':
                n_pass += 1
            else:
                n_fail += 1
                if fails:
                    detail_blocks.append((f'{d}/{name}', fails))

    print('\n' + '-' * 72)
    print(f'  通过 {n_pass} 个，失败 {n_fail} 个')
    print('=' * 72)

    if detail_blocks:
        print('\n没通过的检查项：')
        for name, fails in detail_blocks:
            print(f'\n  --- {name} ---')
            for idx, desc in fails:
                print(f'    C{idx:02d}  {desc}')

    if n_fail == 0:
        print('\n可以去 TD 建工程综合了。')
    else:
        print('\n有失败项，先别上板。')
        print('想看某个测试的完整过程：  python check_results.py <测试名>')
    return 0 if n_fail == 0 else 1


if __name__ == '__main__':
    sys.exit(main())
