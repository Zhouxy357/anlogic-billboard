//============================================================================
// tb_video_timing_data.v  ——  视频时序输出级（video_timing_data）的行为仿真
//---------------------------------------------------------------------------
// 这个模块是"从 SDRAM 取画面的节拍器"：
//   每帧开始（vs 下降沿）向 frame_read_write 发一个 read_req，
//   等对方回 read_req_ack 之后收工；同时把 color_bar 的 hs/vs/de 往后推 2 拍再送出去。
//
// 关于相位（重要，读日志时对着看）：
//   设 cb.vs 在某拍开始变成 0，则
//     · DUT 内部的 video_vs_d0 此时仍为 1（滞后一拍）
//     · 条件 (video_vs_d0 & ~video_vs) 在同一拍成立
//     · read_req 从下一拍开始为高
//     · dut.vs 还要再晚一拍才变 0
//   所以：read_req 拉高时 dut.vs 仍是 1，随后 1 拍内 dut.vs 才落下。
//
// ★★ iverilog 的一个坑（写 tb 必须知道）★★
//   同一个时钟沿触发的【多个】always 块，iverilog 的执行顺序会在不同拍之间"来回交替"。
//   所以"在 A 块里 `t=t+1`、在 B 块里读 t"这种拍计数器会读到重复值（实测 t = 0,2,2,4,4）。
//   本 tb 的对策：**拍计数器和所有时间测量写在同一个 always 块里**，顺序才唯一确定。
//   （用 ModelSim 跑没这个问题，但两边结论要保持一致，就统一按这个规矩写。）
//
// 测什么：
//   ① 复位后 read_req = 0，hs/vs/de 全 0
//   ② hs/vs/de 相对内部 color_bar 正好延迟 2 拍
//   ③ 延迟不破坏时序：hs 周期仍 1650 拍、每行 de 仍 1280 拍
//   ④ 每帧恰好 1 个 read_req（多了会重读同一帧 / 撕裂）
//   ⑤ read_req 发出后一直保持，直到 ack 到来（慢 ack 也不丢）
//   ⑥ ack 之后 1 拍内 read_req 落下
//   ⑦ 没有新 vs 下降沿时，多余的 ack 不会重新触发
//   ⑧ 复位能把 read_req 强行清零
//
// 怎么跑（在 sim 目录下，用 Git Bash）：
//   ./run_iverilog.sh video_timing
//============================================================================
`timescale 1ns / 1ps

module tb_video_timing_data;

    //---------------------------------------------------------- 时钟与复位
    reg clk = 1'b0;
    always #5 clk = ~clk;                 // 100MHz，只看拍数

    reg rst = 1'b1;

    wire hs, vs, de;
    reg  read_req;
    reg  read_req_ack = 1'b0;

    //---------------------------------------------------------- 被测模块
    video_timing_data dut (
        .video_clk    (clk),
        .rst          (rst),
        .read_req     (read_req),
        .read_req_ack (read_req_ack),
        .hs           (hs),
        .vs           (vs),
        .de           (de)
    );

    //------------------------------ 参照物：同参数、同复位的裸 color_bar
    wire cb_hs, cb_vs, cb_de;
    color_bar cb_ref (
        .clk   (clk),
        .rst   (rst),
        .hs    (cb_hs),
        .vs    (cb_vs),
        .de    (cb_de),
        .rgb_r (),
        .rgb_g (),
        .rgb_b ()
    );

    //---------------------------------------------------------- 检查框架
    integer chk_idx  = 0;
    integer fail_cnt = 0;

    task chk;
        input cond;
        input [1023:0] name;      // 【必须 ASCII】中文经位向量参数会被 iverilog 烧成 0xff
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
    // 唯一的一个测量块：拍计数 + 全部统计都写在这里（顺序唯一确定）
    //=====================================================================
    integer t = 0;

    reg cb_hs_d1 = 0, cb_hs_d2 = 0;
    reg cb_vs_d1 = 0, cb_vs_d2 = 0;
    reg cb_de_d1 = 0, cb_de_d2 = 0;
    reg cmp_en   = 0;

    integer hs_mismatch = 0, vs_mismatch = 0, de_mismatch = 0, cmp_cycles = 0;

    reg     hs_p = 0, de_p = 0, cb_vs_p = 0, rq_p = 0;
    integer hs_edges = 0, de_edges = 0;
    integer hs_period_ok = 0, hs_period_bad = 0;
    integer de_hi_ok = 0, de_hi_bad = 0;
    integer hs_up_t = 0, hs_period = 0;
    integer de_hi_cnt = 0, de_hi_val = 0;
    integer rst_rq_dirty = 0;

    integer rq_rise_cnt = 0, rq_fall_cnt = 0;
    integer cb_vs_fall_t = -1, rq_rise_t = -1;

    always @(posedge clk) begin
        t = t + 1;                                // ★ 就在这个块里自增

        // ---- 延迟对齐比对 ----
        cb_hs_d1 <= cb_hs;  cb_hs_d2 <= cb_hs_d1;
        cb_vs_d1 <= cb_vs;  cb_vs_d2 <= cb_vs_d1;
        cb_de_d1 <= cb_de;  cb_de_d2 <= cb_de_d1;
        if (cmp_en) begin
            cmp_cycles = cmp_cycles + 1;
            if (cb_hs_d2 !== hs) hs_mismatch = hs_mismatch + 1;
            if (cb_vs_d2 !== vs) vs_mismatch = vs_mismatch + 1;
            if (cb_de_d2 !== de) de_mismatch = de_mismatch + 1;
        end

        // ---- 复位期异常监视 ----
        if (rst && read_req) rst_rq_dirty = rst_rq_dirty + 1;

        // ---- read_req 边沿计数 ----
        if (read_req && !rq_p) begin
            rq_rise_cnt = rq_rise_cnt + 1;
            if (rq_rise_t < 0) rq_rise_t = t;
        end
        if (!read_req && rq_p) rq_fall_cnt = rq_fall_cnt + 1;
        rq_p <= read_req;

        // ---- 参照 vs 落下时刻 ----
        if (!cb_vs && cb_vs_p && cb_vs_fall_t < 0) cb_vs_fall_t = t;
        cb_vs_p <= cb_vs;

        // ---- hs 周期（按拍数）----
        if (hs && !hs_p) begin
            hs_edges = hs_edges + 1;
            if (hs_edges > 1) begin
                hs_period = t - hs_up_t;
                if (hs_period == 1650) hs_period_ok  = hs_period_ok  + 1;
                else                   hs_period_bad = hs_period_bad + 1;
            end
            hs_up_t = t;
        end
        hs_p <= hs;

        // ---- 每行 de 宽度 ----
        if (de) de_hi_cnt = de_hi_cnt + 1;
        else if (de_hi_cnt > 0) begin
            de_hi_val = de_hi_cnt;
            if (de_hi_val == 1280) de_hi_ok  = de_hi_ok  + 1;
            else                   de_hi_bad = de_hi_bad + 1;
            de_hi_cnt = 0;
        end
        if (de && !de_p) de_edges = de_edges + 1;
        de_p <= de;
    end

    //=====================================================================
    // read_req_ack 的驱动：故意做成"慢 ack"
    //   ★ 用【电平】判断，不做边沿检测，避免跨块读写 rq_p 的竞争
    //   ★ read_req_ack 只在这一个块里被赋值，保证单一驱动源
    //=====================================================================
    integer ack_latency = 200;     // ack 故意等 200 拍才回
    integer st = 0;                // 0=空闲 1=等 ack 2=刚发完 ack
    integer wait_cnt = 0;
    reg     force_ack = 1'b0;      // 由 initial 置起，让 FSM 额外打一个 ack

    always @(posedge clk) begin
        read_req_ack <= 1'b0;              // 默认低，只在需要时拉 1 拍
        case (st)
            0: begin
                   if (read_req) begin
                       wait_cnt = ack_latency;
                       st = 1;
                   end else if (force_ack) begin
                       read_req_ack <= 1'b1;   // 人为打一个多余的 ack
                       force_ack    <= 1'b0;
                       st = 2;
                   end
               end
            1: begin
                   if (wait_cnt > 0) wait_cnt = wait_cnt - 1;
                   else begin
                       read_req_ack <= 1'b1;   // 单拍 ack
                       st = 2;
                   end
               end
            2: st = 0;
            default: st = 0;
        endcase
    end

    //=====================================================================
    // 主流程
    //=====================================================================
    integer rise_snapshot = 0;

    initial begin
        $timeformat(-9, 0, " ns", 12);

        //--------------------------------------------- 复位期间
        #1000;
        $display("");
        $display("[%0t] 复位期间：read_req 应为 0", $time);
        $display("        dut 输出: read_req=%b hs=%b vs=%b de=%b", read_req, hs, vs, de);
        $display("        dut 内部: video_hs_d0=%b video_vs_d0=%b video_de_d0=%b",
                 dut.video_hs_d0, dut.video_vs_d0, dut.video_de_d0);
        $display("        ★ 官方代码只复位了 d0 级，没有复位输出级 video_*_d1，");
        $display("          所以复位期间【输出】是 x（或冻结在上一次的值），这是官方行为，不是 bug。");
        $display("          真正要保证的是：复位一释放，输出必须回到确定的 0。");
        chk(read_req === 1'b0, "C01-rst-read_req-low");
        chk(dut.video_hs_d0 === 1'b0 && dut.video_vs_d0 === 1'b0 && dut.video_de_d0 === 1'b0,
            "C02-rst-clears-internal-d0");
        chk(rst_rq_dirty === 0, "C03-rst-no-stray-req");

        rst = 1'b0;
        repeat (10) @(posedge clk);       // 等内部流水对齐
        chk(hs === 1'b0 && vs === 1'b0 && de === 1'b0, "C02b-outputs-zero-after-rst-release");
        cmp_en = 1'b1;

        //--------------------------------------------- 等第一个 read_req
        $display("");
        $display("[%0t] 等第一帧的 read_req ...", $time);
        wait (rq_rise_cnt >= 1);

        chk(read_req === 1'b1, "C04-read_req-asserted");

        // 相位：read_req 应在 cb.vs 落下后 1 拍拉高
        $display("        cb.vs 在 t=%0d 落下，read_req 在 t=%0d 拉高（差 %0d 拍）",
                 cb_vs_fall_t, rq_rise_t, rq_rise_t - cb_vs_fall_t);
        chk((rq_rise_t - cb_vs_fall_t) >= 1 && (rq_rise_t - cb_vs_fall_t) <= 2,
            "C05-req-1cyc-after-vs-fall");

        //--------------------------------------------- 慢 ack：read_req 必须保持
        repeat (150) @(posedge clk);
        $display("        慢 ack（等 %0d 拍）期间：read_req=%b（应为 1）", ack_latency, read_req);
        chk(read_req === 1'b1, "C06-read_req-holds-until-ack");

        wait (read_req === 1'b0);
        repeat (2) @(posedge clk);
        $display("        ack 之后 read_req 落下：下降沿次数 = %0d", rq_fall_cnt);
        chk(read_req === 1'b0, "C07-read_req-cleared-by-ack");

        //--------------------------------------------- 多余的 ack 不应重新触发
        rise_snapshot = rq_rise_cnt;
        force_ack = 1'b1;
        repeat (30) @(posedge clk);
        $display("        人为多发 1 个 ack 后：read_req 上升沿次数 %0d -> %0d（应不变）",
                 rise_snapshot, rq_rise_cnt);
        chk(rq_rise_cnt === rise_snapshot, "C08-spurious-ack-no-retrigger");

        //--------------------------------------------- 每帧恰好 1 个 read_req
        wait (rq_rise_cnt >= 2);
        $display("");
        $display("[%0t] 已收到第 2 个 read_req，检查「每帧一个」", $time);
        chk(rq_rise_cnt === 2, "C09-one-req-per-frame");

        //--------------------------------------------- 延迟对齐结果
        $display("");
        $display("[%0t] 延迟对齐与时序完整性", $time);
        $display("        比对 %0d 拍：hs 失配 %0d 次，vs 失配 %0d 次，de 失配 %0d 次",
                 cmp_cycles, hs_mismatch, vs_mismatch, de_mismatch);
        chk(hs_mismatch === 0, "C10-hs-delay-exactly-2");
        chk(vs_mismatch === 0, "C11-vs-delay-exactly-2");
        chk(de_mismatch === 0, "C12-de-delay-exactly-2");

        chk(hs_period_bad === 0 && hs_period_ok >= 2, "C13-hs-period-1650-after-delay");
        chk(de_hi_bad     === 0, "C14-de-width-1280-after-delay");
        $display("        延迟后：hs 周期 = %0d 拍（期望 1650），每行 de = %0d 拍（期望 1280）",
                 hs_period, de_hi_val);
        chk(de_hi_val === 1280, "C15-de-1280-after-delay");

        //--------------------------------------------- 复位再验证
        rst = 1'b1;
        repeat (5) @(posedge clk);
        $display("");
        $display("        复位中：read_req=%b hs=%b vs=%b de=%b", read_req, hs, vs, de);
        chk(read_req === 1'b0, "C16-rst-clears-read_req");
        // 复位期间输出允许冻结（官方没复位输出级），但 read_req 必须干净
        repeat (3) @(posedge clk);
        rst = 1'b0;
        repeat (5) @(posedge clk);
        $display("        复位释放后：hs=%b vs=%b de=%b", hs, vs, de);
        chk(hs === 1'b0 && vs === 1'b0 && de === 1'b0, "C17-outputs-zero-after-rst-release");

        $display("");
        $display("==================================================");
        $display("[%0t] 仿真结束：通过 %0d 项，失败 %0d 项",
                 $time, chk_idx - fail_cnt, fail_cnt);
        $display("==================================================");
        $display("### RESULT tb_video_timing_data : %0s  (%0d/%0d) ###",
                 (fail_cnt == 0) ? "PASS" : "FAIL", chk_idx - fail_cnt, chk_idx);
        $finish;
    end

    // 保险：超时
    initial begin
        #250_000_000;
        $display("### RESULT tb_video_timing_data : FAIL  (超时，read_req 没来) ###");
        $finish;
    end

endmodule
