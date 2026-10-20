#!/usr/bin/env python3
# -*- coding: utf-8 -*-
r"""
gen_container.py —— 把若干张图片（+ 一段 PCM 音频）打包成 EBM2 私有容器，
                    供 FPGA 直接按扇区读取。

为什么要有这个工具？
    官方例程靠在 TF 卡的 FAT32 文件系统里"扫描扇区找 BM 文件头"来发现图片，
    图片放哪、有几个、顺序如何都不确定。本工程改用私有容器：
    PC 端把图片、索引表、校验和一次性拼好，写在卡的固定扇区上；
    FPGA 端只要读头部和索引表，就能"按图索骥"定长寻址，读哪张、读多少字节
    完全确定，还能顺手校验数据有没有坏。这也是本作品与参考例程最本质的区别之一。

    EBM2 在 EBM1 基础上把 80 秒语音也塞进同一个容器：图片区后面紧跟音频区，
    FPGA 一边显图一边流式读音频，做到"音画同源、一张卡搞定"。

磁盘布局（相对容器起始扇区，单位：512 字节扇区）
    +0      头部      512 字节
    +1      索引表    512 字节（最多 32 项，每项 16 字节）
    +2 起   像素数据  每张图 1280*720*3 = 2764800 字节 = 5400 个扇区
    +2+N*5400  音频数据  48kHz/16bit/单声道 PCM，向上对齐到 512 字节

头部字段
    0x00  char[4]  "EBM2"（兼容读 "EBM1"：老卡没有音频）
    0x04  u16      版本 = 2（兼容 1）
    0x06  u16      图片数
    0x08  u16      宽 = 1280
    0x0A  u16      高 = 720
    0x0C  u8       每像素字节数 = 3
    0x0D  u8       校验方式 = 1（Fletcher 变体，模 256）
    0x10  u32      音频起始【绝对扇区号】（0 = 无音频）
    0x14  u32      音频字节数（未对齐的原始长度，0 = 无音频）

索引项字段（16 字节）
    +0    u8   id
    +1    u8   flags
    +2-3  --   保留
    +4    u32  像素起始绝对扇区号（小端）
    +8    u32  像素字节数（小端）
    +12   u32  校验值，低 16 位有效，格式 {s2, s1}

像素格式 = BMP 像素区原样：
    每像素 3 字节，顺序 B、G、R；行序自下而上；每行 3840 字节（4 字节对齐）。

音频格式（FPGA 侧 audio_stream.v 约定）
    48kHz / 16bit / 单声道 / 小端。一个 10 秒格子正好 960000 字节 = 1875 扇区。

用法示例
    # 把 img/ 里的图 + 默认音频打包成 container.bin
    python gen_container.py -i img/ -o container.bin

    # 指定图片顺序和 id
    python gen_container.py -i a.png b.png c.png -o container.bin

    # 只要图不要音频
    python gen_container.py -i img/ -o container.bin --no-audio

    # 直接写到 SD 卡（危险操作，需要管理员权限，详见 write_container.py）
    python gen_container.py -i img/ -o container.bin --write \\.\PhysicalDrive2
"""

import os
import sys
import math
import wave
import argparse

try:
    from PIL import Image
except ImportError:
    print("[错误] 没有找到 Pillow 库。请先安装：")
    print("       pip install Pillow")
    sys.exit(1)


# ----------------------------------------------------------------- 常量
IMG_W          = 1280
IMG_H          = 720
BYTES_PER_PIX  = 3
PIX_BYTES      = IMG_W * IMG_H * BYTES_PER_PIX      # 2764800
SECTOR         = 512
PIX_SECTORS    = PIX_BYTES // SECTOR                # 5400，正好整除
MAX_IMG        = 32                                 # 索引表最多 32 项

MAGIC          = b'EBM2'
VERSION        = 2
CK_MODE        = 1

AUDIO_HZ       = 48000
AUDIO_CH       = 1
AUDIO_BITS     = 16
CELL_SECONDS   = 10
CELL_BYTES     = AUDIO_HZ * (AUDIO_BITS // 8) * AUDIO_CH * CELL_SECONDS   # 960000
CELL_SECTORS   = CELL_BYTES // SECTOR                                     # 1875（必须整除）

# FPGA 侧 ebm_reader.v 的 CONTAINER_LBA 参数必须和这里一致
DEFAULT_LBA    = 1048576

# 默认音频（相对工程根目录的 assets/audio/voice80.wav）
_HERE          = os.path.dirname(os.path.abspath(__file__))
DEFAULT_AUDIO  = os.path.join(_HERE, '..', 'assets', 'audio', 'voice80.wav')


def load_pcm(path):
    """
    读 WAV，返回 (pcm_bytes, 帧数, 时长秒)。只接受 48kHz/16bit/单声道。
    为什么要卡这么死：FPGA 侧 audio_stream 是按 1875 扇区/格的硬编码去跳格的，
    采样率/位宽/声道任何一个不对，音画就永远对不上，所以宁可在 PC 端报错。
    """
    with wave.open(path, 'rb') as w:
        ch  = w.getnchannels()
        sw  = w.getsampwidth()
        fr  = w.getframerate()
        n   = w.getnframes()
        pcm = w.readframes(n)

    if ch != AUDIO_CH or sw * 8 != AUDIO_BITS or fr != AUDIO_HZ:
        raise SystemExit(
            f"[错误] 音频格式不对：{path}\n"
            f"       当前 = {fr}Hz / {sw*8}bit / {ch}声道\n"
            f"       要求 = {AUDIO_HZ}Hz / {AUDIO_BITS}bit / {AUDIO_CH}声道\n"
            f"       转换命令：ffmpeg -i 输入 -ar 48000 -ac 1 -c:a pcm_s16le 输出.wav")

    return pcm, n, n / float(fr)


def fletcher16_bytes(data: bytes):
    """
    和 ebm_reader.v 里完全一致的 Fletcher 变体校验（模 256）。
        s1 = (s1 + byte) & 0xFF
        s2 = (s2 + s1)   & 0xFF
    返回值 = (s1, s2)，在索引表里写成 {s2, s1}，低字节是 s1。
    """
    s1 = 0
    s2 = 0
    for b in data:
        s1 = (s1 + b) & 0xFF
        s2 = (s2 + s1) & 0xFF
    return s1, s2


def image_to_bmp_pixels(path: str, mode: str = 'fit') -> bytes:
    """
    把任意图片变成 1280x720 的 BMP 像素区字节流（BGR、自下而上）。
    mode:
        'fit'     等比缩放后居中裁剪，铺满屏幕（默认，效果最好）
        'stretch' 直接拉伸到 1280x720（会变形）
        'pad'     等比缩放后加黑边居中放置
    """
    img = Image.open(path).convert('RGB')

    if mode == 'stretch':
        img = img.resize((IMG_W, IMG_H), Image.LANCZOS)
    elif mode == 'pad':
        img.thumbnail((IMG_W, IMG_H), Image.LANCZOS)
        canvas = Image.new('RGB', (IMG_W, IMG_H), (0, 0, 0))
        canvas.paste(img, ((IMG_W - img.width) // 2, (IMG_H - img.height) // 2))
        img = canvas
    else:  # fit
        scale = max(IMG_W / img.width, IMG_H / img.height)
        new_w = max(IMG_W, int(math.ceil(img.width * scale)))
        new_h = max(IMG_H, int(math.ceil(img.height * scale)))
        img = img.resize((new_w, new_h), Image.LANCZOS)
        left = (new_w - IMG_W) // 2
        top = (new_h - IMG_H) // 2
        img = img.crop((left, top, left + IMG_W, top + IMG_H))

    rgb = img.tobytes()          # 每像素 3 字节，顺序 R,G,B，行序自上而下

    # ① 行序翻过来（BMP 是自下而上存的）
    stride = IMG_W * 3
    rows = [rgb[i * stride:(i + 1) * stride] for i in range(IMG_H)]
    rows.reverse()
    buf = bytearray(b''.join(rows))

    # ② RGB → BGR：整块交换第 0 和第 2 个通道。
    #    每行 1920 字节能被 3 整除，所以整块按 3 取模的位置是对齐的。
    buf[0::3], buf[2::3] = buf[2::3], buf[0::3]

    return bytes(buf)


def collect_inputs(inputs):
    """把输入参数整理成一个有序的图片路径列表。"""
    files = []
    for item in inputs:
        if os.path.isdir(item):
            names = sorted(
                f for f in os.listdir(item)
                if f.lower().endswith(('.png', '.jpg', '.jpeg', '.bmp', '.webp', '.gif'))
            )
            files.extend(os.path.join(item, n) for n in names)
        elif os.path.isfile(item):
            files.append(item)
        else:
            print(f"[警告] 找不到输入：{item}")
    return files


def build_container(files, lba, mode='fit', audio_path=None):
    if not files:
        print("[错误] 没有可用的图片。")
        return None

    if len(files) > MAX_IMG:
        print(f"[警告] 图片太多（{len(files)} 张），只取前 {MAX_IMG} 张。")
        files = files[:MAX_IMG]

    n = len(files)
    print(f"\n共 {n} 张图片，开始转换……")
    print("-" * 64)

    # ---------------- 逐张转像素 + 算校验
    pixels = []
    checks = []
    for idx, path in enumerate(files):
        px = image_to_bmp_pixels(path, mode)
        s1, s2 = fletcher16_bytes(px)
        pixels.append(px)
        checks.append((s1, s2))
        print(f"  [{idx}] {os.path.basename(path):<32} 校验 = {s2:02X}_{s1:02X}")

    # ---------------- 音频（EBM2）
    pcm         = b''
    audio_alen  = 0
    audio_pad   = b''
    if audio_path:
        pcm, nframes, dur = load_pcm(audio_path)
        audio_alen = len(pcm)
        pad = (-audio_alen) % SECTOR
        audio_pad = b'\x00' * pad
        # 容差 0.25s：录音比整格短几十毫秒是常态，不该显示成“少一格”
        ncell = (audio_alen + AUDIO_HZ // 2) // CELL_BYTES
        print("-" * 64)
        print(f"  音频 {os.path.basename(audio_path)}: {dur:.3f}s / {nframes} 帧 / "
              f"{audio_alen} 字节")
        print(f"       整格数 = {ncell}（每格 {CELL_SECONDS}s = {CELL_BYTES} 字节 "
              f"= {CELL_SECTORS} 扇区）")
        # 差一点点不算问题（末尾补静音就行），差一格以上才值得提醒
        need = n * CELL_BYTES
        if audio_alen < need:
            short_ms = (need - audio_alen) / float(AUDIO_HZ * 2) * 1000.0
            if short_ms > 50:
                print(f"[警告] 音频比 {n} 整格短 {short_ms:.0f}ms，"
                      f"第 {ncell+1} 张图起语音会对不上（读到末尾会回卷）。")
            else:
                print(f"       比 {n} 整格短 {short_ms:.1f}ms（末格末尾补静音，听感无影响）")
        elif audio_alen > need:
            print(f"       比 {n} 整格长 {audio_alen - need} 字节，多出来的部分不会被播到")

    audio_sectors = (audio_alen + SECTOR - 1) // SECTOR if audio_alen else 0

    # ---------------- 头部（512 字节）
    def u16(v):
        return int(v).to_bytes(2, 'little')

    def u32(v):
        return int(v).to_bytes(4, 'little')

    header = bytearray(SECTOR)
    header[0x00:0x04] = MAGIC
    header[0x04:0x06] = u16(VERSION)
    header[0x06:0x08] = u16(n)
    header[0x08:0x0A] = u16(IMG_W)
    header[0x0A:0x0C] = u16(IMG_H)
    header[0x0C]      = BYTES_PER_PIX
    header[0x0D]      = CK_MODE

    # ★★ 音频起始扇区也必须是【绝对扇区号】（和索引里的 pixel_sector 同理）。
    #    FPGA 侧 ebm_reader.v 解析完直接把它交给 audio_stream，后者拿它当
    #    SD 卡绝对扇区去读；写成相对值会读到图片区里去（声音全是噪声）。
    audio_start = (lba + 2 + n * PIX_SECTORS) if audio_alen else 0
    header[0x10:0x14] = u32(audio_start)
    header[0x14:0x18] = u32(audio_alen)

    # ---------------- 索引表（512 字节）
    # ★★ 极重要：EBM1 格式规定 pixel_sector = 【绝对扇区号】，不是"相对容器起点"。
    #    FPGA 侧 ebm_reader.v 直接把它当 SD 卡绝对扇区去读（见该文件头部的格式说明），
    #    仿真 testbench 也是按绝对扇区造的索引。
    #    2026-10-12 修正：原代码写的是 2 + idx*PIX_SECTORS（相对值），
    #    上板后 FPGA 会跑到绝对扇区 2、5402、… 去读像素（那是 FAT32 数据区），
    #    读到的全是垃圾 —— 而且这个错仿真永远抓不到（tb 自己造的是绝对扇区）。
    index = bytearray(SECTOR)
    for idx in range(n):
        base = idx * 16
        start_sector = lba + 2 + idx * PIX_SECTORS     # 绝对扇区号 = 容器起点 + 头 + 索引 + 第 idx 张
        s1, s2 = checks[idx]
        index[base + 0]  = idx                    # id
        index[base + 1]  = 0                      # flags
        index[base + 2]  = 0
        index[base + 3]  = 0
        index[base + 4:base + 8]   = u32(start_sector)
        index[base + 8:base + 12]  = u32(PIX_BYTES)
        # 校验值小端存放：低字节 = s1，高字节 = s2（FPGA 侧读成 {s2, s1}）
        index[base + 12]           = s1
        index[base + 13]           = s2
        index[base + 14]           = 0
        index[base + 15]           = 0

    # ---------------- 自检：索引里必须写绝对扇区，且正好落在本容器范围内
    # 这条自检就是为了防止上面那个"相对/绝对"的坑再次出现（它仿真抓不到）。
    for idx in range(n):
        base = idx * 16
        got = int.from_bytes(index[base + 4:base + 8], 'little')
        want = lba + 2 + idx * PIX_SECTORS
        if got != want:
            raise SystemExit(f"[错误] 索引第 {idx} 项的起始扇区 = {got}，应为绝对扇区 {want}。"
                             f"（EBM1 存的是绝对扇区号，不是相对容器的偏移）")

    container = (bytes(header) + bytes(index) + b''.join(pixels)
                 + pcm + audio_pad)

    total_sectors = 2 + n * PIX_SECTORS + audio_sectors
    print("-" * 64)
    print(f"容器大小      : {len(container)} 字节 = {len(container)//SECTOR} 个扇区")
    print(f"写入起始扇区  : {lba}  （= 偏移 {lba*SECTOR/1024/1024:.1f} MiB）")
    print(f"占用扇区范围  : {lba} .. {lba + total_sectors - 1}")
    print(f"各图起始扇区  : " + ", ".join(f"图{i+1}={lba + 2 + i * PIX_SECTORS}" for i in range(n)))
    print(f"                （以上必须是绝对扇区号，与 ebm_reader.v 的 CONTAINER_LBA 配套）")
    if audio_alen:
        print(f"音频区        : 起始扇区 {audio_start} .. {audio_start + audio_sectors - 1}"
              f"（{audio_sectors} 扇区，{audio_alen} 字节 + {len(audio_pad)} 字节对齐填充）")
        print(f"每格语音起点  : " + ", ".join(str(audio_start + i * CELL_SECTORS) for i in range(n)))
    else:
        print(f"音频区        : 无（容器里只有图片）")
    return container, total_sectors


def main():
    ap = argparse.ArgumentParser(
        description="把图片（+ 音频）打包成 FPGA 用的 EBM2 私有容器",
        formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('-i', '--input', nargs='+', required=True,
                    help='图片文件或文件夹（可多个，按给定顺序/id 排列）')
    ap.add_argument('-o', '--output', default='container.bin',
                    help='输出的容器文件（默认 container.bin）')
    ap.add_argument('--lba', type=int, default=DEFAULT_LBA,
                    help=f'容器在 SD 卡上的起始扇区（默认 {DEFAULT_LBA}，'
                         f'必须和 ebm_reader.v 的 CONTAINER_LBA 一致）')
    ap.add_argument('--mode', choices=['fit', 'stretch', 'pad'], default='fit',
                    help='图片适配方式：fit=裁剪铺满(默认) / stretch=拉伸 / pad=加黑边')
    ap.add_argument('--audio', default=None,
                    help=f'音频 WAV（48kHz/16bit/单声道）。默认用 {os.path.relpath(DEFAULT_AUDIO)}，'
                         f'文件不存在则只打包图片')
    ap.add_argument('--no-audio', action='store_true',
                    help='明确不要音频（生成 EBM1 兼容的老式容器）')
    ap.add_argument('--write', metavar='DEVICE', default=None,
                    help='打包完直接写到物理驱动器，例如 \\\\.\\PhysicalDrive2（危险！）')
    ap.add_argument('--yes', action='store_true',
                    help='配合 --write 使用，跳过二次确认')
    args = ap.parse_args()

    # 决定音频来源
    audio_path = None
    if not args.no_audio:
        if args.audio:
            if not os.path.isfile(args.audio):
                raise SystemExit(f"[错误] 找不到音频文件：{args.audio}")
            audio_path = args.audio
        elif os.path.isfile(DEFAULT_AUDIO):
            audio_path = DEFAULT_AUDIO
            print(f"[信息] 使用默认音频：{os.path.normpath(DEFAULT_AUDIO)}")
        else:
            print(f"[信息] 没找到默认音频，本次只打包图片")

    files = collect_inputs(args.input)
    result = build_container(files, args.lba, args.mode, audio_path)
    if result is None:
        sys.exit(1)
    container, total_sectors = result

    with open(args.output, 'wb') as f:
        f.write(container)
    print(f"已生成：{os.path.abspath(args.output)}")

    if args.write:
        # 延迟导入，避免普通用户为了打包还得看这段警告
        sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
        from write_container import write_raw
        write_raw(args.write, container, args.lba, assume_yes=args.yes)
    else:
        print("\n下一步：把 container.bin 写到 SD 卡上。两种办法（任选一种）")
        print("  ① 图形工具（推荐新手）：用 HxD / WinHex 打开物理磁盘，"
              f"跳到扇区 {args.lba}，把 container.bin 内容粘贴进去。")
        print("  ② 命令行：python write_container.py <SD卡物理驱动器> "
              f"--input {args.output} --lba {args.lba}")


if __name__ == '__main__':
    main()
