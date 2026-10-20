//============================================================================
// audio_player_stream.v —— 从 FIFO 取样本的 PCM 播放器（M1d 模块）
//---------------------------------------------------------------------------
// 【和 audio_player.v 的关系】
//   audio_player.v  ：样本来自片内 ROM（4 段 × 8192，共 0.68 秒），已退役。
//   audio_player_stream.v：样本来自 audio_fifo（TF 卡流式读入，80 秒循环）。
//   两者对外时序、跨时钟域握手、24bit 输出格式完全一致，只有“样本来源”不同，
//   所以顶层换掉这一个模块，HDMI 音频通路其余部分（ACR / packet）零改动。
//
// 【时钟域】
//   mclk 域（12.288MHz）：mclk/256 = 48kHz 取样节拍，从 FIFO 读一个样本。
//   vid_clk 域（75MHz）：HDMI 核要求 audio_valid 与像素时钟同步，
//                        用“翻转握手”把每个样本送过去（tgl 打三拍后异或取边沿）。
//
// 【采样率为什么必须是 48kHz】
//   HDMI ACR 包里 N 固定 6144，对应 48kHz，接收端据此恢复采样时钟。
//   节拍由 mclk/256 得到，所以 MCLK 必须是 12.288MHz。
//
// 【enable】
//   上电后 FIFO 会先被填满，但此时第一张图还没显示。enable 由顶层在第一张图
//   装载完成后拉高，保证“画面出现”和“语音第一句”同时开始。
//   enable=0 时仍然每个采样节拍翻转 tgl（保持 ACR 节拍稳定），只是数据送 0。
//============================================================================
`timescale 1ns / 1ps

module audio_player_stream #(
    parameter integer MCLK_HZ   = 12_288_000,
    parameter integer SAMPLE_HZ = 48_000
)(
    input  wire        mclk,          // 12.288MHz
    input  wire        rst_mclk,      // 高有效

    //---------------- 从 audio_fifo 取样本 --------------------------
    output wire        fifo_rd_en,
    input  wire [15:0] fifo_rd_data,
    input  wire        fifo_empty,

    input  wire        enable,        // 1 = 开始播放

    //---------------- 送 HDMI 核 -----------------------------------
    input  wire        vid_clk,
    input  wire        rst_vid,
    output reg         o_audio_valid,
    output reg  [23:0] o_left,
    output reg  [23:0] o_right
);

    localparam integer DIV = MCLK_HZ / SAMPLE_HZ;   // 256

    reg  [8:0] div_cnt;
    reg        rd_en;        // 1 拍：向 FIFO 取数
    reg        rd_vld;       // 取数那一拍 FIFO 里是否真的有数据
    reg        rd_en_d;      // 延迟 1 拍，此时 fifo_rd_data 已有效
    reg        rd_vld_d;     // 与 rd_en_d 同拍，表示 rd_en 那拍取到的是有效样本
    reg [15:0] hold;
    reg        tgl;

    assign fifo_rd_en = rd_en;

    //=========================================================== mclk 域
    always @(posedge mclk or posedge rst_mclk) begin
        if (rst_mclk) begin
            div_cnt <= 9'd0;
            rd_en   <= 1'b0;
            rd_vld  <= 1'b0;
            rd_en_d <= 1'b0;
            rd_vld_d<= 1'b0;
            hold    <= 16'd0;
            tgl     <= 1'b0;
        end else begin
            if (div_cnt == DIV-1)
                div_cnt <= 9'd0;
            else
                div_cnt <= div_cnt + 9'd1;

            rd_en   <= (div_cnt == DIV-1) && enable;
            // ★ 2026-10-19 修正：有效性别在“取数那一拍”就锁存。
            //   原写法等到 rd_en_d 那拍才看 fifo_empty，而读指针在 rd_en 之后就
            //   已经 +1 了 —— 如果 FIFO 里只剩最后 1 个样本，会被误判成“空”
            //   而送一个 0（相当于在那 1/48000 秒里插了个静音，长期听是轻微爆音）。
            rd_vld  <= (div_cnt == DIV-1) && enable && (!fifo_empty);
            rd_en_d <= rd_en;
            rd_vld_d<= rd_vld;

            if (rd_en_d) begin
                // FIFO 空（卡还没供上）就送 0，绝不把上一拍的样本重复播放
                hold <= rd_vld_d ? fifo_rd_data : 16'd0;
            end else if ((div_cnt == DIV-1) && (!enable)) begin
                hold <= 16'd0;
            end

            // 一个采样节拍翻转一次握手信号；即使 enable=0 也翻，保证 ACR 节拍不断
            if (rd_en_d || ((div_cnt == DIV-1) && (!enable)))
                tgl <= ~tgl;
        end
    end

    //=========================================================== vid_clk 域
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
            o_audio_valid <= sample_pulse;
            if (sample_pulse) begin
                // 16bit 样本放进 24bit 的高 16 位（低 8 位补 0 = 乘 256）
                o_left  <= {hold, 8'd0};
                o_right <= {hold, 8'd0};
            end
        end
    end

endmodule
