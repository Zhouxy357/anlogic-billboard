# HDMI 通路诊断工程（hdmi_test）

## 这个工程解决什么问题

正式工程 `billboard.bit` 的显示链路很长：

```
TF 卡 → ebm_reader → SDRAM 乒乓缓存 → video_delay → osd_mixer → AXIS → HDMI 核 → PHY → 引脚
```

**任何一环出问题，现象都是"屏幕黑屏"。** 光看屏幕根本分不清是：

- HDMI 引脚/电平标准/PLL 不对？（硬件侧）
- TF 卡里没数据 / 容器没写进去？（数据侧）
- SDRAM 读写时序不对？（缓存侧）

这个诊断工程把后面全部砍掉，只留最短的一条链：

```
50MHz 晶振 → video_pll → HDMI 核（VIDEO_TPG="Enable"，核内自带彩条）→ PHY → HDMI 引脚
```

**不依赖 TF 卡、不依赖 SDRAM、不依赖任何自研模块。**

## 怎么用

1. 双击 `bit\hdmi_test.bit` 所在位置（`hdmi_test_Runs\phy_1\hdmi_test.bit`），
   用 TD 的 **BitWriter** → `Program SRAM` 烧进去。
2. 板子接 HDMI 到显示器，上电。

## 结果怎么判读

| 现象 | 结论 |
|---|---|
| **LED[3] 快闪（约 3Hz），屏幕出彩色竖条** | HDMI 通路 100% 正常 → 黑屏原因一定在数据链路（TF 卡/容器/SDRAM），直接去查 `write_card.log` 和 `container.bin` |
| **LED[3] 快闪，屏幕无信号/黑** | 问题在硬件侧：换 HDMI 线、换显示器输入源、确认显示器自动选源、确认用的是板上的 HDMI OUT 口 |
| **LED 全不亮/全亮不闪** | FPGA 没配置成功：检查下载器、供电、是不是烧错了工程 |

## 为什么这个工程"一定能出图"

参数**逐项照抄官方 AC201 参考实现** `ac201_docs/board_test/AC201_AL_board_test/src/user_source/hdl_source/design_top_wrapper.v`：

| 参数 | 值 | 来源 |
|---|---|---|
| HTOTAL / HSA / HFP / HBP | 1650 / 40 / 110 / 220 | 官方第 126~129 行 |
| VTOTAL / VSA / VFP / VBP | 750 / 5 / 5 / 20 | 官方第 131~134 行 |
| HACTIVE / VACTIVE | 1280 / 720 | 官方第 130、135 行 |
| **VIDEO_VIC** | **69** | 官方第 137 行（不是 4！） |
| VIDEO_TPG | Enable | 官方第 139 行（核内测试图案） |
| VIDEO_FORMAT | RGB | 官方第 140 行 |
| IIC_SCL_DIV | 125 | 官方第 143 行 |
| HDMI 引脚 | B10 / D11 / C11 / F10，LVDS33_E | 官方 `IO.adc` 第 6~9 行 |

唯一的差别是我们用 `video_pll`（75MHz / 375MHz@90°），官方用 `pll_hdmi1_4b`（73.333MHz / 366.667MHz@90°）。
两者都是 1650×750 的像素时钟，偏差 <2.3%，远在 HDMI 接收端容差内。

## 重新生成

```bash
# 1. 建工程（纯英文路径，TD 不支持中文）
"C:/Anlogic/TD_6.2.1_Engineer_6.2.168.116/bin/td_commands_prompt.exe" \
    "C:/FPGA/billboard_prj/port_ac201/hdmi_test/build_test.tcl"

# 2~3. 综合（syn_1）与布线（phy_1）
cd hdmi_test_Runs/syn_1 && "…/td_commands_prompt.exe" "…/doc/scripts/DefaultFlow.tcl"
cd ../phy_1              && "…/td_commands_prompt.exe" "…/doc/scripts/DefaultFlow.tcl"
```

产物：`hdmi_test_Runs\phy_1\hdmi_test.bit`（约 615 KB）。

> 踩坑记录：TD 的 `settings.cfg` 里 `end_step` 必须写 **`opt_gate`**（不是 `syn`），
> 否则 `lsearch` 在 stepList 里找不到该名字，一步都不跑，却仍然打印"success"。
> 另外 `phy_1` 目录必须同时有 `hdmi_test.prj` 和 `hdmi_test.tcl`（从 syn_1 复制），
> 否则会报 `PRJ-8642 ERROR: Project file hdmi_test.prj does not exist`。
