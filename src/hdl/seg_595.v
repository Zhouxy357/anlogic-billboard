`timescale 1ns / 1ps
//============================================================================
// seg_595.v —— 74HC595 两级级联数码管驱动
//----------------------------------------------------------------------------
// 为什么需要它：
//   HX4S20C 的数码管是"FPGA 直接驱动"（6 根位选 + 8 根段选，共 14 根脚）。
//   而 AC201 一类板子为了省 IO，用 2 片 74HC595 做串并转换，FPGA 只需要
//   3 根线：SER(数据) / SRCLK(移位时钟) / RCLK(锁存时钟)。
//   本模块把本工程原有的 seg_sel(位选) + seg_data(段码) 转成这 3 根线的时序。
//
// 74HC595 时序（芯片手册，跟板子无关）：
//   ① SER 上的电平在 SRCLK 的【上升沿】被移入 8 位移位寄存器
//   ② 两片级联共 16 bit 全部移完后，给 RCLK 一个【上升沿】，
//      16 bit 一次性锁存到并行输出 → 移位过程中输出保持不变，不会鬼影
//   ③ OE 低有效、MR 高有效，板上一般已接死，FPGA 不用管
//
// 级联顺序（接错就会"段码显示在位选上"这种乱象）：
//   数据先进第 1 片的 DS，第 1 片的 Q7' 接第 2 片的 DS。
//   ⇒ 最先送出去的 8 bit 最终停在【远端】那一片。
//   参数 SEG_SENT_FIRST：1 = 段码先送（默认），0 = 位选先送。
//   上板若发现段码/位选反了，只改这个参数即可，不用动接线。
//
// 参数：
//   CLK_FREQ       —— 输入时钟频率（Hz），默认 50MHz
//   SCLK_FREQ      —— 595 移位时钟频率（Hz），默认 1MHz（595 最高 25MHz，1MHz 很稳）
//   SEG_SENT_FIRST —— 见上
//   DIGIT_POLARITY —— 位选输出极性：0 = 高有效（默认），1 = 低有效
//
// 端口：
//   seg_sel_n —— 位选，低有效（直接接 seg_scan 的 seg_sel，未选中的位为 1）
//   seg_data  —— 段码，低有效（0 = 该段点亮，共阳数码管）
//   ser/srclk/rclk —— 接 74HC595 的 DS / SHCP / STCP
//
// 刷新机制：
//   检测到 seg_sel_n 变化 → 抓一份快照 → 串行送出 16 bit → 锁存。
//   送一帧约 (16*2+2) * (CLK_FREQ/SCLK_FREQ/2) 个时钟，
//   50MHz / 1MHz 时约 850 拍 ≈ 17us，远小于一刻度 833us，不会丢帧。
//============================================================================

module seg_595 #(
    parameter integer CLK_FREQ       = 50_000_000,
    parameter integer SCLK_FREQ      = 1_000_000,
    parameter         SEG_SENT_FIRST = 1'b1,
    parameter         DIGIT_POLARITY = 1'b0
)(
    input  wire       clk,
    input  wire       rst_n,
    input  wire [7:0] seg_sel_n,
    input  wire [7:0] seg_data,
    output reg        ser,
    output reg        srclk,
    output reg        rclk
);

    // 半周期拍数：SCLK 一个完整周期 = 2*HALF 个 clk
    localparam integer HALF = (CLK_FREQ / SCLK_FREQ) / 2;

    localparam [2:0] S_IDLE  = 3'd0,
                     S_LO    = 3'd1,   // SRCLK 保持低，SER 已稳定
                     S_HI    = 3'd2,   // SRCLK 拉高 → 上升沿移入
                     S_LATCH = 3'd3,   // RCLK 拉高 → 锁存
                     S_DONE  = 3'd4;   // RCLK 拉低

    reg [15:0] ph;       // 半周期计数器
    reg        tick;     // 每 HALF 拍产生一个单拍脉冲
    reg [2:0]  state;
    reg [15:0] sh;       // 待送出的 16 bit 快照
    reg [4:0]  bitc;     // 已送出的位数 0..15
    reg [7:0]  sel_d;    // 上一次的位选，用来检测变化

    // seg_scan 输出低有效位选 → 转成高有效（或按参数直接取反）
    wire [7:0]  dig   = DIGIT_POLARITY ? seg_sel_n : ~seg_sel_n;
    // 先送出的字节放在高 8 位（移位从 bit15 开始）
    wire [15:0] frame = SEG_SENT_FIRST ? {seg_data, dig} : {dig, seg_data};

    //------------------------------------------------------------------------
    // 半周期定时
    //------------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ph   <= 16'd0;
            tick <= 1'b0;
        end
        else if (ph >= HALF - 1) begin
            ph   <= 16'd0;
            tick <= 1'b1;
        end
        else begin
            ph   <= ph + 16'd1;
            tick <= 1'b0;
        end
    end

    //------------------------------------------------------------------------
    // 移位 / 锁存状态机
    //------------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_IDLE;
            sh    <= 16'd0;
            bitc  <= 5'd0;
            sel_d <= 8'hFF;
            ser   <= 1'b0;
            srclk <= 1'b0;
            rclk  <= 1'b0;
        end
        else if (tick) begin
            case (state)
                S_IDLE: begin
                    if (seg_sel_n != sel_d) begin
                        sel_d <= seg_sel_n;
                        sh    <= frame;
                        bitc  <= 5'd0;
                        ser   <= frame[15];
                        srclk <= 1'b0;
                        state <= S_LO;
                    end
                end

                S_LO: begin
                    // SER 已在前一拍稳定，这里拉高 SRCLK 产生上升沿
                    srclk <= 1'b1;
                    state <= S_HI;
                end

                S_HI: begin
                    srclk <= 1'b0;              // 拉低，为下一位做准备
                    if (bitc == 5'd15) begin
                        state <= S_LATCH;       // 16 bit 送完
                    end
                    else begin
                        bitc  <= bitc + 5'd1;
                        ser   <= sh[15 - (bitc + 5'd1)];
                        state <= S_LO;
                    end
                end

                S_LATCH: begin
                    rclk  <= 1'b1;              // 上升沿：16 bit 一次性输出
                    state <= S_DONE;
                end

                S_DONE: begin
                    rclk  <= 1'b0;
                    state <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
