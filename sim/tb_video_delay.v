//============================================================================
// tb_video_delay.v  ——  视频数据/同步对齐模块（video_delay）的行为仿真
//---------------------------------------------------------------------------
// 这个模块负责把"SDRAM 里取出来的像素"和"同步信号"对齐：
//   · hs/vs/de 往后串 21 拍，从 hs_r/vs_r/de_r 输出
//   · read_en 是 de 往后串 19 拍 —— 比 de_r 早 2 拍发起，给取数留提前量
//   · 源端在 read_en 之后 1 拍把数据放上 read_data，模块在 de_d[19] 时把它
//     锁进 vout_data，于是 vout_data 正好和 de_r 对齐
//
// 为什么这个模块值得单独测：
//   如果这里的对齐差 1 拍，画面上就是"整幅图左右错一列"或者最左边一列是黑的，
//   上板看起来像"花屏"，但板子其实是好的，非常难查。
//
// 测什么：
//   ① 复位后 read_en = 0、hs_r/vs_r/de_r = 0、vout_data = 0
//   ② read_en 恰好 = de 延迟 19 拍
//   ③ hs_r / vs_r / de_r 恰好 = hs / vs / de 延迟 21 拍
//   ④ read_en 比 de_r 早 2 拍（提前量保持）
//   ⑤ 像素对齐：de_r 第 k 个有效像素处，vout_data 必须是第 k 个像素（0 失配）
//   ⑥ 不丢像素：de_r 的高电平拍数 = 输入的 de 高电平拍数
//   ⑦ de_r = 0 期间 vout_data 必须为 0（否则消隐区会有残影）
//
// 测量约定（两个坑都要避开）：
//   · iverilog 里同一时钟沿触发的多个 always 块执行顺序会交替，所以拍计数器和
//     所有测量写在同一个 always 块里。
//   · 计数一律从"复位释放之后"开始（mon_en），否则会拿上电瞬间的 x 当错误。
//
// 怎么跑（在 sim 目录下，用 Git Bash）：
//   ./run_iverilog.sh video_delay
//============================================================================
`timescale 1ns / 1ps

module tb_video_delay;

    //---------------------------------------------------------- 时钟与复位
    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg rst = 1'b1;
    reg run = 1'b0;          // 1 = 假视频时序在跑；0 = 停在消隐位置（便于流水排空）

    //---------------------------------------------------------- 假视频时序
    // 故意做得很小（每行 6 个有效像素、共 3 行），只为快速跑完多帧
    localparam integer LINE_CYC  = 10;     // 每行 10 拍
    localparam integer DE_BEG    = 2;      // 第 2 拍开始有效
    localparam integer DE_LEN    = 6;      // 有效 6 拍
    localparam integer NLINE     = 3;      // 每帧 3 行
    localparam integer BLANK     = 4;      // 帧尾空 4 拍
    localparam integer FRAME_CYC = LINE_CYC * NLINE + BLANK;
    localparam integer IDLE_CYC  = 8;      // 冻结位置：col=8，de/hs/vs 全 0

    integer cyc = 0;
    always @(posedge clk)
        if (rst)      cyc <= 0;
        else if (!run) cyc <= IDLE_CYC;
        else          cyc <= (cyc == FRAME_CYC - 1) ? 0 : cyc + 1;

    wire [31:0] col = cyc % LINE_CYC;
    wire [31:0] lin = cyc / LINE_CYC;

    wire st_hs = (col == 0);
    wire st_vs = (lin == 0) && (col == 0);
    wire st_de = (col >= DE_BEG) && (col < DE_BEG + DE_LEN);

    //---------------------------------------------------------- 被测模块
    wire        read_en;
    reg  [23:0] read_data = 24'h000000;
    wire        hs_r, vs_r, de_r;
    wire [23:0] vout_data;

    video_delay #(.DATA_WIDTH(24)) dut (
        .video_clk (clk),
        .rst       (rst),
        .read_en   (read_en),
        .read_data (read_data),
        .hs        (st_hs),
        .vs        (st_vs),
        .de        (st_de),
        .hs_r      (hs_r),
        .vs_r      (vs_r),
        .de_r      (de_r),
        .vout_data (vout_data)
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

    //=====================================================================
    // 假数据源：按"read_en 之后 1 拍给数据"的契约供数
    //   数据内容 = 该次请求的像素编号（0,1,2,...），这样能直接看出错位
    //=====================================================================
    integer req_cnt = 0;
    always @(posedge clk) begin
        if (rst) begin
            req_cnt   <= 0;
            read_data <= 24'h000000;
        end else if (read_en) begin
            read_data <= req_cnt[23:0];       // 下一拍数据有效 = 本次请求的编号
            req_cnt   <= req_cnt + 1;
        end
    end

    //=====================================================================
    // 测量块（全部写在一个 always 里）
    //=====================================================================
    integer t = 0;
    reg     mon_en = 1'b0;       // 复位释放后才开始计数

    reg [20:0] hsr = 0, vsr = 0, der = 0;
    integer en_bad = 0, hs_bad = 0, vs_bad = 0, de_bad = 0, en_cmp = 0;

    integer de_r_idx = 0;
    integer pix_bad = 0, pix_cmp = 0, blank_bad = 0, blank_dbg = 0;
    integer inp_de_cycles = 0;

    integer lead_ok = 0, lead_bad = 0;
    reg     en_p = 0;

    always @(posedge clk) begin
        t = t + 1;

        // ---- 移位链（独立实现的期望值：hs/vs/de 延迟 21，de 延迟 19）----
        hsr <= {hsr[19:0], st_hs};
        vsr <= {vsr[19:0], st_vs};
        der <= {der[19:0], st_de};

        if (mon_en) begin
            en_cmp = en_cmp + 1;
            if (hsr[20] !== hs_r) hs_bad = hs_bad + 1;
            if (vsr[20] !== vs_r) vs_bad = vs_bad + 1;
            if (der[20] !== de_r) de_bad = de_bad + 1;
            if (der[18] !== read_en) en_bad = en_bad + 1;

            if (st_de) inp_de_cycles = inp_de_cycles + 1;

            // 像素对齐：de_r 高时，vout_data 必须是第 de_r_idx 个像素
            if (de_r) begin
                pix_cmp = pix_cmp + 1;
                if (vout_data !== de_r_idx[23:0]) pix_bad = pix_bad + 1;
                de_r_idx = de_r_idx + 1;
            end else if (vout_data !== 24'h000000) begin
                blank_bad = blank_bad + 1;
                if (blank_dbg < 6) begin
                    blank_dbg = blank_dbg + 1;
                    $display("        [消隐区有数据] t=%0d de_r=%b vout_data=%06h de_d19=%b read_data=%06h",
                             t, de_r, vout_data, dut.de_d[19], read_data);
                end
            end

            // read_en 必须在 de_r 之前发起
            if (read_en && !en_p) begin
                if (de_r === 1'b0) lead_ok = lead_ok + 1;
                else               lead_bad = lead_bad + 1;
            end
        end
        en_p <= read_en;
    end

    //=====================================================================
    // 主流程
    //=====================================================================
    integer pix_snapshot = 0;

    initial begin
        $timeformat(-9, 0, " ns", 12);

        //--------------------------------------------- 复位期间
        #1000;
        $display("");
        $display("[%0t] 复位期间：read_en / hs_r / vs_r / de_r / vout_data 都应为 0", $time);
        $display("        read_en=%b hs_r=%b vs_r=%b de_r=%b vout_data=%06h",
                 read_en, hs_r, vs_r, de_r, vout_data);
        chk(read_en === 1'b0, "C01-rst-read_en-low");
        chk(hs_r === 1'b0 && vs_r === 1'b0 && de_r === 1'b0, "C02-rst-sync-low");
        chk(vout_data === 24'h000000, "C03-rst-data-zero");

        rst = 1'b0;
        repeat (25) @(posedge clk);        // 等复位后的流水稳定
        mon_en = 1'b1;                     // ★ 从这里开始才计数
        run    = 1'b1;                     // 开始放视频时序

        //--------------------------------------------- 跑 5 帧
        repeat (5 * FRAME_CYC) @(posedge clk);
        run = 1'b0;                        // 停下激励，让 21 级流水排空
        repeat (40) @(posedge clk);

        $display("");
        $display("[%0t] 延迟与对齐结果（比对 %0d 拍）", $time, en_cmp);
        $display("        hs_r 失配 %0d 次，vs_r 失配 %0d 次，de_r 失配 %0d 次，read_en 失配 %0d 次",
                 hs_bad, vs_bad, de_bad, en_bad);
        chk(hs_bad === 0, "C04-hs_r-delay-21");
        chk(vs_bad === 0, "C05-vs_r-delay-21");
        chk(de_bad === 0, "C06-de_r-delay-21");
        chk(en_bad === 0, "C07-read_en-delay-19");

        $display("");
        $display("        像素对齐：比对 %0d 个像素，错位 %0d 个", pix_cmp, pix_bad);
        chk(pix_bad === 0, "C08-pixel-data-aligned-with-de_r");
        chk(pix_cmp > 50,  "C09-enough-pixels-compared");
        chk(blank_bad === 0, "C10-blank-region-is-zero");
        $display("        输入 de 高电平 %0d 拍，de_r 高电平 %0d 拍（消隐区异常 %0d 次）",
                 inp_de_cycles, de_r_idx, blank_bad);
        chk(de_r_idx === inp_de_cycles, "C11-no-pixel-lost");

        $display("");
        $display("        read_en 提前量：%0d 次在 de_r 之前（de_r 期间发起 %0d 次）",
                 lead_ok, lead_bad);
        chk(lead_bad === 0 && lead_ok > 0, "C12-read_en-two-cycles-ahead");

        //--------------------------------------------- 复位再验证
        mon_en = 1'b0;
        rst = 1'b1;
        repeat (5) @(posedge clk);
        chk(read_en === 1'b0 && de_r === 1'b0, "C13-rst-clears-outputs");
        rst = 1'b0;
        repeat (3) @(posedge clk);
        chk(vout_data === 24'h000000, "C14-data-zero-after-rst-release");

        $display("");
        $display("==================================================");
        $display("[%0t] 仿真结束：通过 %0d 项，失败 %0d 项",
                 $time, chk_idx - fail_cnt, fail_cnt);
        $display("==================================================");
        $display("### RESULT tb_video_delay : %0s  (%0d/%0d) ###",
                 (fail_cnt == 0) ? "PASS" : "FAIL", chk_idx - fail_cnt, chk_idx);
        $finish;
    end

    initial begin
        #2_000_000;
        $display("### RESULT tb_video_delay : FAIL  (超时) ###");
        $finish;
    end

endmodule
