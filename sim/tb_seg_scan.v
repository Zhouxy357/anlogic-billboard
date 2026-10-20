//============================================================================
// tb_seg_scan.v  ——  6 位数码管动态扫描（seg_scan）的行为仿真
//---------------------------------------------------------------------------
// 官方模块，原样未改。作用：用 6 根位选线轮流点亮 6 个数码管，
//   同时不断切换段数据，人眼看到的就是"6 位同时亮"。
//
// 关键参数（本工程用 50MHz）：
//   SCAN_COUNT = CLK_FREQ/(SCAN_FREQ*6) - 1 = 50e6/(200*6) - 1 = 41665
//   即每位点亮 41666 拍（0.833ms），一圈 6 位 = 249996 拍 ≈ 5ms → 200Hz
//
// 测什么：
//   ① 复位（rst_n=0）时 seg_sel = 6'b111111、seg_data = 8'hff（全灭）
//   ② 每个位选持续 SCAN_COUNT+1 拍（用真实参数算出来的 41666）
//   ③ 位选顺序：111110 -> 111101 -> 111011 -> 110111 -> 101111 -> 011111 -> 回绕
//   ④ 段数据跟着位选走：第 N 位亮的时候 seg_data 必须等于 seg_data_N
//   ⑤ 任何时候都【有且仅有】一位被选中（独热，否则会出现重影/串位）
//   ⑥ 一整圈 = 6 × 41666 拍，对应刷新率 ≈ 200Hz
//
// 怎么跑（在 sim 目录下，用 Git Bash）：
//   ./run_iverilog.sh seg_scan
//============================================================================
`timescale 1ns / 1ps

module tb_seg_scan;

    //---------------------------------------------------------- 时钟与复位
    // 仿真时钟就用 50MHz 的"拍"来数（模块内部全按拍计数，与真实频率无关）
    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg rst_n = 1'b0;

    //------------------------------------------------ 6 位段数据（用互不相同的值，便于验证对应关系）
    //  注意：刻意选成两两不同，且都不是 8'hff
    wire [7:0] d0 = 8'hA0, d1 = 8'hB1, d2 = 8'hC2;
    wire [7:0] d3 = 8'hD3, d4 = 8'hE4, d5 = 8'hF5;

    wire [5:0] seg_sel;
    wire [7:0] seg_data;

    seg_scan #(
        .SCAN_FREQ (200),
        .CLK_FREQ  (50_000_000)
    ) dut (
        .clk        (clk),
        .rst_n      (rst_n),
        .seg_sel    (seg_sel),
        .seg_data   (seg_data),
        .seg_data_0 (d0),
        .seg_data_1 (d1),
        .seg_data_2 (d2),
        .seg_data_3 (d3),
        .seg_data_4 (d4),
        .seg_data_5 (d5)
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

    //------------------------------------------------ 期望值（独立算出来，不用 DUT 的参数）
    localparam integer EXP_COUNT = 50_000_000 / (200 * 6) - 1;   // 41665
    localparam integer EXP_HOLD  = EXP_COUNT + 1;                // 41666

    //=====================================================================
    // 测量块
    //=====================================================================
    integer t = 0;
    reg     mon_en = 0;
    reg [5:0] sel_p = 6'b111111;

    integer hold_cnt = 0;                 // 当前位选已经保持了几拍
    integer hold_ok = 0, hold_bad = 0;
    integer sel_changes = 0;
    reg [5:0] seq [0:15];                 // 记录位选变化序列
    integer seq_len = 0;

    integer multi_sel_bad = 0;            // 同一时刻选中多位/零位 的次数
    integer data_bad = 0;                 // 段数据与位选不对应 的次数
    integer total_cycles = 0;

    // 位选为中心时的段数据期望值
    function [7:0] exp_data;
        input [5:0] sel;
        begin
            case (sel)
                6'b11_1110: exp_data = 8'hA0;
                6'b11_1101: exp_data = 8'hB1;
                6'b11_1011: exp_data = 8'hC2;
                6'b11_0111: exp_data = 8'hD3;
                6'b10_1111: exp_data = 8'hE4;
                6'b01_1111: exp_data = 8'hF5;
                default:    exp_data = 8'hFF;   // 不该出现；真出现会被判为不符
            endcase
        end
    endfunction

    integer zeros;
    always @(posedge clk) begin
        t = t + 1;

        if (mon_en) begin
            hold_cnt     = hold_cnt + 1;
            total_cycles = total_cycles + 1;

            // ---- 独热检查：~seg_sel 里恰好 1 个 1 ----
            zeros = 0;
            if (seg_sel[0] == 1'b0) zeros = zeros + 1;
            if (seg_sel[1] == 1'b0) zeros = zeros + 1;
            if (seg_sel[2] == 1'b0) zeros = zeros + 1;
            if (seg_sel[3] == 1'b0) zeros = zeros + 1;
            if (seg_sel[4] == 1'b0) zeros = zeros + 1;
            if (seg_sel[5] == 1'b0) zeros = zeros + 1;
            if (zeros !== 1) multi_sel_bad = multi_sel_bad + 1;

            // ---- 段数据必须跟随位选 ----
            if (seg_data !== exp_data(seg_sel)) data_bad = data_bad + 1;

            // ---- 位选保持时长 ----
            if (seg_sel !== sel_p) begin
                // ★ 只统计"完整的"保持区间：监测是从半路开始的，
                //   第 1 次变化之前那段是残段，跳过不算。
                if (sel_changes > 1) begin
                    if (hold_cnt === EXP_HOLD) hold_ok  = hold_ok  + 1;
                    else                       hold_bad = hold_bad + 1;
                end
                if (seq_len < 16) begin
                    seq[seq_len] = seg_sel;
                    seq_len = seq_len + 1;
                end
                sel_changes = sel_changes + 1;
                hold_cnt = 0;
                sel_p <= seg_sel;
            end
        end
    end

    //=====================================================================
    // 主流程
    //=====================================================================
    integer i;

    initial begin
        $timeformat(-9, 0, " ns", 12);

        //--------------------------------------------- 复位
        #1000;
        $display("");
        $display("[%0t] 复位（rst_n=0）：seg_sel 应为 6'b111111，seg_data 应为 8'hff", $time);
        $display("        seg_sel=%b seg_data=%02h", seg_sel, seg_data);
        chk(seg_sel === 6'b111111, "C01-rst-sel-all-off");
        chk(seg_data === 8'hFF,    "C02-rst-data-all-off");

        rst_n = 1'b1;
        repeat (5) @(posedge clk);
        mon_en = 1'b1;

        //--------------------------------------------- 跑 2 圈多
        repeat (2 * 6 * EXP_HOLD + EXP_HOLD + 20) @(posedge clk);
        mon_en = 1'b0;

        $display("");
        $display("[%0t] 扫描统计（共 %0d 拍）", $time, total_cycles);
        $display("        位选变化 %0d 次，其中保持时长 = %0d 拍的有 %0d 次，异常 %0d 次",
                 sel_changes, EXP_HOLD, hold_ok, hold_bad);
        chk(hold_bad === 0 && hold_ok >= 12, "C03-each-digit-holds-41666-cycles");
        chk(multi_sel_bad === 0, "C04-exactly-one-digit-on-at-a-time");
        chk(data_bad === 0, "C05-seg-data-follows-select");

        $display("");
        $display("        位选序列（前 %0d 个）：", seq_len);
        for (i = 0; i < seq_len; i = i + 1)
            $display("          [%0d] seg_sel = %b", i, seq[i]);
        // 期望顺序：110 -> 101 -> 011 -> 111 -> 111 -> 111 ... （按 6 位低电平位看）
        chk(seq[0] === 6'b11_1110, "C06-seq0-digit0");
        chk(seq[1] === 6'b11_1101, "C07-seq1-digit1");
        chk(seq[2] === 6'b11_1011, "C08-seq2-digit2");
        chk(seq[3] === 6'b11_0111, "C09-seq3-digit3");
        chk(seq[4] === 6'b10_1111, "C10-seq4-digit4");
        chk(seq[5] === 6'b01_1111, "C11-seq5-digit5");
        chk(seq[6] === 6'b11_1110, "C12-seq6-wraps-back-to-digit0");

        //--------------------------------------------- 刷新率
        begin : refresh
            real fr;
            fr = 1.0 * 50_000_000 / (6.0 * EXP_HOLD);
            $display("");
            $display("        一整圈 = 6 x %0d = %0d 拍；刷新率 = 50MHz / %0d = %0.2f Hz",
                     EXP_HOLD, 6 * EXP_HOLD, 6 * EXP_HOLD, fr);
            chk(fr > 190.0 && fr < 210.0, "C13-refresh-near-200Hz");
        end

        //--------------------------------------------- 复位再验证
        rst_n = 1'b0;
        repeat (3) @(posedge clk);
        $display("");
        $display("        再次复位：seg_sel=%b seg_data=%02h", seg_sel, seg_data);
        chk(seg_sel === 6'b111111 && seg_data === 8'hFF, "C14-rst-again-all-off");
        rst_n = 1'b1;

        $display("");
        $display("==================================================");
        $display("[%0t] 仿真结束：通过 %0d 项，失败 %0d 项",
                 $time, chk_idx - fail_cnt, fail_cnt);
        $display("==================================================");
        $display("### RESULT tb_seg_scan : %0s  (%0d/%0d) ###",
                 (fail_cnt == 0) ? "PASS" : "FAIL", chk_idx - fail_cnt, chk_idx);
        $finish;
    end

    initial begin
        #10_000_000;
        $display("### RESULT tb_seg_scan : FAIL  (超时) ###");
        $finish;
    end

endmodule
