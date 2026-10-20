//============================================================================
// tb_osd_mixer.v  ——  视频混合 + 字幕叠加（osd_mixer）的行为仿真
//---------------------------------------------------------------------------
// 模块做两件事：
//   ① 亮度乘算：raw -> raw * blend >> 8（blend 0..256，256 = 全亮）
//   ② 字幕叠加：屏幕最下面 OSD_H 行叠一条字幕带，内容取自 banner_rom
//
// 本 tb 用两个实例：
//   dut1 —— 真实参数（1280x720, OSD_H=32）测坐标 / 输出延迟 / 亮度 / 字幕带
//           （每行只给 8 个像素，这样很快就能数到第 688 行，不必跑满 1650x750）
//   dut2 —— 缩小参数（SCREEN_H=64, OSD_H=32）测字幕内容
//           一行给足 2048 个像素，把 64 个 32bit 字全走一遍
//
// ★★★ 时序对齐铁律（写错了必然满屏 FAIL，所以写清楚）★★★
//   1) osd_mixer 是【1 级流水】：第 n 拍的输出 = 由第 n-1 拍的输入算出来的。
//      所以"拿本拍输入算出的预测值"必须打到下一拍，再和 o_rgb 比。
//      本 tb 统一用 p1/p1_d（dut1）和 p2/p2_d（dut2）做这件事。
//      —— 绝对不要写 chk(o1_rgb === f(当前输入)) 这种比法，那是拿第 n 拍输出
//         去比第 n 拍输入，天生差 1 拍。
//   2) 监视器的行/列计数器必须和 DUT 内部 x_cnt/y_cnt 【严格同一步调】。
//      做法：两边用同一套规则（de 时列+1、一行结束行+1、vs 时行清零、复位时双清），
//      并且【绝不在主流程里直接给监视器的 x/y 赋值】—— 一赋值两边就永久错位了。
//      需要让两边同时归零时，走 rst（DUT 和监视器一起被清零），而不是手改监视器。
//   3) 改 blend / osd_on / osd_ofs 这类控制量之后，先空跑几拍让流水线排空，
//      再清零统计计数器开始算 —— 否则会统计到"旧控制量"那一拍的残值。
//
// ★ 最关键的一条：字幕取位是 rom_word[31 - bit_sel]（左右不镜像）。
//   本 tb 直接把 banner_rom 的真实内容（层次引用读 mem）算进预测值，
//   所以位序搞反、行地址算错、地址位拼接错，都会被抓住。
//
// 怎么跑（在 sim 目录下，用 Git Bash）：
//   ./run_iverilog.sh osd
//============================================================================
`timescale 1ns / 1ps

module tb_osd_mixer;

    //---------------------------------------------------------- 时钟与复位
    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg rst = 1'b1;
    reg run = 1'b0;

    //---------------------------------------------------------- 视频激励
    integer line_pix = 8;                   // 每行有效像素（A 阶段 8，B 阶段 2048）
    localparam integer LINE_BLK = 4;        // 行消隐
    localparam integer NLINE    = 730;      // 单帧行数（够覆盖 688..719 字幕带）

    integer col_c = 0;
    integer lin_c = 0;

    always @(posedge clk) begin
        if (rst) begin
            col_c <= 0;
            lin_c <= 0;
        end else if (!run) begin
            col_c <= line_pix;              // 停在消隐位置
            lin_c <= 0;
        end else if (col_c >= line_pix + LINE_BLK - 1) begin
            col_c <= 0;
            lin_c <= (lin_c >= NLINE - 1) ? 0 : lin_c + 1;
        end else begin
            col_c <= col_c + 1;
        end
    end

    wire st_de = run && (col_c < line_pix);
    wire st_vs = run && (col_c == line_pix + LINE_BLK - 1) && (lin_c == NLINE - 1);
    // 画面内容：{行号, 列号, 0x55}，能看出错位
    wire [23:0] st_rgb = {lin_c[7:0], col_c[7:0], 8'h55};

    //---------------------------------------------------------- 公共控制
    reg  [8:0]  blend   = 9'd256;
    reg         osd_on  = 1'b1;
    reg  [10:0] osd_ofs = 11'd0;

    // 控制量的"上一拍值"：DUT 内部用的是【输入那一拍】的控制量，
    // 所以预测值也必须用上一拍的控制量来算。
    reg         osd_on_d  = 1'b1;
    reg  [10:0] osd_ofs_d = 11'd0;

    localparam [23:0] FG2 = 24'hFFD24A;
    localparam [23:0] BG2 = 24'h101828;

    //---------------------------------------------------------- 实例 1：真实参数
    wire [23:0] o1_rgb;
    wire        o1_de, o1_vs;

    osd_mixer #(.SCREEN_W(1280), .SCREEN_H(720), .OSD_H(32),
                .FG_COLOR(FG2), .BG_COLOR(BG2)) dut1 (
        .clk (clk), .rst (rst), .rgb_in (st_rgb), .de_in (st_de), .vs_in (st_vs),
        .blend (blend), .osd_on (osd_on), .osd_ofs (osd_ofs),
        .rgb_out (o1_rgb), .de_out (o1_de), .vs_out (o1_vs)
    );

    //---------------------------------------------------------- 实例 2：缩小参数
    wire [23:0] o2_rgb;
    wire        o2_de, o2_vs;

    osd_mixer #(.SCREEN_W(2048), .SCREEN_H(64), .OSD_H(32),
                .FG_COLOR(FG2), .BG_COLOR(BG2)) dut2 (
        .clk (clk), .rst (rst), .rgb_in (st_rgb), .de_in (st_de), .vs_in (st_vs),
        .blend (blend), .osd_on (osd_on), .osd_ofs (osd_ofs),
        .rgb_out (o2_rgb), .de_out (o2_de), .vs_out (o2_vs)
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

    //------------------------------------------------ 亮度乘算的"独立期望值"
    // ★ 坑：Verilog 里 a*b 的结果宽度 = max(宽度a, 宽度b)（不是两宽度之和），
    //   而且"比较表达式"会按较宽的一边对齐 —— 写 (24'hXXXXXX * 9'd128) >> 8
    //   会被截成 24 位再移位，高位溢出，结果就错了。
    //   DUT 是【按通道】算的（8bit * 9bit = 16bit），这里必须照着按通道算。
    function [23:0] lum;
        input [23:0] raw;
        input [8:0]  b;
        reg [15:0] rr, gg, bb;
        begin
            rr = raw[23:16] * b;
            gg = raw[15:8]  * b;
            bb = raw[7:0]   * b;
            lum = {rr[15:8], gg[15:8], bb[15:8]};
        end
    endfunction

    // 亮度 = 128（正好一半）时，DUT 的结果等价于每通道右移 1 位。
    // 这条公式里完全没有乘法，所以是真·独立验算（不是把 lum() 抄一遍）。
    function [23:0] half;
        input [23:0] raw;
        begin
            half = {raw[23:16] >> 1, raw[15:8] >> 1, raw[7:0] >> 1};
        end
    endfunction

    //=====================================================================
    // 监视器 1（dut1）：坐标 / 输出延迟 / 亮度 / 字幕带位置
    //=====================================================================
    integer x1 = 0, y1 = 0;
    reg de1_p = 0, vs1_p = 0;
    reg [23:0] st_rgb_d = 0;        // 比输入晚 1 拍，和 DUT 内部 rgb_1 同步

    integer dly_bad = 0, dly_cmp = 0;
    integer pass_bad = 0, pass_cmp = 0;         // 非字幕区：应等于 输入*blend>>8
    integer band_bad = 0, band_cmp = 0;         // 字幕带：应是 FG 或 BG
    integer zone_bad = 0, zone_cmp = 0;         // 字幕带【行区域】的透传比对（osd_on=0 时用）
    integer hb_bad = 0, hb_cmp = 0;             // blend=128 的"半亮"独立验算

    reg mon_en  = 1'b0;             // 复位释放之后才开始比对
    reg zone_on = 1'b0;
    reg hb_on   = 1'b0;

    // 预测值（第 t 拍输入 -> 第 t+1 拍输出）
    reg [23:0] p1 = 0;
    reg        p1_en = 0;
    reg        p1_band = 0;
    reg        p1_zone = 0;
    reg [23:0] p1_d = 0;
    reg        p1_en_d = 0;
    reg        p1_band_d = 0;
    reg        p1_zone_d = 0;

    reg [23:0] hb_src_s = 0, hb_dut_s = 0, hb_exp_s = 0;

    always @(posedge clk) begin

        //---- 1) 先拿"上一拍算的预测"和"本拍的输出"比 ----
        if (mon_en && p1_en_d) begin
            if (p1_band_d) begin
                // 字幕带内：监视器 1 不知道 ROM 内容，只要求是 FG 或 BG
                band_cmp = band_cmp + 1;
                if (!(o1_rgb === lum(FG2, blend) || o1_rgb === lum(BG2, blend)))
                    band_bad = band_bad + 1;
            end else begin
                pass_cmp = pass_cmp + 1;
                if (o1_rgb !== p1_d) pass_bad = pass_bad + 1;

                // osd_on=0 时，专挑"字幕带那 32 行"统计（应原样透传）
                if (zone_on && p1_zone_d) begin
                    zone_cmp = zone_cmp + 1;
                    if (o1_rgb !== p1_d) zone_bad = zone_bad + 1;
                end

                // blend=128 时按 half() 独立验算
                if (hb_on) begin
                    if (hb_cmp == 0) begin
                        hb_src_s = st_rgb_d;
                        hb_dut_s = o1_rgb;
                        hb_exp_s = half(st_rgb_d);
                    end
                    hb_cmp = hb_cmp + 1;
                    if (o1_rgb !== half(st_rgb_d)) hb_bad = hb_bad + 1;
                end
            end
        end

        //---- 2) 输出延迟：o_de / o_vs 应恰好比输入晚 1 拍 ----
        if (mon_en) begin
            dly_cmp = dly_cmp + 1;
            if (o1_de !== de1_p) dly_bad = dly_bad + 1;
            if (o1_vs !== vs1_p) dly_bad = dly_bad + 1;
        end

        //---- 3) 共享寄存器 ----
        de1_p      <= st_de;
        vs1_p      <= st_vs;
        st_rgb_d   <= st_rgb;
        osd_on_d   <= osd_on;
        osd_ofs_d  <= osd_ofs;

        //---- 4) 用"上一拍的输入坐标"算本拍的预测 ----
        //  注意顺序：x1/y1 的更新在【本块最后】，所以这里读到的是上一拍留下的值。
        p1      = lum(st_rgb, blend);
        p1_band = osd_on_d & (y1 >= (720 - 32));
        p1_zone = (y1 >= (720 - 32));
        p1_en   = st_de;

        p1_d      <= p1;
        p1_en_d   <= p1_en;
        p1_band_d <= p1_band;
        p1_zone_d <= p1_zone;

        //---- 5) 独立坐标（与 DUT 内部完全同一套规则）----
        if (rst) begin
            x1 = 0;
            y1 = 0;
        end else begin
            if (st_vs && !vs1_p)      y1 = 0;
            else if (!st_de && de1_p) y1 = y1 + 1;

            if (st_de) x1 = x1 + 1;
            else       x1 = 0;
        end
    end

    //=====================================================================
    // 监视器 2（dut2）：把 banner_rom 真实内容读出来，逐像素对字幕
    //=====================================================================
    integer x2 = 0, y2 = 0;
    reg de2_p = 0, vs2_p = 0;

    integer rom_bad = 0, rom_cmp = 0;
    integer col_min = 2047, col_max = 0;
    integer rows_seen = 0;
    reg [9:0] last_row = 10'h3FF;
    integer dbg_shown = 0;
    reg     dbg_en = 1'b0;

    // 预测（第 t 拍输入 -> 第 t+1 拍输出）
    reg [23:0] p2 = 0;
    reg        p2_en = 0;
    reg [23:0] p2_d = 0;
    reg        p2_en_d = 0;
    // 连地址/位号/坐标一起延迟，方便打印
    reg [10:0] pra = 0, pra_d = 0;
    reg [4:0]  pbs = 0, pbs_d = 0;
    reg        pbit = 0, pbit_d = 0;
    reg [10:0] pcol = 0, pcol_d = 0;
    reg [4:0]  prow = 0, prow_d = 0;

    integer ra_now;
    reg [4:0] bs_now;
    reg     bit_now;
    reg [10:0] col_now;
    reg     mon2_en = 1'b0;

    always @(posedge clk) begin
        //---- 1) 比对上一拍的预测 ----
        if (mon2_en && p2_en_d) begin
            rom_cmp = rom_cmp + 1;
            if (o2_rgb !== p2_d) begin
                rom_bad = rom_bad + 1;
                if (dbg_shown < 3 && dbg_en) begin
                    dbg_shown = dbg_shown + 1;
                    $display("        [字幕不符] col=%0d row=%0d ra=%0d bs=%0d bit=%b dut=%06h exp=%06h",
                             pcol_d, prow_d, pra_d, pbs_d, pbit_d, o2_rgb, p2_d);
                end
            end
        end

        de2_p <= st_de;
        vs2_p <= st_vs;

        //---- 2) 用"上一拍的输入坐标"算本拍的预测 ----
        //  DUT: rom_addr = {osd_row[4:0], col[10:5]}, bit = rom_word[31 - col[4:0]]
        //  banner_rom 是同步 ROM，dout 比 addr 晚 1 拍 —— 正好和 osd_mixer 第 1 级对齐。
        if (st_de && (y2 >= 32) && osd_on_d) begin
            col_now = (x2 + osd_ofs_d) & 11'h7FF;
            ra_now  = (((y2 - 32) & 5'h1F) << 6) | (col_now >> 5);
            bs_now  = col_now[4:0];
            bit_now = dut2.u_banner_rom.mem[ra_now][31 - bs_now];
            p2      = bit_now ? lum(FG2, blend) : lum(BG2, blend);
            p2_en   = 1'b1;
        end else begin
            col_now = 11'd0;
            ra_now  = 0;
            bs_now  = 5'd0;
            bit_now = 1'b0;
            p2      = 24'h000000;
            p2_en   = 1'b0;
        end

        pra  <= ra_now[10:0];
        pbs  <= bs_now;
        pbit <= bit_now;
        pcol <= col_now;
        prow <= (y2 - 32) & 5'h1F;

        //---- 覆盖率统计（按输入侧算）----
        if (mon2_en && st_de && (y2 >= 32) && osd_on_d) begin
            if (col_now < col_min) col_min = col_now;
            if (col_now > col_max) col_max = col_now;
            if (y2[9:0] !== last_row) begin
                last_row  = y2[9:0];
                rows_seen = rows_seen + 1;
            end
        end

        p2_d    <= p2;
        p2_en_d <= p2_en;
        pra_d   <= pra;
        pbs_d   <= pbs;
        pbit_d  <= pbit;
        pcol_d  <= pcol;
        prow_d  <= prow;

        //---- 3) 独立坐标（与 DUT 内部完全同一套规则）----
        if (rst) begin
            x2 = 0;
            y2 = 0;
        end else begin
            if (st_vs && !vs2_p)      y2 = 0;
            else if (!st_de && de2_p) y2 = y2 + 1;

            if (st_de) x2 = x2 + 1;
            else       x2 = 0;
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
        $display("[%0t] 复位：rgb_out / de_out / vs_out 都应为 0", $time);
        $display("        dut1: rgb=%06h de=%b vs=%b", o1_rgb, o1_de, o1_vs);
        chk(o1_rgb === 24'h000000 && o1_de === 1'b0 && o1_vs === 1'b0, "C01-rst-outputs-zero");
        chk(o2_rgb === 24'h000000 && o2_de === 1'b0, "C02-dut2-rst-zero");

        rst = 1'b0;
        repeat (5) @(posedge clk);
        line_pix = 8;
        run = 1'b1;                     // 从这一刻起 DUT 和监视器一起开始数行列
        repeat (4) @(posedge clk);

        // 统计清零放在"稳下来之后"
        dly_bad = 0; dly_cmp = 0;
        pass_bad = 0; pass_cmp = 0;
        band_bad = 0; band_cmp = 0;
        zone_bad = 0; zone_cmp = 0;
        mon_en = 1'b1;

        //=========================================== A 阶段
        repeat (2 * NLINE * (8 + LINE_BLK)) @(posedge clk);

        $display("");
        $display("[%0t] A 阶段：输出延迟 / 亮度 / 字幕带", $time);
        $display("        o_de / o_vs 与输入不对应 %0d 次（比对 %0d 拍）", dly_bad, dly_cmp);
        chk(dly_bad === 0, "C03-de_vs-delayed-1-cycle");

        $display("        非字幕区（blend=256，应原样透传）：%0d 个像素，不符 %0d 个",
                 pass_cmp, pass_bad);
        chk(pass_bad === 0, "C04-blend256-passthrough");
        chk(pass_cmp > 1000, "C05-enough-pixels-checked");

        $display("        字幕带内（应显示 FG 或 BG）：%0d 个像素，不符 %0d 个",
                 band_cmp, band_bad);
        chk(band_bad === 0, "C06-band-shows-fg-or-bg");
        chk(band_cmp > 100, "C07-band-was-visited");

        //---- blend = 0 应该全黑 ----
        blend = 9'd0;
        repeat (4 * (8 + LINE_BLK)) @(posedge clk);
        $display("");
        $display("        blend=0 时 rgb_out=%06h（输入 %06h）", o1_rgb, st_rgb);
        chk(o1_rgb === 24'h000000, "C08-blend0-gives-black");

        //---- blend = 128 应该正好是一半亮度 ----
        blend = 9'd128;
        repeat (4) @(posedge clk);      // 让流水线排空
        hb_bad = 0; hb_cmp = 0;
        hb_on = 1'b1;
        repeat (40 * (8 + LINE_BLK)) @(posedge clk);   // 跑够 40 行，采样量才够
        hb_on = 1'b0;
        $display("        blend=128：比对 %0d 个像素，不符 %0d 个；样例 输入=%06h 输出=%06h 期望=%06h",
                 hb_cmp, hb_bad, hb_src_s, hb_dut_s, hb_exp_s);
        chk(hb_bad === 0 && hb_cmp > 100, "C09-blend128-is-half");
        blend = 9'd256;

        //---- osd_on = 0：字幕带那 32 行也应是原画面 ----
        osd_on = 1'b0;
        repeat (4) @(posedge clk);
        zone_bad = 0; zone_cmp = 0;
        zone_on = 1'b1;
        repeat (2 * NLINE * (8 + LINE_BLK)) @(posedge clk);
        zone_on = 1'b0;
        $display("");
        $display("        osd_on=0 时字幕带行内（应原样透传）：%0d 个像素，不符 %0d 个",
                 zone_cmp, zone_bad);
        chk(zone_bad === 0 && zone_cmp > 100, "C10-osd-off-shows-picture");
        osd_on = 1'b1;

        //=========================================== B 阶段：字幕内容 + 位序
        $display("");
        $display("[%0t] B 阶段：行拉长到 2048 像素，逐像素对 banner_rom 真实内容", $time);
        run = 1'b0;
        repeat (4) @(posedge clk);
        line_pix = 2048;
        osd_ofs  = 11'd0;
        blend    = 9'd256;

        // ★ 用 rst 让 dut 的行列计数器和监视器【同时】归零。
        //   绝不能直接写 x2=0; y2=0; —— 那样 dut 的计数器不清，两边就永久错位。
        rst = 1'b1;
        repeat (4) @(posedge clk);
        rst = 1'b0;
        repeat (4) @(posedge clk);

        rom_bad = 0; rom_cmp = 0;
        col_min = 2047; col_max = 0;
        rows_seen = 0;
        dbg_en = 1'b1;
        mon2_en = 1'b1;
        run = 1'b1;
        repeat (42 * (2048 + LINE_BLK)) @(posedge clk);
        run = 1'b0;
        dbg_en = 1'b0;
        repeat (4) @(posedge clk);

        $display("        字幕带内逐像素：比对 %0d 个，不符 %0d 个", rom_cmp, rom_bad);
        chk(rom_bad === 0, "C11-osd-pixels-match-real-rom");
        chk(rom_cmp > 15000, "C12-enough-osd-pixels");
        $display("        覆盖 col 范围 %0d..%0d（期望 0..2047）", col_min, col_max);
        chk(col_min === 0 && col_max === 2047, "C13-col-sweeps-0-to-2047");
        $display("        走进字幕带的行数 %0d", rows_seen);
        chk(rows_seen >= 5, "C14-multiple-osd-rows-visited");

        //---- 滚动：osd_ofs = 32 ----
        $display("");
        $display("[%0t] B 阶段 2：横向滚动 osd_ofs = 32", $time);
        run = 1'b0;
        repeat (4) @(posedge clk);
        osd_ofs = 11'd32;

        rst = 1'b1;
        repeat (4) @(posedge clk);
        rst = 1'b0;
        repeat (4) @(posedge clk);

        rom_bad = 0; rom_cmp = 0;
        dbg_en = 1'b1;
        run = 1'b1;
        repeat (42 * (2048 + LINE_BLK)) @(posedge clk);
        run = 1'b0;
        dbg_en = 1'b0;
        repeat (4) @(posedge clk);
        $display("        ofs=32 时逐像素：比对 %0d 个，不符 %0d 个", rom_cmp, rom_bad);
        chk(rom_bad === 0 && rom_cmp > 15000, "C15-scroll-offset-32-correct");

        //---- 复位再验证 ----
        mon_en  = 1'b0;
        mon2_en = 1'b0;
        rst = 1'b1;
        repeat (3) @(posedge clk);
        chk(o1_rgb === 24'h000000 && o1_de === 1'b0, "C16-rst-clears-again");
        rst = 1'b0;

        $display("");
        $display("==================================================");
        $display("[%0t] 仿真结束：通过 %0d 项，失败 %0d 项",
                 $time, chk_idx - fail_cnt, fail_cnt);
        $display("==================================================");
        $display("### RESULT tb_osd_mixer : %0s  (%0d/%0d) ###",
                 (fail_cnt == 0) ? "PASS" : "FAIL", chk_idx - fail_cnt, chk_idx);
        $finish;
    end

    initial begin
        #30_000_000;
        $display("### RESULT tb_osd_mixer : FAIL  (超时) ###");
        $finish;
    end

endmodule
