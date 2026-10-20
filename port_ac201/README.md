# port_ac201 —— 板级迁移记录（HX4S20C → AC201）

> **★ 2026-10-18：移植已全部并入主工程，本目录只保留“记录 + 存档”。**
> 正常使用主工程时**不需要**进入这个目录。

## 一、现在的代码在哪（都在主工程里）

| 内容 | 位置 | 说明 |
|---|---|---|
| 顶层（AC201 版） | `src/hdl/top_billboard.v` | 只改端口层 4 处，内部 33 个模块逐字未动 |
| 引脚约束（AC201） | `src/constraints/pin.adc` | 全部来自官方管脚表 + 官方 `IO.adc` |
| 数码管 595 驱动 | `src/hdl/seg_595.v` | 14 根直驱 → 3 根串行 |
| 595 的 testbench | `sim/tb_seg_595.v` | 已并入 `run_iverilog.sh`（第 ⑲ 项） |
| 点灯验证工程 | `port_ac201/src/led_test_top.v` | 只有 clk/rst_n/led 三个端口，用来验证引脚表 |
| 旧版存档 | `port_ac201/legacy_hx4s20c/` | HX4S20C 版顶层 / 引脚 / bit，**仅备份，不参与编译** |

## 二、验证结果（2026-10-18）

```bash
cd /c/FPGA/billboard_prj/sim
bash run_iverilog.sh
```

```
PASS   top_elaborate   零错误零警告     ← AC201 版顶层 + 全部模块
PASS   wall_compile    零警告
... 19 个 testbench 全 PASS ...
  通过 21 项，失败 0 项          （313 条断言）
```

其中新增的第 ⑲ 项：

```
### RESULT tb_seg_595 : PASS (16/16) ###
```

综合（TD 命令行）：见 `docs/进度对照表.md` 与 `build_logs/`。

## 三、AC201 版顶层改了什么

| # | 改动 | 原因 |
|---|---|---|
| 1 | `key3`/`key4` 端口 → `sw[1:0]` | AC201 只有 3 个按键（KEY0/1/2），第 3/4 个功能改用拨码；拨一下 = 一次按键事件 |
| 2 | `seg_sel[5:0]+seg_data[7:0]` → `seg_ser/seg_sclk/seg_rclk` | AC201 数码管是 2 片 74HC595 串行；片内 `seg_scan`/`seg_status` 原样保留 |
| 3 | `assign led = ~led_on;` | AC201 的 LED **低电平点亮** |
| 4 | 删 `HDMI_DDC_SCL/SDA`，核的 DDC 悬空 | AC201 底板未把 DDC 接到 FPGA（官方 `IO.adc` 无此引脚） |

**零改动**：两个 PLL（AC201 晶振同为 50MHz / K14）、720p 时序、片内 SDRAM、
SD 卡 SPI 链路、音频链路、调度器、OSD、转场……全部 33 个内部模块。

## 四、上板步骤（每步有独立判据）

| 步 | 做什么 | 成功判据 |
|---|---|---|
| 1 | 只烧 `led_test_top`（clk/rst_n/led 三根） | LED 约 1 秒一闪 = 引脚表对、晶振 50MHz 对 |
| 2 | 烧完整 `billboard.bit` | **LED[3] 心跳闪** = 芯片配置成功 |
| 3 | 插 TF 卡（写好 `container.bin`） | `led[0]` 亮 = SD 初始化完成 |
| 4 | 接 HDMI 显示器 | 出 1280×720 画面 + 底部滚动字幕 |
| 5 | 按键/拨码 | K1 切图、K2 自动开关、SW0 周期、SW1 应急 |

## 五、风险清单（上板时按顺序排查）

- **R1 已排除**：晶振 50MHz（K14），PLL 零改动。
- **R2（低）**：HDMI 核 DDC 悬空。核按编译期固定时序输出（`HTOTAL=1650` 等），
  `edid_read` 只是附加功能，读不到不影响 TMDS。若真出现"灯亮、数码管正常、屏幕无信号"，
  再考虑固定 EDID 方案。
- **R3（中）**：数码管位序可能左右镜像。现象是 6 位数字顺序整体颠倒。
  改顶层 `seg_595` 例化的 `.seg_sel_n ({2'b11, seg_sel_w})` → `{seg_sel_w, 2'b11}` 即可。
- **R4（低）**：拨码极性 —— 拨动方向与"按下"的对应关系上板一次即知，只影响直觉。
- **R5**：TMDS 必须用 **`LVDS33_E`**（官方原文），不要沿用 HX4S20C 的 `LVDS33`。
- **R6**：`pin.adc` 的注释必须用 `#`，**不能用 `//`** —— TD 的 ADC 解析器会把 `//` 当命令报错
  （2026-10-18 实测踩过：`USR-8168 ERROR ... is not a valid ADC command`）。

## 六、官方资料在哪

`C:\FPGA\ac201_docs\`（来自 fpga.cn 帖子 30478）：

- `AC601-EG4S20_schematic.pdf` —— 原理图
- `AC201_pin_table.xlsx` —— 管脚信息表（**引脚号的权威来源**）
- `board_test/AC201_AL_board_test/` —— 官方例程：
  - `IO.adc` —— 官方引脚约束（IOSTANDARD / PULLTYPE 照抄它）
  - `src/HC595_Driver.v` / `src/HEX8.v` —— 官方 595 驱动与段码表（帧顺序、极性的依据）
  - `*.bit` —— 官方现成比特流，可用来做 A/B 对照
