#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
gen_banner.py —— 把一行文字做成 FPGA 用的字幕点阵 ROM（banner_rom.hex）。

背景：本工程在画面最下面 32 行叠了一条会横向滚动的字幕带。
      点阵数据存在片内 ROM 里，这个脚本负责把文字转成点阵。

点阵规格（和 banner_rom.v / osd_mixer.v 对应）
    宽 2048 像素 × 高 32 像素，每像素 1 bit（1 = 显示文字）。
    存储：每一行的 2048 像素按 32 像素一组打包成 1 个 32bit 字，共 64 个字。
          32 行 × 64 字 = 2048 个字。
    取址：字地址 = 行号 * 64 + (列号 >> 5)
          取位   = 31 - (列号 & 31)
    滚动：显示时按偏移量横向循环，滚到 2047 后自动绕回 0，所以文字会无缝循环。

用法
    python gen_banner.py -t "欢迎参观 2026 嵌入式芯片与系统设计竞赛作品"
    python gen_banner.py -t "EMERGENCY" --font C:/Windows/Fonts/arialbd.ttf
    python gen_banner.py -t "安全第一" --repeat 3      # 同一句话重复铺满 2048 像素

生成完把 banner_rom.hex 放到 TD 工程目录再综合。
另外会顺便输出 banner_preview.png，可以直观看看字幕长什么样。
"""

import os
import sys
import argparse

try:
    from PIL import Image, ImageDraw, ImageFont
except ImportError:
    print("[错误] 没有找到 Pillow 库。请先安装：pip install Pillow")
    sys.exit(1)

BAN_W  = 2048
BAN_H  = 32
WORDS_PER_ROW = BAN_W // 32     # 64
ROM_DEPTH     = BAN_H * WORDS_PER_ROW   # 2048

# 常见可用的字体，按优先级排；前几个都支持中文
FONT_CANDIDATES = [
    r"C:\Windows\Fonts\msyh.ttc",       # 微软雅黑
    r"C:\Windows\Fonts\msyhbd.ttc",
    r"C:\Windows\Fonts\simhei.ttf",     # 黑体
    r"C:\Windows\Fonts\simsun.ttc",     # 宋体
    r"C:\Windows\Fonts\arialbd.ttf",    # Arial Bold（纯英文用它更清楚）
    r"C:\Windows\Fonts\arial.ttf",
]


def pick_font(user_font, size):
    """挑一个能打开的字体。"""
    candidates = [user_font] if user_font else []
    candidates += FONT_CANDIDATES
    for path in candidates:
        if path and os.path.isfile(path):
            try:
                return ImageFont.truetype(path, size)
            except Exception:
                continue
    print("[警告] 没找到可用的 TrueType 字体，退回 Pillow 内置点阵字体，"
          "中文会显示不出来。建议用 --font 指定一个 .ttf/.ttc。")
    return ImageFont.load_default()


def render_text(text, font):
    """把文字渲染成一张 BAN_W x BAN_H 的单色位图，返回二维 0/1 列表。"""
    img = Image.new('1', (BAN_W, BAN_H), 0)     # 0 = 背景
    draw = ImageDraw.Draw(img)

    # 量一下文字实际占多宽，垂直居中
    try:
        bbox = draw.textbbox((0, 0), text, font=font)
        tw = bbox[2] - bbox[0]
        th = bbox[3] - bbox[1]
        offset_x = -bbox[0]
        offset_y = -bbox[1]
    except Exception:
        tw, th = draw.textsize(text, font=font)
        offset_x = 0
        offset_y = 0

    y = (BAN_H - th) // 2 + offset_y
    draw.text((offset_x, y), text, fill=1, font=font)

    px = img.load()
    return [[px[x, y] for x in range(BAN_W)] for y in range(BAN_H)], tw


def render_repeated(text, font, repeat):
    """把同一句话重复若干次，铺满整条 2048 像素，方便循环播放。"""
    img = Image.new('1', (BAN_W, BAN_H), 0)
    draw = ImageDraw.Draw(img)
    try:
        bbox = draw.textbbox((0, 0), text, font=font)
        tw = bbox[2] - bbox[0]
        offset_x = -bbox[0]
        offset_y = -bbox[1]
        th = bbox[3] - bbox[1]
    except Exception:
        tw, th = draw.textsize(text, font=font)
        offset_x = 0
        offset_y = 0

    gap = 48
    step = tw + gap
    y = (BAN_H - th) // 2 + offset_y

    for k in range(repeat):
        draw.text((offset_x + k * step, y), text, fill=1, font=font)

    px = img.load()
    return [[px[x, y2] for x in range(BAN_W)] for y2 in range(BAN_H)], tw


def pack_to_words(bitmap):
    """二维 0/1 位图 → 2048 个 32bit 字（行优先，每行 64 个字）。"""
    words = []
    for row in range(BAN_H):
        for w in range(WORDS_PER_ROW):
            word = 0
            for b in range(32):
                c = w * 32 + b
                if bitmap[row][c]:
                    word |= (1 << (31 - b))
            words.append(word & 0xFFFFFFFF)
    assert len(words) == ROM_DEPTH
    return words


def save_hex(words, path):
    with open(path, 'w', encoding='ascii') as f:
        f.write('\n'.join(f"{w:08X}" for w in words))
        f.write('\n')


def save_preview(bitmap, path):
    """输出一张放大 3 倍、白字黑底的预览图，方便肉眼检查。"""
    scale = 3
    # 竖着放大 3 倍、横着也放大 3 倍，看起来更清楚
    img = Image.new('RGB', (BAN_W * scale, BAN_H * scale), (0x10, 0x18, 0x28))
    px = img.load()
    for y in range(BAN_H):
        for x in range(BAN_W):
            if bitmap[y][x]:
                for dy in range(scale):
                    for dx in range(scale):
                        px[x * scale + dx, y * scale + dy] = (0xFF, 0xD2, 0x4A)
    img.save(path)


def main():
    ap = argparse.ArgumentParser(
        description="生成 FPGA 字幕点阵 ROM（banner_rom.hex）",
        formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('-t', '--text', required=True, help='字幕文字')
    ap.add_argument('-o', '--output', default='banner_rom.hex', help='输出的 hex 文件')
    ap.add_argument('--font', default=None, help='指定字体文件（.ttf/.ttc）')
    ap.add_argument('--size', type=int, default=26, help='字号（默认 26，别超过 32）')
    ap.add_argument('--repeat', type=int, default=1,
                    help='同一句话重复几次铺满整条（默认 1）')
    ap.add_argument('--preview', default='banner_preview.png', help='预览图输出名')
    args = ap.parse_args()

    print(f"字幕文字：{args.text}")
    font = pick_font(args.font, args.size)

    if args.repeat > 1:
        bitmap, tw = render_repeated(args.text, font, args.repeat)
    else:
        bitmap, tw = render_text(args.text, font)

    words = pack_to_words(bitmap)
    save_hex(words, args.output)
    try:
        save_preview(bitmap, args.preview)
        preview_ok = True
    except Exception as e:
        preview_ok = False
        print(f"[警告] 预览图生成失败：{e}")

    lit = sum(sum(1 for v in row if v) for row in bitmap)
    print("-" * 60)
    print(f"已生成：{os.path.abspath(args.output)}")
    print(f"  点阵尺寸  : {BAN_W} x {BAN_H}")
    print(f"  ROM 字数  : {ROM_DEPTH} （每字 32bit）")
    print(f"  文字宽度  : {tw} 像素")
    print(f"  点亮点数  : {lit}")
    print("-" * 60)
    if tw > BAN_W:
        print("提示：文字总宽超过 2048 像素，超出部分会被截掉。"
              "可以把 --size 调小，或减少 --repeat 次数。")
    if preview_ok:
        print(f"预览图：{os.path.abspath(args.preview)}（先看一眼再烧板子）")
    print("\n下一步：把 banner_rom.hex 复制到 TD 工程目录再重新综合。")


if __name__ == '__main__':
    main()
