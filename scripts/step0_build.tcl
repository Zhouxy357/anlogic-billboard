# step0_build.tcl —— TD 命令行方式"从零重建 billboard 工程"
#
# 作用：
#   创建 billboard.al（顶层 top_billboard），加入全部源文件 + 引脚约束，
#   并跑 design 步（Read Design / elaborate）验证工程可综合。
#
# 运行方式（推荐用同目录的 .bat 双击）：
#   C:\Anlogic\TD_6.2.1_Engineer_6.2.168.116\bin\td_commands_prompt.exe <本文件>
#
# 注意：本脚本用绝对路径，从任何目录运行都可以。
# 依据：SWUG105_TCL_Command_User_Guide.pdf（TD 6.2 官方 TCL 手册）
#
# ⚠️ 重建前请注意：先备份或删除旧的 billboard.al / billboard_Runs，
#    否则会报 "Project ... already exists"。

set P {C:/FPGA/billboard_prj}

create_project billboard $P -family eg4 -device EG4S20BG256
open_project $P/billboard.al

top_module top_billboard

# 自研 11 个模块（seg_595 是 AC201 板级适配：14 根直驱 → 3 根 595 串行）
add_files "$P/src/hdl/top_billboard.v $P/src/hdl/key_debounce.v $P/src/hdl/play_scheduler.v $P/src/hdl/transition_ctrl.v $P/src/hdl/ebm_reader.v $P/src/hdl/banner_rom.v $P/src/hdl/osd_mixer.v $P/src/hdl/audio_rom.v $P/src/hdl/audio_player.v $P/src/hdl/seg_status.v $P/src/hdl/seg_595.v"

# IP 核（例程的 PLL / SDRAM / 异步 FIFO）
add_files "$P/src/ip/sys_pll.v $P/src/ip/video_pll.v $P/src/ip/PLL_HDMI_AUDIO.v $P/src/ip/sdram.v $P/src/ip/afifo_16_32_256.v $P/src/ip/afifo_32_16_256.v"

# 例程支撑模块
add_files "$P/src/support/frame_read_write.v $P/src/support/frame_fifo_read.v $P/src/support/frame_fifo_write.v $P/src/support/sd_card_top.v $P/src/support/sd_card_sec_read_write.v $P/src/support/sd_card_cmd.v $P/src/support/spi_master.v $P/src/support/color_bar.v $P/src/support/video_delay.v $P/src/support/video_timing_data.v $P/src/support/video_rgb_to_axis_640x480.v $P/src/support/hdmi_1_4b_transmitter_core_wrapper.enc.v $P/src/support/hdmi_phy_warpper.v $P/src/support/lane_lvds_10_1.v $P/src/support/audio_arc_calculate.v $P/src/support/startup_pulse.v $P/src/support/seg_scan.v"

# include 搜索路径（sdr_as_ram / global_def 等）
add_include_dir $P/src/include
add_files "$P/src/include/sdr_as_ram.enc.v $P/src/include/sdr_init_ref.enc.v $P/src/include/sdr_wrrd.enc.v"

# 引脚约束
add_files $P/src/constraints/pin.adc

# 跑 design 步（等价于 GUI 双击 Read Design）
launch_runs syn_1 -step design
wait_run syn_1 -quiet

puts ">>>> STEP0 DONE: project created, sources added, design step finished."
close_project
exit
