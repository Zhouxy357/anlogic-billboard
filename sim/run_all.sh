#!/usr/bin/env bash
#============================================================================
# run_all.sh —— 一条命令跑完 4 个仿真，并打印 ASCII 结论汇总
#----------------------------------------------------------------------------
# 用法（在 sim 目录下，用 Git Bash 执行）：
#     cd <工程路径>/fpga_billboard/sim
#     ./run_all.sh              # 跑全部 4 个
#     ./run_all.sh ebm          # 只跑容器解析
#
# 结果：
#   - 每个测试的完整输出存到 logs/<名字>.log（UTF-8）
#   - 最后打印一张 ASCII 汇总表，一眼看出过没过
#
# 为什么要有 ASCII 结论行：
#   ModelSim 在本机 cp936 环境下偶尔会把中文多字节序列截断，日志里的中文
#   可能变成乱码。但 tb 里额外打印的 "### RESULT ... ###" 是纯 ASCII，
#   任何编码环境下都不会坏，所以判断结果一律以它为准。
#============================================================================
set -u

# ---- 找到 vsim/vlog：先在 PATH 里找，找不到再试常见安装位置 ----
if ! command -v vsim >/dev/null 2>&1; then
    for d in /c/modeltech64_2020.4/win64 /c/modeltech64/win64 \
             "/c/Program Files/modeltech64/win64" /c/questasim/win64; do
        if [ -x "$d/vsim" ] || [ -x "$d/vsim.exe" ]; then
            export PATH="$d:$PATH"
            break
        fi
    done
fi
if ! command -v vlog >/dev/null 2>&1; then
    echo "!! 找不到 ModelSim 的 vlog/vsim。"
    echo "   请把 ModelSim 的 win64 目录加进 PATH，例如："
    echo "   export PATH=\"/c/modeltech64_2020.4/win64:\$PATH\""
    exit 1
fi

HDL=../src/hdl
LOGS=logs
mkdir -p "$LOGS"

# 重新建库，保证干净
rm -rf work
vlib work >/dev/null 2>&1 || { echo "!! vlib work 失败"; exit 1; }

# 文件名 -- 测试名 -- 需要编译的源文件
TESTS=(
  "tb_key_debounce|① 按键消抖|$HDL/key_debounce.v"
  "tb_audio_player|② 音频播放器（跨时钟域握手）|$HDL/audio_rom.v $HDL/audio_player.v"
  "tb_play_scheduler|③ 三层优先级调度器|$HDL/play_scheduler.v"
  "tb_ebm_reader|④ 私有容器解析|$HDL/ebm_reader.v"
)

# 只跑指定的一个？
WANT="${1:-all}"

echo "================================================================"
echo " ModelSim 批量仿真"
echo " 工作目录 : $(pwd)"
echo "---------------------------------------------------------------"

n_pass=0
n_fail=0
lines=()

for item in "${TESTS[@]}"; do
    IFS='|' read -r tb title srcs <<< "$item"

    # 名字过滤
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
    if ! vlog $srcs "$tb.v" > "$LOGS/${tb}.vlog" 2>&1; then
        echo "!! 编译失败，详见 $LOGS/${tb}.vlog"
        sed -n '1,20p' "$LOGS/${tb}.vlog"
        n_fail=$((n_fail+1))
        lines+=("FAIL   $tb   （编译失败）")
        continue
    fi
    if grep -q "Errors: [1-9]" "$LOGS/${tb}.vlog"; then
        echo "!! 编译有错误，详见 $LOGS/${tb}.vlog"
        grep -E "\*\* Error|Errors:" "$LOGS/${tb}.vlog" | head -10
        n_fail=$((n_fail+1))
        lines+=("FAIL   $tb   （编译报错）")
        continue
    fi

    # ---- 仿真 ----
    vsim -c "$tb" -do "run -all; quit -f" -l "$log" >/dev/null 2>&1
    rc=$?

    # ---- 提取 ASCII 结论行 ----
    res=$(grep -a -o "### RESULT .* ###" "$log" | tail -1)
    if [ -z "$res" ]; then
        if [ $rc -ne 0 ]; then
            res="### RESULT $tb : FAIL  (vsim 异常退出 rc=$rc) ###"
        else
            res="### RESULT $tb : FAIL  (日志里没有结论行，可能卡住或没跑到结尾) ###"
        fi
    fi

    echo "  $res"

    if echo "$res" | grep -q "PASS"; then
        n_pass=$((n_pass+1))
        lines+=("PASS   $tb   $res")
    else
        n_fail=$((n_fail+1))
        lines+=("FAIL   $tb   $res")
    fi

    # 把失败的条目顺手列出来，省得翻日志
    if grep -aq "### FAIL idx=" "$log"; then
        echo "  ---- 这个测试里没通过的检查项 ----"
        # 用 Python 按 UTF-8 容错解码，中文乱码也不影响找到 ">>>" 那两行
        PY=""
        for c in "C:/Users/asus/.workbuddy/binaries/python/versions/3.13.12/python.exe" python3 python; do
            if command -v "$c" >/dev/null 2>&1; then PY="$c"; break; fi
        done
        if [ -n "$PY" ]; then
            "$PY" - "$log" <<'PYEOF'
import sys
raw = open(sys.argv[1], 'rb').read().decode('utf-8', errors='replace')
for i, l in enumerate(raw.splitlines()):
    if '失败' in l or '### FAIL idx=' in l:
        print('   ', l.strip())
PYEOF
        else
            grep -a "### FAIL idx=" "$log" | sed 's/^/    /'
        fi
    fi
done

echo ""
echo "================================================================"
echo " 汇总"
echo "----------------------------------------------------------------"
for l in "${lines[@]}"; do
    echo "  $l"
done
echo "----------------------------------------------------------------"
echo "  通过 $n_pass 个测试程序，失败 $n_fail 个"
echo ""
if [ "$n_fail" -eq 0 ]; then
    echo "  可以去 TD 建工程综合了。"
else
    echo "  有失败项，先别上板。把 logs/ 下对应日志发出来就能定位。"
fi
echo "  （日志目录：$LOGS/ ，UTF-8 编码，用记事本/VSCode 都能直接看）"
echo "================================================================"

exit "$n_fail"
