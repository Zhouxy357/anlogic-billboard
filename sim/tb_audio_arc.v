//============================================================================
// tb_audio_arc.v  ——  HDMI 音频时钟再生参数（audio_arc_calculate）的行为仿真
//---------------------------------------------------------------------------
// 模块干什么：
//   在视频时钟域里数"收到多少个音频样本"，每 AUDIO_DIV = ACR_N>>7 = 48 个样本
//   输出一次 ACR 参数：
//       O_acr_valid  1 拍脉冲
//       O_acr_n      = ACR_N = 6144
//       O_acr_cts    = 上一次 ACR 到这一次 ACR 之间的【视频时钟个数】
//   ★ 本 tb 要专门验的一条：CTS 数的是"时钟"不是"样本"——
//     所以把音频采样率改稀（隔 N 拍才给 1 个 valid），CTS 就应该变成 48*N。
//
// 两个容易写错的点：
//   ① O_acr_cts 是寄存器输出，和 O_acr_valid 同一拍更新。在 tb 里同一个时钟沿
//      直接读会碰到调度竞争（可能读到上一拍的值）→ 本 tb 统一用"延迟 1 拍的
//      对齐寄存器"（av_v/acr_v/cts_r/n_r）再比对，彻底消掉竞争。
//   ② 统计必须从"复位释放之后"开始；换激励图案之后要先空跑几拍，
//      并且跳过换档后的前几个脉冲（分频计数器还带着上一档的残余进度）。
//
// 怎么跑（在 sim 目录下，用 Git Bash）：
//   ./run_iverilog.sh arc
//============================================================================
`timescale 1ns / 1ps

module tb_audio_arc;

    //---------------------------------------------------------- 时钟与复位
    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg rst = 1'b1;

    //---------------------------------------------------------- 音频 valid 图案
    // 每 gap 拍给 1 个 valid 脉冲（gap=1 → 每拍都给；gap=2 → 隔一拍给一个）
    // av_en = 0 → 静音：完全不产生 valid
    integer gap   = 1;
    integer g     = 0;
    reg     av_en = 1'b1;
    reg     av    = 1'b0;

    always @(posedge clk) begin
        if (rst || !av_en) begin
            g  <= 0;
            av <= 1'b0;
        end else if (g >= gap - 1) begin
            g  <= 0;
            av <= 1'b1;
        end else begin
            g  <= g + 1;
            av <= 1'b0;
        end
    end

    //---------------------------------------------------------- 被测模块
    localparam integer ACR_N = 6144;
    localparam integer DIV   = ACR_N >> 7;      // = 48

    wire        acr_valid;
    wire [19:0] acr_cts;
    wire [19:0] acr_n;

    audio_arc_calculate #(.ACR_N(ACR_N)) dut (
        .I_clk         (clk),
        .I_rst         (rst),
        .I_audio_valid (av),
        .O_acr_valid   (acr_valid),
        .O_acr_cts     (acr_cts),
        .O_acr_n       (acr_n)
    );

    //------------------------------------------------ 对齐寄存器（消竞争）
    reg        av_v   = 1'b0;
    reg        acr_v  = 1'b0;
    reg        acr_v2 = 1'b0;
    reg [19:0] cts_r  = 20'd0;
    reg [19:0] n_r    = 20'd0;

    always @(posedge clk) begin
        av_v   <= av;
        acr_v  <= acr_valid;
        acr_v2 <= acr_v;
        cts_r  <= acr_cts;
        n_r    <= acr_n;
    end

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
    // 监视器：数 ACR 脉冲 + 四条结构性质
    //   (a) clk_since（两次 ACR 之间实测的时钟数）== O_acr_cts
    //   (b) O_acr_cts == 期望周期（= DIV * gap）
    //   (c) 两次 ACR 之间的音频样本数 == DIV == 48
    //   (d) O_acr_n == ACR_N
    //=====================================================================
    integer acr_cnt   = 0;      // 见到的 acr 脉冲总数
    integer cmp       = 0;      // 真正参与比对的脉冲数
    integer bad_period= 0;      // clk_since 与 O_acr_cts 不符
    integer bad_exp   = 0;      // O_acr_cts 与期望周期不符
    integer bad_grp   = 0;      // 两次 ACR 之间的样本数不是 48
    integer bad_n     = 0;      // O_acr_n 不是 6144
    integer bad_width = 0;      // 脉冲宽度不是 1 拍
    integer bad_zero  = 0, zero_cmp = 0;   // 非脉冲拍 cts/n 应为 0
    integer clk_since = 0;
    integer av_tot    = 0, av_last = 0;
    integer exp_period = DIV;    // 期望周期（拍）
    reg [19:0] exp_period_r = 20'd48;
    integer last_cts  = 0, min_cts = 0, max_cts = 0;
    reg     mon_en    = 1'b0;
    integer dbg_n     = 0;
    integer int_meas  = 0;

    always @(posedge clk) begin
        if (rst) begin
            clk_since = 0;
            av_tot    = 0;
            av_last   = 0;
        end else begin
            if (av_v) av_tot = av_tot + 1;

            if (acr_v) begin
                if (mon_en) begin
                    // 宽度：连续两拍都高 → 不是 1 拍宽
                    if (acr_v2) bad_width = bad_width + 1;

                    if (acr_cnt >= 3) begin        // 跳过换档后的前 3 个脉冲
                        cmp = cmp + 1;
                        // clk_since 记的是"两次脉冲之间空过去的拍数"（脉冲那拍记 0），
                        // 而 CTS 数的是"区间内的时钟周期数"，所以要把脉冲那拍补上 → +1。
                        int_meas = clk_since + 1;
                        if (int_meas !== cts_r) begin
                            bad_period = bad_period + 1;
                            if (dbg_n < 6) begin
                                dbg_n = dbg_n + 1;
                                $display("        [周期不符] 实测时钟数=%0d  O_acr_cts=%0d  样本数=%0d",
                                         int_meas, cts_r, av_tot - av_last);
                            end
                        end
                        if (cts_r !== exp_period_r)       bad_exp    = bad_exp + 1;
                        if ((av_tot - av_last) !== DIV)   bad_grp    = bad_grp + 1;
                        if (n_r !== 20'd6144)             bad_n      = bad_n + 1;
                        last_cts = cts_r;
                        if (cts_r < min_cts) min_cts = cts_r;
                        if (cts_r > max_cts) max_cts = cts_r;
                    end

                    acr_cnt = acr_cnt + 1;
                    av_last = av_tot;
                end
                clk_since = 0;                     // 本拍是脉冲拍
            end else begin
                clk_since = clk_since + 1;
            end

            // 非脉冲拍：cts / n 必须是 0
            if (mon_en && !acr_v && acr_cnt > 0) begin
                zero_cmp = zero_cmp + 1;
                if (cts_r !== 20'd0 || n_r !== 20'd0) bad_zero = bad_zero + 1;
            end
        end
    end

    //---------------------------------------------------------- 换档
    task rearm;
        input [19:0] per;
        begin
            exp_period = per;
            exp_period_r = per;
            acr_cnt    = 0;
            cmp        = 0;
            bad_period = 0;
            bad_exp    = 0;
            bad_grp    = 0;
            bad_n      = 0;
            bad_width  = 0;
            bad_zero   = 0;
            zero_cmp   = 0;
            min_cts    = 100000;
            max_cts    = 0;
            mon_en     = 1'b1;
        end
    endtask

    integer n0 = 0;

    //=====================================================================
    // 主流程
    //=====================================================================
    initial begin
        $timeformat(-9, 0, " ns", 12);

        //--------------------------------------------- 复位
        #1000;
        $display("");
        $display("[%0t] 复位：O_acr_valid / O_acr_cts / O_acr_n 都应为 0", $time);
        $display("        valid=%b cts=%0d n=%0d", acr_valid, acr_cts, acr_n);
        chk(acr_valid === 1'b0 && acr_cts === 20'd0 && acr_n === 20'd0, "C01-rst-outputs-zero");

        rst = 1'b0;
        repeat (3) @(posedge clk);

        //=========================================== 阶段 1：连续 valid（gap=1）
        av_en = 1'b1;
        gap   = 1;
        repeat (3) @(posedge clk);
        rearm(1 * DIV);
        repeat (3000) @(posedge clk);

        $display("");
        $display("[%0t] 阶段 1：每拍都给 valid（gap=1，理论 CTS = 48 个时钟）", $time);
        $display("        比对 %0d 个 ACR 脉冲；CTS 实测范围 %0d..%0d，末次 %0d",
                 cmp, min_cts, max_cts, last_cts);
        chk(bad_period === 0, "C02-cts-equals-measured-clock-count");
        chk(bad_exp    === 0, "C03-cts-is-48-at-gap1");
        chk(bad_grp    === 0, "C04-48-audio-samples-per-acr");
        chk(bad_n      === 0, "C05-acr-n-is-6144");
        chk(bad_width  === 0, "C06-acr-valid-is-1-cycle");
        chk(cmp > 50,         "C07-enough-acr-pulses");

        //=========================================== 阶段 2：隔一拍给（gap=2）
        gap = 2;
        repeat (3) @(posedge clk);
        rearm(2 * DIV);
        repeat (6000) @(posedge clk);

        $display("");
        $display("[%0t] 阶段 2：隔一拍给 valid（gap=2，理论 CTS = 96 个时钟）", $time);
        $display("        比对 %0d 个脉冲；CTS 实测范围 %0d..%0d", cmp, min_cts, max_cts);
        chk(bad_period === 0 && bad_exp === 0 && bad_grp === 0 && cmp > 30,
            "C08-gap2-cts-is-96-clocks");

        //=========================================== 阶段 3：每 5 拍给一个（gap=5）
        gap = 5;
        repeat (3) @(posedge clk);
        rearm(5 * DIV);
        repeat (12000) @(posedge clk);

        $display("");
        $display("[%0t] 阶段 3：每 5 拍给 1 个 valid（gap=5，理论 CTS = 240 个时钟）", $time);
        $display("        比对 %0d 个脉冲；CTS 实测范围 %0d..%0d", cmp, min_cts, max_cts);
        chk(bad_period === 0 && bad_exp === 0 && bad_grp === 0 && cmp > 20,
            "C09-gap5-cts-is-240-clocks");

        //=========================================== 阶段 4：静音
        av_en = 1'b0;
        repeat (8) @(posedge clk);
        n0 = acr_cnt;
        repeat (500) @(posedge clk);

        $display("");
        $display("[%0t] 阶段 4：静音 500 拍", $time);
        $display("        静音前脉冲数 %0d，静音后 %0d", n0, acr_cnt);
        chk(acr_cnt === n0, "C10-no-acr-during-silence");

        //---- 静音结束，恢复正常，应能继续正确输出 ----
        av_en = 1'b1;
        gap   = 1;
        repeat (6) @(posedge clk);
        rearm(1 * DIV);
        repeat (3000) @(posedge clk);
        $display("        恢复后比对 %0d 个脉冲；CTS 范围 %0d..%0d", cmp, min_cts, max_cts);
        chk(bad_period === 0 && bad_exp === 0 && bad_grp === 0 && cmp > 50,
            "C11-recovers-after-silence");

        //=========================================== 非脉冲拍 cts/n 归零
        $display("");
        $display("[%0t] C12：非脉冲拍 cts/n 应保持 0（比对 %0d 拍）", $time, zero_cmp);
        chk(bad_zero === 0 && zero_cmp > 1000, "C12-cts-n-zero-when-idle");

        //=========================================== 复位再验证
        rst = 1'b1;
        repeat (3) @(posedge clk);
        $display("");
        $display("[%0t] 复位再验证：valid=%b cts=%0d n=%0d", $time, acr_valid, acr_cts, acr_n);
        chk(acr_valid === 1'b0 && acr_cts === 20'd0 && acr_n === 20'd0, "C13-rst-clears-again");
        rst = 1'b0;

        $display("");
        $display("==================================================");
        $display("[%0t] 仿真结束：通过 %0d 项，失败 %0d 项",
                 $time, chk_idx - fail_cnt, fail_cnt);
        $display("==================================================");
        $display("### RESULT tb_audio_arc : %0s  (%0d/%0d) ###",
                 (fail_cnt == 0) ? "PASS" : "FAIL", chk_idx - fail_cnt, chk_idx);
        $finish;
    end

    initial begin
        #30_000_000;
        $display("### RESULT tb_audio_arc : FAIL  (超时) ###");
        $finish;
    end

endmodule
