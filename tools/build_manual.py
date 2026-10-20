#!/usr/bin/env python3
# -*- coding: utf-8 -*-
r"""
build_manual.py —— 把手册模板里的 {{CODE:相对路径}} 占位符替换成真实代码。

为什么要这么干：手册里的代码必须和 src/ 下的源文件一字不差，
手抄容易出现"改了源码忘了改手册"的不一致。用脚本生成保证永远同步。

用法（在 fpga_billboard 目录下）：
    python tools/build_manual.py

生成：fpga_billboard/docs/从零到上板操作手册.md
（模板仍在根目录 manual_template.md；生成物统一进 docs/，与工程目录结构一致）
"""

import os
import re
import io
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TEMPLATE = os.path.join(ROOT, 'manual_template.md')
OUTPUT   = os.path.join(ROOT, 'docs', '从零到上板操作手册.md')

LANG = {
    '.v': 'verilog',
    '.adc': '',
    '.py': 'python',
    '.md': 'markdown',
    '.do': 'tcl',
    '.sh': 'bash',
}


def lang_of(path):
    return LANG.get(os.path.splitext(path)[1].lower(), '')


def render(text):
    def repl(m):
        rel = m.group(1).strip()
        full = os.path.join(ROOT, rel.replace('/', os.sep))
        if not os.path.isfile(full):
            raise SystemExit(f"[错误] 手册里引用的文件不存在：{rel}")
        with io.open(full, 'r', encoding='utf-8') as f:
            code = f.read().rstrip('\n')
        fence = '```' + lang_of(rel)
        return f"{fence}\n{code}\n```"

    return re.sub(r'\{\{CODE:([^}]+)\}\}', repl, text)


def main():
    if not os.path.isfile(TEMPLATE):
        raise SystemExit(f"[错误] 找不到模板：{TEMPLATE}")
    with io.open(TEMPLATE, 'r', encoding='utf-8') as f:
        tpl = f.read()

    out = render(tpl)
    os.makedirs(os.path.dirname(OUTPUT), exist_ok=True)
    with io.open(OUTPUT, 'w', encoding='utf-8') as f:
        f.write(out)

    n_lines = out.count('\n') + 1
    print(f"已生成：{OUTPUT}")
    print(f"  共 {n_lines} 行，{len(out)/1024:.0f} KB")


if __name__ == '__main__':
    main()
