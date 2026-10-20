//============================================================================
// audio_rom.v  ——  音频素材 ROM（M1 模块的“音源”）
//---------------------------------------------------------------------------
// 内容：4 段音效顺序存放，每段 ROM_DEPTH 个 8bit 有符号样本。
//       段 0 → 地址 [0*8192 .. 1*8192-1]
//       段 1 → 地址 [1*8192 .. 2*8192-1]
//       段 2 → 地址 [2*8192 .. 3*8192-1]
//       段 3 → 地址 [3*8192 .. 4*8192-1]
//       合计 32768 个样本 × 8bit = 32KB，占用片内 EMB 约 256Kbit（30 块左右）。
//       ★ 为什么是 8bit：EG4S20 只有 64 块 9Kb EMB，16bit 版要占 60 块、
//         加上其它模块共 88 块超限（PHY-9013）。改 8bit 后降到约 30 块，
//         全工程约 58 块 < 64，放得下。对外仍输出 16bit（符号扩展），
//         audio_player / testbench 不用改。
//
// 数据来源：由 tools/gen_audio_rom.py 生成的 audio_rom.hex
//           样本格式：2 位十六进制（8bit 二进制补码），每行一个。
//
// 【重要】如果仿真/综合时报“找不到 audio_rom.hex”：
//   $readmemh 第一个参数必须是**字面量文件名**，含义是“在当前工作目录下找”。
//   （ModelSim 不接受用 parameter 把文件名传进来，会把它当层次名解析并报
//     vopt-7063 错误，所以这里只能写死字符串。）
//   - 仿真时：在 sim/ 目录下运行 vsim，并确保 audio_rom.hex 就在 sim/ 里。
//   - TD 综合时：TD 按**本 .v 文件所在目录**（src/hdl/）解析相对路径，
//     所以 audio_rom.hex 必须在 src/hdl/ 里有一份（工程里已放好）。
//   若确实要换目录，只能改下面那句话里的字符串本身，例如：
//     $readmemh("../../user_source/hdl_source/audio_rom.hex", mem);
//============================================================================
`timescale 1ns / 1ps

module audio_rom #(
    parameter integer ADDR_W = 15,    // 32768 = 2^15
    parameter integer DATA_W = 16,    // 对外输出位宽（符号扩展到 16bit）
    parameter integer SAM_W  = 8      // ROM 内实际存储位宽（8bit 样本）
)(
    input  wire                  clk,
    input  wire [ADDR_W-1:0]     addr,
    output reg  [DATA_W-1:0]     dout
);

    reg [SAM_W-1:0] mem [0:(1<<ADDR_W)-1];

    integer i;
    initial begin
        // 先把整块 ROM 清 0，即使 hex 文件读失败也只会是静音，不会出现 X 态
        for (i = 0; i < (1<<ADDR_W); i = i + 1)
            mem[i] = {SAM_W{1'b0}};
        $readmemh("audio_rom.hex", mem);
    end

    always @(posedge clk)
        // 8bit 有符号样本符号扩展到 16bit（数值不变，只是精度低 8 位）
        dout <= {{(DATA_W-SAM_W){mem[addr][SAM_W-1]}}, mem[addr]};

endmodule
