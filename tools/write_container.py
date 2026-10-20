#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
write_container.py —— 把 container.bin 按扇区偏移直接写进 SD 卡。

!!! 重要提醒 !!!
    这个脚本会绕过 Windows 文件系统，直接往物理磁盘的指定扇区写数据。
    写错盘 = 那个盘上的数据全部损坏，而且**无法恢复**。
    所以：
      · 一定要先在 Windows 的"磁盘管理"里确认 SD 卡是哪一个 PhysicalDriveN；
      · 脚本会先打印出设备信息、写多少字节、写到什么位置，请你逐字核对；
      · 默认需要手动输入 YES 才真正开写。

    如果你不想承担这个风险，可以不使用本脚本，改用图形化工具：
    用 HxD / WinHex 打开物理磁盘 → 跳到第 --lba 个扇区 → 把 container.bin
    的内容粘贴进去 → 保存。效果完全一样。

Windows 上需要"以管理员身份运行"。

v2 改动（2026-10-12）
    · 写入前自动「锁定 + 卸载」目标盘上的卷 —— 这是上次写入失败里
      最常见的 WinError 5（拒绝访问，卷被 Windows 占用）的解药。
    · 全过程写入 write_card.log，失败时把 Windows 错误码翻译成人话。
    · 卸载过的卷不会立刻回来，写完请**重新插拔一次读卡器**。

用法
    # 先看看有哪些物理盘（不会写任何东西）
    python write_container.py --list

    # 写入（会二次确认）
    python write_container.py \\\\.\\PhysicalDrive2 --input container.bin --lba 1048576

    # 也支持从 container.img 直接写入，速度更快（一次性顺序写）
"""

import os
import re
import sys
import time
import ctypes
import argparse
import subprocess
from ctypes import wintypes

SECTOR = 512
LOG_NAME = 'write_card.log'

GENERIC_READ = 0x80000000
GENERIC_WRITE = 0x40000000
OPEN_EXISTING = 3
FILE_SHARE_READ = 0x00000001
FILE_SHARE_WRITE = 0x00000002

FSCTL_LOCK_VOLUME = 0x00090018
FSCTL_UNLOCK_VOLUME = 0x0009001C
FSCTL_DISMOUNT_VOLUME = 0x00090020

INVALID_HANDLE_VALUE = ctypes.c_void_p(-1).value

_LOG_PATH = None


def log(msg=''):
    """同时打印到屏幕和 write_card.log。"""
    print(msg)
    if _LOG_PATH:
        try:
            with open(_LOG_PATH, 'a', encoding='utf-8') as f:
                f.write(msg + '\n')
        except Exception:
            pass


def init_log():
    global _LOG_PATH
    base = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    _LOG_PATH = os.path.join(base, LOG_NAME)
    try:
        with open(_LOG_PATH, 'w', encoding='utf-8') as f:
            f.write('write_card.log  开始于 %s\n' % time.strftime('%Y-%m-%d %H:%M:%S'))
            f.write('Python: %s  (%s)\n' % (sys.version.split()[0], sys.executable))
    except Exception:
        _LOG_PATH = None


def is_windows():
    return os.name == 'nt'


def list_physical_drives():
    """在 Windows 上列出所有物理驱动器及其容量，帮用户确认盘号。"""
    if not is_windows():
        log("这个功能只在 Windows 上有意义。Linux 下请用 lsblk。")
        return

    log("=" * 70)
    log("当前机器上的物理驱动器（请用'磁盘管理'里的容量再核对一遍）")
    log("=" * 70)
    try:
        cmd = ['powershell', '-NoProfile', '-Command',
               "Get-Disk | Select-Object Number,FriendlyName,@{"
               "n='SizeGB';e={[math]::Round($_.Size/1GB,1)}},PartitionStyle "
               "| Format-Table -AutoSize | Out-String -Width 200"]
        out = subprocess.check_output(cmd, stderr=subprocess.STDOUT)
        log(out.decode('utf-8', errors='replace'))
        log("提示：SD 卡一般是 PartitionStyle 为 MBR 且容量和你手上那张一致的那个。")
        log("      PhysicalDrive 号就是上表的 Number 列。")
    except Exception as e:
        log("[警告] 自动查询失败（%s）。请手动打开'磁盘管理'查看。" % e)
    log("=" * 70)


def disk_number_from_device(device):
    m = re.search(r'PhysicalDrive\s*(\d+)', device or '', re.I)
    return int(m.group(1)) if m else None


def volume_letters(disk_no):
    """列出某个物理盘上所有已挂载的盘符，例如 ['F']。只读操作。"""
    if not is_windows():
        return []
    cmd = ['powershell', '-NoProfile', '-Command',
           "(Get-Partition -DiskNumber %d -ErrorAction SilentlyContinue | "
           "Where-Object {$_.DriveLetter} | "
           "Select-Object -ExpandProperty DriveLetter) -join ','" % disk_no]
    try:
        out = subprocess.check_output(cmd, stderr=subprocess.STDOUT)
        text = out.decode('utf-8', errors='replace').strip()
    except Exception:
        return []
    return [c.strip() for c in text.split(',') if c.strip()]


def _kernel32():
    k32 = ctypes.WinDLL('kernel32', use_last_error=True)
    k32.CreateFileW.restype = wintypes.HANDLE
    k32.CreateFileW.argtypes = [wintypes.LPCWSTR, wintypes.DWORD, wintypes.DWORD,
                                wintypes.LPVOID, wintypes.DWORD, wintypes.DWORD,
                                wintypes.HANDLE]
    k32.DeviceIoControl.restype = wintypes.BOOL
    k32.DeviceIoControl.argtypes = [wintypes.HANDLE, wintypes.DWORD, wintypes.LPVOID,
                                    wintypes.DWORD, wintypes.LPVOID, wintypes.DWORD,
                                    ctypes.POINTER(wintypes.DWORD), wintypes.LPVOID]
    return k32


def lock_and_dismount(disk_no):
    """锁定并卸载目标盘上所有卷，返回需要保持打开的句柄列表。

    这是解决"写入物理盘被拒绝（WinError 5）"的标准做法：
    Windows 会把已挂载的卷当成'正在使用'，Lock + Dismount 之后
    物理盘才允许被独占写入。
    """
    handles = []
    if not is_windows() or disk_no is None:
        return handles

    letters = volume_letters(disk_no)
    if not letters:
        log('  · 这个盘上没有已挂载的卷（或本身就是裸盘），无需卸载。')
        return handles

    k32 = _kernel32()
    for letter in letters:
        path = '\\\\.\\%s:' % letter
        h = k32.CreateFileW(path, GENERIC_READ | GENERIC_WRITE,
                            FILE_SHARE_READ | FILE_SHARE_WRITE, None,
                            OPEN_EXISTING, 0, None)
        if not h or h == INVALID_HANDLE_VALUE:
            log('  · 卷 %s: 打开失败（WinError %d），跳过'
                % (letter, ctypes.get_last_error()))
            continue

        n = wintypes.DWORD(0)
        if not k32.DeviceIoControl(h, FSCTL_LOCK_VOLUME, None, 0, None, 0,
                                   ctypes.byref(n), None):
            log('  · 卷 %s: 锁定失败（WinError %d）—— 有程序正占用它'
                % (letter, ctypes.get_last_error()))
            k32.CloseHandle(h)
            continue

        if not k32.DeviceIoControl(h, FSCTL_DISMOUNT_VOLUME, None, 0, None, 0,
                                   ctypes.byref(n), None):
            log('  · 卷 %s: 卸载失败（WinError %d）'
                % (letter, ctypes.get_last_error()))
            k32.CloseHandle(h)
            continue

        log('  · 卷 %s: 已锁定并卸载 OK' % letter)
        handles.append(h)

    return handles


def release_volumes(handles):
    if not is_windows() or not handles:
        return
    k32 = _kernel32()
    for h in handles:
        n = wintypes.DWORD(0)
        try:
            k32.DeviceIoControl(h, FSCTL_UNLOCK_VOLUME, None, 0, None, 0,
                                ctypes.byref(n), None)
        except Exception:
            pass
        try:
            k32.CloseHandle(h)
        except Exception:
            pass


def explain_winerror(code):
    table = {
        5: ('拒绝访问。三种可能：'
            '① 没用管理员权限 —— bat 弹出的 UAC 要选"是"；'
            '② 有程序正占用这张卡 —— 关掉所有打开 F: 的资源管理器窗口、暂停杀毒软件实时防护；'
            '③ 卡带写保护开关，拨到了 Lock。'),
        32: '文件被其他进程占用。关掉所有打开这张卡的窗口和软件再重试。',
        19: '磁盘写保护。卡侧面的写保护开关拨到 Lock 了，或读卡器带写保护。',
        1: '函数不正确。多半仍是权限或卷占用问题，重插一次卡再试。',
        87: '参数错误。扇区偏移超出设备容量 —— 确认卡插好、容量对不对。',
        21: '设备未就绪。读卡器可能松了，重新插一次卡。',
    }
    if code in table:
        return table[code]
    return '未知错误，请把 write_card.log 的内容发给开发者。'


def write_raw(device, data, lba, assume_yes=False):
    """把 data 写到 device 的第 lba 个扇区开始的位置。"""
    if not is_windows():
        log("[提示] 非 Windows 平台，请直接用 dd：")
        log("       sudo dd if=<容器文件> of=%s bs=%d seek=%d conv=notrunc"
            % (device, SECTOR, lba))
        return False

    log("=" * 70)
    log("即将执行【原始扇区写入】，请逐行核对下面的信息：")
    log("=" * 70)
    log("  目标物理驱动器 : %s" % device)
    log("  写入起始扇区   : %d  （偏移 %.1f MiB）" % (lba, lba * SECTOR / 1024 / 1024))
    log("  写入字节数     : %d 字节 = %d 个扇区" % (len(data), len(data) // SECTOR))
    log("  写入扇区范围   : %d .. %d" % (lba, lba + len(data) // SECTOR - 1))
    log("=" * 70)
    log("!! 这一步会直接覆盖目标磁盘上的原有数据，且不可撤销！")

    if not assume_yes:
        try:
            ans = input("确认无误请输入大写的 YES 继续，其它任意键取消：").strip()
        except EOFError:
            ans = ''
        if ans != 'YES':
            log("已取消，没有任何数据被写入。（注意：必须输入 大写 的 YES）")
            return False

    disk_no = disk_number_from_device(device)
    handles = []
    if disk_no is not None:
        log("")
        log("[权限准备] 正在锁定并卸载该盘上的卷 —— 这是上次'写入失败'最常见的解药 ...")
        handles = lock_and_dismount(disk_no)
        if not handles:
            log("  · 没有任何卷被卸载。如果接下来仍报'拒绝访问'，请：")
            log("      1) 关掉所有打开这张卡的资源管理器窗口 / 看图软件；")
            log("      2) 暂停杀毒软件的实时防护；")
            log("      3) 再重跑一次 4_write_card.bat。")

    try:
        with open(device, 'r+b') as f:
            f.seek(lba * SECTOR)
            f.write(data)
            f.flush()
            try:
                os.fsync(f.fileno())
            except Exception:
                pass
        log("")
        log("写入完成 OK —— 数据已经写到 %s 的第 %d 扇区。" % (device, lba))
        log("  接下来：")
        log("    1. 重新插拔一次读卡器（让 Windows 重新识别这张卡）；")
        log("    2. 把卡插到 FPGA 开发板背面的 TF 卡槽；")
        log("    3. 在 TD 的 BitWriter 里烧 billboard_Runs\\phy_1\\billboard.bit。")
        return True
    except PermissionError as e:
        log("")
        log("  [错误] 权限不足：%s" % e)
        log("  → 请确认 bat 弹出的 UAC 里点的是'是'，然后重跑。")
        return False
    except OSError as e:
        we = getattr(e, 'winerror', None)
        log("")
        log("  [错误] 写入失败：%s" % e)
        log("  Windows 错误码 : %s" % we)
        log("  人话解释：%s" % explain_winerror(we))
        return False
    finally:
        release_volumes(handles)


def main():
    init_log()

    ap = argparse.ArgumentParser(description="把 EBM1 容器按扇区写进 SD 卡")
    ap.add_argument('device', nargs='?', help=r'物理驱动器，例如 \\.\PhysicalDrive2')
    ap.add_argument('--input', '-i', default='container.bin', help='容器文件')
    ap.add_argument('--lba', type=int, default=1048576,
                    help='起始扇区，必须和 ebm_reader.v 的 CONTAINER_LBA 一致')
    ap.add_argument('--list', action='store_true', help='只列出物理驱动器，不写任何东西')
    ap.add_argument('--yes', action='store_true', help='跳过手动确认（危险）')
    args = ap.parse_args()

    if args.list:
        list_physical_drives()
        return

    if not args.device:
        ap.print_help()
        log("\n提示：先用 --list 看看你的 SD 卡是哪一个 PhysicalDriveN。")
        sys.exit(1)

    if not os.path.isfile(args.input):
        log("[错误] 找不到容器文件：%s" % args.input)
        log("       请先运行 gen_container.py 生成它。")
        sys.exit(1)

    with open(args.input, 'rb') as f:
        data = f.read()

    if len(data) % SECTOR != 0:
        log("[错误] 容器文件大小 %d 不是 512 的整数倍，"
            "说明文件不完整，请重新生成。" % len(data))
        sys.exit(1)

    ok = write_raw(args.device, data, args.lba, assume_yes=args.yes)
    if not ok:
        log("")
        log("日志已保存到：%s" % _LOG_PATH)
    sys.exit(0 if ok else 2)


if __name__ == '__main__':
    main()
