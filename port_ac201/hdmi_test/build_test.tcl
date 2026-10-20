#============================================================================
# build_test.tcl —— 建立 HDMI 诊断工程（顶层 top_hdmi_test）
#
# 运行：
#   C:\Anlogic\TD_6.2.1_Engineer_6.2.168.116\bin\td_commands_prompt.exe ^
#       C:\FPGA\billboard_prj\port_ac201\hdmi_test\build_test.tcl
#
# 注意：路径必须全英文（TD 不支持中文路径）；重复运行前先删 hdmi_test.al 和 hdmi_test_Runs。
#============================================================================

set P {C:/FPGA/billboard_prj}
set T $P/port_ac201/hdmi_test

create_project hdmi_test $T -family eg4 -device EG4S20BG256
open_project $T/hdmi_test.al

top_module top_hdmi_test

# 诊断顶层
add_files "$T/top_hdmi_test.v"

# HDMI 相关（PLL + 加密核 + PHY）
add_files "$P/src/ip/video_pll.v"
add_files "$P/src/support/hdmi_1_4b_transmitter_core_wrapper.enc.v $P/src/support/hdmi_phy_warpper.v $P/src/support/lane_lvds_10_1.v"

add_include_dir $P/src/include

# 引脚约束
add_files $T/pin_test.adc

# 跑 design 步（等价 GUI 双击 Read Design）
launch_runs syn_1 -step design
wait_run syn_1 -quiet

puts ">>>> HDMI TEST PROJECT CREATED"
close_project
exit
