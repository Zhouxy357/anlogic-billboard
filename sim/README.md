# sim 目录 —— 行为仿真

上板之前先把这几个仿真跑一遍，**能省掉 90% 的上板调试时间**。

> **本文是 sim 目录的技术细节手册。**
> 想知道"仿真怎么跑、结果怎么看、跑不过怎么查"这种入门级问题
> → 看 **`docs\仿真操作说明.md`**（更易懂、更完整）。

> 这个目录下的仿真已经在两套工具链上**实际跑通**（2026-10-11 复核，结论不变）：
> * ModelSim SE-64 2020.4：4 个测试程序、共 48 项检查，全部通过
> * IC Coder 自带 iverilog 12.0：2 项静态检查 + 同一批 48 项检查，全部通过

## 怎么跑

本目录有两套脚本，随便用哪套都行，结论完全一致：

| 脚本 | 用哪个仿真器 | 额外能力 |
|------|--------------|----------|
| `run_all.sh` | ModelSim（需自己装） | 无 |
| `run_iverilog.sh` | iverilog（IC Coder 插件自带，免安装） | 多跑 2 项静态检查 |

### 方式一：iverilog（推荐，零安装）

```bash
cd {你的路径}/fpga_billboard/sim
./run_iverilog.sh              # 全部
./run_iverilog.sh ebm          # 只跑容器解析（key / audio / sched / ebm）
```

除了 4 个功能仿真，它还会跑两项**静态检查**（这是 ModelSim 路线没有的）：

* **顶层连线检查** —— 用 `ip_stubs.v` 里 14 个官方 IP 的空壳，
  把整个 `top_billboard.v` 过一遍网表，抓端口名拼错、位宽不匹配、信号漏接。
* **`-Wall` 严格编译** —— 抓隐式网线、位宽静默截断等隐患。

### 方式二：ModelSim 命令行

```bash
cd {你的路径}/fpga_billboard/sim
./run_all.sh              # 跑全部 4 个
./run_all.sh ebm          # 只跑容器解析
```

它会自动：建库 → 依次编译并仿真 → 把每个测试的完整日志存到 `logs/` →
最后打一张 ASCII 汇总表。

**之所以推荐这个方式**：日志是通过 `vsim -l` 写的，是**干净的 UTF-8**，中文完全正常。

### 方式三：ModelSim 图形界面

1. 打开 ModelSim
2. 在 Transcript 窗口里切到本目录，然后执行：

   ```tcl
   cd {C:/你的路径/fpga_billboard/sim}
   do run_all.do
   ```

> ⚠️ `run_all.do` **只适用于图形界面**。不要用 `vsim -c -do "do run_all.do"` 跑它——
> 批处理模式下 testbench 结尾的 `$finish` 会直接把整个会话结束掉，后面的测试跑不到。
> 命令行请用上面的 `run_all.sh`。

## 结果怎么看（重要）

**每个 testbench 结尾都会打印一行纯 ASCII 的结论：**

```
### RESULT tb_play_scheduler : PASS  (18/18) ###
### RESULT tb_ebm_reader : PASS  (17/17) ###
```

**以这一行为准。** 原因是两套仿真器都有各自的“中文显示坑”：

* **ModelSim**：在本机 cp936 环境下，往 Transcript 窗口写中文时偶尔会把多字节序列
  截断，导致中文显示成乱码（例如 `鍥�0 Fletcher 鏍￠獙鍊�`）。
* **iverilog**：把字符串**通过 `[1023:0]` 位向量参数**传递时，非 ASCII 字节高位会被
  补成 `0xff`，日志里就是 `閫氳繃锛�` 这种乱码（见下面“坑”一节）。

两种情况下 **ASCII 都不受影响**，所以“到底过没过”一律看 `### RESULT ... ###` 行。
日志文件本身（`logs/` 和 `ivlogs/`）都是**干净的 UTF-8**，用记事本 / VSCode 打开中文正常。

想看中文详情的两条路：

1. **打开 `logs/`（ModelSim）或 `ivlogs/`（iverilog）下的日志文件**，都是干净的 UTF-8
2. 在 sim 目录下执行：

   ```bash
   python check_results.py                  # 汇总所有日志，列出没通过的检查项
   python check_results.py tb_ebm_reader    # 打印某个测试的完整过程
   ```

没通过时，日志里会出现 `### FAIL idx=3 ###` 这样的 ASCII 标记，
它**上面紧挨着的那行**就是该项的说明。

> 检查项的标签是 `C01`、`C02`…… 这是**故意用编号而不是中文**的 ——
> 中文一旦经过位向量参数传递就会变乱码。每个标签对应的中文说明写在
> tb 源码里那一行的**行尾注释**里，`check_results.py` 会把它一起打出来。

## 每个测试在测什么

| 文件 | 测的模块 | 重点 | 检查项 |
|------|----------|------|--------|
| `tb_key_debounce.v` | `key_debounce` | 毛刺不出脉冲；按住才出 1 拍；松手不出多余脉冲 | 6 |
| `tb_audio_player.v` | `audio_player` | 采样率≈48kHz；左右一致；**ROM 里真的有素材**；换段生效 | 7 |
| `tb_play_scheduler.v` | `play_scheduler` | 三层优先级；缓冲区指针来回切且**永不越界**；按键不连击 | 18 |
| `tb_ebm_reader.v` | `ebm_reader` | 头部/索引解析；写入像素个数；Fletcher 校验；各种错误码 | 17 |

## 文件清单

| 文件 | 作用 |
|------|------|
| `run_iverilog.sh` | **iverilog 一键跑全部 + 2 项静态检查（推荐，免安装）** |
| `ip_stubs.v` | 14 个官方 IP 的空壳，**只用于顶层连线检查**，不是仿真模型 |
| `run_all.sh` | ModelSim 命令行一键跑全部 |
| `run_all.do` | ModelSim 图形界面一键跑全部 |
| `check_results.py` | 读 `logs/` / `ivlogs/` 打结论表 |
| `audio_rom.hex` | 音频素材，`audio_rom.v` 要读它。**已生成好**（32768 行） |

> 跑完脚本后会自动多出 4 个目录：`logs/`（ModelSim 日志）、`ivlogs/`（iverilog 日志）、
> `ivl_tmp/`（中间 `.vvp`）、`work/`（ModelSim 编译库）。**这些都是可再生的临时产物，
> 删掉不影响任何东西**，下次跑脚本会自动重建。交付/打包前可以整个删掉。

## 几个容易踩的坑

* **【iverilog 专属】中文不要通过位向量参数传**。
  写成 `input [1023:0] name;` 再 `$display("%0s", name)`，中文会被烧成 `0xff`。
  这是 iverilog 的已知行为，**不是编码问题**（日志文件本身仍是合法 UTF-8）。
  正确做法：参数只传 ASCII 标签（如 `"C01"`），中文说明写成行尾注释，或直接
  `$display("...中文...")` 内联打印。

* **【iverilog 专属】`begin : label` 块里不能声明 `reg`**（那是 SystemVerilog 语法）。
  ModelSim 宽松模式允许，iverilog 严格模式会报 `syntax error`。
  把局部变量提到模块级即可。

* **`audio_rom.hex` 必须在本目录**。`audio_rom.v` 里写的是 `$readmemh("audio_rom.hex", mem)`，
  含义是“在仿真器的当前工作目录下找”。所以仿真必须在 `sim/` 目录下运行。
  如果文件丢了，用下面这条命令重新生成（在工程根目录执行）：

  ```bash
  python tools/gen_audio_rom.py -o sim/audio_rom.hex
  ```

  **丢了会怎样**：ROM 全 0，前几个测试照样“通过”，但一点声音都没有。
  所以 `tb_audio_player` 专门加了一项“ROM 里真的有素材”的检查来兜这个底。

* **`$readmemh` 的文件名不能写成参数**。ModelSim 会把参数当层次名解析，
  报 `vopt-7063 Failed to find 'HEX_FILE' in hierarchical name`。只能写字面量字符串。

* **`tb_ebm_reader.v` 里自己拼了一个迷你容器**（8 行高，跑得快）。
  如果你改了 `ebm_reader.v` 的容器格式，记得同步改这里。

* **想看波形**：ModelSim 图形界面 `vsim tb_xxx`（不带 `-c`），
  然后 `add wave -r /*`、`run -all`；

  iverilog 里加 `-DDUMP_VCD`（或直接改 tb 加 `$dumpfile/$dumpvars`）后
  用 `vvp` 跑出 `.vcd`，再用 GTKWave 或 IC Coder 的 VCD 查看器打开。

* **`ip_stubs.v` 不能用来跑功能仿真**。它内部是空的，只是为了骗过
  iverilog 的模块解析、让顶层能通过 elaboration。真正的功能验证靠 4 个 testbench。
