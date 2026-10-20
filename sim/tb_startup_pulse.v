//============================================================================
// tb_startup_pulse.v  ——  上电延时脉冲（startup_pulse）的行为仿真
//---------------------------------------------------------------------------
// 模块干什么：
//   复位释放之后数 CNT_MAX 个时钟，在【第 CNT_MAX 拍】输出 1 拍宽的脉冲，
//   然后锁存 S_done，以后再也不出（除非再复位）。用途是给下游留一段
//   "等板子上电稳定 / 等 PLL 锁定"的启动时间。
//
// ★ 本 tb 的采样姿势（很重要，不这么写就会差 1 拍）：
//   用 negedge 采样，而不是 @(posedge clk) 之后立刻读。
//   因为 DUT 的输出是寄存器输出（非阻塞赋值），在 posedge 的"同一拍"里读到的
//   还是上一拍的值；等半个周期到 negedge，所有非阻塞赋值都落地了，读到的才是
//   "这个 posedge 之后"的真实值。
//   于是：rst 释放后的第 k 个 negedge，看到的就是"第 k 拍之后"的状态。
//
// 三个实例：
//   dut_a  CNT_MAX = 8        —— 小参数，逐拍数
//   dut_b  CNT_MAX = 100000   —— 官方默认值（真正上板用的那一档）
//   dut_c  CNT_MAX = 1        —— 边界：第 1 拍就出脉冲
//
// 怎么跑（在 sim 目录下，用 Git Bash）：
//   ./run_iverilog.sh startup
//============================================================================
`timescale 1ns / 1ps

module tb_startup_pulse;

    //---------------------------------------------------------- 时钟与复位
    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg rst = 1'b1;

    //---------------------------------------------------------- 三个实例
    localparam integer CN_A = 8;
    localparam integer CN_B = 100000;
    localparam integer CN_C = 1;

    wire p_a, p_b, p_c;

    startup_pulse #(.CNT_MAX(20'd8))      dut_a (.I_clk(clk), .I_rst(rst), .O_pulse(p_a));
    startup_pulse #(.CNT_MAX(20'd100000)) dut_b (.I_clk(clk), .I_rst(rst), .O_pulse(p_b));
    startup_pulse #(.CNT_MAX(20'd1))      dut_c (.I_clk(clk), .I_rst(rst), .O_pulse(p_c));

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

    //=====================================================================
    // 监视器：脉冲次数 + 脉冲宽度（连续两拍都高就是宽度 > 1）
    //=====================================================================
    reg pa_d = 0, pa_dd = 0;
    reg pb_d = 0, pb_dd = 0;
    reg pc_d = 0, pc_dd = 0;

    integer cnt_a = 0, cnt_b = 0, cnt_c = 0;
    integer wide_a = 0, wide_b = 0, wide_c = 0;

    always @(posedge clk) begin
        pa_d  <= p_a;  pa_dd  <= pa_d;
        pb_d  <= p_b;  pb_dd  <= pb_d;
        pc_d  <= p_c;  pc_dd  <= pc_d;

        // 不加 if(!rst) 门：复位期间 O_pulse 恒为 0，本来就不会产生假边沿；
        // 而"上升沿检测"比脉冲本身晚 2 拍，一旦用 rst 去门它，
        // 紧跟其后的复位就会把这个边沿吞掉（本 tb 踩过这个坑）。
        if (pa_d && !pa_dd) cnt_a = cnt_a + 1;      // 上升沿
        if (pb_d && !pb_dd) cnt_b = cnt_b + 1;
        if (pc_d && !pc_dd) cnt_c = cnt_c + 1;

        if (pa_d && pa_dd) wide_a = wide_a + 1;     // 宽度 > 1 拍
        if (pb_d && pb_dd) wide_b = wide_b + 1;
        if (pc_d && pc_dd) wide_c = wide_c + 1;
    end

    //=====================================================================
    // 主流程
    //  ★ 采样约定：复位释放之后的第 k 个 negedge = "第 k 拍结束后"
    //=====================================================================
    initial begin
        $timeformat(-9, 0, " ns", 12);

        //--------------------------------------------- 复位期间
        // ★ 用 #1002 而不是 #1000：时钟在 t=5,15,25...,5+10k 上跳、在 10k 下落，
        //   #1000 正好落在下降沿上，initial 块和时钟块会在同一个时间步里竞争，
        //   "第 1 拍后"那次采样就可能比第一个上升沿还早。挪到两个沿中间最干净。
        #1002;
        $display("");
        $display("[%0t] 复位：三个实例的 O_pulse 都应为 0", $time);
        $display("        p_a=%b p_b=%b p_c=%b", p_a, p_b, p_c);
        chk(p_a === 1'b0 && p_b === 1'b0 && p_c === 1'b0, "C01-rst-pulse-low");

        rst = 1'b0;

        //=========================================== 阶段 A：dut_c（CNT_MAX=1）
        $display("");
        $display("[%0t] 阶段 A：CNT_MAX=1，第 1 拍就应该出脉冲", $time);
        @(negedge clk);                                 // 第 1 拍结束
        $display("        第 1 拍后：p_c=%b（p_a=%b p_b=%b）", p_c, p_a, p_b);
        chk(p_c === 1'b1, "C02-cntmax1-pulse-at-1st-cycle");
        chk(p_a === 1'b0 && p_b === 1'b0, "C03-others-not-yet");
        @(negedge clk);
        $display("        第 2 拍后：p_c=%b", p_c);
        chk(p_c === 1'b0, "C04-cntmax1-pulse-width-1");

        //=========================================== 阶段 B：dut_a（CNT_MAX=8）
        // 重新复位，干净地从 0 开始数
        rst = 1'b1;
        repeat (3) @(negedge clk);
        rst = 1'b0;

        $display("");
        $display("[%0t] 阶段 B：CNT_MAX=8", $time);
        repeat (CN_A - 1) @(negedge clk);               // 第 7 拍结束
        $display("        第 7 拍后：p_a=%b", p_a);
        chk(p_a === 1'b0, "C05-cntmax8-no-early-pulse");
        @(negedge clk);                                 // 第 8 拍结束
        $display("        第 8 拍后：p_a=%b", p_a);
        chk(p_a === 1'b1, "C06-cntmax8-pulse-at-8th-cycle");
        @(negedge clk);
        $display("        第 9 拍后：p_a=%b", p_a);
        chk(p_a === 1'b0, "C07-cntmax8-pulse-width-1");

        //---- 长时间不再重复 ----
        repeat (10 * CN_A) @(negedge clk);
        $display("        又过了 %0d 拍（合计 %0d 次脉冲）", 10 * CN_A, cnt_a);
        chk(cnt_a === 1, "C08-pulse-not-repeated");

        //=========================================== 阶段 C：dut_b（默认 100000）
        $display("");
        $display("[%0t] 阶段 C：CNT_MAX=100000（官方默认值）", $time);
        rst = 1'b1;
        repeat (3) @(negedge clk);
        rst = 1'b0;

        repeat (CN_B - 1) @(negedge clk);
        $display("        第 %0d 拍后：p_b=%b", CN_B - 1, p_b);
        chk(p_b === 1'b0, "C09-default-no-pulse-before-100000");
        @(negedge clk);
        $display("        第 %0d 拍后：p_b=%b", CN_B, p_b);
        chk(p_b === 1'b1, "C10-default-pulse-at-100000");
        @(negedge clk);
        $display("        第 %0d 拍后：p_b=%b", CN_B + 1, p_b);
        chk(p_b === 1'b0, "C11-default-pulse-width-1");

        //=========================================== 汇总：脉冲总数与宽度
        repeat (20) @(negedge clk);
        $display("");
        $display("[%0t] 脉冲统计：", $time);
        $display("        dut_a(8)      共 %0d 次，宽度异常 %0d 次", cnt_a, wide_a);
        $display("        dut_b(100000) 共 %0d 次，宽度异常 %0d 次", cnt_b, wide_b);
        $display("        dut_c(1)      共 %0d 次，宽度异常 %0d 次", cnt_c, wide_c);
        chk(cnt_a === 2 && cnt_b === 1 && wide_a === 0 && wide_b === 0,
            "C12-total-pulses-as-expected");
        chk(wide_c === 0 && cnt_c === 3, "C13-cntmax1-total-3-pulses");

        $display("");
        $display("==================================================");
        $display("[%0t] 仿真结束：通过 %0d 项，失败 %0d 项",
                 $time, chk_idx - fail_cnt, fail_cnt);
        $display("==================================================");
        $display("### RESULT tb_startup_pulse : %0s  (%0d/%0d) ###",
                 (fail_cnt == 0) ? "PASS" : "FAIL", chk_idx - fail_cnt, chk_idx);
        $finish;
    end

    initial begin
        #60_000_000;
        $display("### RESULT tb_startup_pulse : FAIL  (超时) ###");
        $finish;
    end

endmodule
