#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
gen_audio_rom.py —— 生成 FPGA 片内音频素材 ROM（audio_rom.hex）。

背景：本工程的音频不是"FPGA 自己发方波、自己再解出来"（那是官方例程的做法），
      而是事先做好的 PCM 素材，存在片内 ROM 里，播放时直接取出来送给 HDMI。
      这个脚本负责把素材做成 audio_rom.hex。

ROM 结构（和 audio_rom.v 对应）
    一共 4 段，每段 8192 个 8bit 有符号样本，采样率 48000 Hz。
    段 0 占地址 0..8191，段 1 占 8192..16383，依此类推。
    hex 每行 2 位十六进制（8bit 二进制补码），共 32768 行。

    ★ 为什么是 8bit：EG4S20 只有 64 块 9Kb EMB（块 RAM）。
      16bit 版本 ROM 要占约 60 块，全工程 88 块超限（TD 报 PHY-9013）；
      8bit 版本只占约 30 块，全工程约 58 块，放得下。
      ROM 对外做符号扩展回 16bit，audio_player 不用改。

两种用法
    ① 什么都不给，直接生成 4 段内置提示音（新手推荐，先跑起来）
         python gen_audio_rom.py

    ② 用自己的 wav 素材（最多 4 个，按顺序对应音效段 0/1/2/3）
         python gen_audio_rom.py -w beep.wav chime.wav alert.wav warm.wav

生成完把 audio_rom.hex 放到 TD 工程目录（和 .al 文件同层）再综合。
"""

import os
import sys
import math
import array
import wave
import argparse

ROM_DEPTH = 8192
SEG_NUM   = 4
RATE      = 48000
AMP       = 0.75          # 合成音的幅度（0~1），留点余量防止削顶


# ------------------------------------------------------------------ 音效合成
def synth_beep(freq=1000.0, ms=120):
    """单声提示音。"""
    n = int(RATE * ms / 1000)
    out = []
    for i in range(n):
        out.append(math.sin(2 * math.pi * freq * i / RATE))
    return out


def synth_double_beep(freq=1200.0, ms=90, gap_ms=70):
    """双声提示音（"嘀-嘀"）。"""
    beep = synth_beep(freq, ms)
    gap = [0.0] * int(RATE * gap_ms / 1000)
    return beep + gap + beep


def synth_sweep(f0=400.0, f1=2000.0, ms=180):
    """上升扫频。"""
    n = int(RATE * ms / 1000)
    out = []
    phase = 0.0
    for i in range(n):
        f = f0 + (f1 - f0) * i / max(1, n - 1)
        phase += 2 * math.pi * f / RATE
        out.append(math.sin(phase))
    return out


def synth_chime(f0=880.0, ms=260):
    """柔和铃声：基频 + 两个泛音，指数衰减。"""
    n = int(RATE * ms / 1000)
    out = []
    for i in range(n):
        t = i / RATE
        env = math.exp(-4.0 * t)
        v = (1.00 * math.sin(2 * math.pi * f0 * t)
             + 0.50 * math.sin(2 * math.pi * f0 * 2.0 * t)
             + 0.25 * math.sin(2 * math.pi * f0 * 3.0 * t))
        out.append(v * env / 1.75)
    return out


def default_segments():
    """4 段内置音效：短提示 / 双提示 / 上升扫频 / 铃声。"""
    return [
        ("段0 短提示音",  synth_beep()),
        ("段1 双声提示",  synth_double_beep()),
        ("段2 上升扫频",  synth_sweep()),
        ("段3 柔和铃声",  synth_chime()),
    ]


# ------------------------------------------------------------------ WAV 读取
def read_wav_mono(path):
    """读 wav，返回 float 列表（-1..1）和原始采样率。只支持 16bit PCM。"""
    with wave.open(path, 'rb') as w:
        nch   = w.getnchannels()
        width = w.getsampwidth()
        rate  = w.getframerate()
        nframes = w.getnframes()
        raw = w.readframes(nframes)

    if width != 2:
        raise ValueError(f"{path}: 只支持 16bit PCM 的 wav，当前是 {width*8}bit。"
                         f"请先转成 16bit。")

    samples = array.array('h')
    samples.frombytes(raw)
    if sys.byteorder == 'big':
        samples.byteswap()

    if nch == 2:
        # 立体声 → 取左右平均
        mono = [(samples[i] + samples[i + 1]) / 2.0 / 32768.0
                for i in range(0, len(samples) - 1, 2)]
    else:
        mono = [s / 32768.0 for s in samples]

    return mono, rate


def resample_linear(data, src_rate, dst_rate):
    """线性插值重采样。素材不长，简单算法足够。"""
    if src_rate == dst_rate or not data:
        return data
    ratio = src_rate / dst_rate
    out_len = int(len(data) / ratio)
    out = []
    for i in range(out_len):
        pos = i * ratio
        i0 = int(pos)
        i1 = min(i0 + 1, len(data) - 1)
        frac = pos - i0
        out.append(data[i0] * (1 - frac) + data[i1] * frac)
    return out


def to_segment_length(data, n=ROM_DEPTH):
    """把任意长度的素材整理成恰好 n 个样本（长了就截，短了就补静音 + 轻微循环）。"""
    if len(data) >= n:
        return data[:n]
    if not data:
        return [0.0] * n
    out = list(data)
    while len(out) < n:
        out.extend(data)
    return out[:n]


def apply_fades(data, fade_in=64, fade_out=512):
    """首尾做淡入淡出，避免爆音（"啪"的一声）。"""
    n = len(data)
    out = list(data)
    for i in range(min(fade_in, n)):
        out[i] *= i / fade_in
    for i in range(min(fade_out, n)):
        out[n - 1 - i] *= i / fade_out
    return out


# ------------------------------------------------------------------ 输出
def write_hex(segments, out_path):
    """把 4 段（每段 8192 个 -1..1 的浮点样本）写成 audio_rom.hex（8bit）。"""
    assert len(segments) == SEG_NUM, f"必须正好 {SEG_NUM} 段"

    lines = []
    peak = 0.0
    for name, data in segments:
        data = apply_fades(to_segment_length(data))
        assert len(data) == ROM_DEPTH
        for v in data:
            # 量化到 8bit 有符号（-128..127）
            x = int(round(v * AMP * 127.0))
            x = max(-128, min(127, x))
            # 记录实际写进 ROM 的峰值（相对满刻度 127）
            pk = abs(x) / 127.0
            if pk > peak:
                peak = pk
            if x < 0:
                x += 0x100
            lines.append(f"{x:02X}")

    with open(out_path, 'w', encoding='ascii') as f:
        f.write('\n'.join(lines))
        f.write('\n')

    print("-" * 60)
    print(f"已生成：{os.path.abspath(out_path)}")
    print(f"  段数        : {SEG_NUM}")
    print(f"  每段样本数  : {ROM_DEPTH}  （{ROM_DEPTH/RATE*1000:.0f} ms）")
    print(f"  总样本数    : {SEG_NUM * ROM_DEPTH}  （8bit/样本）")
    print(f"  实际峰值    : {peak:.3f}（1.0 = 满刻度）")
    print(f"  ROM 占用    : {SEG_NUM * ROM_DEPTH // 1024} KB 片内 EMB"
          f"（约 {(SEG_NUM * ROM_DEPTH * 8 + 9215) // 9216} 块 9Kb EMB）")
    print("-" * 60)
    if peak > 0.99:
        print("提示：素材峰值接近满刻度，可能会有轻微削顶。"
              "把脚本开头的 AMP 调小一点再生成。")


def main():
    ap = argparse.ArgumentParser(
        description="生成 FPGA 音频 ROM（audio_rom.hex）",
        formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('-w', '--wav', nargs='*', default=None,
                    help='最多 4 个 wav 文件，按顺序对应音效段 0/1/2/3')
    ap.add_argument('-o', '--output', default='audio_rom.hex',
                    help='输出文件名（默认 audio_rom.hex）')
    args = ap.parse_args()

    if args.wav:
        if len(args.wav) > SEG_NUM:
            print(f"[警告] 给了 {len(args.wav)} 个 wav，只用前 {SEG_NUM} 个。")
            args.wav = args.wav[:SEG_NUM]

        segs = []
        for i, path in enumerate(args.wav):
            if not os.path.isfile(path):
                print(f"[错误] 找不到 {path}")
                sys.exit(1)
            data, rate = read_wav_mono(path)
            data = resample_linear(data, rate, RATE)
            segs.append((f"段{i} {os.path.basename(path)}", data))
            print(f"  段{i}: {os.path.basename(path)}  "
                  f"原始 {rate}Hz / {len(data)} 样本 → 重采样到 {RATE}Hz")

        # 不足 4 段的，用内置音效补齐
        defaults = default_segments()
        while len(segs) < SEG_NUM:
            segs.append(defaults[len(segs)])
            print(f"  段{len(segs)-1}: 用内置音效补齐")
    else:
        print("没有指定 wav，使用 4 段内置提示音。")
        segs = default_segments()

    write_hex(segs, args.output)
    print("\n下一步：把 audio_rom.hex 复制到 TD 工程目录"
          "（和 .al 工程文件同一层），然后重新综合。")


if __name__ == '__main__':
    main()
