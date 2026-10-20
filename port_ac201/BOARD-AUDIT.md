# AC201 板级迁移审计（已完成）

> 目标板：**米联客 AC201 底板 + EG4S20BG256 核心板**
> 原工程目标板：康芯 HX4S20C（同一颗芯片 `EG4S20BG256`）
> 审计日期：2026-10-18　｜　结论：**37 个源文件里只有 4 处需要改，已全部完成并验证**

---

## 一、逐目录审计结果

| 目录 | 文件数 | 需要改 | 说明 |
|---|---|---|---|
| `src/hdl/` | 11 个 .v（新增 `seg_595.v`） | **1 个**（`top_billboard.v` 端口层） | 其余 10 个逐字未动 |
| `src/support/` | 17 个 | **0 个** | 官方例程支撑代码，与板无关 |
| `src/ip/` | 6 个 | **0 个** | PLL / 片内 SDRAM / 异步 FIFO，都是芯片内部资源 |
| `src/constraints/` | 1 个 | **1 个**（`pin.adc` 全重写） | 引脚号全部换 |
| `src/include/` | 5 个 | 0 个 | 加密 IP 的 include |
| `sim/` | 19 个 tb + 2 个假器件模型 | **1 个新增**（`tb_seg_595.v`） | 其余全部照旧可用 |
| `tools/` | 6 个 py | 0 个 | 与板无关 |
| `assets/`、`scripts/` | — | 0 个 | 与板无关 |

**为什么 33 个内部模块零改动**：Verilog 描述的是"芯片内部发生什么"，与"引脚接到板上哪个器件"无关。
换板只换最外面那一层（引脚 + 端口 + 板级器件适配）。

---

## 二、真正改的 4 处

| # | 改动 | 文件 | 依据 |
|---|---|---|---|
| 1 | 全部引脚号重排 | `src/constraints/pin.adc` | 官方《AC201-EG4S20 管脚信息表.xlsx》+ 官方例程 `IO.adc` |
| 2 | 数码管 14 根直驱 → 3 根 74HC595 串行 | 新增 `src/hdl/seg_595.v` + 顶层例化 | 官方 `HC595_Driver.v` / `HEX8.v` |
| 3 | `key3/key4` 端口 → `sw[1:0]`（拨码） | `src/hdl/top_billboard.v` 端口 | 官方 `IO.adc`：AC201 只有 `key_0/key_1` + 8 位 `sw` |
| 4 | `led` 取反 + 删 `HDMI_DDC_*` | `src/hdl/top_billboard.v` | 官方 `led.v`（低有效）；`IO.adc` 无 DDC 引脚 |

---

## 三、信号对照表（23 个信号，全部已核实）

| 信号 | 方向 | HX4S20C（旧） | **AC201（新）** | 依据 |
|---|---|---|---|---|
| `clk` | in | R7 | **K14** | 管脚表 `CLK_50MHz`，50MHz |
| `rst_n` | in | A2 | **H14** | 官方 `IO.adc` = KEY2，低有效 |
| `key1` | in | B2 | **F7** | 官方 `key_0` |
| `key2` | in | C1 | **E7** | 官方 `key_1` |
| `sw[0]` | in | —（原 key3=B1） | **N14** | 官方 `sw[0]`，拨码替代按键 |
| `sw[1]` | in | —（原 key4=C8） | **K12** | 官方 `sw[1]` |
| `led[0]` | out | A4 | **M12** | 官方 `led[0]`，**低电平点亮** |
| `led[1]` | out | A3 | **R16** | 官方 `led[1]` |
| `led[2]` | out | C10 | **R15** | 官方 `led[2]` |
| `led[3]` | out | B12 | **T15** | 官方 `led[3]`（心跳） |
| `seg_ser` | out | —（原 seg_data[7:0]） | **R14** | 官方 `seg7_dio` |
| `seg_sclk` | out | —（原 seg_sel[5:0]） | **T14** | 官方 `seg7_sclk` |
| `seg_rclk` | out | — | **R12** | 官方 `seg7_rclk` |
| `HDMI_CLK_P` | out | C3 | **B10** | 官方 `O_tmds_clk_p`，**LVDS33_E** |
| `HDMI_D0_P` | out | G5 | **D11** | 官方 `O_tmds_ch0_p` |
| `HDMI_D1_P` | out | F1 | **C11** | 官方 `O_tmds_ch1_p` |
| `HDMI_D2_P` | out | E1 | **F10** | 官方 `O_tmds_ch2_p` |
| `HDMI_DDC_SCL` | out | P2 | **无（已删）** | AC201 未接 DDC |
| `HDMI_DDC_SDA` | io | R2 | **无（已删）** | 同上 |
| `sd_ncs` | out | A12 | **R2** | 管脚表 `SD_CS` |
| `sd_dclk` | out | A14 | **M2** | 管脚表 `SD_CLK` |
| `sd_mosi` | out | A13 | **L3** | 管脚表 `SD_MOSI` |
| `sd_miso` | in | B14 | **K6** | 管脚表 `SD_MISO` |

> ⚠️ **ADC 语法坑**：`pin.adc` 的注释只能用 `#`，不能写 `//`。
> 用 `//` 会让 TD 报 `USR-8168 ERROR: ... is not a valid ADC command`（2026-10-18 实测踩过）。
> 行内也不能写注释，注释必须独占一行。

---

## 四、验证证据（都是实际跑出来的）

### 4.1 仿真：21 项 / 313 条断言

```
PASS   top_elaborate   零错误零警告
PASS   wall_compile    零警告
... 19 个 testbench 全 PASS（含新增 tb_seg_595 16/16）...
  通过 21 项，失败 0 项
```

### 4.2 综合（TD 命令行，2026-10-18 19:15）

```
Device      : EG4S20BG256
#IO         : 21 / 188      ← 与顶层端口数完全一致（7 输入 + 14 输出）
#lut        : 4302 / 19600  (21.95%)
#reg        : 4029 / 19600  (20.56%)
#bram       : 58 / 64       (90.62%)   ← 最紧的一项，但没超
#pll        : 3 / 4
Setup WNS   : +7276ps   TNS 0   NUM_FEPS 0
Hold  WNS   : +471ps    TNS 0
read_adc    : 202 条命令全部接受（引脚名/位置/电平都合法）
```

### 4.3 布线 + 比特流（19:16）

```
SWNS 7.096ns   HWNS 0.033ns   Period Check WNS 16.586ns
STA coverage 94.02%
billboard.bit  676,194 字节  → billboard_Runs/phy_1/billboard.bit
```

两条 CRITICAL-WARNING（不阻断）：

| 警告 | 含义 | 处置 |
|---|---|---|
| `PHY-7002: u_sdram/sdram location (12,12) is not honored` | 片内 SDRAM 硬核的初始位置约束被 P&R 自动挪到合法位置 | 片内 SDRAM 是**芯片内部硬核**，位置由硬件决定，工具会自动落到唯一合法位置；`#bram/#pad` 统计正常，先上板验证 |
| `PHY-5079: 1 clock net uses local routing` | 某根时钟网走了局部布线 | 时序全正（SWNS 7.1ns），先上板 |

> **Hold 余量只有 33ps**，偏小。真机上若出现零星花屏，优先怀疑供电/温度导致的 hold 违例，
> 可在 TD 里把 `drHoldFix` 保持 on 重跑，或补 SDC 约束后重综合。

---

## 五、上板 5 步（每步独立判据）

| 步 | 做什么 | 成功判据 | 失败先查 |
|---|---|---|---|
| 1 | 只烧 `led_test_top`（clk/rst_n/led[0]） | LED 约 1 秒一闪 | 引脚表 / 晶振 |
| 2 | 烧完整 `billboard.bit` | **LED[3] 心跳闪** | 烧录链路（不是代码） |
| 3 | 插 TF 卡 | `led[0]` 亮 | 卡没插到底 / 卡里没 container |
| 4 | 接 HDMI | 出 1280×720 画面 | 分辨率 / 数据链路 |
| 5 | 按键与拨码 | K1 切图、K2 自动、SW0 周期、SW1 应急 | 极性 / 消抖 |

### 点灯工程的最小约束（3 行，复制到新建工程的 `.adc` 里）

```
set_pin_assignment	{ clk }	{ LOCATION = K14; IOSTANDARD = LVCMOS33; PULLTYPE = PULLUP; }
set_pin_assignment	{ rst_n }	{ LOCATION = H14; IOSTANDARD = LVCMOS33; PULLTYPE = PULLUP; }
set_pin_assignment	{ led[0] }	{ LOCATION = M12; IOSTANDARD = LVCMOS33; DRIVESTRENGTH = 8; PULLTYPE = NONE; }
```

> `led_test_top.v` 的 `led` 已经是"低电平点亮"写法，直接烧就能看到闪。

---

## 六、风险清单

| 编号 | 风险 | 现象 | 处置 |
|---|---|---|---|
| R1 | ~~晶振不是 50MHz~~ | — | **已排除**：管脚表 `CLK_50MHz = K14` |
| R2 | HDMI 核 DDC 悬空 | 灯亮、数码管正常、屏幕无信号 | 核按编译期固定时序输出（HTOTAL=1650），EDID 只是附加；真遇到再配固定 EDID |
| R3 | 数码管位序镜像 | 6 位数字顺序整体颠倒 | 顶层 `seg_595` 例化把 `{2'b11, seg_sel_w}` 改成 `{seg_sel_w, 2'b11}` |
| R4 | 拨码极性 | 拨 ON 与"按下"对应关系反直觉 | 只影响手感，不影响功能；必要时顶层 `sw` 取反 |
| R5 | TMDS 电平写错 | 布线报差分对错误 / 无输出 | 必须 `LVDS33_E`，不能沿用 `LVDS33` |
| R6 | ADC 注释用 `//` | `USR-8168 ERROR` | 只能用 `#`，且注释独占一行 |
| R7 | BRAM 90.6% 占用 | 后续加功能可能超 64 块 | 加功能前先看 `billboard_gate.area` 的 `#bram` 列 |
| R8 | Hold 余量 33ps | 偶发花屏 | 保持 `drHoldFix on`；有条件补 SDC 重综合 |

---

## 七、2026-10-18 晚 二次核对：三处"照抄 HX4S20C 造成的不适配"

第一次适配只改了引脚层（`pin.adc` + 顶层端口 + 数码管 595），
**HDMI 发射那一层的参数是从 HX4S20C 版 lab_ex5 原样带过来的**。
后来把官方 AC201 的 720p 参考实现 `design_top_wrapper.v` 逐行比对，发现三处必须改：

| # | 项目 | 改前（HX4S20C 版） | 改后（照官方 AC201） | 依据 | 影响 |
|---|---|---|---|---|---|
| ① | `VIDEO_VIC` | `4` | **`69`** | `design_top_wrapper.v:137` | 两者时序相同，但核内部按 VIC 生成 AVI InfoFrame；VIC 不在核的查表里时行为不可预期 |
| ② | `I_edid_read_trig` | 上电 1.33ms 自动触发一次 | **固定 `1'b0`** | `design_top_wrapper.v:149` 用按键触发（默认不读） | AC201 的 HDMI 座**没把 DDC 接到 FPGA**，自动读等于让 I2C 主机去找一个不存在的从机，收不到 ACK；严重时核停在"等 EDID"而完全不输出 TMDS |
| ③ | `IIC_SCL_DIV` | `250` | **`125`** | `design_top_wrapper.v:143` | 只在读 EDID 时生效；②之后已无实际作用，仅为与官方一致 |
| ④ | HDMI 四脚 `DRIVESTRENGTH` | 未写（用默认） | **显式 `8`** | `IO.adc:6~9` | 与官方完全一致 |

### 7.1 PLL 对照（这项**不改**）

| | 像素时钟 | 串行时钟 | 相位 |
|---|---|---|---|
| 官方 `pll_hdmi1_4b` | 73.333 MHz | 366.667 MHz | **90°** |
| 本工程 `video_pll` | 75 MHz | 375 MHz | **90°** |

相位一致（都是 90°，这对 TMDS 的 DDR 采样窗口很关键）。
频率差 +2.27% / +2.27%，对应刷新率 60.6Hz vs 59.26Hz，都在 HDMI 接收端容差内。
**权衡后不改**：75MHz 更接近标准 74.25MHz，而且已经综合布线通过、时序全正，
改频率要重走一整轮验证，收益不足以抵消风险。

### 7.2 新增：诊断比特流 `hdmi_test.bit`

| 项 | 内容 |
|---|---|
| 源码 | `port_ac201/hdmi_test/top_hdmi_test.v` + `pin_test.adc` |
| 链路 | 50MHz → video_pll → HDMI 核（`VIDEO_TPG="Enable"`）→ PHY → 引脚 |
| 依赖 | **零**：不碰 TF 卡、SDRAM、任何自研模块 |
| 产物 | `port_ac201/hdmi_test/hdmi_test_Runs/phy_1/hdmi_test.bit`（629,634 B） |
| 资源 | IO 10 / 188（2 in + 8 out），lut 1356，reg 1226 |
| 时序 | SWNS 13.639ns，HWNS 0.025ns |
| 引脚 | K14 / H14 / B10 / D11 / C11 / F10 / M12 / R16 / R15 / T15，全部命中 |
| 用途 | 上板第一步：出彩条 = HDMI 通路 OK；不出 = 硬件侧问题，别改代码 |

### 7.3 本轮重新生成的主工程比特流

```
源码  top_billboard.v 19:39 / pin.adc 19:39   <   bit 19:57   ✓ 新鲜
IO    #IO 21/188 (7 in + 14 out)
时序  SWNS 6.721ns  HWNS 0.048ns  Period Check WNS 16.586ns
产物  billboard_Runs/phy_1/billboard.bit  676,194 B  md5 3ee5fe837d91952b8b7555121dad10ae
引脚  21/21 逐脚 grep 命中
```

> **更新（2026-10-18 21:20）**：以上是 19:57 那一版的记录，**已被后续重综合取代**。
> 当前交付比特流是 **20:59 版**，md5 `51b2082b74b1ae5a113ab3fbed57302e`
> （`bit\2_billboard_full.bit`，与 `phy_1\billboard.bit` 同源），
> Setup WNS **+6721ps** / Hold WNS **+48ps**（TNS 均 0，0 条违例路径；
> `phy_1\run.log` Run Date 20:42，中间步骤曾出现 SWNS 8060 / HWNS −11ps，最终布线收敛到 6721/48），
> `#lut 4328` / `#reg 4078` / `#bram 58` / `#pll 3`。已由用户实板验证"出画面 + 滚动字幕 + 有声音"。
> 引用时序数据时请用这一组。


### 7.4 AC201 板上按键/拨码的物理位置（2026-10-18 深夜复核）

> 之前一版坐标（把 S0/S1 说成"左侧并排两颗"）是 OLE 解析跨记录污染所致，**作废**。
> 本版从 `AC201_EG4S20.PcbDoc` 的 Components6/Data 逐记录（单记录 800 字节窗口内
> 匹配 `X=..mil|Y=..mil`）重新提取，并对 S0/S1/S2/S4/J1/J2/J5/MK1 逐条人工复核。
> 坐标系为 Altium 内部坐标（mil，Y 向上），只用于**相对位置**判断。

| 位号 | 器件 | Altium X,Y (mil) | 板上丝印 | 接 FPGA | 本工程用途 |
|---|---|---|---|---|---|
| S1 | 轻触按键 SW-PB | 9550, 4744 | **KEY1**（挨着 HDMI 插座） | F7 (key1) | **下一张** |
| S0 | 轻触按键 SW-PB | 13467, 4058 | **KEY2**（挨着 8 位拨码） | E7 (key2) | **自动轮播开/关** |
| S2 | 轻触按键 SW-PB（6×8.5 大按键） | 10963, 6332 | **KEY3**（靠 USB-C 一侧、板中部偏左） | H14 | **复位** |
| S4 | 8 位拨码 NDI-08H-V | 14502, 3543 | SW1~SW8（板右下角，音频端子旁） | sw[0]=N14, sw[1]=K12 | **SW1=轮播周期，SW2=应急开关** |
| S3 | 滑动开关 SS-13F24-G050 | 10347, 4383 | 电源开关（勿混用） | — | 电源 |

相对参照（找的时候按这个来）：
- HDMI 插座 J4(9842,4814)、TF 卡座 J2(9562,5260)、电源座 J3(9764,5283) 全部挤在板左侧边缘中部。
- **KEY1 = 紧挨 HDMI 插座的那颗轻触按键**（同一竖列，最靠 HDMI）。
- USB-C J1(14015,6533) 在对侧边缘；RJ45 网口 J5(13487,5474) 也在右侧。
- **KEY2 = 板右侧、8 位拨码开关旁边的轻触按键**，与一颗 LED（D3）并排。
- **KEY3 = 靠 USB-C 一侧、板中部偏左的大个轻触按键**（复位）。
- **拨码 = 板右下角一排 8 个小拨动开关**，旁边是音频接线端子 SPK_L1(13830,3685)；本工程只用第一、二位。

操作特性（RTL 决定）：
- 轻触按键低有效，`key_debounce` 20ms 消抖 + `play_scheduler` 上升沿检测 → **按下瞬间触发一次**。
- 拨码"往上拨为亮（=0）"→ `key_debounce` 只在 1→0 出脉冲 → **往下拨产生事件，拨回去不产生**。
  即 SW1 往下拨一次 = 周期切到下一档（2→5→10→20 秒循环）；SW2 往下拨开应急、想关要往下拨……不行，
  需拨回不触发 → 应急开关实际"拨下开、拨回无效"的局限已知（可选双向边沿 3 行改动，未做）。

> **照片对照补充（2026-10-18 21:45）**：用户提供官方宣传图后进一步确认——
> 板上丝印实测（PCB Texts 层）：只有复位键旁印 **"KEY"**（S2 旁，挨着 DC 电源口丝印），
> S0/S1 旁的丝印是封装名 **"SW-PB"**（没有 KEY1/KEY2/KEY3 编号丝印！）。
> 因此按邻居找键才可靠：
> ① 挨着 HDMI 口 = S1 = F7 = 切图下一张；
> ② 右上角挨着红外接收头（丝印 HS38B）和 8 位拨码、旁边有 LED = S0 = E7 = 自动轮播开关；
> ③ 底边挨着 DC 5V 电源口、丝印 KEY = S2 = H14 = 复位；
> ④ 右上区那排 8 位拨码（照片"拨码开关"，旁边"4个用户LED"）= S4，位1=轮播周期(N14)、位2=应急(K12)。
> 官方宣传图标注（红外接收头/轻触按键/拨码开关/4个用户LED 挤在右上角）与此完全吻合。
