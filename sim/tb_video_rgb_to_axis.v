//============================================================================
// tb_video_rgb_to_axis_640x480.v  ——  RGB 像素 -> AXI-Stream 转换的行为仿真
//---------------------------------------------------------------------------
// 模块作用：把 video_delay 的图像（I_rgb + I_de + I_vs）转成 HDMI 发射核要的
//           AXI-Stream 形式（user / valid / last / data）。
//
// 本 tb 要证明两件事：
//   (A) 正常路径都对：valid / data 分别与 de / rgb 对齐（各延迟 1 拍），
//       每帧恰好 1 个 user（帧起始），像素顺序不乱、不丢。
//   (B) 【记录在案的官方遗留问题】O_video_last 永远为 0。
//       不是因为没测到，而是可以证明：
//         de 每行只有 1280 拍，而 S_x_cnt 的取值比"真实像素号"滞后 1 拍，
//         所以一行里 S_x_cnt 最大只到 1278，判断条件 `== 1279` 永远不成立。
//       本 tb 直接把每行最后一个 de 拍时的 S_x_cnt 读出来断言它 == 1278，
//       把"它确实差 1"这件事钉死。官方原文写的是 639（640 宽），同样差 1。
//
// 为什么暂时不改：
//   官方另一个视频源 video_source_test.v 是"每行产一次 last"，
//   而本工程这块 HDMI 核在 last 恒 0 时是否正常，没有板子无法判定；
//   贸然把 1279 改成 1278 有打乱核内行计数的风险。
//   若上板后"配置正常、其它都对但 HDMI 无输出"，这里（改成 11'd1278）是第一个该试的地方。
//
// 怎么跑（在 sim 目录下，用 Git Bash）：
//   ./run_iverilog.sh rgb_to_axis
//============================================================================
`timescale 1ns / 1ps

module tb_video_rgb_to_axis_640x480;

    //---------------------------------------------------------- 时钟与复位
    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg rst = 1'b1;
    reg run = 1'b0;                       // 0 = 停在消隐位置，便于流水排空

    //---------------------------------------------------------- 假图像时序
    // 每行 1280 个有效像素（和真实 720p 一样宽，这样 S_x_cnt 才能跑到头）
    localparam integer LINE_PIX  = 1280;
    localparam integer LINE_BLK  = 8;     // 行消隐
    localparam integer NLINE     = 2;     // 每帧 2 行，够验证"每帧一个 user"
    localparam integer FRAME_BLK = 16;    // 帧消隐
    localparam integer LINE_CYC  = LINE_PIX + LINE_BLK;
    localparam integer FRAME_CYC = LINE_CYC * NLINE + FRAME_BLK;
    localparam integer IDLE_CYC  = 0;      // 冻结在帧首；此时 st_de 被 run 压掉

    integer cyc = 0;
    always @(posedge clk)
        if (rst)       cyc <= 0;
        else if (!run) cyc <= IDLE_CYC;
        else           cyc <= (cyc == FRAME_CYC - 1) ? 0 : cyc + 1;

    wire [31:0] col = cyc % LINE_CYC;
    wire [31:0] lin = cyc / LINE_CYC;

    // ★ 注意 (lin < NLINE)：帧尾那段填充不能算作有效行，
    //   否则 col 会绕回 0，把帧尾消隐和下一帧的行首连成一大块 de
    //   （踩过这个坑：de 变成 1296 拍，S_x_cnt 反而能到 1279，last 就"意外"出现了）。
    wire st_de = run && (lin < NLINE) && (col < LINE_PIX);
    wire st_vs = run && (cyc == FRAME_CYC - 1);


    // 像素内容 = 全局像素序号（低 12 位），这样能看出错位/重排
    wire [23:0] st_rgb = (lin * LINE_PIX + col) & 24'h000FFF;

    //---------------------------------------------------------- 被测模块
    wire        o_user, o_valid, o_last;
    wire [23:0] o_data;

    video_rgb_to_axis_640x480 dut (
        .I_clk        (clk),
        .I_rst        (rst),
        .I_vs         (st_vs),
        .I_de         (st_de),
        .I_rgb        (st_rgb),
        .O_video_user (o_user),
        .O_video_valid(o_valid),
        .O_video_last (o_last),
        .O_video_data (o_data)
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
    // 测量块（单一 always，避免 iverilog 多块顺序交替）
    //=====================================================================
    integer t = 0;
    reg mon_en = 1'b0;

    reg de_1 = 0;
    reg [23:0] rgb_1 = 0;
    integer valid_bad = 0, data_bad = 0, cmp = 0;

    integer de_cycles = 0, valid_cycles = 0;
    integer user_pulses = 0, user_bad = 0, user_ok = 0;
    integer valid_rise = 0, valid_fall = 0;
    integer last_pulses = 0;
    integer vs_edges = 0;
    reg     vs_p = 0, user_p = 0, valid_p = 0;

    // S_x_cnt 诊断：每行最后一个 de 拍的值
    // ★ 取样时机很关键：S_x_cnt 是寄存器，在"最后一个 de 拍"那一拍它的值才是最终值；
    //   等 de 落下后再读，已经被清零了。所以这里改成【取一行内的最大值】。
    integer xcnt_max = 0, xcnt_rpt = 0, xcnt_ok = 0, xcnt_bad = 0;
    integer line_pix = 0, line_pix_rpt = 0, line_pix_bad = 0;

    // 一帧内像素顺序：valid 期间的 data 必须逐 1 递增
    integer order_bad = 0;
    reg [23:0] prev_data = 0;
    reg        prev_valid = 0;

    always @(posedge clk) begin
        t = t + 1;

        // ---- 影子寄存器（无论是否计数都更新；非阻塞，读到的仍是上一拍的值）----
        de_1  <= st_de;
        rgb_1 <= st_rgb;
        user_p  <= o_user;
        valid_p <= o_valid;
        vs_p    <= st_vs;

        if (mon_en) begin
            cmp = cmp + 1;
            if (o_valid !== de_1)  valid_bad = valid_bad + 1;
            if (o_data  !== rgb_1) data_bad  = data_bad  + 1;

            if (st_de)   de_cycles    = de_cycles    + 1;
            if (o_valid) valid_cycles = valid_cycles + 1;

            // 像素顺序：同一个 de 块内，连续两个 valid 拍 data 必须 +1
            //（块首那一拍要跳过：跨行时 lin 变了，数据本来就会跳）
            if (st_de && !de_1) begin
                prev_valid = 1'b0;             // 强制当作块首，不做 +1 比对
            end
            if (o_valid && prev_valid) begin
                if (o_data !== ((prev_data + 24'd1) & 24'h000FFF)) order_bad = order_bad + 1;
            end
            prev_data  = o_data;
            prev_valid = o_valid;

            // ---- user ----
            if (o_user && !user_p) begin
                user_pulses = user_pulses + 1;
                if (o_valid === 1'b1 && valid_p === 1'b0) user_ok = user_ok + 1;
                else                                      user_bad = user_bad + 1;
            end

            // ---- valid 边沿 / last / vs ----
            if (o_valid && !valid_p) valid_rise = valid_rise + 1;
            if (!o_valid && valid_p) valid_fall = valid_fall + 1;
            if (o_last) last_pulses = last_pulses + 1;

            if (st_vs && !vs_p) vs_edges = vs_edges + 1;

            // ---- S_x_cnt / 行像素数诊断 ----
            if (st_de && !de_1) begin          // 行首
                xcnt_max = 0;
                line_pix = 0;
            end
            if (st_de) begin
                line_pix = line_pix + 1;
                if (dut.S_x_cnt > xcnt_max) xcnt_max = dut.S_x_cnt;
            end
            if (!st_de && de_1) begin          // 行尾结算
                xcnt_rpt     = xcnt_max;
                line_pix_rpt = line_pix;
                if (xcnt_max === 1278) xcnt_ok  = xcnt_ok  + 1;
                else                   xcnt_bad = xcnt_bad + 1;
                if (line_pix !== 1280) line_pix_bad = line_pix_bad + 1;
            end
        end
    end

    //=====================================================================
    // 主流程
    //=====================================================================
    initial begin
        $timeformat(-9, 0, " ns", 12);

        //--------------------------------------------- 复位
        #1000;
        $display("");
        $display("[%0t] 复位期间：user / valid / last / data 都应为 0", $time);
        $display("        user=%b valid=%b last=%b data=%06h",
                 o_user, o_valid, o_last, o_data);
        chk(o_user === 1'b0 && o_valid === 1'b0 && o_last === 1'b0, "C01-rst-outputs-low");
        chk(o_data === 24'h000000, "C02-rst-data-zero");

        rst = 1'b0;
        repeat (10) @(posedge clk);
        mon_en = 1'b1;
        run    = 1'b1;

        //--------------------------------------------- 跑 3 帧
        repeat (3 * FRAME_CYC) @(posedge clk);
        run = 1'b0;
        repeat (20) @(posedge clk);

        $display("");
        $display("[%0t] 正常路径（比对 %0d 拍）", $time, cmp);
        $display("        valid 失配 %0d 次（应为 de 延迟 1 拍），data 失配 %0d 次",
                 valid_bad, data_bad);
        chk(valid_bad === 0, "C03-valid-equals-de-delayed-1");
        chk(data_bad  === 0, "C04-data-equals-rgb-delayed-1");

        $display("        输入 de 高电平 %0d 拍，valid 高电平 %0d 拍",
                 de_cycles, valid_cycles);
        chk(de_cycles === valid_cycles, "C05-no-valid-lost");
        chk(order_bad === 0, "C06-pixel-order-preserved");

        $display("");
        $display("        帧起始 user：脉冲 %0d 个，其中对齐到 valid 首拍 %0d 个，异常 %0d 个",
                 user_pulses, user_ok, user_bad);
        chk(user_bad === 0, "C07-user-aligned-to-first-valid");
        chk(user_pulses === 3, "C08-one-user-per-frame");
        chk(vs_edges === 3 && valid_rise === 6 && valid_fall === 6,
            "C09-three-frames-two-lines-each");
        $display("        vs 跳变 %0d 次，valid 上升沿 %0d 次，下降沿 %0d 次",
                 vs_edges, valid_rise, valid_fall);

        $display("");
        $display("[%0t] ★ 官方遗留问题：O_video_last 恒为 0", $time);
        $display("        整个仿真里 last 脉冲数 = %0d", last_pulses);
        chk(last_pulses === 0, "C10-last-never-asserts-official-behaviour");

        $display("        每行有效像素 %0d 个（异常行 %0d），行内 S_x_cnt 最大值 = %0d（%0d 行命中 1278，%0d 行没命中）",
                 line_pix_rpt, line_pix_bad, xcnt_rpt, xcnt_ok, xcnt_bad);
        chk(line_pix_bad === 0, "C11-each-line-1280-pixels");
        chk(xcnt_bad === 0 && xcnt_ok > 0, "C12-xcnt-max-is-1278-not-1279");
        $display("        即：一行只有 1280 拍，S_x_cnt 最大到 1278，");
        $display("            所以判断条件 `S_x_cnt == 1279` 永远不成立。");
        $display("            把阈值改成 11'd1278 就会每行产一次 last（备选改法）。");

        //--------------------------------------------- 复位再验证
        mon_en = 1'b0;
        rst = 1'b1;
        repeat (5) @(posedge clk);
        chk(o_user === 1'b0 && o_valid === 1'b0 && o_last === 1'b0, "C13-rst-clears-outputs");
        rst = 1'b0;
        repeat (3) @(posedge clk);
        // 注意：O_video_data 是无条件把 I_rgb 打一拍送出的（消隐区也送），
        // 这是官方写法；因为 O_video_valid = 0，下游不会取用，所以无害。
        // 这里只检查下游真正看重的 valid。
        $display("        复位释放后：valid=%b（应为 0），data=%06h（消隐区跟随 I_rgb，属正常）",
                 o_valid, o_data);
        chk(o_valid === 1'b0, "C14-valid-low-after-rst-release");

        $display("");
        $display("==================================================");
        $display("[%0t] 仿真结束：通过 %0d 项，失败 %0d 项",
                 $time, chk_idx - fail_cnt, fail_cnt);
        $display("==================================================");
        $display("### RESULT tb_video_rgb_to_axis : %0s  (%0d/%0d) ###",
                 (fail_cnt == 0) ? "PASS" : "FAIL", chk_idx - fail_cnt, chk_idx);
        $finish;
    end

    initial begin
        #5_000_000;
        $display("### RESULT tb_video_rgb_to_axis : FAIL  (超时) ###");
        $finish;
    end

endmodule
