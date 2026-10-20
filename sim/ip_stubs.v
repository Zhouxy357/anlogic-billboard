//============================================================================
// ip_stubs.v  ——  官方 IP 的空壳（仅用于 iverilog 顶层连线检查）
//----------------------------------------------------------------------------
// 顶层 top_billboard.v 例化了 14 个只有在安路 TD 里才存在的官方 IP
// （PLL / SDRAM 控制器 / HDMI 收发器 / SD 卡底层 / 数码管扫描 等）。
// 这些 IP 没有源码，iverilog 无法解析，会报 "Unknown module type"。
//
// 这个文件给每个 IP 造一个**端口完全一致**的空壳，只为让 iverilog 能把
// 整个顶层"过一遍网表"，从而检查：
//   * 例化名字有没有写错（端口名拼错会被抓出来）
//   * 位宽有没有不匹配
//   * 有没有漏接/重名信号
//
// 注意：这不是仿真模型，内部没有任何逻辑，**不能用它跑功能仿真**。
// 真正跑功能仿真用 sim/ 下的 19 个 testbench（它们只编译自写的 RTL）。
//
// 用法：
//   iverilog -g2012 -o /dev/null src/hdl/*.v sim/ip_stubs.v
//============================================================================
`timescale 1ns / 1ps

//------------------------------------------------ PLL × 3
module sys_pll (
    input  wire refclk,
    input  wire reset,
    output wire extlock,
    output wire clk0_out,
    output wire clk1_out,
    output wire clk2_out
);
endmodule

module video_pll (
    input  wire refclk,
    input  wire reset,
    output wire extlock,
    output wire clk0_out,
    output wire clk1_out
);
endmodule

module PLL_HDMI_AUDIO (
    input  wire refclk,
    input  wire reset,
    output wire extlock,
    output wire clk0_out,
    output wire clk1_out,
    output wire clk2_out
);
endmodule

//------------------------------------------------ SD 卡底层（SPI 模式）
module sd_card_top (
    input  wire        clk,
    input  wire        rst,
    output wire        SD_nCS,
    output wire        SD_DCLK,
    output wire        SD_MOSI,
    input  wire        SD_MISO,
    output wire        sd_init_done,
    input  wire        sd_sec_read,
    input  wire [31:0] sd_sec_read_addr,
    output wire [7:0]  sd_sec_read_data,
    output wire        sd_sec_read_data_valid,
    output wire        sd_sec_read_end,
    input  wire        sd_sec_write,
    input  wire [31:0] sd_sec_write_addr,
    input  wire [7:0]  sd_sec_write_data,
    output wire        sd_sec_write_data_req,
    output wire        sd_sec_write_end
);
endmodule

//------------------------------------------------ 视频时序 / 延时 / 帧读写
module video_timing_data (
    input  wire video_clk,
    input  wire rst,
    output wire read_req,
    input  wire read_req_ack,
    output wire hs,
    output wire vs,
    output wire de
);
endmodule

module video_delay (
    input  wire        video_clk,
    input  wire        rst,
    output wire        read_en,
    input  wire [23:0] read_data,
    input  wire        hs,
    input  wire        vs,
    input  wire        de,
    output wire        hs_r,
    output wire        vs_r,
    output wire        de_r,
    output wire [23:0] vout_data
);
endmodule

module frame_read_write #(
    parameter WRITE_V_FLIP = 1,
    parameter FRAME_WIDTH  = 1280,
    parameter FRAME_HEIGHT = 720
)(
    input  wire        mem_clk,
    input  wire        rst,
    input  wire        Sdr_init_done,
    input  wire        Sdr_init_ref_vld,
    input  wire        Sdr_busy,

    output wire        App_rd_en,
    output wire [20:0] App_rd_addr,
    output wire        Sdr_rd_en,
    input  wire [31:0] Sdr_rd_dout,

    input  wire        read_clk,
    input  wire        read_req,
    output wire        read_req_ack,
    output wire        read_finish,
    input  wire [20:0] read_addr_0,
    input  wire [20:0] read_addr_1,
    input  wire [20:0] read_addr_2,
    input  wire [20:0] read_addr_3,
    input  wire [1:0]  read_addr_index,
    input  wire [20:0] read_len,
    output wire        read_en,
    output wire [31:0] read_data,

    output wire        App_wr_en,
    output wire [20:0] App_wr_addr,
    output wire [31:0] App_wr_din,
    output wire [3:0]  App_wr_dm,

    input  wire        write_clk,
    input  wire        write_req,
    output wire        write_req_ack,
    output wire        write_finish,
    input  wire [20:0] write_addr_0,
    input  wire [20:0] write_addr_1,
    input  wire [20:0] write_addr_2,
    input  wire [20:0] write_addr_3,
    input  wire [1:0]  write_addr_index,
    input  wire [20:0] write_len,
    input  wire        write_en,
    input  wire [31:0] write_data
);
endmodule

module sdram (
    input  wire        Clk,
    input  wire        Clk_sft,
    input  wire        Rst,
    output wire        Sdr_init_done,
    output wire        Sdr_init_ref_vld,
    output wire        Sdr_busy,
    input  wire        App_wr_en,
    input  wire [20:0] App_wr_addr,
    input  wire [3:0]  App_wr_dm,
    input  wire [31:0] App_wr_din,
    input  wire        App_rd_en,
    input  wire [20:0] App_rd_addr,
    input  wire        Sdr_rd_en,
    output wire [31:0] Sdr_rd_dout
);
endmodule

//------------------------------------------------ 音频 ACR / RGB→AXIS
module audio_arc_calculate #(
    parameter ACR_N = 6144
)(
    input  wire        I_clk,
    input  wire        I_rst,
    input  wire        I_audio_valid,
    output wire        O_acr_valid,
    output wire [19:0] O_acr_cts,
    output wire [19:0] O_acr_n
);
endmodule

module video_rgb_to_axis_640x480 (
    input  wire        I_clk,
    input  wire        I_rst,
    input  wire        I_vs,
    input  wire        I_de,
    input  wire [23:0] I_rgb,
    output wire        O_video_user,
    output wire        O_video_valid,
    output wire        O_video_last,
    output wire [23:0] O_video_data
);
endmodule

//------------------------------------------------ HDMI 发射 + PHY
module startup_pulse #(
    parameter CNT_MAX = 100000
)(
    input  wire I_clk,
    input  wire I_rst,
    output wire O_pulse
);
endmodule

module hdmi_1_4b_transmitter_core_wrapper #(
    parameter DEVICE            = "EG",
    parameter HTOTAL            = 2200,
    parameter HSA               = 44,
    parameter HFP               = 88,
    parameter HBP               = 148,
    parameter HACTIVE           = 1920,
    parameter VTOTAL            = 1125,
    parameter VSA               = 5,
    parameter VFP               = 4,
    parameter VBP               = 36,
    parameter VACTIVE           = 1080,
    parameter VIDEO_VIC         = 16,
    parameter VIDEO_TPG         = "Disable",
    parameter VIDEO_FORMAT      = "RGB",
    parameter AUDIO_SAMPLE_RATE = "48K",
    parameter IIC_SCL_DIV       = 250
)(
    input  wire        I_pixel_clk,
    input  wire        I_rst,
    input  wire        I_edid_read_trig,
    output wire        O_edid_read_valid,
    output wire [7:0]  O_edid_read_data,

    input  wire        I_axis_s_user,
    input  wire        I_axis_s_valid,
    input  wire        I_axis_s_last,
    input  wire [23:0] I_axis_s_data,
    output wire        O_axis_s_ready,

    input  wire        I_audio_valid,
    input  wire [23:0] I_audio_left_data,
    input  wire [23:0] I_audio_right_data,
    input  wire        I_acr_valid,
    input  wire [19:0] I_acr_cts,
    input  wire [19:0] I_acr_n,

    output wire        O_video_locked,
    output wire        O_ddc_scl,
    inout  wire        IO_ddc_sda,

    output wire [9:0]  O_ch0_tmds_data,
    output wire [9:0]  O_ch1_tmds_data,
    output wire [9:0]  O_ch2_tmds_data,
    output wire [9:0]  O_clk_tmds_data
);
endmodule

module hdmi_phy_wrapper #(
    parameter DEVICE = "EG"
)(
    input  wire       I_pixel_clk,
    input  wire       I_serial_clk,
    input  wire       I_rst,
    input  wire [9:0] I_tmds_channel_0,
    input  wire [9:0] I_tmds_channel_1,
    input  wire [9:0] I_tmds_channel_2,
    input  wire [9:0] I_tmds_channel_clk,
    output wire       O_tmds_ch0_p,
    output wire       O_tmds_ch1_p,
    output wire       O_tmds_ch2_p,
    output wire       O_tmds_clk_p
);
endmodule

//------------------------------------------------ 数码管扫描
module seg_scan (
    input  wire       clk,
    input  wire       rst_n,
    output wire [5:0] seg_sel,
    output wire [7:0] seg_data,
    input  wire [7:0] seg_data_0,
    input  wire [7:0] seg_data_1,
    input  wire [7:0] seg_data_2,
    input  wire [7:0] seg_data_3,
    input  wire [7:0] seg_data_4,
    input  wire [7:0] seg_data_5
);
endmodule
