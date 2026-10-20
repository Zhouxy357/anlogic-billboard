//============================================================================
// osd_mixer.v  ——  视频混合 + 字幕叠加（M4 模块）
//---------------------------------------------------------------------------
// 【与官方例程的差别，答辩时要讲清楚】
//   例程：video_delay 出来的像素直接丢给 HDMI，没有任何后处理。
//   本工程：在这中间插了一级混合器，做两件事：
//            ① 亮度乘算 —— 用转场控制器给的 blend(0..256) 整体调节画面明暗，
//                          由此实现“淡入淡出”转场；
//            ② 字幕叠加 —— 在最下面 32 行叠一条字幕带（文字来自 banner_rom），
//                          并且字幕带可以横向滚动。
//
// 【为什么要“1 级流水”】
//   点阵 ROM 读出来要 1 个时钟周期，如果直接把 ROM 输出和当前像素拼在一起，
//   文字会串位。这里的做法是：
//       第 0 级(组合)：按当前像素坐标算 ROM 地址，同时把视频像素存下来；
//       第 1 级(寄存)：ROM 数据到位，用同一时刻寄存的坐标位选择该取哪一位；
//       输出级(组合)：拼出最终颜色，再乘 blend 亮度。
//   视频像素和字幕位因此严格同步，同时 de / vs 也一起延迟 1 拍，保证对齐。
//
// 【字幕条规格】
//   高 32 行，占屏幕最下面 32 行（1280x720 下是第 688..719 行）。
//   宽 2048 像素（比屏幕宽），显示时按 osd_ofs 横向滚动，
//   滚到 2047 之后自动绕回 0，所以文字会无缝循环。
//============================================================================
`timescale 1ns / 1ps

module osd_mixer #(
    parameter integer SCREEN_W = 1280,
    parameter integer SCREEN_H = 720,
    parameter integer OSD_H    = 32,
    parameter [23:0]  FG_COLOR = 24'hFFD24A,   // 字幕文字颜色（暖黄）
    parameter [23:0]  BG_COLOR = 24'h101828    // 字幕底色（深蓝黑）
)(
    input  wire        clk,          // video_clk 75MHz
    input  wire        rst,          // 高有效复位
    input  wire [23:0] rgb_in,       // 来自 video_delay 的画面
    input  wire        de_in,        // 像素有效
    input  wire        vs_in,        // 场同步（用来数行，保证字幕位置固定）

    input  wire [8:0]  blend,        // 0..256 亮度系数，256 = 全亮
    input  wire        osd_on,       // 字幕总开关
    input  wire [10:0] osd_ofs,      // 字幕横向滚动偏移 0..2047

    output wire [23:0] rgb_out,      // 混合后的画面
    output wire        de_out,       // 与 rgb_out 对齐的像素有效
    output wire        vs_out        // 与 rgb_out 对齐的场同步
);

    localparam [9:0] OSD_TOP = SCREEN_H - OSD_H;    // 720-32 = 688

    //======================================================= 像素坐标计数
    // 和 video_delay 输出严格对齐：de 高时 x 从 0 数到 1279；
    // 每结束一行 y 加 1；每次 vs 上升沿把 y 清零。
    reg [10:0] x_cnt;               // 1280 像素需要 11 位
    reg [9:0]  y_cnt;
    reg       de_d;
    reg       vs_d;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            x_cnt <= 11'd0;
            y_cnt <= 10'd0;
            de_d  <= 1'b0;
            vs_d  <= 1'b0;
        end else begin
            de_d <= de_in;
            vs_d <= vs_in;

            if (de_in)
                x_cnt <= x_cnt + 11'd1;
            else
                x_cnt <= 11'd0;

            if (vs_in & ~vs_d)
                y_cnt <= 10'd0;                       // 新的一帧
            else if (~de_in & de_d)
                y_cnt <= y_cnt + 10'd1;               // 一行结束
        end
    end

    //======================================================= 字幕取点
    wire [9:0]  osd_row  = y_cnt - OSD_TOP;                       // 0..31
    wire        osd_here = de_in & osd_on & (y_cnt >= OSD_TOP);   // 是否在字幕带内
    wire [10:0] col      = (x_cnt + osd_ofs) & 11'h7FF;           // 0..2047 循环
    wire [10:0] rom_addr = {osd_row[4:0], col[10:5]};             // 行(5) + 字序号(6)
    wire [4:0]  bit_sel0 = col[4:0];                              // 该字内第几位

    wire [31:0] rom_word;

    banner_rom u_banner_rom (
        .clk  (clk),
        .addr (rom_addr),
        .dout (rom_word)
    );

    //======================================================= 第 1 级寄存器
    reg [23:0] rgb_1;
    reg        de_1;
    reg        vs_1;
    reg        here_1;
    reg [4:0]  bs_1;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            rgb_1  <= 24'd0;
            de_1   <= 1'b0;
            vs_1   <= 1'b0;
            here_1 <= 1'b0;
            bs_1   <= 5'd0;
        end else begin
            rgb_1  <= rgb_in;      // 视频像素也延迟 1 拍，和 ROM 数据对齐
            de_1   <= de_in;
            vs_1   <= vs_in;
            here_1 <= osd_here;
            bs_1   <= bit_sel0;
        end
    end

    //======================================================= 输出级
    // ROM 里一个字 32 位对应连续 32 个像素；bit_sel 决定取哪一位。
    // 用 31-bs 是为了让文字左右不镜像。
    wire bit_on = rom_word[5'd31 - bs_1];

    // 先做“字幕 / 画面”二选一，得到一个“原始颜色”
    wire [23:0] raw = here_1 ? (bit_on ? FG_COLOR : BG_COLOR) : rgb_1;

    // 再整体乘 blend 做淡入淡出。blend 最大 256，所以 8bit*9bit 最大
    // 255*256 = 65280，用 16 位存得下，取高 8 位就是结果。
    wire [15:0] r_mul = raw[23:16] * blend;
    wire [15:0] g_mul = raw[15:8]  * blend;
    wire [15:0] b_mul = raw[7:0]   * blend;

    assign rgb_out = {r_mul[15:8], g_mul[15:8], b_mul[15:8]};
    assign de_out  = de_1;
    assign vs_out  = vs_1;

endmodule
