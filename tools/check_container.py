# -*- coding: utf-8 -*-
"""
check_container.py —— 容器自检（上板黑屏时第一步跑它）

检查三件事：
  1. container.bin 是否存在、大小是否 = 1024 + 张数 x 2764800
  2. 头部 magic/版本/分辨率/位深 是否正确
  3. 每条索引的扇区号是否是【绝对扇区】、字节数是否正确、
     并抽检每张图的像素数据（是否整块同色 = 黑图/纯色图）

用法（工程根目录下）：
    python tools/check_container.py
    python tools/check_container.py --img assets/img     # 顺便看源图片
"""
import argparse
import os
import struct
import sys

DEFAULT_LBA = 1048576
PIX_BYTES   = 1280 * 720 * 3
HDR_BYTES   = 512
IDX_OFF     = 512
IDX_MAX     = 32
ENT_BYTES   = 16

MAGIC_V1 = b"EBM1"      # 老容器：只有图片
MAGIC_V2 = b"EBM2"      # 新容器：图片 + 音频
CELL_BYTES   = 960000   # 一格 10s 语音 = 48000*2*10
CELL_SECTORS = CELL_BYTES // 512   # 1875


def log(msg=""):
    sys.stdout.write(str(msg) + "\n")


def check_container(path, lba):
    ok = True
    if not os.path.exists(path):
        log("[FAIL] 找不到 %s —— 先跑 4_write_card_auto.bat 生成它" % path)
        return False
    size = os.path.getsize(path)
    if size < HDR_BYTES + IDX_OFF:
        log("[FAIL] 文件太小：%d 字节" % size)
        return False

    with open(path, "rb") as f:
        hdr = f.read(1024)

    magic = hdr[0:4]
    ver, n, w, h = struct.unpack("<HHHH", hdr[4:12])
    bpp = hdr[0x0C]
    ckm = hdr[0x0D]

    log("=" * 66)
    log("  容器自检  %s" % path)
    log("=" * 66)
    log("  文件大小      : %d 字节 (%.2f MiB)" % (size, size / 1024.0 / 1024))
    log("  magic         : %r" % magic)
    log("  版本 / 张数   : %d / %d" % (ver, n))
    log("  分辨率        : %d x %d   bpp=%d  ckm=%d" % (w, h, bpp, ckm))
    log("  起始扇区(LBA) : %d  (%.0f MiB 偏移)" % (lba, lba * 512 / 1024.0 / 1024))

    if magic not in (MAGIC_V1, MAGIC_V2):
        log("  [FAIL] magic 不是 EBM1/EBM2 —— 这个文件不是容器")
        return False
    if ver not in (1, 2):
        log("  [FAIL] 版本 %d 不是 1/2" % ver); ok = False

    # ---- EBM2 音频区（0x10 起始绝对扇区 / 0x14 字节数）
    asec, alen = struct.unpack("<II", hdr[0x10:0x18])
    audio_sectors = (alen + 511) // 512 if alen else 0
    if alen:
        # 容差 0.25s：录音比整格短几十毫秒是常态，不该显示成“少一格”
        ncell = (alen + 48000) // CELL_BYTES
        log("  音频区        : 起始扇区 %d, %d 字节 (%.3f 秒), %d 扇区, 约 %d 个 10s 格"
            % (asec, alen, alen / 96000.0, audio_sectors, ncell))
        exp_asec = lba + 2 + n * (PIX_BYTES // 512)
        if asec != exp_asec:
            log("  [FAIL] 音频起始扇区 %d，应为 %d（必须是绝对扇区号）" % (asec, exp_asec))
            ok = False
    else:
        log("  音频区        : 无（EBM1 或 alen=0，FPGA 侧会静音）")
    if (w, h, bpp) != (1280, 720, 3):
        log("  [FAIL] 分辨率/位深不对，ebm_reader 会报 E_FORMAT(0x0004)"); ok = False
    if n == 0 or n > 8:
        log("  [FAIL] 张数 %d 超出 1..8 —— ebm_reader 会报 E_COUNT(0x0008)" % n); ok = False

    expect_size = 1024 + n * PIX_BYTES + audio_sectors * 512
    if size != expect_size:
        log("  [WARN] 期望大小 %d，实际 %d" % (expect_size, size))

    log("")
    log("  #    扇区       期望(绝对扇区)   字节数     数据抽检")
    log("  " + "-" * 62)
    fh = open(path, "rb")
    for i in range(n):
        o = IDX_OFF + i * ENT_BYTES
        eid = hdr[o]
        sec, nbytes, ck = struct.unpack("<III", hdr[o + 4:o + 16])
        exp = lba + 2 + i * (PIX_BYTES // 512)
        tag_ok = "OK" if sec == exp else "错(期望%d)" % exp
        len_ok = "OK" if nbytes == PIX_BYTES else "错(期望%d)" % PIX_BYTES

        # 抽检像素：取第 360 行中间 64 个像素
        sample = ""
        try:
            fh.seek(1024 + i * PIX_BYTES + (360 * 1280 + 600) * 3)
            chunk = fh.read(64 * 3)
            if len(chunk) == 192:
                px = [chunk[j:j + 3] for j in range(0, 192, 3)]
                uniq = len(set(px))
                sample = "64px 里 %d 种颜色%s" % (
                    uniq, "" if uniq > 1 else "  << 疑似纯色/黑图")
            else:
                sample = "读不到数据"
        except Exception as e:
            sample = "抽检异常 %s" % e

        if sec != exp or nbytes != PIX_BYTES:
            ok = False
        log("  %-3d  %-11d %-15s %-10s %s" % (i, sec, tag_ok, len_ok, sample))
    fh.close()

    log("")
    if ok:
        log("  结论：容器结构完全正确 ✓")
        log("  若上板仍黑屏 → 问题在【卡没写进去】或【SD 卡接触/容量】，"
            "不是容器的问题。")
        log("  验证办法：重新双击 scripts\\4_write_card_auto.bat，"
            "看最后是否出现『写入完成』。")
    else:
        log("  结论：容器有问题 ✗ —— 重新跑 scripts\\4_write_card_auto.bat 重建")
    return ok


def show_images(d):
    log("")
    log("=" * 66)
    log("  源图片  %s" % d)
    log("=" * 66)
    if not os.path.isdir(d):
        log("  [FAIL] 目录不存在")
        return
    exts = (".jpg", ".jpeg", ".png", ".bmp", ".gif", ".webp")
    files = sorted([f for f in os.listdir(d)
                    if f.lower().endswith(exts)])
    if not files:
        log("  [FAIL] 一张图都没有")
        return
    if len(files) > 8:
        log("  [WARN] 有 %d 张，只会用前 8 张" % len(files))
    for i, f in enumerate(files[:8]):
        p = os.path.join(d, f)
        log("  %-2d  %-28s %8.1f KB" % (i + 1, f, os.path.getsize(p) / 1024.0))
    log("")
    log("  第 1 张同时作为【应急画面】，建议放最关键的那张公告图")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("-c", "--container", default="container.bin")
    ap.add_argument("--lba", type=int, default=DEFAULT_LBA)
    ap.add_argument("--img", default=None, help="顺便列出源图片目录")
    a = ap.parse_args()
    ok = check_container(a.container, a.lba)
    if a.img:
        show_images(a.img)
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
