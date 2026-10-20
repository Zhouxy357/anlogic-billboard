//============================================================================
// tb_transition_ctrl.v  ——  淡入淡出转场控制器（transition_ctrl）的行为仿真
//---------------------------------------------------------------------------
// 模块职责：
//   P_IDLE(全黑) --req--> P_SWITCH(全黑, 给 ack) -> P_HOLD(再黑 1 帧)
//     -> P_FADE_IN(每帧 +16 直到 256) -> P_STEADY(保持 256)
//     --req--> P_FADE_OUT(每帧 -16 直到 0) -> P_SWITCH ...
//
// 最关键的两条不变量（画面撕裂就出在这两条上）：
//   ★ ack 只允许在"全黑"（blend == 0）的那一拍发出 —— 换缓冲区指针必须在全黑瞬间。
//   ★ blend 只能在"帧边界"（frame_tick）变化 —— 否则会出现撕裂的横向亮暗带。
//
// 测什么：
//   ① 复位：phase = P_IDLE，blend = 0，ack = 0
//   ② req 之后 ack 恰好 1 拍
//   ③ ★ ack 发生时 blend 必须 == 0（全黑换帧）
//   ④ ack 时 phase = P_SWITCH，随后进 P_HOLD
//   ⑤ FADE_IN：blend 每帧 +16，最终【正好】到 256 并转 P_STEADY
//   ⑥ STEADY：blend 恒 256
//   ⑦ FADE_OUT：blend 每帧 -16，最终【正好】到 0
//   ⑧ blend 值域恒在 [0,256]，从不越界（不会冲到 272 或变成负数）
//   ⑨ 相邻两次 ack 之间恰好 33 帧（FADE_OUT 16 + HOLD 1 + FADE_IN 16）
//   ⑩ blend 只在 frame_tick 那一拍变化
//   ⑪ req 拉低后不再产生新的 ack
//   ⑫ 复位能随时打断并回到 IDLE
//
// 怎么跑（在 sim 目录下，用 Git Bash）：
//   ./run_iverilog.sh transition
//============================================================================
`timescale 1ns / 1ps

module tb_transition_ctrl;

    //---------------------------------------------------------- 时钟
    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg rst = 1'b1;
    reg req = 1'b0;

    //---------------------------------------------------------- 帧同步脉冲
    localparam integer FRAME_CYC = 50;      // 50 拍一帧（只为方便数拍）
    integer fc = 0;
    reg     frame_tick = 1'b0;

    always @(posedge clk) begin
        if (rst) begin
            fc <= 0;
            frame_tick <= 1'b0;
        end else if (fc == FRAME_CYC - 1) begin
            fc <= 0;
            frame_tick <= 1'b1;
        end else begin
            fc <= fc + 1;
            frame_tick <= 1'b0;
        end
    end

    //---------------------------------------------------------- 被测模块
    wire        ack;
    wire [8:0]  blend;
    wire [2:0]  phase;

    transition_ctrl #(.STEP(9'd16)) dut (
        .clk        (clk),
        .rst        (rst),
        .frame_tick (frame_tick),
        .req        (req),
        .ack        (ack),
        .blend      (blend),
        .phase      (phase)
    );

    localparam [2:0] P_IDLE = 3'd0, P_FADE_IN = 3'd1, P_STEADY = 3'd2;
    localparam [2:0] P_FADE_OUT = 3'd3, P_SWITCH = 3'd4, P_HOLD = 3'd5;

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
    // 监视块（单一 always）
    //=====================================================================
    integer t = 0;
    reg     ft_p = 0, ack_p = 0;
    integer frames = 0;

    integer ack_cnt = 0, ack_blend_bad = 0, ack_phase_bad = 0, ack_width_bad = 0;
    integer blend_range_bad = 0;
    integer blend_change_off_frame = 0;
    integer last_ack_frame = -1;
    integer fade_in_frames = 0, fade_out_frames = 0;
    integer ack_cycle = 0;

    reg [8:0] blend_p = 9'd0;
    reg [2:0] phase_p = P_IDLE;
    reg       rst_p   = 1'b1;

    always @(posedge clk) begin
        t = t + 1;

        ft_p  <= frame_tick;
        ack_p <= ack;
        phase_p <= phase;
        rst_p   <= rst;

        if (frame_tick && !ft_p) frames = frames + 1;      // 帧边界

        // ---- ack 检查 ----
        // 注意：源码里 ack 和 phase<=P_HOLD 是【同一个时钟沿】发生的，
        //       所以 ack=1 那一拍看到的 phase 已经是 P_HOLD，上一拍才是 P_SWITCH。
        if (ack) begin
            if (!ack_p) begin                              // ack 上升
                ack_cnt = ack_cnt + 1;
                ack_cycle = 1;
                if (blend !== 9'd0)        ack_blend_bad = ack_blend_bad + 1;
                if (phase_p !== P_SWITCH)  ack_phase_bad = ack_phase_bad + 1;
                last_ack_frame = frames;
            end else begin
                ack_cycle = ack_cycle + 1;
                if (ack_cycle > 1) ack_width_bad = ack_width_bad + 1;   // 必须只有 1 拍
            end
        end

        // ---- blend 值域 ----
        if (blend > 9'd256) blend_range_bad = blend_range_bad + 1;

        // ---- blend 只能在帧边界变化 ----
        //   （复位会强行把 blend 拉 0，这条不算；所以复位那一拍跳过）
        if (blend !== blend_p) begin
            if (!(frame_tick || ft_p) && !(rst || rst_p)) blend_change_off_frame = blend_change_off_frame + 1;
            blend_p <= blend;
        end else begin
            blend_p <= blend;
        end

        // ---- 数一下淡入/淡出各用了多少帧 ----
        if (frame_tick && !ft_p) begin
            if (phase === P_FADE_IN)  fade_in_frames  = fade_in_frames  + 1;
            if (phase === P_FADE_OUT) fade_out_frames = fade_out_frames + 1;
        end
    end

    //=====================================================================
    // 主流程
    //=====================================================================
    integer ack_before = 0;
    integer i;
    integer f_a = 0, f_b = 0, gap = 0;
    reg [8:0] seq_in [0:63];
    integer   seq_in_len = 0;
    integer   seq_ok = 0;

    // 记录 FADE_IN 过程中的 blend 序列
    // ★ 用这个块【自己的】影子寄存器，不共用监视块的 ft_p
    //   （iverilog 里两个 always 块的执行顺序会交替，共用影子寄存器会漏采或重采）
    reg        rec = 0;
    reg        ft_p2 = 0;
    always @(posedge clk) begin
        ft_p2 <= frame_tick;
        if (rec && frame_tick && !ft_p2 && seq_in_len < 64 && phase === P_FADE_IN) begin
            seq_in[seq_in_len] = blend;      // 采集的是"本帧更新前"的值
            seq_in_len = seq_in_len + 1;
        end
    end

    initial begin
        $timeformat(-9, 0, " ns", 12);

        //--------------------------------------------- ① 复位
        #1000;
        $display("");
        $display("[%0t] ① 复位：phase 应为 IDLE，blend=0，ack=0", $time);
        $display("        phase=%b blend=%0d ack=%b", phase, blend, ack);
        chk(phase === P_IDLE, "C01-rst-phase-idle");
        chk(blend === 9'd0,   "C02-rst-blend-zero");
        chk(ack === 1'b0,     "C03-rst-ack-low");

        rst = 1'b0;
        repeat (10) @(posedge clk);

        //--------------------------------------------- ② req -> ack
        $display("");
        $display("[%0t] ② 拉起 req，等 ack（换帧必须发生在全黑瞬间）", $time);
        req = 1'b1;
        wait (ack === 1'b1);
        chk(blend === 9'd0, "C04-ack-asserted-at-black");
        chk(phase === P_HOLD, "C05-ack-cycle-is-hold-phase");
        $display("        ack 时：blend=%0d phase=%0d（P_HOLD=5；P_SWITCH 只停留 1 拍）",
                 blend, phase);
        req = 1'b0;                              // 这一轮先不请求下一次

        //--------------------------------------------- ③ 等淡入完成
        $display("");
        $display("[%0t] ③ 等淡入完成（看 blend 是不是每帧 +16 且正好到 256）", $time);
        rec = 1'b1;
        #20;                                     // 跳过 ack 后的同拍
        wait (blend === 9'd256 && phase === P_STEADY);
        rec = 1'b0;
        repeat (3) @(posedge clk);
        chk(phase === P_STEADY, "C06-reach-steady");
        $display("        淡入用了 %0d 帧，blend 序列（每帧末值）：", fade_in_frames);
        for (i = 0; i < (seq_in_len < 20 ? seq_in_len : 20); i = i + 1)
            $display("          帧 %0d: blend=%0d", i, seq_in[i]);
        chk(fade_in_frames === 16, "C07-fade-in-16-frames");
        // FADE_IN 每帧更新前的 blend 应该是 0,16,32,...,240（正好 16 个，最后封顶到 256）
        begin : seqchk
            integer k;
            seq_ok = 1;
            if (seq_in_len !== 16) seq_ok = 0;
            for (k = 0; k < 16 && k < seq_in_len; k = k + 1) begin
                if (seq_in[k] !== (k * 16)) seq_ok = 0;
            end
        end
        chk(seq_ok === 1, "C08-blend-steps-of-16-then-clamped-256");
        $display("        采集到 %0d 个淡入帧的 blend 值", seq_in_len);

        //--------------------------------------------- ④ STEADY 时 blend 恒 256
        $display("");
        $display("[%0t] ④ STEADY 阶段：blend 必须恒定 256", $time);
        repeat (3 * FRAME_CYC) @(posedge clk);
        chk(blend === 9'd256 && phase === P_STEADY, "C09-steady-holds-256");
        $display("        blend=%0d phase=%0d", blend, phase);

        //--------------------------------------------- ⑤ 再请求一次换帧
        $display("");
        $display("[%0t] ⑤ 再拉起 req：应走 FADE_OUT（16 帧）-> ack", $time);
        ack_before = ack_cnt;
        req = 1'b1;
        wait (ack_cnt > ack_before);
        chk(blend === 9'd0, "C10-second-ack-also-at-black");
        chk(phase === P_HOLD, "C11-second-ack-cycle-phase");
        $display("        第二次 ack：blend=%0d phase=%0d", blend, phase);
        req = 1'b0;

        //--------------------------------------------- ⑥ 再跑一轮完整循环看间隔
        $display("");
        $display("[%0t] ⑥ 完整循环：req 一直保持，量两次 ack 之间的帧数", $time);
        req = 1'b1;                              // 让它一直循环
        ack_before = ack_cnt;
        wait (ack_cnt > ack_before);             // 第 1 个 ack
        f_a = frames;
        wait (ack_cnt > ack_before + 1);         // 第 2 个 ack
        f_b = frames;
        req = 1'b0;
        gap = f_b - f_a;
        $display("        相邻两次 ack 间隔：%0d 帧（期望 33 = 淡出16 + 保持1 + 淡入16）", gap);
        chk(gap === 33, "C12-ack-gap-is-33-frames");

        //--------------------------------------------- ⑦ req 拉低后不再 ack
        $display("");
        $display("[%0t] ⑦ req 已拉低：不应再产生新的 ack", $time);
        ack_before = ack_cnt;
        repeat (60 * FRAME_CYC) @(posedge clk);
        chk(ack_cnt === ack_before, "C13-no-new-ack-after-req-cleared");
        $display("        60 帧内 ack 次数：%0d -> %0d", ack_before, ack_cnt);

        //--------------------------------------------- 汇总判据
        $display("");
        $display("[%0t] 汇总：ack 共 %0d 次，帧数 %0d", $time, ack_cnt, frames);
        chk(ack_blend_bad === 0, "C14-all-acks-at-blend-zero");
        chk(ack_phase_bad === 0, "C15-all-acks-in-switch-phase");
        chk(ack_width_bad === 0, "C16-ack-is-exactly-one-cycle");
        chk(blend_range_bad === 0, "C17-blend-never-exceeds-256");
        chk(blend_change_off_frame === 0, "C18-blend-changes-only-on-frame-tick");
        $display("        ack 时非全黑 %0d 次；相位错 %0d 次；ack 超过 1 拍 %0d 次；",
                 ack_blend_bad, ack_phase_bad, ack_width_bad);
        $display("        blend 越界 %0d 次；非帧边界变化 %0d 次；",
                 blend_range_bad, blend_change_off_frame);

        //--------------------------------------------- ⑧ 复位打断
        $display("");
        $display("[%0t] ⑧ 中途复位：应立刻回到 IDLE 且 blend=0", $time);
        req = 1'b1;
        repeat (5 * FRAME_CYC) @(posedge clk);       // 让它跑到淡出中途
        rst = 1'b1;
        repeat (3) @(posedge clk);
        $display("        复位后：phase=%0d blend=%0d ack=%b", phase, blend, ack);
        chk(phase === P_IDLE && blend === 9'd0, "C19-rst-interrupts-to-idle");
        rst = 1'b0;

        $display("");
        $display("==================================================");
        $display("[%0t] 仿真结束：通过 %0d 项，失败 %0d 项",
                 $time, chk_idx - fail_cnt, fail_cnt);
        $display("==================================================");
        $display("### RESULT tb_transition_ctrl : %0s  (%0d/%0d) ###",
                 (fail_cnt == 0) ? "PASS" : "FAIL", chk_idx - fail_cnt, chk_idx);
        $finish;
    end

    initial begin
        #2_000_000;
        $display("### RESULT tb_transition_ctrl : FAIL  (超时) ###");
        $finish;
    end

endmodule
