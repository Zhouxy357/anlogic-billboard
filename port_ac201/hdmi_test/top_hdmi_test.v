//=============================================================================
// top_hdmi_test.v —— HDMI 通路诊断用顶层（只出核内部测试图案，不依赖 SD 卡/SDRAM）
//
// 【为什么需要这个文件】
//   正式工程 billboard.bit 的显示链路很长：
//       TF 卡 → ebm_reader → SDRAM 乒乓 → video_delay → osd_mixer → AXIS → HDMI 核
//   任何一环有问题都表现为"屏幕黑屏"，无法区分到底是"HDMI 硬件不通"还是"数据没来"。
//   这个顶层把后面全部砍掉，只保留：
//       50MHz → video_pll → HDMI 核（VIDEO_TPG="Enable"，核内自带彩条）→ PHY → 引脚
//   烧这个 bit：
//       · 屏幕出彩条  → HDMI 引脚 / 电平标准 / PLL / 屏 / 线 全部正常，
//                        黑屏原因一定在数据链路（TF 卡、容器、SDRAM）
//       · 屏幕仍无信号 → 问题在硬件侧（线、屏的输入源、供电、HDMI 座）
//   参数全部照抄官方 AC201 参考实现 design_top_wrapper.v：
//       HTOTAL=1650 HSA=40 HFP=110 HBP=220 HACTIVE=1280
//       VTOTAL=750  VSA=5  VFP=5   VBP=20  VACTIVE=720
//       VIDEO_VIC=69  VIDEO_FORMAT="RGB"  AUDIO_SAMPLE_RATE="48K"
//
// 【判读】
//   LED[3] 快闪 = FPGA 已配置（与正式工程同一判据）
//   屏幕出彩条 = 通
//=============================================================================
`timescale 1ns/1ps

module top_hdmi_test (
    input  wire        clk,           // AC201: K14, 50MHz
    input  wire        rst_n,         // AC201: H14, KEY2, 低有效

    output wire [3:0]  led,           // AC201: M12/R16/R15/T15，低电平点亮

    output wire        HDMI_CLK_P,    // AC201: B10  LVDS33_E
    output wire        HDMI_D2_P,     // AC201: F10
    output wire        HDMI_D1_P,     // AC201: C11
    output wire        HDMI_D0_P      // AC201: D11
);

    //--------------------------------------------------------- 时钟
    wire video_clk;      // 75MHz   像素时钟
    wire hdmi_5x_clk;    // 375MHz  串行时钟（90° 相位，见 video_pll.v）
    wire pll_lock;

    video_pll u_video_pll (
        .refclk   (clk),
        .reset    (1'b0),
        .extlock  (pll_lock),
        .clk0_out (video_clk),
        .clk1_out (hdmi_5x_clk)
    );

    //--------------------------------------------------------- 复位
    // 与正式工程同策略：等 PLL 锁定后延迟约 20us 放复位；40us 超时兜底放行。
    reg [11:0] rst_cnt;
    reg        rst_wait;
    always @(posedge clk) begin
        if (!rst_n) begin
            rst_cnt  <= 12'd0;
            rst_wait <= 1'b1;
        end else if (!rst_wait) begin
            rst_wait <= 1'b0;
        end else if (pll_lock) begin
            if (rst_cnt < 12'd1000) begin
                rst_cnt  <= rst_cnt + 12'd1;
                rst_wait <= 1'b1;
            end else begin
                rst_wait <= 1'b0;
            end
        end else if (rst_cnt < 12'd2000) begin
            rst_cnt <= rst_cnt + 12'd1;
        end else begin
            rst_wait <= 1'b0;
        end
    end
    wire rst_all = rst_wait;

    //--------------------------------------------------------- HDMI 核
    wire [9:0] tmds_ch0_data;
    wire [9:0] tmds_ch1_data;
    wire [9:0] tmds_ch2_data;
    wire [9:0] tmds_clk_data;

    hdmi_1_4b_transmitter_core_wrapper #(
        .DEVICE            ("EG"),
        .HTOTAL            (1650),
        .HSA               (40),
        .HFP               (110),
        .HBP               (220),
        .HACTIVE           (1280),
        .VTOTAL            (750),
        .VSA               (5),
        .VFP               (5),
        .VBP               (20),
        .VACTIVE           (720),
        .VIDEO_VIC         (69),        // 官方 AC201 720p 参考值
        .VIDEO_TPG         ("Enable"),  // ★ 用核内部测试图案，不依赖外部数据
        .VIDEO_FORMAT      ("RGB"),
        .AUDIO_SAMPLE_RATE ("48K"),
        .IIC_SCL_DIV       (125)
    ) u_hdmi_core (
        .I_pixel_clk        (video_clk),
        .I_rst              (rst_all),
        .I_edid_read_trig   (1'b0),     // AC201 无 DDC，永不读 EDID
        .O_edid_read_valid  (),
        .O_edid_read_data   (),

        // TPG 模式下核自己产生像素，AXIS 输入全部固定 0
        .I_axis_s_user      (1'b0),
        .I_axis_s_valid     (1'b0),
        .I_axis_s_last      (1'b0),
        .I_axis_s_data      (24'd0),
        .O_axis_s_ready     (),

        .I_audio_valid      (1'b0),
        .I_audio_left_data  (24'd0),
        .I_audio_right_data (24'd0),
        .I_acr_valid        (1'b0),
        .I_acr_cts          (20'd0),
        .I_acr_n            (20'd6144),

        .O_video_locked     (),
        .O_ddc_scl          (),
        .IO_ddc_sda         (),

        .O_ch0_tmds_data    (tmds_ch0_data),
        .O_ch1_tmds_data    (tmds_ch1_data),
        .O_ch2_tmds_data    (tmds_ch2_data),
        .O_clk_tmds_data    (tmds_clk_data)
    );

    hdmi_phy_wrapper #(
        .DEVICE ("EG")
    ) u_hdmi_phy (
        .I_pixel_clk        (video_clk),
        .I_serial_clk       (hdmi_5x_clk),
        .I_rst              (rst_all),
        .I_tmds_channel_0   (tmds_ch0_data),
        .I_tmds_channel_1   (tmds_ch1_data),
        .I_tmds_channel_2   (tmds_ch2_data),
        .I_tmds_channel_clk (tmds_clk_data),
        .O_tmds_ch0_p       (HDMI_D0_P),
        .O_tmds_ch1_p       (HDMI_D1_P),
        .O_tmds_ch2_p       (HDMI_D2_P),
        .O_tmds_clk_p       (HDMI_CLK_P)
    );

    //--------------------------------------------------------- 指示灯
    // LED[3] 心跳挂 50MHz、不受复位：只要芯片配置成功就一定闪。
    // LED[2:0] 常亮（低电平点亮 → 输出 0），用来确认 4 只灯本身没坏。
    reg [23:0] hb_cnt = 24'd0;
    always @(posedge clk) hb_cnt <= hb_cnt + 24'd1;

    assign led = ~{hb_cnt[23], 1'b1, 1'b1, 1'b1};

endmodule
