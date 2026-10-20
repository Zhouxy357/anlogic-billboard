//============================================================================
// tb_seg_status.v  ——  6 位数码管状态汇总模块（seg_status）的行为仿真
//---------------------------------------------------------------------------
// 这个模块是"现场不看示波器也能判断板子状态"的眼睛，把系统状态压到 6 位数码管：
//     d5 = 模式   E=应急 / A=自动 / n=手动
//     d4 = 当前图片 id
//     d3 = 图片总数
//     d2 = 运行状态（未初始化 SD 时显示 'S'）
//     d1/d0 = 错误码高/低半字节（无错就全灭）
//
// 本 tb 顺带把那个一直困扰上板的"数码管上出现两个 9"钉死：
//   d5 的取值只可能是 {E, A, n} 三种段码，
//   而数字 '9' 的段码是 8'b1001_0000（含小数点位）。
//   三者都不等于它 —— 也就是说【这个模块无论如何产不出 9】。
//   再结合"多位显示一模一样的字形"，就只能是 FPGA 未配置、引脚浮空。
//
// 段码约定（沿用官方 seg_decoder，低电平点亮）：
//   bit0=a bit1=b bit2=c bit3=d bit4=e bit5=f bit6=g，最高位是小数点（1=灭）
//   例如 '0'=100_0000（g 灭，a~f 亮）、'9'=001_0000（e 灭，其余亮）
//
// 怎么跑（在 sim 目录下，用 Git Bash）：
//   ./run_iverilog.sh seg_status
//============================================================================
`timescale 1ns / 1ps

module tb_seg_status;

    //---------------------------------------------------------- 输入激励
    reg  [3:0] state_code   = 4'd0;
    reg  [3:0] cur_id       = 4'd0;
    reg  [3:0] n_img        = 4'd0;
    reg        auto_en      = 1'b0;
    reg        emerg_en     = 1'b0;
    reg        sd_init_done = 1'b0;
    reg  [7:0] err_byte     = 8'h00;

    wire [7:0] sd0, sd1, sd2, sd3, sd4, sd5;

    seg_status dut (
        .state_code   (state_code),
        .cur_id       (cur_id),
        .n_img        (n_img),
        .auto_en      (auto_en),
        .emerg_en     (emerg_en),
        .sd_init_done (sd_init_done),
        .err_byte     (err_byte),
        .seg_data_0   (sd0),
        .seg_data_1   (sd1),
        .seg_data_2   (sd2),
        .seg_data_3   (sd3),
        .seg_data_4   (sd4),
        .seg_data_5   (sd5)
    );

    //---------------------------------------------------------- 检查框架
    integer chk_idx  = 0;
    integer fail_cnt = 0;

    task chk;
        input cond;
        input [1023:0] name;      // 【必须 ASCII】
        begin
            chk_idx = chk_idx + 1;
            if (cond) $display("   >>> [PASS] %0s", name);
            else begin
                fail_cnt = fail_cnt + 1;
                $display("   >>> [FAIL] %0s", name);
                $display("### FAIL idx=%0d ###", chk_idx);
            end
        end
    endtask

    //------------------------------------------------ 期望段码（按官方 seg_decoder 约定独立写出）
    localparam [6:0] E_BLANK = 7'b111_1111;
    localparam [6:0] E_0 = 7'b100_0000, E_1 = 7'b111_1001, E_2 = 7'b010_0100;
    localparam [6:0] E_3 = 7'b011_0000, E_4 = 7'b001_1001, E_5 = 7'b001_0010;
    localparam [6:0] E_6 = 7'b000_0010, E_7 = 7'b111_1000, E_8 = 7'b000_0000;
    localparam [6:0] E_9 = 7'b001_0000, E_A = 7'b000_1000, E_B = 7'b000_0011;
    localparam [6:0] E_C = 7'b100_0110, E_D = 7'b010_0001, E_E = 7'b000_0110;
    localparam [6:0] E_F = 7'b000_1110;
    // 模式位 d5 的三个人造图案（2026-10-19 与 seg_status.v 对齐：
    //   作者在 10-18 深夜把这三位从 n/E 改成了 L/C —— 因为 AC201 数码管
    //   是共阳+位序镜像，'n' 和 'E' 镜像后更容易被误读成数字。
    //   这里按 RTL 的现状更新期望值，硬件行为保持不动。）
    localparam [6:0] E_LET_A = 7'b000_1000;    // 'A' 自动轮播
    localparam [6:0] E_LET_C = 7'b100_0110;    // 'C' 应急（原 E）
    localparam [6:0] E_LET_L = 7'b100_0111;    // 'L' 手动/锁定（原 n）
    localparam [6:0] E_LET_S = 7'b010_0110;    // 'S' 等 SD 卡

    function [6:0] exp_hex7;
        input [3:0] d;
        begin
            case (d)
                4'h0: exp_hex7 = E_0;   4'h1: exp_hex7 = E_1;
                4'h2: exp_hex7 = E_2;   4'h3: exp_hex7 = E_3;
                4'h4: exp_hex7 = E_4;   4'h5: exp_hex7 = E_5;
                4'h6: exp_hex7 = E_6;   4'h7: exp_hex7 = E_7;
                4'h8: exp_hex7 = E_8;   4'h9: exp_hex7 = E_9;
                4'hA: exp_hex7 = E_A;   4'hB: exp_hex7 = E_B;
                4'hC: exp_hex7 = E_C;   4'hD: exp_hex7 = E_D;
                4'hE: exp_hex7 = E_E;   default: exp_hex7 = E_F;
            endcase
        end
    endfunction

    //========================================================== 主流程
    integer i;
    integer hex_ok = 0, hex_bad = 0;
    integer d5_ok = 0, d5_bad = 0;

    initial begin
        $timeformat(-9, 0, " ns", 12);
        #10;

        //--------------------------------------------- ① 默认态（SD 未好、无错）
        $display("");
        $display("[%0t] ① 默认态：SD 未初始化、无错误、自动/应急都关", $time);
        sd_init_done = 1'b0; auto_en = 1'b0; emerg_en = 1'b0;
        err_byte = 8'h00; state_code = 4'd2; cur_id = 4'd3; n_img = 4'd8;
        #10;
        $display("        d5=%07b d4=%07b d3=%07b d2=%07b d1=%07b d0=%07b",
                 sd5[6:0], sd4[6:0], sd3[6:0], sd2[6:0], sd1[6:0], sd0[6:0]);
        chk(sd5[6:0] === E_LET_L, "C01-default-mode-is-L-manual");
        chk(sd2[6:0] === E_LET_S, "C02-sd-not-ready-shows-S");
        chk(sd4[6:0] === E_3, "C03-d4-is-cur_id-3");
        chk(sd3[6:0] === E_8, "C04-d3-is-n_img-8");
        chk(sd1[6:0] === E_BLANK && sd0[6:0] === E_BLANK, "C05-no-error-both-blank");

        //--------------------------------------------- ② 模式位优先级
        $display("");
        $display("[%0t] ② 模式位 d5：A=自动 n=手动 E=应急（应急优先）", $time);
        auto_en = 1'b1; emerg_en = 1'b0; #10;
        chk(sd5[6:0] === E_LET_A, "C06-auto-mode-shows-A");
        auto_en = 1'b0; emerg_en = 1'b1; #10;
        chk(sd5[6:0] === E_LET_C, "C07-emerg-mode-shows-C");
        auto_en = 1'b1; emerg_en = 1'b1; #10;
        chk(sd5[6:0] === E_LET_C, "C08-emerg-wins-over-auto");

        //--------------------------------------------- ③ ★ d5 不可能是数字 9
        $display("");
        $display("[%0t] ③ ★ 关键：d5 在 4 种模式组合下只可能是 C/A/L，永远不是 9", $time);
        for (i = 0; i < 4; i = i + 1) begin
            mesg_ctrl(i);
            #10;
            $display("        auto=%b emerg=%b -> d5 的 8bit 码 = %02h",
                     auto_en, emerg_en, sd5);
            if (sd5 === 8'hC6 || sd5 === 8'h88 || sd5 === 8'hC7) d5_ok = d5_ok + 1;
            else                                                 d5_bad = d5_bad + 1;
            // 数字 '9' 的 8bit 码是 1001_0000（含小数点位）
            if (sd5 === 8'h90) d5_bad = d5_bad + 1;
        end
        chk(d5_bad === 0 && d5_ok === 4, "C09-d5-never-a-nine");
        $display("        数字 9 的段码 = 8'h90；C=8'hC6  A=8'h88  L=8'hC7 —— 都不等于 8'h90");

        //--------------------------------------------- ④ hex7 全 16 值译码
        $display("");
        $display("[%0t] ④ 4bit -> 7 段译码：0~F 共 16 个值逐个核对", $time);
        auto_en = 1'b0; emerg_en = 1'b0;
        for (i = 0; i < 16; i = i + 1) begin
            cur_id = i[3:0];
            #10;
            if (sd4[6:0] === exp_hex7(i[3:0])) hex_ok = hex_ok + 1;
            else begin
                hex_bad = hex_bad + 1;
                $display("        [译码不符] 输入 %0h -> 得到 %07b，期望 %07b",
                         i[3:0], sd4[6:0], exp_hex7(i[3:0]));
            end
        end
        chk(hex_bad === 0, "C10-hex7-decoding-all-16-values");
        $display("        16 个值里正确 %0d 个", hex_ok);
        cur_id = 4'd0;

        //--------------------------------------------- ⑤ 状态位随 state_code
        $display("");
        $display("[%0t] ⑤ 状态位 d2 = state_code（SD 好了以后）", $time);
        sd_init_done = 1'b1;
        for (i = 0; i < 8; i = i + 1) begin
            state_code = i[3:0];
            #10;
            if (sd2[6:0] !== exp_hex7(i[3:0])) begin
                $display("        [状态位不符] state_code=%0h -> %07b", i[3:0], sd2[6:0]);
            end
        end
        state_code = 4'd2; #10;
        chk(sd2[6:0] === E_2, "C11-d2-follows-state_code");
        state_code = 4'd5; #10;
        chk(sd2[6:0] === E_5, "C12-d2-state-5-means-error");

        //--------------------------------------------- ⑥ 错误码拆半字节
        $display("");
        $display("[%0t] ⑥ 错误码拆成高低半字节显示", $time);
        err_byte = 8'h80; #10;
        chk(sd1[6:0] === E_8 && sd0[6:0] === E_BLANK, "C13-err-0x80-hi8-lo-blank");
        err_byte = 8'h01; #10;
        chk(sd1[6:0] === E_BLANK && sd0[6:0] === E_1, "C14-err-0x01-hi-blank-lo1");
        err_byte = 8'hA5; #10;
        chk(sd1[6:0] === E_A && sd0[6:0] === E_5, "C15-err-0xA5-split-A-and-5");
        err_byte = 8'h0F; #10;
        chk(sd1[6:0] === E_BLANK && sd0[6:0] === E_F, "C16-err-0x0F-hi-blank-loF");
        err_byte = 8'h00; #10;

        //--------------------------------------------- ⑦ 小数点最高位恒为 1
        $display("");
        $display("[%0t] ⑦ 6 个输出的最高位（小数点）必须恒为 1（熄灭）", $time);
        err_byte = 8'hA5; auto_en = 1'b1; state_code = 4'd1; n_img = 4'd8; cur_id = 4'd7;
        #10;
        chk(sd0[7] && sd1[7] && sd2[7] && sd3[7] && sd4[7] && sd5[7], "C17-dp-bit-always-1");
        $display("        d5=%02h d4=%02h d3=%02h d2=%02h d1=%02h d0=%02h",
                 sd5, sd4, sd3, sd2, sd1, sd0);
        // 顺手确认这一组组合值符合预期（自动 + id7 + 总数8 + 状态1 + 错误 A5）
        chk(sd5 === {1'b1, E_LET_A} && sd4 === {1'b1, E_7} && sd3 === {1'b1, E_8} &&
            sd2 === {1'b1, E_1}     && sd1 === {1'b1, E_A} && sd0 === {1'b1, E_5},
            "C18-combined-scenario-correct");

        $display("");
        $display("==================================================");
        $display("[%0t] 仿真结束：通过 %0d 项，失败 %0d 项",
                 $time, chk_idx - fail_cnt, fail_cnt);
        $display("==================================================");
        $display("### RESULT tb_seg_status : %0s  (%0d/%0d) ###",
                 (fail_cnt == 0) ? "PASS" : "FAIL", chk_idx - fail_cnt, chk_idx);
        $finish;
    end

    // 辅助：按 0..3 设置 auto/emerg 组合
    task mesg_ctrl;
        input integer k;
        begin
            auto_en  = k[0];
            emerg_en = k[1];
        end
    endtask

endmodule
