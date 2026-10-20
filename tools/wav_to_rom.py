#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
wav_to_rom.py —— 把你自己的一段音频，直接灌进 FPGA 的音频 ROM。

和 gen_audio_rom.py 的区别：
  gen_audio_rom.py  是「按参数生成/合成」，要你先把音频转成 16bit wav。
  wav_to_rom.py     是「拖进来的文件是什么就是什么」：
      · 自动找 ffmpeg 转码（mp3 / m4a / flac / 任意 wav / 24bit / 32bit 都行）
      · 自动转单声道、48kHz、16bit
      · 自动做淡入淡出、归一化，避免爆音和削顶
      · 自动把 hex 同步到 5 个位置

用法（最简单：把音频文件拖到 scripts\\6_audio_drop.bat 图标上）：

    ① 只拖 1 个文件  → 这个声音同时占满 4 段（8 张图都是同一声音）
    ② 拖 2~4 个文件 → 按顺序对应段 0/1/2/3，不够的用内置音效补齐

也可以命令行用：

    python tools/wav_to_rom.py -w 我的音效.mp3 --repeat
    python tools/wav_to_rom.py -w a.mp3 b.wav c.m4a d.flac
    python tools/wav_to_rom.py -w 声音.wav --fill 0    # 只替换段 0
"""

import os
import sys
import math
import array
import shutil
import wave
import argparse
import subprocess

ROM_DEPTH = 8192          # 每段样本数（= 170.7ms @48kHz，RTL 里写死）
SEG_NUM   = 4             # 段数（RTL 里写死）
RATE      = 48000         # 播放采样率（HDMI ACR N=6144 对应 48kHz）
PEAK_TGT  = 0.85          # 归一化目标峰值（留 15% 余量，防削顶）

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)

HEX_PLACES = [
    ("src/hdl",              "TD 综合时真正读这里"),
    ("src/rom",              "归档"),
    ("sim",                  "iverilog / ModelSim 仿真"),
    ("billboard_Runs/syn_1", "TD 综合运行目录"),
    ("",                     "工程根目录"),
]


# ---------------------------------------------------------------- 转码
def find_ffmpeg():
    """找 ffmpeg：先看 PATH，再看 imageio_ffmpeg 自带的静态版。"""
    p = shutil.which("ffmpeg")
    if p:
        return p
    try:
        import imageio_ffmpeg
        return imageio_ffmpeg.get_ffmpeg_exe()
    except Exception:
        return None


def decode_with_ffmpeg(ffmpeg, src):
    """任何音频 -> 48kHz 单声道 int16 裸 PCM（从 stdout 读回）。"""
    cmd = [ffmpeg, '-v', 'error', '-i', src,
           '-vn',                      # 丢掉封面图
           '-ac', '1', '-ar', str(RATE),
           '-f', 's16le', '-acodec', 'pcm_s16le',
           '-af', 'highpass=f=40',     # 去直流/低频隆隆声，否则 8bit 量化后有咔哒
           '-']
    r = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if r.returncode != 0 or len(r.stdout) < 4:
        lines = r.stderr.decode("utf-8", "replace").strip().splitlines()
        msg = lines[-1] if lines else "未知错误"
        raise RuntimeError("ffmpeg 解码失败：%s\n  %s" % (src, msg))
    samp = array.array('h')
    samp.frombytes(r.stdout[:len(r.stdout) // 2 * 2])
    if sys.byteorder == 'big':
        samp.byteswap()
    return [s / 32768.0 for s in samp]


def decode_with_wave(src):
    """没有 ffmpeg 时的兜底：只吃 16bit PCM 的 wav。"""
    with wave.open(src, 'rb') as w:
        nch, width, rate = w.getnchannels(), w.getsampwidth(), w.getframerate()
        raw = w.readframes(w.getnframes())
    if width != 2:
        raise RuntimeError(
            "%s 是 %dbit wav，没装 ffmpeg 时只支持 16bit。\n"
            "  请先转成 16bit，或装一下 ffmpeg：pip install imageio-ffmpeg"
            % (os.path.basename(src), width * 8))
    samp = array.array('h')
    samp.frombytes(raw)
    if sys.byteorder == 'big':
        samp.byteswap()
    if nch == 2:
        mono = [(samp[i] + samp[i + 1]) / 2.0 / 32768.0
                for i in range(0, len(samp) - 1, 2)]
    else:
        mono = [s / 32768.0 for s in samp]
    return mono, rate


def resample_linear(data, src_rate):
    """线性插值到 48kHz。素材都在 1 秒以内，精度够用。"""
    if src_rate == RATE or not data:
        return data
    ratio = src_rate / RATE
    out_n = int(len(data) / ratio)
    out = []
    for i in range(out_n):
        pos = i * ratio
        i0 = int(pos)
        i1 = min(i0 + 1, len(data) - 1)
        fr = pos - i0
        out.append(data[i0] * (1 - fr) + data[i1] * fr)
    return out


def load_any(src, ffmpeg):
    """返回 (48kHz 单声道 float 列表, 原始时长秒)。"""
    if ffmpeg:
        data = decode_with_ffmpeg(ffmpeg, src)
        rate = RATE
    else:
        data, rate = decode_with_wave(src)
    dur = len(data) / float(rate)
    if rate != RATE:
        data = resample_linear(data, rate)
    return data, dur


# ---------------------------------------------------------------- 加工
def trim_tail(data, n):
    """长于 n 就截掉，并把最后 128 个样本淡出（避免一刀切的爆音）。"""
    if len(data) <= n:
        return list(data)
    out = list(data[:n])
    for i in range(min(128, n)):
        out[n - 1 - i] *= i / 128.0
    return out


def norm_and_fade(data):
    """归一化到目标峰值 + 两端淡入淡出。"""
    if not data:
        return [0.0] * ROM_DEPTH
    pk = max(abs(v) for v in data) or 1.0
    g = PEAK_TGT / pk
    out = [v * g for v in data]
    n = len(out)
    fi, fo = min(64, n), min(256, n)
    for i in range(fi):
        out[i] *= i / float(fi)
    for i in range(fo):
        out[n - 1 - i] *= i / float(fo)
    return out


def pad_to(data, n=ROM_DEPTH):
    """短了就补静音（不循环，循环会被听出来抖动）。"""
    out = list(data)
    if len(out) < n:
        out.extend([0.0] * (n - len(out)))
    return out[:n]


# ---------------------------------------------------------------- 输出
def write_hex(segs, out_path):
    lines = []
    for data in segs:
        for v in data:
            x = int(round(v * 127.0))
            x = max(-128, min(127, x))
            if x < 0:
                x += 0x100
            lines.append("%02X" % x)
    with open(out_path, "w", encoding="ascii", newline="\n") as f:
        f.write("\n".join(lines))
        f.write("\n")
    return len(lines)


def sync_hex(hex_path):
    done = []
    for sub, note in HEX_PLACES:
        d = os.path.join(ROOT, sub) if sub else ROOT
        if sub == "billboard_Runs/syn_1" and not os.path.isdir(d):
            continue
        os.makedirs(d, exist_ok=True)
        dst = os.path.join(d, os.path.basename(hex_path))
        shutil.copy2(hex_path, dst)
        done.append((dst, note))
    return done


# ---------------------------------------------------------------- 内置备用
def builtin_seg(i):
    """和 gen_audio_rom.py 的 4 段内置音效一致的简化重算。"""
    if i == 0:
        n = int(RATE * 0.12)
        return [math.sin(2 * math.pi * 1000 * k / RATE) for k in range(n)]
    if i == 1:
        b = [math.sin(2 * math.pi * 1200 * k / RATE)
             for k in range(int(RATE * 0.09))]
        g = [0.0] * int(RATE * 0.07)
        return b + g + b
    if i == 2:
        n = int(RATE * 0.18)
        out, ph = [], 0.0
        for k in range(n):
            f = 400 + (2000 - 400) * k / float(max(1, n - 1))
            ph += 2 * math.pi * f / RATE
            out.append(math.sin(ph))
        return out
    n = int(RATE * 0.26)
    out = []
    for k in range(n):
        t = k / float(RATE)
        v = (math.sin(2 * math.pi * 880 * t)
             + 0.5 * math.sin(2 * math.pi * 1760 * t)
             + 0.25 * math.sin(2 * math.pi * 2640 * t))
        out.append(v * math.exp(-4.0 * t) / 1.75)
    return out


# ---------------------------------------------------------------- main
def main():
    ap = argparse.ArgumentParser(
        description="把音频文件直接灌进 FPGA 音频 ROM（自动转码/归一化/五处同步）",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="例：python tools/wav_to_rom.py -w ding.mp3 --repeat")
    ap.add_argument('-w', '--wav', nargs='+', required=True,
                    help="1~4 个音频文件，按顺序对应段 0/1/2/3（mp3/m4a/flac/wav 均可）")
    ap.add_argument('--repeat', action='store_true',
                    help="只给 1 个文件时用它填满 4 段")
    ap.add_argument('--fill', type=int, default=None, choices=[0, 1, 2, 3],
                    help="只把第 1 个文件写进指定段，其余段保留内置音效")
    ap.add_argument('-o', '--output', default=os.path.join(ROOT, 'audio_rom.hex'),
                    help="输出 hex 路径（默认工程根的 audio_rom.hex）")
    ap.add_argument('--no-sync', action='store_true',
                    help="不自动复制到 5 个位置")
    ap.add_argument('--preview', default=None,
                    help="额外把处理后的 4 段合成一个 wav 存到指定路径，方便先听")
    args = ap.parse_args()

    files = args.wav[:SEG_NUM]
    if len(args.wav) > SEG_NUM:
        print("[提示] 给了 %d 个文件，只用前 %d 个" % (len(args.wav), SEG_NUM))

    ffmpeg = find_ffmpeg()
    if ffmpeg:
        print("[转码] 使用 ffmpeg：%s" % ffmpeg)
    else:
        print("[转码] 没找到 ffmpeg —— 只支持 16bit PCM 的 wav")
        print("       想支持 mp3/m4a，执行一次：pip install imageio-ffmpeg")
    print("")

    loaded = []
    for i, path in enumerate(files):
        if not os.path.isfile(path):
            print("[错误] 找不到文件：%s" % path)
            return 1
        try:
            data, dur = load_any(path, ffmpeg)
        except Exception as e:
            print("[错误] %s" % e)
            return 1
        data = trim_tail(data, ROM_DEPTH)
        used = len(data) / float(RATE) * 1000.0
        tail = ""
        if dur * 1000.0 > 171.0:
            tail = "  <- 原长 %.0fms，已截到 171ms" % (dur * 1000.0)
        print("  段%d: %-28s 原 %6.0fms -> 用 %5.0fms%s"
              % (i, os.path.basename(path), dur * 1000.0, used, tail))
        loaded.append(data)

    segs = []
    for i in range(SEG_NUM):
        if args.fill is not None:
            if i == args.fill:
                segs.append(norm_and_fade(pad_to(loaded[0])))
            else:
                segs.append(norm_and_fade(pad_to(trim_tail(builtin_seg(i), ROM_DEPTH))))
            continue
        if args.repeat and len(loaded) == 1:
            segs.append(norm_and_fade(pad_to(loaded[0])))
            continue
        if i < len(loaded):
            segs.append(norm_and_fade(pad_to(loaded[i])))
        else:
            segs.append(norm_and_fade(pad_to(trim_tail(builtin_seg(i), ROM_DEPTH))))
            print("  段%d: 用内置音效补齐" % i)

    n = write_hex(segs, args.output)
    pk = max(max(abs(v) for v in s) for s in segs)
    print("")
    print("-" * 62)
    print("已生成：%s" % args.output)
    print("  段数      : %d（每段 %d 样本 = 171ms @48kHz）" % (SEG_NUM, ROM_DEPTH))
    print("  总样本    : %d（8bit/样本，约占 %d 块 9Kb EMB）"
          % (n, (n * 8 + 9215) // 9216))
    print("  归一化峰值: %.2f（满刻度 1.0，已留余量防削顶）" % pk)
    print("-" * 62)

    if args.preview:
        pcm = array.array('h')
        for s in segs:
            for v in s:
                pcm.append(int(round(v * 32767)))
        with wave.open(args.preview, 'wb') as w:
            w.setnchannels(1)
            w.setsampwidth(2)
            w.setframerate(RATE)
            w.writeframes(pcm.tobytes())
        print("试听文件：%s（4 段连播，每段 171ms）" % args.preview)
        print("")

    if not args.no_sync:
        for p, note in sync_hex(args.output):
            rel = os.path.relpath(p, ROOT)
            print("  已同步 %-32s （%s）" % (rel, note))
        print("")
        print("下一步：双击 scripts\\6_audio_drop.bat 的同类流程，或直接运行")
        print("        scripts\\5_audio_to_bit.bat（注意：5 号脚本会用内置音效重生成，")
        print("        所以换自己的音频请用 6_audio_drop.bat）。")
    return 0


if __name__ == '__main__':
    sys.exit(main())
