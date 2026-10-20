# build_all.tcl —— 对【现有】billboard.al 跑完整综合+布线+生成比特流
#----------------------------------------------------------------------------
# 与 step0_build.tcl 的区别：
#   step0 是"从零新建工程 + 只跑 design 步"；本脚本不动工程结构，
#   直接对现有工程（AC201 版顶层 + AC201 引脚约束）跑完整流程。
#
# 运行（Git Bash / cmd 均可，TD 路径必须是纯英文）：
#   C:\Anlogic\TD_6.2.1_Engineer_6.2.168.116\bin\td_commands_prompt.exe C:\FPGA\billboard_prj\scripts\build_all.tcl
#
# 产物：
#   billboard_Runs/syn_1/  综合中间结果
#   billboard_Runs/phy_1/billboard.bit   可直接用 BitWriter 烧
#----------------------------------------------------------------------------

set P {C:/FPGA/billboard_prj}

open_project $P/billboard.al
puts ">>>> BUILD: project opened"

# 重置 syn（会连带重置 phy_1），保证不用旧中间结果
reset_runs syn_1

# ---- 1) 综合（RTL → gate）----
launch_runs syn_1
wait_run syn_1 -quiet
puts ">>>> BUILD: synthesis finished"

# ---- 2) 布局布线（含时序分析）----
launch_runs phy_1
wait_run phy_1 -quiet
puts ">>>> BUILD: place & route finished"

# ---- 3) 生成比特流 ----
open_run phy_1
bitgen -bit $P/billboard_Runs/phy_1/billboard.bit
puts ">>>> BUILD: bitstream generated"

close_project
puts ">>>> BUILD: ALL DONE"
exit
