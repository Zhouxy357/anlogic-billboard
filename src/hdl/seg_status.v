//============================================================================
// seg_status.v  ——  8 位数码管状态显示（M5 模块）
//---------------------------------------------------------------------------
// 【与官方例程的差别，答辩时要讲清楚】
//   例程：只把 sd_card_bmp 内部的 state_code 通过 seg_decoder 显示在 1 位
//         数码管上，只能看到“0~5”这几个数字，信息量很小。
//   本工程：用一个专门的模块把系统里所有关键状态汇总到 6 位数码管，
//           调试和现场演示时一眼就能看出哪里出了问题：
//
//      seg_data_5 : 模式            L = 锁定/手动    A = 自动轮播    C = 应急
//                  （2026-10-18 调整：原来用 E/A/n，E 与数字 3 撞形、n 太像 '9'，
//                   上板实测容易被误读成"切换/换到 n"。现改为 L/A/C 三个不会撞形的字母，
//                   并让三种状态与"哪颗键管什么"一一对应：
//                     L = 画面锁定（按 S1/切换键才动）
//                     A = 自动轮播（S0 开/关）
//                     C = 应急告警（拨码位 2））
//      seg_data_4 : 当前图片 id     0..7
//      seg_data_3 : 图片总数        0..8
//      seg_data_2 : 运行状态        0=等待SD 1=读索引 2=显示中
//                                   3=装载中 4=换帧中 5=错误
//      seg_data_1 : 错误码高 4 位   没错误时熄灭
//      seg_data_0 : 错误码低 4 位   没错误时熄灭
//
// 【数码管位序说明】
//   本模块输出的 seg_data_0 .. seg_data_5 直接接到 seg_scan 的同名端口。
//   如果你的板子上电后发现左右顺序是反的，只要把下面最后的 assign 顺序
//   整体倒过来即可（例如把 d5 接到 seg_data_0）。
//
// 【数码管段码约定】（沿用官方例程 seg_decoder 的约定）
//   7 位对应 a b c d e f g，低电平点亮。例如 "0" = 7'b100_0000。
//   最高位是小数点，固定给 1 表示熄灭。
//============================================================================
`timescale 1ns / 1ps

module seg_status (
    input  wire [3:0]  state_code,   // 来自 play_scheduler
    input  wire [3:0]  cur_id,       // 当前图片 id
    input  wire [3:0]  n_img,        // 图片总数
    input  wire        auto_en,      // 自动轮播开
    input  wire        emerg_en,     // 应急模式开
    input  wire        sd_init_done, // SD 卡初始化完成
    input  wire [7:0]  err_byte,     // 错误码低 8 位（0 = 无错误）

    output wire [7:0]  seg_data_0,
    output wire [7:0]  seg_data_1,
    output wire [7:0]  seg_data_2,
    output wire [7:0]  seg_data_3,
    output wire [7:0]  seg_data_4,
    output wire [7:0]  seg_data_5
);

    // 常用图案
    localparam [6:0] S_BLANK = 7'b111_1111;   // 全灭
    localparam [6:0] S_LET_A = 7'b000_1000;   // 'A' 自动轮播
    localparam [6:0] S_LET_L = 7'b100_0111;   // 'L' 锁定/手动（a b c 亮，d e f g 灭）
    localparam [6:0] S_LET_C = 7'b100_0110;   // 'C' 应急告警
    localparam [6:0] S_LET_S = 7'b010_0110;   // 'S' 等 SD 卡

    // d5 的判定优先级：应急 > 自动 > 锁定（定义在下方"6 个数字分别算"处）
    //------------------------------------------------- 4bit → 7 段译码
    function [6:0] hex7;
        input [3:0] d;
        begin
            case (d)
                4'h0: hex7 = 7'b100_0000;
                4'h1: hex7 = 7'b111_1001;
                4'h2: hex7 = 7'b010_0100;
                4'h3: hex7 = 7'b011_0000;
                4'h4: hex7 = 7'b001_1001;
                4'h5: hex7 = 7'b001_0010;
                4'h6: hex7 = 7'b000_0010;
                4'h7: hex7 = 7'b111_1000;
                4'h8: hex7 = 7'b000_0000;
                4'h9: hex7 = 7'b001_0000;
                4'hA: hex7 = 7'b000_1000;
                4'hB: hex7 = 7'b000_0011;
                4'hC: hex7 = 7'b100_0110;
                4'hD: hex7 = 7'b010_0001;
                4'hE: hex7 = 7'b000_0110;
                default: hex7 = 7'b000_1110;   // 'F'
            endcase
        end
    endfunction

    //------------------------------------------------- 6 个数字分别算
    // d5 模式位：优先级 应急 > 自动 > 锁定
    wire [6:0] d5 = emerg_en ? S_LET_C : (auto_en ? S_LET_A : S_LET_L);
    wire [6:0] d4 = hex7(cur_id);
    wire [6:0] d3 = hex7(n_img);
    wire [6:0] d2 = sd_init_done ? hex7(state_code) : S_LET_S;

    // 错误码为 0 就熄灭，避免误以为“0 号错误”
    wire [6:0] d1 = (err_byte[7:4] != 4'd0) ? hex7(err_byte[7:4]) : S_BLANK;
    wire [6:0] d0 = (err_byte[3:0] != 4'd0) ? hex7(err_byte[3:0]) : S_BLANK;

    //------------------------------------------------- 补上小数点最高位
    assign seg_data_0 = {1'b1, d0};
    assign seg_data_1 = {1'b1, d1};
    assign seg_data_2 = {1'b1, d2};
    assign seg_data_3 = {1'b1, d3};
    assign seg_data_4 = {1'b1, d4};
    assign seg_data_5 = {1'b1, d5};

endmodule
