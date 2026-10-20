# billboard_prj —— 工程总目录（README）

> 安路 FPGA 全逻辑应急广告牌 · **AC201 底板**（EG4S20BG256）
> 工程根目录：`C:\FPGA\billboard_prj`
> 整理时间：2026-10-11

---

## 一、先看这里：三步上手

| 想干什么 | 点这个 |
|---|---|
| **★ 上板第一步：先确认 HDMI 通不通** | 烧 `bit\1_hdmi_test_colorbar.bit`（出彩条 = 通） |
| **★ 上板第二步：烧完整作品** | 烧 `bit\2_billboard_full.bit` |
| **打开工程看代码 / 综合烧录** | `scripts\1_open_project.bat` |
| **把图片写进 TF 卡**（上板前必做） | `scripts\4_write_card_auto.bat`（全自动） |
| **把代码跑一遍（每个模块怎么验证）** | `docs\代码运行速查卡.md` |
| **查某个文件在哪、该用哪个工具调** | `docs\操作手册-文件总目录与调试环境.md` |
| **跑仿真（怎么跑、怎么看、跑不过怎么办）** | `docs\仿真操作说明.md` |
| **报错 / 上板不对，怎么查** | 手册 **第 6 节**〔四级排查法〕+ 速查卡第 7 节 |
| **不知道点哪个菜单 / 仿真怎么搞** | 手册 **第 7 节**〔手把手：点哪里、敲什么〕 |
| **清理临时产物**（卡顿了/要打包交付了） | `scripts\3_clean_temp.bat` |
| **从零重建工程**（出问题了才用） | `scripts\2_rebuild_project.bat` |
| **看文档**（从哪读起） | `docs\README.md` |

> ⚠️ **打开工程前先看**：任务管理器里如果已经有 `td.exe`，说明 TD 早开着了。
> 同一时刻只能开一个 TD，此时再双击 bat 会"没反应"——这是正常的。
> 详见 `docs\操作手册-文件总目录与调试环境.md` 开头。

---

## 二、目录结构总览（9 个目录 + 4 个文件）

```
C:\FPGA\billboard_prj\
│
├─ billboard.al              ★ TD 工程主文件（双击可开，或走 scripts\1_open_project.bat）
├─ audio_rom.hex             综合必需的音频数据（$readmemh 在工程根找）
├─ banner_rom.hex            综合必需的字幕数据
├─ README-工程总目录.md       本文件
│
├─ bit\                      【成品比特流】★ 上板就烧这里面的
│   ├─ 1_hdmi_test_colorbar.bit   先烧这个：30 秒确认 HDMI 通路通不通
│   └─ 2_billboard_full.bit     再烧这个：图片轮播 + 字幕 + 音效
├─ docs\                     【文档】9 份说明（README 索引 / 主手册 / 文件总目录 / 速查卡 / 仿真说明 / 上板连接与驱动 / 720p改造说明 / 进度 / 代码复查）
├─ scripts\                  【一键脚本】7 个 bat + 1 个 tcl（GBK 编码）
├─ src\                      【源代码】43 个文件，分 6 个子目录
│   ├─ hdl\                  自研 11 个 .v（★ 最核心）
│   ├─ ip\                   IP 核 6 个（PLL / SDRAM / FIFO）
│   ├─ support\              例程支撑模块 17 个
│   ├─ include\              头文件 5 个
│   ├─ constraints\          引脚约束 pin.adc
│   └─ rom\                  ROM 数据存档（hex + 预览图）
├─ sim\                      【仿真】19 个 testbench + 2 个假器件模型 + 脚本（28 个）
├─ tools\                    【PC 工具】7 个 Python 脚本
├─ assets\                   【素材输入】你自己放素材的地方
│   ├─ img\                  放图片（任意格式，自动转 1280×720）
│   └─ audio\                放音频源 .wav（16bit PCM，每段约 171ms）
├─ port_ac201\               【换板档案】AC201 适配的审计报告 + HDMI 诊断工程
├─ billboard_Runs\           【编译产物】TD 自动生成，别手改
├─ build_logs\               【日志】建工程时产生的日志
└─ log\                      【临时】TD 控制台日志（可随时删，见 scripts\3_clean_temp.bat）
```

> **只有 4 个文件是你需要关心的**（`billboard.al` + 两个 hex + 本 README），
> 其余全在目录里归好类了。`billboard_Runs\` `build_logs\` `log\` 都是**自动生成**的，
> 删了也不影响（TD 会重建；`log\` 可随时清）。

---

## 三、逐目录详解

### 3.1 根目录（4 个文件）

| 文件 | 大小 | 说明 |
|---|---|---|
| `billboard.al` | 15 KB | **TD 工程主文件**。顶层 `top_billboard`，37 个源文件 + 1 个引脚约束已登记 |
| `audio_rom.hex` | 128 KB | 音频采样（8bit/样本）。**综合时 TD 从这里读**，不能只留 `src\rom\` 那份 |
| `banner_rom.hex` | 20 KB | 字幕点阵。同上 |
| `README-工程总目录.md` | 12 KB | 本文件（全工程目录汇总） |

> **为什么 hex 要放五处**：Verilog 的 `$readmemh("xxx.hex", mem)` 参数只能是字面量，
> 而**相对路径是 TD 按 `$readmemh` 所在的 .v 文件目录解析的**。
> 所以 `audio_rom.hex` 必须在
> **工程根 + `src\rom\` + `src\hdl\` + `sim\` + `billboard_Runs\syn_1\`** 五处都有；
> `banner_rom.hex` 在 **工程根 + `src\rom\` + `src\hdl\` + `billboard_Runs\syn_1\`** 四处（`sim\` 不需要）。
> **少放 → 不报 ERROR，只报 `CRITICAL-WARNING`，但 ROM 是空的 → 上板黑屏。**

### 3.2 `docs\` —— 文档（9 份）

| 文件 | 大小 | 什么时候看 |
|---|---|---|
| `README.md` | 7 KB | ★ **第一个看这个**。文档总索引 + 推荐阅读顺序 |
| `从零到上板操作手册.md` | 292 KB | **主手册**，6600+ 行：逐模块讲解 + 怎么跑（第 5 节）+ 怎么调试（第 6 节）+ 点哪里（第 7 节） |
| `代码运行速查卡.md` | 13 KB | 一页纸：**每个代码在哪个软件怎么跑**（19 个 tb 总表）+ 跑不过怎么办 |
| `仿真操作说明.md` | 21 KB | **只讲仿真**：三条跑法 / 19 个 tb 测什么 / 结果怎么读 / 跑不过怎么查 |
| `上板第一步-连接开发板与驱动安装.md` | 9 KB | **上板前看**：USB 线怎么插、为什么不用外加电源、驱动/签名怎么处理 |
| `分辨率升级-720p改造说明.md` | 7 KB | **本次改造相关**：为什么改 720p、改了什么、TD 怎么重跑、怎么回退 |
| `操作手册-文件总目录与调试环境.md` | 22 KB | **查文件 + 查该用哪个工具** + 第 6 节逐个文件绝对路径速查 |
| `代码复查报告-2026-10-12.md` | 12 KB | 全工程代码复查：查出什么、改了什么、还剩什么风险 |
| `进度对照表.md` | 11 KB | 想知道"做完哪些、该我做哪些" |

### 3.3 `scripts\` —— 一键脚本（7 个）

| 文件 | 类型 | 作用 |
|---|---|---|
| `1_open_project.bat` | 双击 | **打开 TD 工程**（4 步自检 + 清残留锁 + 拉起 TD）★ 最常用 |
| `2_rebuild_project.bat` | 双击 | **从零重建工程**（约 30 秒，自动清旧工程） |
| `3_clean_temp.bat` | 双击 | **清理临时产物**（仿真日志 / TD 日志 / 锁文件；不动源码文档；有确认提示） |
| `4_write_card_auto.bat` | 双击 | **全自动写 TF 卡**：查依赖 → 生成 `container.bin` → 列物理盘 → 5 秒后直接写（不用输 YES）★ 推荐 |
| `4_write_card.bat` | 双击 | 同上的**慢速确认版**：写之前停下来让你核对盘号 + 输 `YES` |
| `open_project_simple.bat` | 双击 | 简易版打开（不自检、不停留） |
| `step0_build.tcl` | 参数 | 重建工程的 TCL 脚本，被 `2_rebuild_project.bat` 调用 |

> **为什么 bat 是英文名**：安路 TD 读不了中文路径（实测 `一键启动` 会被读成乱码 `Ò»¼üÆô¶¯`）。
> 但 bat 运行时的**窗口标题和内容都是中文**，不影响阅读。
> `2_rebuild_project.bat` 还会把 tcl 复制到 `C:\FPGA\_tmp_tcl\` 再执行，彻底避开中文。
>
> ★ **这 5 个 `.bat` 的编码是 GBK + CRLF**——中文 Windows 的 cmd 只认这个组合。
> 实测用 UTF-8 保存时，中文行会被 cmd 当成命令执行，整片报"不是内部或外部命令"。
> 所以改这些 bat 时**不要用纯 UTF-8 编辑器直接保存**。

### 3.4 `src\hdl\` —— 自研模块（11 个）★ 核心

| 文件 | 大小 | 作用 |
|---|---|---|
| `top_billboard.v` | 24 KB | **顶层**，所有模块在这里连起来 |
| `play_scheduler.v` | 18 KB | 播放调度（自动轮播 / 手动翻页） |
| `ebm_reader.v` | 20 KB | 读 SD 卡私有容器（EBM1） |
| `osd_mixer.v` | 5.8 KB | 字幕叠加 + 亮度调节 |
| `transition_ctrl.v` | 5.2 KB | 淡入淡出转场 |
| `audio_player.v` | 5.2 KB | HDMI 音频播放 |
| `seg_status.v` | 4.4 KB | 数码管状态显示 |
| `seg_595.v` | 6.3 KB | **AC201 专用**：段码/位选 → 3 线 74HC595 串行帧 |
| `key_debounce.v` | 3.2 KB | 按键消抖 |
| `audio_rom.v` | 2.2 KB | 音频 ROM 封装 |
| `banner_rom.v` | 1.7 KB | 字幕 ROM 封装 |

### 3.5 `src\ip\` —— IP 核（6 个）

| 文件 | 说明 |
|---|---|
| `sys_pll.v` | 系统 PLL（**带 `extlock` 端口**，顶层需要） |
| `video_pll.v` | 视频 PLL（同样带 `extlock`） |
| `PLL_HDMI_AUDIO.v` | 音频 PLL |
| `sdram.v` | SDRAM 控制器（端口 `Clk` / `Clk_sft`） |
| `afifo_16_32_256.v` | 写 FIFO（提供 `wfifo_32_32_512`） |
| `afifo_32_16_256.v` | 读 FIFO（提供 `rfifo_32_32_512`） |

> ⚠️ **别换版本**：`sys_pll`/`video_pll` 必须用**带 `extlock`** 的那版（来自官方 `lab_ex4_tf`），
> 换错了 TD 会报 `cannot find port 'extlock'`。

### 3.6 `src\support\` —— 例程支撑模块（17 个）

SD 卡驱动、HDMI 发射核、视频时序、SDRAM 读写等，来自官方例程，**不要改**：

```
frame_read_write.v            frame_fifo_read.v           frame_fifo_write.v
sd_card_top.v                 sd_card_sec_read_write.v    sd_card_cmd.v
spi_master.v                  color_bar.v                 video_delay.v
video_timing_data.v           video_rgb_to_axis_640x480.v
hdmi_1_4b_transmitter_core_wrapper.enc.v   hdmi_phy_warpper.v   lane_lvds_10_1.v
audio_arc_calculate.v         startup_pulse.v             seg_scan.v
```

### 3.7 `src\include\` —— 头文件（5 个）

| 文件 | 说明 |
|---|---|
| `global_def.v` | 宏定义（`ADDR_WIDTH=21` 等） |
| `video_define.v` | 视频参数宏 |
| `sdr_as_ram.enc.v` | SDRAM 当 RAM 用 |
| `sdr_init_ref.enc.v` | SDRAM 初始化刷新 |
| `sdr_wrrd.enc.v` | SDRAM 读写 |

### 3.8 `src\constraints\`（1 个）与 `src\rom\`（3 个）

| 文件 | 说明 |
|---|---|
| `constraints\pin.adc` | **引脚约束**（HDMI / LED / 按键 / 数码管）|
| `rom\audio_rom.hex` | 音频数据存档（与根目录那份相同） |
| `rom\banner_rom.hex` | 字幕数据存档（与根目录那份相同） |
| `rom\banner_preview.png` | **字幕预览图**，双击能看黄字点阵 |

### 3.9 `sim\` —— 仿真（22 个）

| 文件 | 说明 |
|---|---|
| `run_iverilog.sh` | **一键跑仿真**（iverilog 12.0，IC Coder 自带），21 项 / 313 条断言 |
| `run_all.sh` / `run_all.do` | ModelSim 版一键脚本（早期 4 个 tb） |
| `check_results.py` | 判读结果、ASCII 标签翻中文 |
| `ip_stubs.v` | IP 空壳（仿真时替代官方加密 IP；只用于顶层连线检查，不能跑功能仿真） |
| `sd_card_model.v` | **假 SD 卡**（给 `tb_sd_card` 用：收命令/回响应/收发 512 字节/故意回"忙"逼出重试分支） |
| `tb_key_debounce.v` | 测试台：按键消抖（6 项） |
| `tb_audio_player.v` | 测试台：音频播放（7 项） |
| `tb_play_scheduler.v` | 测试台：调度器（18 项） |
| `tb_ebm_reader.v` | 测试台：容器读取（17 项） |
| `tb_color_bar.v` | 测试台：1280×720@60 视频时序（23 项） |
| `tb_video_timing_data.v` | 测试台：时序输出级（18 项） |
| `tb_video_delay.v` | 测试台：像素/同步对齐（14 项） |
| `tb_video_rgb_to_axis.v` | 测试台：RGB→AXI-Stream（14 项） |
| `tb_seg_status.v` | 测试台：数码管状态位（18 项） |
| `tb_seg_scan.v` | 测试台：数码管动态扫描（14 项） |
| `tb_seg_595.v` | 测试台：74HC595 串行驱动（16 项） |
| `tb_transition_ctrl.v` | 测试台：换帧转场（19 项） |
| `tb_osd_mixer.v` | 测试台：字幕叠加 + 亮度乘算（16 项） |
| `tb_audio_arc.v` | 测试台：HDMI 音频 ACR/CTS（13 项） |
| `tb_startup_pulse.v` | 测试台：上电延时脉冲（13 项） |
| `tb_rom_content.v` | 测试台：素材 ROM 内容校验（26 项） |
| `tb_spi_master.v` | 测试台：SPI 主机（24 项） |
| `tb_sd_card.v` | 测试台：**SD 卡全链路**（27 项） |
| `tb_frame_rw.v` | 测试台：**SDRAM 帧缓存 + V_FLIP**（10 项，内含行为级 SDRAM 模型 `sdr_beh`） |
| `audio_rom.hex` | 仿真用音频数据 |
| `README.md` | 仿真说明 |

**怎么跑**：Git Bash 里
```bash
cd /c/FPGA/billboard_prj/sim
bash run_iverilog.sh
```
应输出 `通过 21 项，失败 0 项`。

### 3.10 `tools\` —— PC 工具（7 个）

| 文件 | 作用 | 哪一步用 |
|---|---|---|
| `gen_container.py` | 图片 → `container.bin` | 第 10 步 |
| `write_container.py` | `container.bin` → TF 卡 | 第 10 步 |
| `gen_banner.py` | 文字 → `banner_rom.hex` | 第 4 步（已用过） |
| `gen_audio_rom.py` | 生成 `audio_rom.hex` | 第 5 步（已用过） |
| `build_manual.py` | 由模板+源码重新生成主手册 | 改了 .v 或模板后 |
| `sync_delivery.py` | 工作工程 → 交付源镜像（单向同步） | 打包交付前 |
| `README.md` | 每个工具的详细用法 | 随时 |

### 3.11 `billboard_Runs\syn_1\` —— 编译产物（**验证看这里**）

| 文件 | 怎么验证 |
|---|---|
| `run.log` | **最关键**。搜 `ERROR` 应为 **0 条**；搜 `Successfully analyzed` 显示 `36 source files` |
| `billboard_elaborate.db` | 编译出的网表，**3.3 MB**（大小不为 0 = 真编出来了）|
| `.read_design.begin.f` + `.read_design.end.f` | **两个都在 = design 步完整跑完没崩** |
| `billboard.prj` / `billboard.tcl` / `settings.cfg` / `run.bat` | TD 自动生成的配置，别手改 |

### 3.12 `build_logs\` —— 日志

| 文件 | 说明 |
|---|---|
| `step0_run.log` | 建工程时的 TD 输出。搜 `STEP0 DONE` 能找到 |

### 3.13 `assets\` —— 你自己的素材输入（图片 / 音频）

| 文件 | 说明 |
|---|---|
| `assets\img\README.md` | 图片用法说明 |
| `assets\img\*` | **要你自己放**：任意格式图片（png / jpg / bmp / webp…），自动转 1280×720。`gen_container.py` 的输入 |
| `assets\audio\README.md` | 音频用法说明 |
| `assets\audio\*.wav` | **可选，要你自己放**：16bit PCM 音频源，`gen_audio_rom.py` 的输入（每段仅约 171ms） |

> **图片走 TF 卡**：放 `assets\img\` → `python tools/gen_container.py -i assets/img/ -o container.bin`
> → 写进卡。改完**只需重写卡，不用重新综合**。
> **音频走片内 ROM**：放 `assets\audio\` → `python tools/gen_audio_rom.py -w ...`
> → 生成 hex 放**五处** → **必须重新综合 + 重新烧板**。
> 两个目录现在都只有一份 README（还没有素材），放东西进去就能开工。

### 3.14 可随时删的临时目录

| 目录 | 谁生成 | 说明 |
|---|---|---|
| `log\` | TD 启动时 | TD 控制台日志。删了不影响，TD 会重建 |
| `sim\ivlogs\` `sim\ivl_tmp\` | `run_iverilog.sh` | 仿真日志与中间文件，跑脚本自动重建 |
| `sim\logs\` `sim\work\` | `run_all.sh`（ModelSim） | 同上 |

> **一键清空**：双击 `scripts\3_clean_temp.bat`（只删上面这些，绝不碰源码/文档/素材）。

---

## 四、验证清单（30 秒做完）

| # | 动作 | 通过标准 |
|---|---|---|
| 1 | 资源管理器粘 `C:\FPGA\billboard_prj` | 看到 **8 个目录 + 4 个文件** |
| 2 | 打开 `build_logs\step0_run.log` 搜 `STEP0 DONE` | 能找到 |
| 3 | 打开 `billboard_Runs\syn_1\run.log` 搜 `ERROR` | **0 条**（`CRITICAL-WARNING` 也要看，应为 0） |
| 4 | 看 `billboard_Runs\syn_1\billboard_elaborate.db` 属性 | 约 3.3 MB |
| 5 | 双击 `src\rom\banner_preview.png` | 看到黄字点阵 |
| 6 | 双击 `scripts\1_open_project.bat` | 自检 4 步全 OK（或提示 TD 已运行）|
| 7 | Git Bash：`cd sim && bash run_iverilog.sh` | 末尾显示 **`通过 21 项，失败 0 项`** |
| 8 | 打开 `docs\` | 看到 **9 份 md** |

---

## 五、清理记录（各次整理做了什么）

| 动作 | 对象 | 原因 |
|---|---|---|
| **删除** | `_td_console_logs\`（24 个文件，105 KB） | 建工程时的探测残留，无用 |
| **删除** | `billboard_Runs\phy_1\`（空目录） | 空目录 |
| **删除** | 根目录 4 个 `td_*.log`、`td_*.logw` | TCL 控制台回显，已由 `build_logs\step0_run.log` 涵盖 |
| **删除** | 根目录 `step0_build.tcl` 旧副本 | 已移入 `scripts\` |
| **改位置** | 4 份 .md 文档 → `docs\` | 归类 |
| **改位置** | 5 个 bat + 1 个 tcl → `scripts\` | 归类 |
| **改位置** | `step0_run.log` → `build_logs\` | 归类 |
| **改名字** | `一键启动\` → `scripts\` | **中文目录 TD 读不了**（实测） |
| **改名字** | bat 文件改英文名 | 同上（内容仍是中文） |
| **新建** | `scripts\2_rebuild_project.bat` | 一键重建工程 |
| **新建** | `scripts\3_clean_temp.bat` | 一键清临时产物（仿真日志 / TD 日志 / 锁文件） |
| **新建** | `scripts\4_write_card.bat` | 一键写卡（打包 `assets\img\` → 列盘核对 → 提权写入 TF 卡） |
| **新建** | 本 README | 总目录汇总 |
| **新建** | `docs\代码运行速查卡.md` | "每个代码怎么跑"速查卡 |
| **新建** | `docs\仿真操作说明.md` | 只讲仿真：三条跑法 / 19 个 tb / 结果怎么读 / 报错对症（2026-10-13 随新增 tb 全面重写）|
| **改路径** | `tools\build_manual.py` 输出改到 `docs\` | 生成物与目录结构一致 |
| **改内容** | 手册改成"代码已写好、怎么跑"版 | 删除第 0 步的"从零建工程/删例程文件"大段，每步加「▶ 单独跑一遍」，新增第 5 节速查总表 |
| **新建章节** | 手册第 6 节〔出了问题怎么调试（四级排查法）〕 | 含 L1~L4 四级、报错对症表、ChipWatcher 在线逻辑分析仪用法、板级现象对照表 |
| **新建章节** | 手册第 7 节〔手把手：每个软件点哪里、敲什么〕 | 菜单路径全部从 TD 官方手册核实；含"仿真三种跑法"和"代码要不要复制" |
| **修坑** | `billboard_Runs\syn_1\` 补放两个 hex | TD 读 `$readmemh` 的 hex 缺了会 CRITICAL-WARNING（ROM 空 → 上板黑屏）。**后经实测确认：TD 是按 `$readmemh` 所在 .v 的目录解析**，故 `src\hdl\` 也必须放（现为五处） |
| **复核（2026-10-11）** | 全套仿真 + 工程体检 | iverilog 6/6、ModelSim 4/4（48 项断言）；登记 37 项（36 源文件 + 1 约束）0 缺失；0 个编码异常 |
| **扩充仿真（2026-10-13）** | **逐模块补齐 testbench** | 新增 14 个 tb（视频时序/对齐/AXIS、数码管、转场、字幕、音频 ACR、上电脉冲、素材 ROM、SPI、SD 卡全链路、SDRAM 帧缓存）→ **19 个 tb + 2 项静态检查 = 21 项 / 313 条断言全过**。为 SD 卡写了**假卡模型** `sd_card_model.v`、为帧缓存写了**行为级 SDRAM** `sdr_beh`；`run_iverilog.sh` 增加"**已知无害告警放行清单**"（`wallow`），既能保留厂商 IP 原样、又不放过新告警 |
| **修 bug（2026-10-13）** | `sd_card_model.v` + `tb_frame_rw.v` | ① 假卡把"复位后 DCLK 回到空闲电平"的那次跳变当成数据位，导致整串位相位错 1 位（解出假命令 0x7F）；② 假卡重组命令参数时多算了 CRC 字节；③ `tb_frame_rw` 在 FIFO 异步复位还没放干净时就灌数据，前 2 个字被丢 |
| **清理（2026-10-11 二次）** | 删残留产物 | `log\`（TD 控制台日志）、`sim\{ivlogs,ivl_tmp}`、`run.logw`、工作区 `fpga_doc_pages\`（2.8MB）、交付源 `assets\examples\`（3 张旧示例图）；新建 `assets\img\` 输入目录 |

> **`log\` 目录与 `.lock.f`**：都是 TD 运行时产生的（`log\td_*.log` 是控制台日志，
> `.lock.f` 是工程锁）。**关掉 TD 后**可以随时删，或者双击 `scripts\3_clean_temp.bat` 一键处理。

**保留不动的重复文件**（有意为之）：
- `audio_rom.hex` 5 份（根 / `src\rom\` / `src\hdl\` / `sim\` / `billboard_Runs\syn_1\`）—— 五处用途不同，都必须有
- `banner_rom.hex` 4 份（根 / `src\rom\` / `src\hdl\` / `billboard_Runs\syn_1\`）—— 同上
  > 其中 `src\hdl\` 那份是 **TD 综合时 `$readmemh` 实际读取的位置**（相对路径按 .v 文件所在目录解析），
  > 缺了不报 ERROR，只报 `CRITICAL-WARNING`，但 ROM 会是空的 → 上板黑屏。

---

## 六、四个运行环境 + 常用命令速查

同一个工程的文件分属 4 个环境，**用错工具会得到莫名其妙的报错**：

| 代号 | 环境 | 用途 |
|---|---|---|
| **【TD】** | 安路 TangDynasty 6.2.1（图形界面） | 打开工程、综合、布局布线、烧录 |
| **【GB】** | Git Bash（命令行） | 跑仿真脚本、跑 Python 工具 |
| **【IC】** | IC Coder（VS Code 插件，自带 iverilog） | 备用仿真器（不装也能跑，脚本会自动找） |
| **【硬件】** | 开发板 + 显示器 + TF 卡 | 上板验证 |

**最常用的 6 条命令**：

| 想干什么 | 在哪敲 |
|---|---|
| 打开工程 | 双击 `scripts\1_open_project.bat` |
| 打包图片 + 写 TF 卡 | 双击 `scripts\4_write_card.bat` |
| 跑全套仿真（21 项 / 313 条断言） | 【GB】`cd /c/FPGA/billboard_prj/sim && bash run_iverilog.sh` |
| 只跑一个模块 | 【GB】`bash run_iverilog.sh key`（或 `audio` / `sched` / `ebm` 等，见速查卡）|
| 看仿真中文结论 | 【GB】`python check_results.py` |
| 清临时产物 | 双击 `scripts\3_clean_temp.bat` |

**三条关键规则**：
1. **`tb_*.v` 绝对不要加进 TD 工程**（加了会综合出一堆无用逻辑甚至报错）。
2. **两个 `.hex` 要放多处**：工程根 + `src\rom\` + `src\hdl\` + `billboard_Runs\syn_1\` **四处都要有**；
   **`audio_rom.hex` 另加 `sim\`**（共五处，供 `tb_audio_player`），`banner_rom.hex` 四处即可。
3. **改了任何 `.v`，必须重跑仿真**，再重跑 `python tools/build_manual.py`，最后才上板。

---

## 七、与官方例程的四个实质差异（答辩要点）

赛题指南 1.3 注明：*"提交作品中的整体实现架构、音频和图片处理方法不能和参考实例相同。"*

| 层面 | 官方例程 | 本作品 |
|---|---|---|
| 图片组织 | FAT32 目录扫描 | **EBM1 私有容器 + 索引表** |
| 音频来源 | 内部 DDS 方波 → I2S 回环 → 自解回 PCM | **PC 侧预生成 PCM → 直送 HDMI** |
| 切换控制 | 单一按键直通 | **三层优先级调度 + 状态机** |
| 画面处理 | 无 | **OSD 滚动字幕 + 淡入淡出转场** |

> 详细对比见手册**附录 A**；合规相关的完整论述见交付源目录里的
> `例程复用边界与差异化实现方案.md`。
