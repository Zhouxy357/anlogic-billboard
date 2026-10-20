#============================================================================
# run_all.do —— 在 ModelSim 图形界面里一键跑完 4 个仿真
#----------------------------------------------------------------------------
# 【怎么用】
#   1) 打开 ModelSim（图形界面）
#   2) 在下方 Transcript 窗口里先切到本目录：
#          cd {你的工程路径}/fpga_billboard/sim
#   3) 执行：
#          do run_all.do              # 跑全部 4 个
#          do run_all.do ebm          # 只跑容器解析（关键字：key/audio/sched/ebm）
#
# 【重要】本脚本是给“图形界面”用的。
#   在命令行批处理模式（vsim -c）里不要用它，因为 testbench 结尾的 $finish
#   会直接把整个批处理会话结束掉，后面的测试就跑不到了。
#   命令行模式请用同目录下的 run_all.sh。
#
# 【关于中文乱码（请务必看这一段）】
#   ModelSim 在本机 cp936 环境下，往控制台/transcript 写中文时，偶尔会把
#   多字节序列切断，导致中文变乱码。这是显示层的问题，不代表仿真出错。
#   本脚本做了两件事来规避：
#     ① 每次仿真都加 "-l logs/<名字>.log"，这样写出的日志是**干净的 UTF-8**，
#       中文完全正常。想看详细过程就去 logs/ 里翻。
#     ② 每个 testbench 结尾都会打印一行**纯 ASCII** 的结论：
#           ### RESULT tb_key_debounce : PASS  (6/6) ###
#       ASCII 永远不受编码影响，所以“到底过没过”以这一行为准。
#   本脚本自己的提示文字也全部用 ASCII，就是为了不乱码。
#============================================================================

set HDL  ../src/hdl
set LOGS logs

#---------------------------------------------------------------
# 建库
#---------------------------------------------------------------
if {[file exists work]} { vdel -all }
vlib work
file mkdir $LOGS

set n_pass  0
set n_fail  0
set summary {}

#---------------------------------------------------------------
# 从某次仿真的日志里把结论行读出来
#   （日志是 UTF-8，中文可能被 Tcl 读成乱码，但结论行是 ASCII，匹配没问题）
#---------------------------------------------------------------
proc read_result {tb} {
    global LOGS
    set path "$LOGS/$tb.log"
    if {![file exists $path]} {
        return "### RESULT $tb : FAIL  (no log file - simulation did not start) ###"
    }
    set fp  [open $path r]
    set txt [read $fp]
    close $fp

    set res ""
    foreach line [split $txt "\n"] {
        if {[string match "*### RESULT*" $line]} {
            set res [string trim $line]
        }
    }
    if {$res eq ""} {
        return "### RESULT $tb : FAIL  (no RESULT line - stuck or did not reach the end) ###"
    }
    return $res
}

#---------------------------------------------------------------
# 跑一个测试：卸载旧仿真 -> 编译 -> 仿真 -> 打印结论
#---------------------------------------------------------------
proc run_one {tb title srcs} {
    global LOGS n_pass n_fail summary

    puts "\n\n=================== $title ==================="

    # 先把上一次的仿真卸掉，否则 work 库会被占用，vlog 会失败
    catch {quit -sim}
    catch {vdel -lib work -all}

    # ---- 编译 ----
    if {[catch {eval vlog $srcs $tb.v} msg]} {
        puts "!! COMPILE FAILED : $msg"
        incr n_fail
        lappend summary "FAIL   $tb   (compile error)"
        return
    }

    # ---- 仿真（-l 让日志写成干净的 UTF-8） ----
    if {[catch {eval vsim -l $LOGS/$tb.log $tb} msg]} {
        puts "!! SIM START FAILED : $msg"
        incr n_fail
        lappend summary "FAIL   $tb   (cannot start simulation)"
        return
    }
    run -all

    # ---- 结论 ----
    set res [read_result $tb]
    puts "\n  ---- $tb result ----"
    puts "  $res"

    if {[string match "*PASS*" $res]} {
        incr n_pass
        lappend summary "PASS   $tb   $res"
    } else {
        incr n_fail
        lappend summary "FAIL   $tb   $res"

        # 列出没通过的检查项编号（### FAIL idx= 是 ASCII，不会乱码）
        set fp  [open $LOGS/$tb.log r]
        set txt [read $fp]
        close $fp
        puts "  ---- failed check indexes ----"
        foreach line [split $txt "\n"] {
            if {[string match "*### FAIL idx=*" $line]} {
                puts "    [string trim $line]"
            }
        }
        puts "  (open $LOGS/$tb.log to see which check each index is:"
        puts "   the Chinese line right above '### FAIL idx=N' is its description)"
    }
}

#---------------------------------------------------------------
# 选择要跑哪些
#   【注意】ModelSim 的 do 里 $argv 有时拿到的是 vsim 自己的参数（例如 -c），
#   所以这里只认 4 个关键字，其它任何内容都当成“全跑”，
#   避免出现“一个都没跑却报告全部通过”的假象。
#---------------------------------------------------------------
set filter [lindex $argv 0]

proc want {tb} {
    global filter
    if {![info exists filter]} { return 1 }
    switch -glob -- $filter {
        key   { return [expr {[string match *key*   $tb]}] }
        audio { return [expr {[string match *audio* $tb]}] }
        sched { return [expr {[string match *sched* $tb]}] }
        ebm   { return [expr {[string match *ebm*   $tb]}] }
        default { return 1 }
    }
}

set shown "ALL"
switch -glob -- $filter {
    key   { set shown "key_debounce only" }
    audio { set shown "audio_player only" }
    sched { set shown "play_scheduler only" }
    ebm   { set shown "ebm_reader only" }
}

puts "================================================================"
puts " ModelSim batch simulation"
puts " cwd     : [pwd]"
puts " filter  : $shown"
puts "---------------------------------------------------------------"

if {[want tb_key_debounce]} {
    run_one tb_key_debounce   "1) key debounce"                [list $HDL/key_debounce.v]
}
if {[want tb_audio_player]} {
    run_one tb_audio_player   "2) audio player (clock domain crossing)" [list $HDL/audio_rom.v $HDL/audio_player.v]
}
if {[want tb_play_scheduler]} {
    run_one tb_play_scheduler "3) play scheduler (3-level priority)"    [list $HDL/play_scheduler.v]
}
if {[want tb_ebm_reader]} {
    run_one tb_ebm_reader     "4) EBM1 container parser"       [list $HDL/ebm_reader.v]
}

#---------------------------------------------------------------
# 汇总
#---------------------------------------------------------------
puts "\n\n================================================================"
puts " SUMMARY"
puts "----------------------------------------------------------------"
foreach l $summary {
    puts "  $l"
}
puts "----------------------------------------------------------------"
puts "  $n_pass testbench(es) PASS, $n_fail FAIL"
puts ""
if {$n_fail == 0} {
    puts "  All good. Next step: create the project in TD and synthesize."
} else {
    puts "  Some checks failed - do NOT flash the board yet."
    puts "  Open the corresponding file under logs/ to see which check failed."
}
puts "  (logs are UTF-8, in $LOGS/)"
puts "================================================================"
