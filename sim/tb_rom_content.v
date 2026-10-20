//============================================================================
// tb_rom_content.v  ——  两个素材 ROM 的内容 + 读时序校验
//                        （banner_rom 字幕点阵 / audio_rom 音频样本）
//---------------------------------------------------------------------------
// 为什么要有这个 tb：
//   这两个 ROM 是"数据"不是"逻辑"，综合/仿真都不会报错，内容错了只会表现为
//   "字幕是乱码"或"声音不对"，最难查。所以这里做三件事：
//     ① 读时序：必须是同步 ROM（dout 比 addr 晚 1 拍），不是组合直通；
//     ② 定值抽查：从 .hex 原文里挑几个地址写死期望值，直接对；
//     ③ 全量指纹：把 .hex 用 Python 独立算出的"字数和/异或/亮点数/每行亮点数"
//        固化成期望值，把 2048 / 32768 个地址全部走一遍再对账。
//        —— 只要 hex 被改错一个 bit，指纹就对不上。
//
// 期望值的来源（可复算，不要手改）：
//   python - <<'PY'
//     import io
//     ban=[int(l,16) for l in io.open('banner_rom.hex') if l.strip()]
//     print('banner: xor=0x%08X sum=0x%08X nz=%d bits=%d' % (
//         __import__('functools').reduce(lambda a,b:a^b, ban, 0),
//         sum(ban)&0xFFFFFFFF,
//         sum(1 for x in ban if x),
//         sum(bin(x).count('1') for x in ban)))
//   PY
//
// 怎么跑（在 sim 目录下，用 Git Bash）：
//   ./run_iverilog.sh rom
//============================================================================
`timescale 1ns / 1ps

module tb_rom_content;

    //---------------------------------------------------------- 时钟
    reg clk = 1'b0;
    always #5 clk = ~clk;

    //---------------------------------------------------------- banner_rom
    reg  [10:0] b_addr = 11'd0;
    wire [31:0] b_dout;

    banner_rom u_ban (.clk (clk), .addr (b_addr), .dout (b_dout));

    //---------------------------------------------------------- audio_rom
    reg  [14:0] a_addr = 15'd0;
    wire [15:0] a_dout;

    audio_rom u_aud (.clk (clk), .addr (a_addr), .dout (a_dout));

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

    //---------------------------------------------------------- popcount
    function integer pc32;
        input [31:0] v;
        integer k;
        begin
            pc32 = 0;
            for (k = 0; k < 32; k = k + 1) pc32 = pc32 + v[k];
        end
    endfunction

    //=====================================================================
    // banner_rom 监视器：全量走地址时做指纹累加
    //   ★ b_dout(n) = mem[b_addr(n-1)]，同时 b_addr_d(n) = b_addr(n-1)，
    //     所以 (b_addr_d, b_dout) 是严格配对的一组。
    //   ★ 监视器自己数"统计了多少个地址"，数满 2048 就停 —— 这样主流程
    //     什么时候收尾都不会多算/少算。
    //=====================================================================
    reg [10:0] b_addr_d = 11'd0;
    reg        b_walk   = 1'b0;
    integer    b_idx    = -1;          // 已经对账到第几个字（-1 = 还没对齐）

    reg [31:0] b_xor = 32'd0;
    reg [31:0] b_sum = 32'd0;
    integer    b_nz    = 0;
    integer    b_bits  = 0;
    integer    b_first = -1;
    integer    b_last  = -1;

    integer    row_got [0:31];
    integer    row_exp [0:31];

    integer    bi, ri, rdiff;

    initial begin
        row_exp[ 0] =   0;  row_exp[ 1] =   0;  row_exp[ 2] =   2;  row_exp[ 3] =  23;
        row_exp[ 4] = 114;  row_exp[ 5] = 468;  row_exp[ 6] = 550;  row_exp[ 7] = 387;
        row_exp[ 8] = 376;  row_exp[ 9] = 387;  row_exp[10] = 383;  row_exp[11] = 345;
        row_exp[12] = 388;  row_exp[13] = 489;  row_exp[14] = 474;  row_exp[15] = 435;
        row_exp[16] = 371;  row_exp[17] = 355;  row_exp[18] = 422;  row_exp[19] = 464;
        row_exp[20] = 390;  row_exp[21] = 292;  row_exp[22] = 326;  row_exp[23] = 416;
        row_exp[24] = 357;  row_exp[25] = 385;  row_exp[26] = 499;  row_exp[27] = 260;
        row_exp[28] =  16;  row_exp[29] =   0;  row_exp[30] =   0;  row_exp[31] =   0;
        for (ri = 0; ri < 32; ri = ri + 1) row_got[ri] = 0;
    end

    integer rb_add;

    always @(posedge clk) begin
        b_addr_d <= b_addr;

        // ★ 自同步对齐（很重要）：
        //   地址是在 negedge 上推进的，而 dout 是 posedge 采的，中间隔了 2 拍，
        //   直接用"第 k 拍"硬对齐必然错位（会重复算 mem[0]、漏掉尾部）。
        //   这里的做法：先锁到 addr_d==0，之后每拍都要求 addr_d 正好等于序号，
        //   对上了才累加、序号+1。
        //   好处：① (addr_d, dout) 严格配对；② 顺带验证地址确实是 0,1,2,... 连着走的
        //   —— 中间断一拍就会卡住，b_idx 到不了 2048，C07 会直接报出来。
        if (b_walk) begin
            if (b_idx < 0) begin
                if (b_addr_d === 11'd0) b_idx = 0;
            end else if (b_idx < 2048 && b_addr_d === b_idx) begin
                b_idx = b_idx + 1;

                b_xor  = b_xor ^ b_dout;
                b_sum  = b_sum + b_dout;
                rb_add = pc32(b_dout);
                b_bits = b_bits + rb_add;

                if (b_dout !== 32'h00000000) begin
                    b_nz = b_nz + 1;
                    if (b_first < 0) b_first = b_addr_d;
                    b_last = b_addr_d;
                end

                row_got[b_addr_d[10:6]] = row_got[b_addr_d[10:6]] + rb_add;
            end
        end
    end

    //=====================================================================
    // audio_rom 监视器
    //   地址顺序递增，所以"上一拍的 dout"就是"上一个样本"，可以直接拿来做
    //   过零计数（每段首位重新起算）。
    //=====================================================================
    reg [14:0] a_addr_d = 15'd0;
    reg        a_walk   = 1'b0;
    integer    a_idx    = -1;          // 已经对账到第几个样本

    integer    a_signbad = 0;          // 符号扩展不对的样本数
    integer    a_sawneg  = 0, a_sawpos = 0;

    integer    a_zc  [0:3];
    integer    a_min [0:3];
    integer    a_max [0:3];
    reg [15:0] a_s16 [0:3];            // 16bit 有符号累加（自然回绕）
    reg [15:0] a_raw [0:3];            // 低 8bit 当无符号累加
    reg [15:0] a_first[0:3];
    reg [15:0] a_last [0:3];

    reg        a_psign = 1'b0;
    reg        a_pok   = 1'b0;

    integer    ai;
    integer    seg;

    initial begin
        for (ai = 0; ai < 4; ai = ai + 1) begin
            a_zc[ai]   = 0;
            a_min[ai]  = 32767;
            a_max[ai]  = -32768;
            a_s16[ai]  = 16'd0;
            a_raw[ai]  = 16'd0;
            a_first[ai]= 16'd0;
            a_last[ai] = 16'd0;
        end
    end

    always @(posedge clk) begin
        a_addr_d <= a_addr;

        // 同 banner：自同步对齐（地址 negedge 推进 / dout posedge 采，差 2 拍）
        if (a_walk) begin
            if (a_idx < 0) begin
                if (a_addr_d === 15'd0) a_idx = 0;
            end else if (a_idx < 32768 && a_addr_d === a_idx) begin
                a_idx = a_idx + 1;
                seg   = a_addr_d[14:13];

                //---- 符号扩展必须成立 ----
                if (a_dout[15:8] !== {8{a_dout[7]}}) a_signbad = a_signbad + 1;
                if (a_dout[15]) a_sawneg = 1; else a_sawpos = 1;

                //---- 段首/段尾 ----
                if (a_addr_d[12:0] === 13'd0)    a_first[seg] = a_dout;
                if (a_addr_d[12:0] === 13'd8191) a_last[seg]  = a_dout;

                //---- 过零（段内相邻样本符号位不同；段首不参与）----
                if (a_addr_d[12:0] === 13'd0) begin
                    a_psign = a_dout[15];
                    a_pok   = 1'b1;
                end else begin
                    if (a_pok && (a_dout[15] !== a_psign)) a_zc[seg] = a_zc[seg] + 1;
                    a_psign = a_dout[15];
                end

                //---- 幅值 / 累加指纹 ----
                if ($signed(a_dout) < a_min[seg]) a_min[seg] = $signed(a_dout);
                if ($signed(a_dout) > a_max[seg]) a_max[seg] = $signed(a_dout);
                a_s16[seg] = a_s16[seg] + a_dout;
                a_raw[seg] = a_raw[seg] + a_dout[7:0];
            end
        end
    end

    //========================================= 期望值（Python 独立算出）
    integer    zc_exp  [0:3];
    integer    mn_exp  [0:3];
    integer    mx_exp  [0:3];
    reg [15:0] s16_exp [0:3];
    reg [15:0] raw_exp [0:3];

    initial begin
        zc_exp[0] = 340;  mn_exp[0] = -95;  mx_exp[0] = 95;
        zc_exp[1] = 242;  mn_exp[1] = -95;  mx_exp[1] = 95;
        zc_exp[2] = 394;  mn_exp[2] = -95;  mx_exp[2] = 95;
        zc_exp[3] = 300;  mn_exp[3] = -75;  mx_exp[3] = 75;
        s16_exp[0] = 16'h004F;  s16_exp[1] = 16'hFFDD;
        s16_exp[2] = 16'hFF7B;  s16_exp[3] = 16'h0055;
        raw_exp[0] = 16'h464F;  raw_exp[1] = 16'hEEDD;
        raw_exp[2] = 16'hDE7B;  raw_exp[3] = 16'hD355;
    end

    //=====================================================================
    // 主流程
    //=====================================================================
    initial begin
        $timeformat(-9, 0, " ns", 12);

        $display("");
        $display("==================================================");
        $display(" 一、banner_rom（字幕点阵 2048 字 x 32bit）");
        $display("==================================================");

        //-------------------------------------------------- 读时序 + 定值抽查
        b_addr = 11'd1500;
        repeat (3) @(negedge clk);
        $display("[%0t] 稳态读 mem[1500] = %08h（期望 00303383）", $time, b_dout);
        chk(b_dout === 32'h00303383, "C01-banner-steady-read-ok");

        b_addr = 11'd1601;
        #1;                                   // 只过 1ns，还没到上升沿
        $display("        换地址后 1ns：%08h（必须还是旧值 00303383）", b_dout);
        chk(b_dout === 32'h00303383, "C02-banner-not-combinational");
        @(negedge clk);
        $display("        过一个上升沿：%08h（期望 F06040C0）", b_dout);
        chk(b_dout === 32'hF06040C0, "C03-banner-1cycle-latency");

        b_addr = 11'd130;   repeat (2) @(negedge clk);
        chk(b_dout === 32'h00000020, "C04-banner-spot-0130");
        b_addr = 11'd1600;  repeat (2) @(negedge clk);
        chk(b_dout === 32'h0C600306, "C05-banner-spot-1600");
        b_addr = 11'd1824;  repeat (2) @(negedge clk);
        chk(b_dout === 32'h00060000, "C06-banner-spot-1824");

        //-------------------------------------------------- 全量走一遍
        b_xor = 32'd0; b_sum = 32'd0; b_nz = 0; b_bits = 0;
        b_first = -1;  b_last = -1;   b_idx = -1;
        for (ri = 0; ri < 32; ri = ri + 1) row_got[ri] = 0;

        b_addr = 11'd0;
        repeat (3) @(negedge clk);            // 先稳定住 addr=0
        b_walk = 1'b1;
        for (bi = 0; bi < 2056; bi = bi + 1) begin   // 多跑几拍收尾，监视器自己会停
            b_addr = bi;
            @(negedge clk);
        end
        b_walk = 1'b0;

        $display("");
        $display("[%0t] 全量走完 %0d 个地址", $time, b_idx);
        $display("        非零字数 = %0d（期望 943）", b_nz);
        $display("        总亮点数 = %0d（期望 9374）", b_bits);
        $display("        XOR 指纹 = %08h（期望 375D47B8）", b_xor);
        $display("        求和指纹 = %08h（期望 32EAC0D8）", b_sum);
        $display("        首个/末个非零字地址 = %0d / %0d（期望 130 / 1824）", b_first, b_last);

        chk(b_idx === 2048,           "C07-banner-all-2048-words-walked");
        chk(b_nz === 943,            "C08-banner-nonzero-word-count");
        chk(b_bits === 9374,         "C09-banner-total-on-pixels");
        chk(b_xor === 32'h375D47B8,   "C10-banner-xor-fingerprint");
        chk(b_sum === 32'h32EAC0D8,   "C11-banner-sum-fingerprint");
        chk(b_first === 130 && b_last === 1824, "C12-banner-first-last-nonzero-addr");

        rdiff = 0;
        for (ri = 0; ri < 32; ri = ri + 1) begin
            if (row_got[ri] !== row_exp[ri]) begin
                rdiff = rdiff + 1;
                $display("        [行不符] 第 %0d 行：实测 %0d，期望 %0d",
                         ri, row_got[ri], row_exp[ri]);
            end
        end
        $display("        每行亮点数：不符 %0d 行", rdiff);
        chk(rdiff === 0, "C13-banner-per-row-pixel-count");

        $display("        第 0/1/29/30/31 行亮点数 = %0d/%0d/%0d/%0d/%0d（期望全 0）",
                 row_exp[0], row_exp[1], row_exp[29], row_exp[30], row_exp[31]);
        chk(row_got[0] === 0 && row_got[1] === 0 && row_got[29] === 0 &&
            row_got[30] === 0 && row_got[31] === 0,
            "C14-banner-top-bottom-rows-blank");

        $display("");
        $display("==================================================");
        $display(" 二、audio_rom（4 段 x 8192 个 8bit 样本，对外 16bit）");
        $display("==================================================");

        //-------------------------------------------------- 读时序 + 定值抽查
        a_addr = 15'd100;
        repeat (3) @(negedge clk);
        $display("[%0t] 稳态读 mem[100] = %04h（期望 0030）", $time, a_dout);
        chk(a_dout === 16'h0030, "C15-audio-steady-read-ok");

        a_addr = 15'd20000;
        #1;
        $display("        换地址后 1ns：%04h（必须还是旧值 0030）", a_dout);
        chk(a_dout === 16'h0030, "C16-audio-not-combinational");
        @(negedge clk);
        $display("        过一个上升沿：%04h（期望 0044）", a_dout);
        chk(a_dout === 16'h0044, "C17-audio-1cycle-latency");

        a_addr = 15'd30000;  repeat (2) @(negedge clk);
        chk(a_dout === 16'h0009, "C18-audio-spot-30000");

        //-------------------------------------------------- 全量走一遍
        for (ai = 0; ai < 4; ai = ai + 1) begin
            a_zc[ai]   = 0;
            a_min[ai]  = 32767;
            a_max[ai]  = -32768;
            a_s16[ai]  = 16'd0;
            a_raw[ai]  = 16'd0;
            a_first[ai]= 16'd0;
            a_last[ai] = 16'd0;
        end
        a_signbad = 0; a_sawneg = 0; a_sawpos = 0; a_idx = -1;
        a_pok = 1'b0;

        a_addr = 15'd0;
        repeat (3) @(negedge clk);
        a_walk = 1'b1;
        for (bi = 0; bi < 32776; bi = bi + 1) begin   // 多跑几拍收尾
            a_addr = bi;
            @(negedge clk);
        end
        a_walk = 1'b0;

        $display("");
        $display("[%0t] 全量走完 %0d 个样本", $time, a_idx);
        $display("        符号扩展不符 %0d 个；见到负样本=%b 正样本=%b",
                 a_signbad, a_sawneg, a_sawpos);
        chk(a_idx === 32768,   "C19-audio-all-32768-samples-walked");
        chk(a_signbad === 0,   "C20-audio-sign-extension");
        chk(a_sawneg === 1 && a_sawpos === 1, "C21-audio-has-both-polarities");

        for (ai = 0; ai < 4; ai = ai + 1) begin
            $display("        段%0d：幅值 %4d..%4d  过零 %4d  累加(有符号) %04h  累加(低8bit) %04h  首 %04h 尾 %04h",
                     ai, a_min[ai], a_max[ai], a_zc[ai], a_s16[ai], a_raw[ai],
                     a_first[ai], a_last[ai]);
        end

        chk(a_min[0] === mn_exp[0] && a_max[0] === mx_exp[0] && a_zc[0] === zc_exp[0] &&
            a_s16[0] === s16_exp[0] && a_raw[0] === raw_exp[0], "C22-audio-seg0-stats");
        chk(a_min[1] === mn_exp[1] && a_max[1] === mx_exp[1] && a_zc[1] === zc_exp[1] &&
            a_s16[1] === s16_exp[1] && a_raw[1] === raw_exp[1], "C23-audio-seg1-stats");
        chk(a_min[2] === mn_exp[2] && a_max[2] === mx_exp[2] && a_zc[2] === zc_exp[2] &&
            a_s16[2] === s16_exp[2] && a_raw[2] === raw_exp[2], "C24-audio-seg2-stats");
        chk(a_min[3] === mn_exp[3] && a_max[3] === mx_exp[3] && a_zc[3] === zc_exp[3] &&
            a_s16[3] === s16_exp[3] && a_raw[3] === raw_exp[3], "C25-audio-seg3-stats");

        //---- 每段首尾样本都是 0（淡入淡出，接缝不爆音）----
        $display("        四段段尾样本 = %04h %04h %04h %04h（期望全 0000）",
                 a_last[0], a_last[1], a_last[2], a_last[3]);
        chk(a_first[0] === 0 && a_first[1] === 0 && a_first[2] === 0 && a_first[3] === 0 &&
            a_last[0]  === 0 && a_last[1]  === 0 && a_last[2]  === 0 && a_last[3]  === 0,
            "C26-audio-segment-fade-zero");

        $display("");
        $display("==================================================");
        $display("[%0t] 仿真结束：通过 %0d 项，失败 %0d 项",
                 $time, chk_idx - fail_cnt, fail_cnt);
        $display("==================================================");
        $display("### RESULT tb_rom_content : %0s  (%0d/%0d) ###",
                 (fail_cnt == 0) ? "PASS" : "FAIL", chk_idx - fail_cnt, chk_idx);
        $finish;
    end

    initial begin
        #30_000_000;
        $display("### RESULT tb_rom_content : FAIL  (超时) ###");
        $finish;
    end

endmodule
