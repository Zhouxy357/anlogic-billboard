# PC 端素材工具使用说明

> **【在哪运行】Git Bash**，在**工程根目录** `fpga_billboard/` 下打开并执行。
> 完整流程（含"产物该放哪"）见操作手册 **第 10 步**；本文是工具自身的参数手册。

这一目录下的脚本负责把"人能看懂的素材"变成"FPGA 能直接读的数据"。
所有脚本都用 **Python 3** 写，只依赖 Pillow（`pip install Pillow`）。

| 脚本 | 作用 | 产出 | 产出去哪 |
|------|------|------|----------|
| `gen_container.py` | 把若干张图片打包成 EBM1 私有容器 | `container.bin` | 用 `write_container.py` 写进 **TF 卡** |
| `write_container.py` | 把 `container.bin` 按扇区偏移写进 SD 卡 | （直接写卡） | **TF 卡**（物理磁盘） |
| `gen_audio_rom.py` | 生成 4 段 48kHz PCM 音效 | `audio_rom.hex` | **五处**：工程根 + `src\hdl\`（综合真读这里）+ `src\rom\`（存档）+ `billboard_Runs\syn_1\` + `sim\`（`tb_audio_player` 要读） |
| `gen_banner.py` | 把一行文字转成 2048×32 点阵 | `banner_rom.hex` + 预览图 | **四处**：工程根 + `src\hdl\` + `src\rom\` + `billboard_Runs\syn_1\`（`sim\` 不需要） |
| `build_manual.py` | 从模板 + 真实源码拼装操作手册 | `从零到上板操作手册.md` | **`docs\`** 目录 |
| `sync_delivery.py` | 把工作工程同步到交付源镜像（`--dry-run` 只看差异） | — | 交付源目录 |

> **改过 `.v` 源码或 `manual_template.md` 之后，必须重跑 `python tools/build_manual.py`**，
> 否则手册里的代码和实际工程会不一致。
>
> **两个 `.hex` 为什么要放多处**：`$readmemh` 的相对路径是 TD 按**该 .v 文件所在目录**
> （`src\hdl\`）解析的，另外工程根、`src\rom\`（存档）、综合运行目录也各要一份。
> **音频**额外放一份到 `sim\`（`tb_audio_player` 会真的跑、要读它）；**字幕**不用放 `sim\`。
> 少放只会报 `CRITICAL-WARNING`（不报 ERROR），但 ROM 内容为空 → 上板表现为静音 / 字幕纯色底。
> 详见主手册 4d 节的「★ TD 读 hex 的坑」。

---

## 一、图片：gen_container.py + write_container.py

### 1. 打包

```bash
# 把一个文件夹里的所有图片（按文件名排序）打包
python gen_container.py -i 图片文件夹/ -o container.bin

# 或者明确指定顺序
python gen_container.py -i 01开机.png 02广告A.jpg 03广告B.jpg 04应急.png -o container.bin
```

可选参数：

| 参数 | 说明 |
|------|------|
| `--mode fit` | 等比缩放后居中裁剪，铺满全屏（**默认**） |
| `--mode stretch` | 直接拉伸到 1280×720（会变形） |
| `--mode pad` | 等比缩放后加黑边居中 |
| `--lba N` | 容器在 SD 卡上的起始扇区，**默认 1048576（= 512 MiB 偏移）** |
| `--write 设备` | 打包完直接写卡（见下） |

最多 32 张图，建议 4~8 张。

### 2. 写卡

**先确认 SD 卡是哪个物理磁盘**（这一步绝对不能省）：

```bash
python write_container.py --list
```

会列出所有 PhysicalDrive 及其容量。打开 Windows 的"磁盘管理"，找到容量和你
手上那张 SD 卡一致的那一个，记住它的编号，比如 `2`。

```bash
# 管理员权限运行
python write_container.py \\.\PhysicalDrive2 --input container.bin --lba 1048576
```

脚本会打印"写到哪个盘、写到第几个扇区、写多少字节"，并要求你手动输入大写的
`YES` 才真正开写。

> ⚠️ **写错盘 = 那个盘上的数据全部损坏且无法恢复。**
> 如果你不想碰命令行，用图形工具也可以：HxD / WinHex 打开物理磁盘 →
> 跳到第 1048576 个扇区 → 把 `container.bin` 的内容粘贴进去 → 保存。

### 3. 为什么是 1048576 这个数字

SD 卡按 512 字节一个扇区编址。第 1048576 个扇区正好落在 **512 MiB 偏移**处，
对绝大多数 SD 卡来说已经越过了 FAT32 文件系统的元数据区，所以：

* 写完之后卡插回电脑，Windows 仍然认得出来（不会提示"需要格式化"）；
* FPGA 侧 `ebm_reader.v` 的 `CONTAINER_LBA` 参数和这里必须**完全一致**；
* 卡上不要再放别的文件，这张卡就专用于本作品。

---

## 二、音效：gen_audio_rom.py

### 新手：直接生成 4 段内置提示音

```bash
python gen_audio_rom.py
```

会生成：短提示音 / 双声提示 / 上升扫频 / 柔和铃声，每段 171ms。

### 用自己的素材

```bash
python gen_audio_rom.py -w 素材0.wav 素材1.wav 素材2.wav 素材3.wav
```

要求 16bit PCM 的 wav（别的格式先用剪辑软件转一下）。工具会自动：
* 重采样到 48000 Hz；
* 截断或循环补齐到 8192 个样本；
* 首尾做淡入淡出，避免"啪"的爆音；
* 写成 `audio_rom.hex`（32768 行，每行 4 位十六进制）。

音效段号和图片 id 的对应关系是 **`音效段 = 图片 id 的低 2 位`**，
也就是**一张图固定配一段音**，4 段按图片顺序循环。放满 8 张时是这样：

| 图片（按文件名排序） | 第1张 | 第2张 | 第3张 | 第4张 | 第5张 | 第6张 | 第7张 | 第8张 |
|---|---|---|---|---|---|---|---|---|
| 图片 id | 0 | 1 | 2 | 3 | 4 | 5 | 6 | 7 |
| 播放音效段 | 段0 | 段1 | 段2 | 段3 | 段0 | 段1 | 段2 | 段3 |

> 即第 1/5 张同音、第 2/6 张同音、第 3/7 张同音、第 4/8 张同音。
> 想让某张图配哪段音，调它的**文件名顺序**即可。应急（key4）会切到第 0 张 → 段 0。

---

## 三、字幕：gen_banner.py

```bash
python gen_banner.py -t "欢迎参观 2026 嵌入式芯片与系统设计竞赛作品"
python gen_banner.py -t "EMERGENCY  PLEASE  CALM  DOWN" --font C:/Windows/Fonts/arialbd.ttf
python gen_banner.py -t "安全第一" --repeat 4      # 同一句话重复铺满，滚动更连贯
```

| 参数 | 说明 |
|------|------|
| `-t` | 字幕文字（支持中文） |
| `--font` | 字体文件；默认自动从微软雅黑/黑体/宋体里挑一个 |
| `--size` | 字号，默认 26，**不要超过 32**（字幕条只有 32 像素高） |
| `--repeat` | 重复次数，铺满 2048 像素后滚动才是无缝循环 |

会同时输出 `banner_preview.png`，**先看这张图再烧板子**，确认文字没被截断。

---

## 四、生成完放哪里

三个产物：

```
container.bin    →  用 write_container.py 写进 TF 卡（见上）
audio_rom.hex    →  复制到五处：工程根 / src\hdl\ / src\rom\ / billboard_Runs\syn_1\ / sim\
banner_rom.hex   →  复制到四处：工程根 / src\hdl\ / src\rom\ / billboard_Runs\syn_1\
```

> ★ **为什么要放多处**：`$readmemh` 的相对路径由 TD 按**该 `.v` 文件所在目录**（`src\hdl\`）解析，
> 所以那一份是关键；再各留一份在工程根、`src\rom\`（存档）、综合运行目录。
> **音频**额外一份进 `sim\`（`tb_audio_player` 真的会跑）；**字幕**不需要 `sim\`。
> 少放只会报 `CRITICAL-WARNING`（不报 ERROR），但 ROM 内容为空 → 上板表现为
> "音频是静音 / 字幕条是纯色底"，很容易漏掉。改完 `.hex` 必须**重新综合 + 重新烧板**。
