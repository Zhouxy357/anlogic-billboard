//============================================================================
// audio_player.v  ——  PCM 素材播放器（M1 模块，本工程音频通路的核心）
//---------------------------------------------------------------------------
// 【与官方例程的差别，答辩时要讲清楚】
//   例程音频：FPGA 内部 DDS 生成方波音阶 → 串行成 I2S → I2S_receiver 再解串
//             回 PCM。属于“自己发、自己收”的自测环路。
//   本工程  ：音源是事先做好的 PCM 素材，直接从 ROM 取出并输出 24bit PCM，
//             全程不经过 I2S 编解码。
//
// 【时钟域】
//   mclk 域（12.288MHz）：产生 48kHz 采样节拍、取 ROM 数据。
//   vid_clk 域（75MHz）：HDMI 核要求 audio_valid 与像素时钟同步，
//                        所以用“翻转握手”把每个样本送到 vid_clk 域。
//   做法：mclk 域每采到一个样本就把 tgl 翻转一次；vid_clk 域对 tgl 打三拍
//         后做异或边沿检测，得到每个样本恰好 1 拍 audio_valid。
//         数据在 tgl 翻转前就已稳定，保持时间约 250 个 mclk 周期，
//         远大于 2 个 vid_clk 周期，所以采样是安全的。
//
// 【采样率为什么是 48kHz】
//   HDMI ACR 包里 N 固定 6144，对应 48kHz。节拍由 mclk/256 得到，
//   接 HDMI 核的 audio_arc_calculate 会实测这个节拍并算出 CTS，
//   接收端据此恢复采样时钟。
//============================================================================
`timescale 1ns / 1ps

module audio_player #(
    parameter integer MCLK_HZ    = 12_288_000,  // 音频主时钟
    parameter integer SAMPLE_HZ  = 48_000,      // 目标采样率
    parameter integer ROM_DEPTH  = 8192,        // 每段样本数（必须是 2 的幂）
    parameter integer SEG_NUM    = 4,           // 音效段数
    parameter        OFS_W       = 13,          // log2(ROM_DEPTH) = 13
    parameter        ADDR_W      = 15           // log2(ROM_DEPTH*SEG_NUM) = 15
)(
    input  wire        mclk,          // 12.288MHz 音频主时钟
    input  wire        rst_mclk,      // 与 mclk 同域的复位（高有效）
    input  wire [3:0]  seg_id,        // 要播放的音效段号（0..SEG_NUM-1）

    input  wire        vid_clk,       // 75MHz 像素时钟
    input  wire        rst_vid,       // 与 vid_clk 同域的复位（高有效）

    output reg         o_audio_valid, // 每个立体声样本 1 拍高电平
    output reg  [23:0] o_left,        // 左声道 PCM
    output reg  [23:0] o_right        // 右声道 PCM
);

    localparam integer DIV = MCLK_HZ / SAMPLE_HZ;   // 12_288_000/48_000 = 256

    // ======================================================== mclk 域
    reg  [8:0]  div_cnt;
    reg  [OFS_W-1:0] ofs;          // 段内偏移 0..ROM_DEPTH-1
    reg  [1:0]  seg_r;             // 当前正在播放的段
    reg  [ADDR_W-1:0] rom_addr;
    wire [15:0] rom_q;
    reg  [15:0] hold_l;
    reg         tgl;

    // 段内偏移到达末尾才允许换段 → 换音效永远发生在段边界，不会有杂音
    wire [OFS_W-1:0] ofs_next = (ofs == ROM_DEPTH-1) ? {OFS_W{1'b0}} : (ofs + 1'b1);
    wire [1:0]       seg_next = (ofs == ROM_DEPTH-1) ? seg_id[1:0] : seg_r;
    wire [ADDR_W-1:0] addr_next = {seg_next, ofs_next};

    always @(posedge mclk or posedge rst_mclk) begin
        if (rst_mclk) begin
            div_cnt  <= 9'd0;
            ofs      <= {OFS_W{1'b0}};
            seg_r    <= 2'd0;
            rom_addr <= {ADDR_W{1'b0}};
            hold_l   <= 16'd0;
            tgl      <= 1'b0;
        end else begin
            if (div_cnt == DIV-1) begin
                div_cnt  <= 9'd0;
                ofs      <= ofs_next;
                seg_r    <= seg_next;
                rom_addr <= addr_next;
                hold_l   <= rom_q;      // 取出上一个地址对应的样本
                tgl      <= ~tgl;       // 通知 vid_clk 域：新样本已就绪
            end else begin
                div_cnt <= div_cnt + 9'd1;
            end
        end
    end

    audio_rom #(
        .ADDR_W (ADDR_W),
        .DATA_W (16)
    ) u_audio_rom (
        .clk  (mclk),
        .addr (rom_addr),
        .dout (rom_q)
    );

    // ======================================================== vid_clk 域
    reg [2:0] tgl_sync;
    wire      sample_pulse;

    always @(posedge vid_clk or posedge rst_vid) begin
        if (rst_vid)
            tgl_sync <= 3'b000;
        else
            tgl_sync <= {tgl_sync[1:0], tgl};
    end

    assign sample_pulse = tgl_sync[2] ^ tgl_sync[1];

    always @(posedge vid_clk or posedge rst_vid) begin
        if (rst_vid) begin
            o_audio_valid <= 1'b0;
            o_left        <= 24'd0;
            o_right       <= 24'd0;
        end else begin
            o_audio_valid <= sample_pulse;      // 与下面的赋值同一拍，天然对齐
            if (sample_pulse) begin
                // 16bit 样本左移 8 位变成 24bit（低位补 0 等于乘 256）
                o_left  <= {hold_l, 8'd0};
                o_right <= {hold_l, 8'd0};      // 左右声道放同一个素材
            end
        end
    end

endmodule
