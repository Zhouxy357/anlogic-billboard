//============================================================================
// tb_color_bar.v  ——  720p 视频时序发生器（color_bar）的行为仿真
//---------------------------------------------------------------------------
// 这个模块是整个"黑屏"问题里最该先测的一个：
//   它决定了 HDMI 出不出画面 —— 只要 H/V 时序参数错一个，显示器就是"无信号"。
//
// 测什么：
//   ① 行周期 = H_TOTAL = 1650 拍；hs 高电平 = H_SYNC = 40 拍
//   ② 帧周期 = V_TOTAL × H_TOTAL = 750 × 1650 拍；vs 高电平 = 5 行
//   ③ 每行有效像素 de = 1280 拍；每帧 de 脉冲 = 720 个
//   ④ 帧率 = 75MHz / (1650×750) ≈ 60.6Hz（用 75MHz 像素时钟反推）
//   ⑤ 极性为正（空闲低、同步期高），HS_POL = VS_POL = 1
//   ⑥ 复位的有效性：复位期间 hs/vs/de 全 0
//   ⑦ 彩条像素映射：8 等分的颜色分界与 BMP 顺序一致
//   ⑧ 记录两处官方遗留写法（见文件末尾说明）
//
// 时钟说明：
//   本 tb 用 100MHz（周期 10ns）跑仿真，只为"数拍"方便；
//   模块内部全部按"拍"计数，与具体频率无关，所以结论对 75MHz 同样成立。
//   唯独帧率那一项，额外用 75MHz 反算了一次。
//
// 怎么跑（在 sim 目录下，用 Git Bash）：
//   ./run_iverilog.sh color        # 只跑这一个
//============================================================================
`timescale 1ns / 1ps

module tb_color_bar;

    //---------------------------------------------------------- 时钟与复位
    reg clk = 1'b0;
    always #5 clk = ~clk;                 // 100MHz，只看拍数

    reg rst = 1'b1;

    wire       hs, vs, de;
    wire [7:0] r, g, b;

    //---------------------------------------------------------- 被测模块
    color_bar dut (
        .clk   (clk),
        .rst   (rst),
        .hs    (hs),
        .vs    (vs),
        .de    (de),
        .rgb_r (r),
        .rgb_g (g),
        .rgb_b (b)
    );

    //---------------------------------------------------------- 检查框架
    integer chk_idx  = 0;
    integer fail_cnt = 0;

    task chk;
        input cond;
        // 【必须用 ASCII】中文不要通过这个参数传：
        // iverilog 把字符串打包进位向量时非 ASCII 字节高位会补成 0xff，日志变乱码。
        input [1023:0] name;
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

    //------------------------------------------------ 期望值
    // ★ 这里故意"写死"，不引用被测模块的参数：
    //   期望值必须是对规格的独立陈述，否则模块改错了、期望值跟着一起错，测试就白做了。
    localparam integer EXP_H_TOTAL  = 1650;      // 1280 + 110 + 40 + 220
    localparam integer EXP_V_TOTAL  = 750;       // 720 + 5 + 5 + 20
    localparam integer EXP_H_SYNC   = 40;
    localparam integer EXP_V_SYNC   = 5;
    localparam integer EXP_H_ACTIVE = 1280;
    localparam integer EXP_V_ACTIVE = 720;
    localparam integer PIX_CLK_HZ   = 75_000_000;   // 720p 的像素时钟

    // 被测模块里的实际值（层次引用只能在过程块里读，不能进 localparam）
    integer dut_h_total, dut_v_total, dut_h_sync, dut_v_sync;
    integer dut_h_active, dut_v_active;

    //=====================================================================
    // 测量逻辑：全部用"数拍"的方式，避开同一时钟沿同时跳变带来的采样歧义
    //
    // ★★ iverilog 的坑（写 tb 必须知道）★★
    //   同一个时钟沿触发的【多个】always 块，iverilog 的执行顺序会在不同拍之间来回交替，
    //   所以"在 A 块里 t=t+1、在 B 块里读 t"会读到重复值（实测 t = 0,2,2,4,4）。
    //   本 tb 把拍计数器 t 放进【同一个】测量块里自增，顺序才唯一确定。
    //=====================================================================
    integer t = 0;

    reg hs_d = 1'b0;
    reg vs_d = 1'b0;
    reg de_d = 1'b0;

    // --- 行：hs 周期 / hs 高电平宽度 ---
    integer hs_up_t      = 0;
    integer hs_period    = 0;      // 最近一次测到的 hs 周期
    integer hs_period_ok = 0;
    integer hs_period_bad= 0;
    integer hs_hi_cnt    = 0;
    integer hs_hi_val    = 0;      // 最近一次测到的 hs 高电平宽度
    integer hs_hi_ok     = 0;
    integer hs_hi_bad    = 0;
    integer hs_edges     = 0;

    // --- 帧：vs 周期 / vs 高电平宽度 ---
    integer vs_up_t      = 0;
    integer vs_period    = 0;
    integer vs_period_ok = 0;
    integer vs_period_bad= 0;
    integer vs_hi_cnt    = 0;
    integer vs_hi_val    = 0;
    integer vs_hi_ok     = 0;
    integer vs_hi_bad    = 0;
    integer vs_edges     = 0;

    // --- 有效区：每行 de 高电平拍数 / 每帧 de 脉冲个数 ---
    integer de_hi_cnt    = 0;
    integer de_hi_val    = 0;
    integer de_hi_ok     = 0;
    integer de_hi_bad    = 0;
    integer de_lines_cur = 0;      // 本帧已数到的 de 脉冲数
    integer de_lines_val = 0;      // 上一帧的 de 脉冲数
    integer de_lines_ok  = 0;
    integer de_lines_bad = 0;

    // --- 复位期间是否干净 ---
    integer rst_dirty = 0;         // 复位期间 hs/vs/de 出现 1 的次数

    // --- 彩条取样：de 高电平期间第 0/160/320... 个像素的颜色 ---
    integer de_pix = 0;            // 本行 de 内的像素序号
    reg [23:0] pix0,  pix160, pix320, pix480;
    reg [23:0] pix640, pix800, pix960, pix1120;
    integer sample_line = 0;       // 只在第 1 个有效行取样

    always @(posedge clk) begin
        t = t + 1;                       // ★ 就在这个块里自增（见上面的坑）

        hs_d <= hs;
        vs_d <= vs;
        de_d <= de;

        //-------------------------------------------------- 复位期监视
        if (rst && (hs || vs || de)) rst_dirty = rst_dirty + 1;

        //-------------------------------------------------- hs 上升沿
        if (hs && !hs_d) begin
            if (hs_edges > 0) begin
                hs_period = t - hs_up_t;
                if (hs_period == EXP_H_TOTAL) hs_period_ok = hs_period_ok + 1;
                else                          hs_period_bad = hs_period_bad + 1;
            end
            hs_up_t = t;
            hs_edges = hs_edges + 1;
        end

        //-------------------------------------------------- hs 高电平宽度
        if (hs) hs_hi_cnt = hs_hi_cnt + 1;
        else if (hs_hi_cnt > 0) begin
            hs_hi_val = hs_hi_cnt;
            if (hs_hi_val == EXP_H_SYNC) hs_hi_ok  = hs_hi_ok  + 1;
            else                         hs_hi_bad = hs_hi_bad + 1;
            hs_hi_cnt = 0;
        end

        //-------------------------------------------------- vs 上升沿
        if (vs && !vs_d) begin
            if (vs_edges > 0) begin
                vs_period = t - vs_up_t;
                if (vs_period == EXP_V_TOTAL * EXP_H_TOTAL) vs_period_ok  = vs_period_ok  + 1;
                else                                         vs_period_bad = vs_period_bad + 1;
                // 结算上一帧的"有效行数"
                de_lines_val = de_lines_cur;
                if (de_lines_val == EXP_V_ACTIVE) de_lines_ok  = de_lines_ok  + 1;
                else                              de_lines_bad = de_lines_bad + 1;
            end
            vs_up_t = t;
            vs_edges = vs_edges + 1;
            de_lines_cur = 0;
        end

        //-------------------------------------------------- vs 高电平宽度
        if (vs) vs_hi_cnt = vs_hi_cnt + 1;
        else if (vs_hi_cnt > 0) begin
            vs_hi_val = vs_hi_cnt;
            if (vs_hi_val == EXP_V_SYNC * EXP_H_TOTAL) vs_hi_ok  = vs_hi_ok  + 1;
            else                                        vs_hi_bad = vs_hi_bad + 1;
            vs_hi_cnt = 0;
        end

        //-------------------------------------------------- de 上升沿 = 一个有效行
        if (de && !de_d) de_lines_cur = de_lines_cur + 1;

        //-------------------------------------------------- de 高电平宽度
        if (de) begin
            de_hi_cnt = de_hi_cnt + 1;

            // 彩条取样：只在第一个有效行做
            if (sample_line == 0) begin
                if      (de_pix ==    0) pix0    = {r, g, b};
                else if (de_pix ==  160) pix160  = {r, g, b};
                else if (de_pix ==  320) pix320  = {r, g, b};
                else if (de_pix ==  480) pix480  = {r, g, b};
                else if (de_pix ==  640) pix640  = {r, g, b};
                else if (de_pix ==  800) pix800  = {r, g, b};
                else if (de_pix ==  960) pix960  = {r, g, b};
                else if (de_pix == 1120) pix1120 = {r, g, b};
            end
            de_pix = de_pix + 1;
        end
        else if (de_hi_cnt > 0) begin
            de_hi_val = de_hi_cnt;
            if (de_hi_val == EXP_H_ACTIVE) de_hi_ok  = de_hi_ok  + 1;
            else                           de_hi_bad = de_hi_bad + 1;
            de_hi_cnt  = 0;
            de_pix     = 0;
            sample_line = sample_line + 1;
        end

        //-------------------------------------------------- 复位期清零统计
        if (rst) begin
            hs_hi_cnt = 0; vs_hi_cnt = 0; de_hi_cnt = 0; de_pix = 0;
        end
    end

    //---------------------------------------------------------- 主流程
    initial begin
        $timeformat(-9, 0, " ns", 12);

        $display("");
        $display("[%0t] 复位期间：hs/vs/de 应全部为 0", $time);
        #1000;
        chk(rst_dirty === 0, "C01-rst-clean");

        rst = 1'b0;

        // 跑到第 3 个 vs 上升沿：这样能测到 vs 周期、且上一帧的有效行已结算完
        wait (vs_edges >= 3);
        #100;                                   // 留点余量让统计收尾

        $display("");
        $display("[%0t] 参数与周期核对", $time);
        dut_h_total  = dut.H_TOTAL;
        dut_v_total  = dut.V_TOTAL;
        dut_h_sync   = dut.H_SYNC;
        dut_v_sync   = dut.V_SYNC;
        dut_h_active = dut.H_ACTIVE;
        dut_v_active = dut.V_ACTIVE;
        $display("        H_TOTAL=%0d  V_TOTAL=%0d  H_SYNC=%0d  V_SYNC=%0d  H_ACTIVE=%0d  V_ACTIVE=%0d",
                 dut_h_total, dut_v_total, dut_h_sync, dut_v_sync, dut_h_active, dut_v_active);

        //--------------------------------------------- 参数本身（= 确认选对了分辨率）
        chk(dut_h_total  === 1650, "C02-H_TOTAL-1650");
        chk(dut_v_total  ===  750, "C03-V_TOTAL-750");
        chk(dut_h_active === 1280, "C04-H_ACTIVE-1280");
        chk(dut_v_active ===  720, "C05-V_ACTIVE-720");
        $display("        （期望 H_TOTAL=%0d V_TOTAL=%0d H_ACTIVE=%0d V_ACTIVE=%0d）",
                 EXP_H_TOTAL, EXP_V_TOTAL, EXP_H_ACTIVE, EXP_V_ACTIVE);

        //--------------------------------------------- 行时序
        chk(hs_period_bad === 0 && hs_period_ok >= 2, "C06-hs-period-1650");
        chk(hs_hi_bad     === 0 && hs_hi_ok     >= 2, "C07-hs-width-40");
        $display("        hs 周期测到 %0d 拍（期望 %0d），高电平 %0d 拍（期望 %0d）",
                 hs_period, EXP_H_TOTAL, hs_hi_val, EXP_H_SYNC);

        //--------------------------------------------- 帧时序
        chk(vs_period_bad === 0 && vs_period_ok >= 1, "C08-vs-period-750lines");
        chk(vs_hi_bad     === 0 && vs_hi_ok     >= 1, "C09-vs-width-5lines");
        $display("        vs 周期 = %0d 拍 = %0d 行（期望 %0d 行），高电平 = %0d 拍",
                 vs_period, vs_period / EXP_H_TOTAL, EXP_V_TOTAL, vs_hi_val);

        //--------------------------------------------- 有效区
        chk(de_hi_bad    === 0, "C10-de-width-1280");
        chk(de_lines_bad === 0, "C11-de-720-lines-per-frame");
        $display("        每行 de = %0d 拍（期望 %0d），每帧 de 脉冲 = %0d 个（期望 %0d）",
                 de_hi_val, EXP_H_ACTIVE, de_lines_val, EXP_V_ACTIVE);

        //--------------------------------------------- 帧率
        begin : frame_rate
            real fr;
            // 注意：Verilog 里整数/整数 会截断成整数，所以先乘 1.0 强制走实数运算，
            // 否则这里会打印出 60 而不是真实的 60.606。
            fr = 1.0 * PIX_CLK_HZ / (EXP_H_TOTAL * EXP_V_TOTAL);
            $display("        帧率 = 75MHz / (%0d x %0d) = %0.3f Hz", EXP_H_TOTAL, EXP_V_TOTAL, fr);
            chk(fr > 59.5 && fr < 60.8, "C12-frame-rate-60Hz");
        end

        //--------------------------------------------- 极性
        chk(dut.HS_POL === 1'b1 && dut.VS_POL === 1'b1, "C13-polarity-positive");
        // 源码里 vs 的置位写的是 HS_POL（官方原样），记录一下：只有两者相等才无害
        chk(dut.HS_POL === dut.VS_POL, "C14-hs-pol-vs-vs-pol");

        //--------------------------------------------- 彩条像素映射
        $display("");
        $display("[%0t] 彩条取样（de 内第 0/160/320/480/640/800/960/1120 个像素）", $time);
        $display("        %06h %06h %06h %06h %06h %06h %06h %06h",
                 pix0, pix160, pix320, pix480, pix640, pix800, pix960, pix1120);
        chk(pix0    === 24'hFFFFFF, "C15-bar0-white");
        chk(pix160  === 24'hFFFF00, "C16-bar1-yellow");
        chk(pix320  === 24'h00FFFF, "C17-bar2-cyan");
        chk(pix480  === 24'h00FF00, "C18-bar3-green");
        chk(pix640  === 24'hFF00FF, "C19-bar4-magenta");
        chk(pix800  === 24'hFF0000, "C20-bar5-red");
        chk(pix960  === 24'h0000FF, "C21-bar6-blue");
        chk(pix1120 === 24'h000000, "C22-bar7-black");

        //--------------------------------------------- 复位是否真的能清时序
        // 再复位一次，确认 hs/vs/de 被拉回 0
        rst = 1'b1;
        @(posedge clk); @(posedge clk); @(posedge clk); @(posedge clk);
        chk(hs === 1'b0 && vs === 1'b0 && de === 1'b0, "C23-rst-clears-outputs");
        rst = 1'b0;

        $display("");
        $display("==================================================");
        $display("[%0t] 仿真结束：通过 %0d 项，失败 %0d 项",
                 $time, chk_idx - fail_cnt, fail_cnt);
        $display("==================================================");
        $display("### RESULT tb_color_bar : %0s  (%0d/%0d) ###",
                 (fail_cnt == 0) ? "PASS" : "FAIL", chk_idx - fail_cnt, chk_idx);
        $finish;
    end

    // 保险：万一时序完全不动，别让仿真跑不完
    initial begin
        #80_000_000;                                     // 80ms 仿真时间上限
        $display("### RESULT tb_color_bar : FAIL  (超时，时序没有起来) ###");
        $finish;
    end

endmodule
