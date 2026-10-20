#!/usr/bin/env bash
#============================================================================
# run_iverilog.sh —— 用 IC Coder 自带 iverilog 一键跑完所有检查
#----------------------------------------------------------------------------
# 和 run_all.sh（ModelSim 版）的区别：
#   * 不需要装 ModelSim，iverilog 是 IC Coder 插件自带的
#   * 除了 4 个功能仿真，还多跑 2 项静态检查：
#       - 顶层连线检查（用 IP 空壳，抓端口名拼错 / 位宽不匹配）
#       - -Wall 严格编译（抓隐式网线、位宽截断等隐患）
#
# 用法（在 sim 目录下，用 Git Bash 执行）：
#     cd <工程路径>/fpga_billboard/sim
#     ./run_iverilog.sh              # 跑全部
#     ./run_iverilog.sh ebm          # 只跑容器解析
#
# 结果：
#   - 功能仿真的完整输出存到 ivlogs/<名字>.log
#   - 最后打印 ASCII 汇总表
#============================================================================
set -u

# ---- 找 iverilog：先 PATH，再 IC Coder 插件内置目录 ----
ICROOT_DEFAULT="/c/Users/asus/.vscode/extensions/iccoderagenticverilogplatform.iccoder-2.0.9-win32-x64/tools/iverilog/win"
if command -v iverilog >/dev/null 2>&1; then
    IVL="$(command -v iverilog)"
elif [ -n "${ICCODER_TOOLS_ROOT:-}" ] && [ -x "$ICCODER_TOOLS_ROOT/bin/iverilog" ]; then
    IVL="$ICCODER_TOOLS_ROOT/bin/iverilog"
elif [ -x "$ICROOT_DEFAULT/bin/iverilog.exe" ]; then
    IVL="$ICROOT_DEFAULT/bin/iverilog.exe"
else
    # 自己去插件目录里找
    IVL=""
    for d in /c/Users/*/.vscode/extensions/*iccoder*/tools/iverilog/win/bin/iverilog.exe \
             /c/Users/*/.cursor/extensions/*iccoder*/tools/iverilog/win/bin/iverilog.exe; do
        if [ -x "$d" ]; then IVL="$d"; break; fi
    done
fi

if [ -z "$IVL" ] || [ ! -x "$IVL" ]; then
    echo "!! 找不到 iverilog。"
    echo "   请确认 IC Coder 插件已安装（它自带 iverilog），或把 iverilog 加进 PATH。"
    exit 127
fi

# vvp 和 iverilog 在同一个 bin 目录
IVL_BIN="$(dirname "$IVL")"
VVP="$IVL_BIN/vvp.exe"
[ -x "$VVP" ] || VVP="$IVL_BIN/vvp"

HDL=../src/hdl
SUP=../src/support
INC=../src/include
IPD=../src/ip
BUILD=ivl_tmp
LOGS=ivlogs
mkdir -p "$BUILD" "$LOGS"

# 所有编译都带上 include 目录（color_bar.v / ebm_reader.v 等会 `include）
IVLFLAGS="-g2012 -I$INC"

# tb 编译用的严格选项。
# 为什么额外关掉 timescale 这一类警告：
#   官方 support/ 下的文件（color_bar.v / video_*.v / sd_card_*.v / spi_master.v ...）
#   本身不带 `timescale，而 testbench 要带（不然打印的时间没单位）。
#   两者混用会报 "no explicit time unit" 警告。
#   官方代码要保持原样不能动，所以这一类警告在这里显式关掉；
#   其它所有 -Wall 警告（隐式网线、位宽截断等）依然会报出来。
TBFLAGS="-Wall -Wno-timescale"

echo "================================================================"
echo " iverilog 批量检查"
echo " iverilog : $($IVL -V 2>&1 | head -1)"
echo " 工作目录 : $(pwd)"
echo "---------------------------------------------------------------"

n_pass=0
n_fail=0
lines=()

rec() {  # rec <PASS|FAIL> <名字> <备注>
    if [ "$1" = "PASS" ]; then n_pass=$((n_pass+1)); else n_fail=$((n_fail+1)); fi
    lines+=("$1   $2   $3")
}

#============================================================================
# 第一组：静态检查（不需要 testbench）
#============================================================================
echo ""
echo "=================== ⓪ 静态检查 ==================="

# ---- 0a. 顶层连线检查（自写 RTL + IP 空壳）----
echo -n "  [连线] 顶层实例化 / 端口名 / 位宽 ... "
out=$("$IVL" $IVLFLAGS -o "$BUILD/top.vvp" "$HDL"/*.v ip_stubs.v 2>&1)
if [ -z "$out" ]; then
    echo "OK"
    rec PASS "top_elaborate" "零错误零警告"
else
    echo "有问题"
    echo "$out" | head -20 | sed 's/^/        /'
    rec FAIL "top_elaborate" "$(echo "$out" | grep -c error) 处错误"
fi

# ---- 0b. -Wall 严格编译 ----
echo -n "  [严格] -Wall 全量编译 ... "
out=$("$IVL" $IVLFLAGS -Wall -o "$BUILD/top_wall.vvp" "$HDL"/*.v ip_stubs.v 2>&1)
if [ -z "$out" ]; then
    echo "OK"
    rec PASS "wall_compile" "零警告"
else
    echo "有警告"
    echo "$out" | head -20 | sed 's/^/        /'
    rec FAIL "wall_compile" "$(echo "$out" | grep -c warning) 条警告"
fi

#============================================================================
# 第二组：功能仿真
#============================================================================
TESTS=(
  "tb_key_debounce|① 按键消抖|$HDL/key_debounce.v"
  "tb_audio_player|② 音频播放器（跨时钟域握手）|$HDL/audio_rom.v $HDL/audio_player.v"
  "tb_play_scheduler|③ 三层优先级调度器|$HDL/play_scheduler.v"
  "tb_ebm_reader|④ 私有容器解析|$HDL/ebm_reader.v"
  "tb_color_bar|⑤ 720p 视频时序发生器|$SUP/color_bar.v"
  "tb_video_timing_data|⑥ 视频时序输出级（2 拍延迟 + 每帧取数请求）|$SUP/video_timing_data.v $SUP/color_bar.v"
  "tb_video_delay|⑦ 像素与同步对齐（消隐区/错位）|$SUP/video_delay.v"
  "tb_video_rgb_to_axis|⑧ RGB 转 AXI-Stream（含 last 恒 0 的官方遗留点）|$SUP/video_rgb_to_axis_640x480.v"
  "tb_seg_status|⑨ 数码管状态位（判定两个 9 的成因）|$HDL/seg_status.v"
  "tb_seg_scan|⑩ 数码管动态扫描（位选/段码对应）|$SUP/seg_scan.v"
  "tb_transition_ctrl|⑪ 淡入淡出转场（换帧必须全黑）|$HDL/transition_ctrl.v"
  "tb_osd_mixer|⑫ 字幕叠加 + 亮度乘算（含位序不镜像）|$HDL/osd_mixer.v $HDL/banner_rom.v"
  "tb_audio_arc|⑬ HDMI 音频时钟再生参数（CTS 数时钟不数样本）|$SUP/audio_arc_calculate.v"
  "tb_startup_pulse|⑭ 上电延时脉冲（第 CNT_MAX 拍出 1 拍宽脉冲）|$SUP/startup_pulse.v"
  "tb_rom_content|⑮ 素材 ROM 内容校验（2048 字字幕点阵 + 4x8192 音频样本）|$HDL/banner_rom.v $HDL/audio_rom.v"
  "tb_spi_master|⑯ SPI 主机（全双工对发对收 + CPOL/CPHA/分频）|$SUP/spi_master.v"
  "tb_sd_card|⑰ SD 卡全链路（初始化 + 读扇区 + 写扇区，挂假卡对账）|$SUP/sd_card_sec_read_write.v $SUP/sd_card_cmd.v $SUP/spi_master.v $SUP/sd_card_top.v sd_card_model.v"
  "tb_frame_rw|⑱ 帧缓存链路（V_FLIP 地址映射 + 双缓冲 + 读写整帧）|$SUP/frame_fifo_write.v $SUP/frame_fifo_read.v $SUP/frame_read_write.v $IPD/afifo_16_32_256.v $IPD/afifo_32_16_256.v|dangling input port;expects 10 bits;Padding 1 high bits"
  "tb_seg_595|⑲ 74HC595 数码管串行驱动（16bit 帧 / 移位锁存时序）|$HDL/seg_595.v"
  "tb_audio_fifo|⑳ 音频跨时钟域 FIFO（格雷码满/空 + 顺序一致）|$HDL/audio_fifo.v"
  "tb_sd_arbiter|㉑ SD 读通道仲裁（扇区边界抢占 + 补满才还）|$HDL/sd_arbiter.v"
  "tb_audio_stream|㉒ TF 卡音频流（水位迟滞 + 跳格 + 回卷）|$HDL/audio_stream.v"
)

WANT="${1:-all}"

for item in "${TESTS[@]}"; do
    IFS='|' read -r tb title srcs wallow <<< "$item"

    if [ "$WANT" != "all" ]; then
        case "$tb" in
            *"$WANT"*) ;;
            *) continue ;;
        esac
    fi

    echo ""
    echo "=================== $title ==================="
    log="$LOGS/${tb}.log"

    # ---- 编译 ----
    # wallow：本用例【已知无害】的告警指纹（分号分隔的子串）。
    #   只允许两种来源：① 厂商生成的 IP 内部悬空端口；② 官方 support 代码里
    #   本身存在的位宽不一致（改了就不是"原样"了，所以只能放行）。
    #   清单之外的任何告警仍然判失败 —— 保证不会把新引入的隐患放过去。
    cerr=$("$IVL" $IVLFLAGS $TBFLAGS -o "$BUILD/${tb}.vvp" $srcs "$tb.v" 2>&1)
    if [ -n "$cerr" ]; then
        if echo "$cerr" | grep -qi "error"; then
            echo "!! 编译有错误："
            echo "$cerr" | head -20 | sed 's/^/        /'
            rec FAIL "$tb" "编译失败"
            continue
        fi
        wlines=$(echo "$cerr" | grep -i "warning")
        if [ -z "$wallow" ]; then
            unexpected="$wlines"
        else
            unexpected=$(echo "$wlines" | grep -Ev "$(echo "$wallow" | tr ';' '|')")
        fi
        if [ -n "$unexpected" ]; then
            echo "   [警告] 出现清单外的编译告警，请处理（清单：$wallow）："
            echo "$unexpected" | head -20 | sed 's/^/        /'
            rec FAIL "$tb" "有清单外告警"
            continue
        fi
        echo "   [告警] $(echo "$wlines" | grep -c .) 条已知无害告警，已放行"
    fi

    # ---- 语法错误会阻止产出 vvp ----
    if [ ! -f "$BUILD/${tb}.vvp" ]; then
        rec FAIL "$tb" "编译失败"
        continue
    fi

    # ---- 仿真 ----
    "$VVP" "$BUILD/${tb}.vvp" > "$log" 2>&1
    rc=$?

    res=$(grep -a -o "### RESULT .* ###" "$log" | tail -1)
    if [ -z "$res" ]; then
        if [ $rc -ne 0 ]; then
            res="### RESULT $tb : FAIL  (vvp 异常退出 rc=$rc) ###"
        else
            res="### RESULT $tb : FAIL  (日志里没有结论行) ###"
        fi
    fi
    echo "  $res"

    if echo "$res" | grep -q "PASS"; then
        rec PASS "$tb" "$(echo "$res" | sed 's/### RESULT [^ ]* : //; s/ ###//')"
    else
        rec FAIL "$tb" "$(echo "$res" | sed 's/### RESULT [^ ]* : //; s/ ###//')"
        if grep -aq "### FAIL idx=" "$log"; then
            echo "  ---- 没通过的检查项 ----"
            grep -aB1 "### FAIL idx=" "$log" | sed 's/^/        /'
        fi
    fi
done

#============================================================================
# 汇总
#============================================================================
echo ""
echo "================================================================"
echo " 汇总（iverilog）"
echo "----------------------------------------------------------------"
for l in "${lines[@]}"; do
    echo "  $l"
done
echo "----------------------------------------------------------------"
echo "  通过 $n_pass 项，失败 $n_fail 项"
echo ""
if [ "$n_fail" -eq 0 ]; then
    echo "  自写 RTL 全部检查通过，可以去 TD 建工程综合了。"
    echo "  （注意：官方 IP 在 TD 里的行为，iverilog 无法覆盖，最终仍需上板验证）"
else
    echo "  有失败项，先别上板。把上面的输出或 $LOGS/ 下的日志发出来就能定位。"
fi
echo "  （日志目录：$LOGS/）"
echo "================================================================"

exit "$n_fail"
