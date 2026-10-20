# 安路 FPGA 全逻辑应急广告牌（2026 全国大学生嵌入式芯片与系统设计竞赛·安路赛题一）

纯 FPGA 逻辑（无处理器、无软核）实现的多媒体应急广告牌：**TF 卡读取 8 张 BMP 图片与 80 秒语音，HDMI 1280×720@60 输出画面、伴音与底部滚动字幕**，支持按键/拨码交互与自动轮播。

- 目标平台：米联客 AC201 底板 + EG4S20BG256 核心板（Anlogic Eagle EG4S20，50 MHz 晶振）
- 开发工具：Anlogic TD 6.2.1（综合/布线/烧录）+ iverilog 12.0（24 项回归仿真全绿）
- 设计语言：Verilog（自写 RTL 33 个模块，另含官方加密 IP：SDRAM/HDMI/PLL/FIFO）

## 功能特性

| 功能 | 说明 |
|---|---|
| 图片轮播 | TF 卡私有 EBM2 容器格式，最多 8 张 1280×720 BMP，自动轮播 + 按键切换 |
| 应急语音 | 80 秒 48 kHz/16 bit PCM 流式播放，与图片逐张对应（每张 10 秒），换图即换解说 |
| 滚动字幕 | 点阵字幕 ROM + OSD 叠加，画面底部循环滚动安全提示 |
| HDMI 输出 | 1280×720@60，TMDS 编码由自写 lane_lvds_10_1 完成，音频经 ACR 时钟再生 |
| 容错 | 上电 4 s 未就绪自动输出八段彩条；SD 卡初始化失败有状态码数码管提示 |
| 状态显示 | 74HC595 串行驱动数码管，实时显示系统状态位（永不出现数字 9 的误读） |

## 目录结构

```
billboard/
├── billboard.al          # TD 6.2.1 工程文件（顶层 top_billboard）
├── src/hdl/              # 自写 RTL（top_billboard / ebm_reader / audio_stream / sd_arbiter ...）
├── src/support/          # 官方例程支持模块（SD 卡协议栈 / HDMI 核封装 / 视频时序）
├── src/ip/               # TD 生成 IP（PLL×3 / SDRAM / FIFO）
├── src/constraints/pin.adc  # AC201 引脚约束
├── sim/                  # iverilog 回归：24 项测试（run_iverilog.sh）
├── scripts/              # 一键脚本（写卡 / 清理 / 打开工程）
├── tools/                # Python 工具（gen_container.py 生成 TF 卡容器 / check_container.py 校验）
├── assets/               # 素材：8 张图片 + 80 秒语音 voice80.wav
├── docs/                 # 设计文档、操作手册、音频方案说明
├── bit/                  # 可直接烧录的 .bit（1=彩条基准，3=出图+字幕版本）
└── port_ac201/           # AC201 移植审计记录 + HDMI 测试工程
```

## 快速复现

1. **仿真**：`cd sim && ./run_iverilog.sh`（需 Git Bash，iverilog 12.0；末行 `通过 24 项，失败 0 项` 即通过）
2. **生成 TF 卡容器**：`py -3 tools/gen_container.py`，图片放 `assets/img/`（≤8 张）、语音放 `assets/audio/voice80.wav`
3. **写卡**：管理员运行 `scripts/4_write_card_auto.bat`（写入物理盘 LBA 1048576，即 512 MiB 偏移）
4. **综合布线**：TD 6.2.1 打开 `billboard.al`，或命令行在 `billboard_Runs/syn_1` 下运行 `td_commands_prompt.exe <TD>/doc/scripts/DefaultFlow.tcl`
5. **烧录**：BitWriter 选择 `bit/` 下 .bit，`PROGRAM_FLASH` 后**断电重新上电**（烧 Flash 不会重配 FPGA）

## 仿真与上板结果

- iverilog 回归：**24 项测试 / 约 400 条断言，全部通过**（含 SD 协议栈全链路、EBM2 解析、仲裁、音频流、视频时序等）
- 资源占用：LUT 4947/19600（25.2%）、BRAM 30/64、PLL 3/4
- 时序：Setup WNS **+7.551 ns**，Hold WNS +40 ps，0 失效路径（EG4S20BG256-6）
- 上板：HDMI 1280×720 稳定出图 + 滚动字幕 + 伴音，7×24 小时连续运行无死机

## 关键设计点（踩坑记录）

- **TMDS 时钟通道防优化**：HDMI 核输出的时钟图案是常量 `10'b1111100000`，工程规模变大后整条串行化 lane 会被综合器常量折叠（只剩 3 条 lane，现象为全屏黑）。顶层用计数器在 `1111100000`/`0000011111` 间交替，两图案串行化后同频同形仅差 180° 相位，合法且不可折叠。
- **复位三条铁律**：`rst_wait` 必须有上电初值；放行条件不能只依赖按键；彩条能出图 ≠ AXIS 数据通路正常。
- **SD 读通道仲裁**：音频按 FIFO 水位抢总线，**抢到就补满再还**（一次约 8 扇区），总线占用仅 ~6%；只在扇区边界换主，`end` 拍用旧 grant 门控避免串扰。
- 详细记录见 `docs/`。

## 许可

竞赛提交用途。代码基于安路官方例程（SD 卡 / HDMI / SDRAM 驱动）二次开发，版权归参赛队所有。
