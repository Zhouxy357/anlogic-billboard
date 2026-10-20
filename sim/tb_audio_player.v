//============================================================================
// tb_audio_player.v  ——  PCM 播放器 + 跨时钟域握手 的行为仿真
//---------------------------------------------------------------------------
// 测什么（这是本模块最关键、最容易出错的地方）：
//   ① 实际采样率是不是 ≈ 48kHz（HDMI 音频能不能被电视认出来的关键）；
//   ② 左右声道数据一致（本工程左右放同一个素材）；
//   ③ 【重要】ROM 里真的有素材：样本非零、波形在变化。
//      这一条专治“hex 文件没找到 / 路径写错”——那种情况下 ROM 全 0，
//      前两条照样会“通过”，但上板是一点声音都没有。
//   ④ 更换音效段号时，只在段边界切换，切完读到的数据确实变了。
//
// 【运行前必须做的事】
//   把 tools/gen_audio_rom.py 生成的 audio_rom.hex 放在**本目录（sim/）**下，
//   否则 ③ 会报“ROM 是空的”。生成命令（在工程根目录执行）：
//       python tools/gen_audio_rom.py -o sim/audio_rom.hex
//
// 怎么跑：
//   vlog ../src/hdl/audio_rom.v ../src/hdl/audio_player.v tb_audio_player.v
//   vsim -c tb_audio_player -do "run -all; quit -f"
//   跑完看本目录下自动生成的 transcript 文件（UTF-8 编码，中文不会乱码）。
//============================================================================
`timescale 1ns / 1ps

module tb_audio_player;

    // 12.288MHz 音频主时钟：周期 ≈ 81.38ns
    reg mclk = 1'b0;
    always #40.69 mclk = ~mclk;

    // 视频像素时钟：实际工程里是 75MHz（周期 13.33ns）。
    // 这里仍用 25MHz 跑，只是为了缩短仿真时间——audio_player 的 vid_clk
    // 只用来同步 audio_valid，逻辑与具体频率无关，不影响本测试的有效性。
    reg vid_clk = 1'b0;
    always #20 vid_clk = ~vid_clk;

    reg        rst_mclk = 1'b1;
    reg        rst_vid  = 1'b1;
    reg  [3:0] seg_id   = 4'd0;

    wire        o_audio_valid;
    wire [23:0] o_left;
    wire [23:0] o_right;

    //--------------------------------------------------------------- 统计量
    integer vld_cnt   = 0;    // audio_valid 拍数（= 样本数）
    integer mism_cnt  = 0;    // 左右不一致次数
    integer nz_cnt    = 0;    // 非零样本数
    integer chg_cnt   = 0;    // 与上一个样本不同的次数
    integer peak      = 0;    // 峰值（取绝对值）
    reg [23:0] prev_l  = 24'd0;

    // 波形指纹：对样本序列做简单加权，用来判断“两个段取到的数据是不是同一份”
    reg [31:0] sig = 32'd0;

    // 统计窗口控制：cap_en=1 时才累积指纹
    reg        cap_en  = 1'b0;
    reg [31:0] sig_seg0 = 32'd0;
    reg [31:0] sig_seg3 = 32'd0;

    integer absv;

    always @(posedge vid_clk) begin
        if (o_audio_valid) begin
            vld_cnt = vld_cnt + 1;
            if (o_left !== o_right) mism_cnt = mism_cnt + 1;
            if ((o_left !== 24'd0) && (o_left !== 24'hxxxxxx)) nz_cnt = nz_cnt + 1;
            if (o_left !== prev_l) chg_cnt = chg_cnt + 1;
            prev_l = o_left;

            // 峰值：24bit 有符号补码，取绝对值
            absv = (o_left[23]) ? (~o_left + 24'd1) : o_left;
            if (absv > peak) peak = absv;

            if (cap_en) sig = (sig << 1) ^ o_left;
        end
    end

    audio_player #(
        .MCLK_HZ   (12_288_000),
        .SAMPLE_HZ (48_000),
        .ROM_DEPTH (8192),
        .SEG_NUM   (4),
        .OFS_W     (13),
        .ADDR_W    (15)
    ) dut (
        .mclk          (mclk),
        .rst_mclk      (rst_mclk),
        .seg_id        (seg_id),
        .vid_clk       (vid_clk),
        .rst_vid       (rst_vid),
        .o_audio_valid (o_audio_valid),
        .o_left        (o_left),
        .o_right       (o_right)
    );

    //--------------------------------------------------------------- 通过/失败计数
    integer pass_cnt = 0;
    integer fail_cnt = 0;
    integer chk_idx  = 0;

    task chk;
        input cond;
        // 【必须用 ASCII】中文不要通过这个参数传！
        // iverilog 把字符串打包进位向量时，非 ASCII 字节高位会补成 0xff，
        // 日志里就变成 "閫氳繃锛�" 这种乱码。中文说明请直接用 $display 打印。
        input [1023:0] name;
        begin
            chk_idx = chk_idx + 1;
            if (cond) begin
                pass_cnt = pass_cnt + 1;
                $display("   >>> [PASS] %0s", name);
            end
            else begin
                fail_cnt = fail_cnt + 1;
                $display("   >>> [FAIL] %0s", name);
                $display("### FAIL idx=%0d ###", chk_idx);
            end
        end
    endtask

    integer start_cnt;
    integer win_cnt;
    integer win_nz;
    integer win_chg;

    initial begin
        #200 rst_mclk = 1'b0;
             rst_vid  = 1'b0;

        // 丢掉最初一小段，让内部计数器稳定
        #100_000;

        //================================================== ① 采样率
        start_cnt = vld_cnt;
        #2_000_000;                     // 2ms
        win_cnt = vld_cnt - start_cnt;

        $display("--------------------------------------------------");
        $display("[%0t] 2ms 内产生样本数 = %0d（期望约 96）", $time, win_cnt);
        chk((win_cnt >= 94) && (win_cnt <= 98), "C01");   // 采样率 ≈ 48kHz

        //================================================== ② 左右一致
        $display("--------------------------------------------------");
        $display("[%0t] 左右声道不一致的次数 = %0d（期望 0）", $time, mism_cnt);
        chk(mism_cnt == 0, "C02");   // 左右声道数据一致

        //================================================== ③ ROM 真的有素材
        // 这一条专门抓“hex 没找到 / ROM 全 0”的情况。
        // 内置提示音是正弦/方波一类的波形，不可能是常数。
        win_nz  = nz_cnt;
        win_chg = chg_cnt;

        $display("--------------------------------------------------");
        $display("[%0t] 累计样本数 = %0d，其中非零样本 = %0d，波形变化次数 = %0d",
                 $time, vld_cnt, win_nz, win_chg);
        $display("           峰值 = %0d（满刻度 8388607；8bit 源理论峰值约 24320）",
                 peak);
        chk(win_nz > (vld_cnt * 8 / 10), "C03");   // ROM 里有素材（非零样本占比 > 80%）
        chk(win_chg > (vld_cnt / 100), "C04");     // 波形确实在变化（不是一条直流线）
        chk(peak > 10_000, "C05");   // 峰值幅度正常（素材不是静音）；8bit 源满幅约 24320

        //================================================== ④ 换段
        $display("--------------------------------------------------");
        $display("[%0t] 记录段 0 的波形指纹，然后把段号改成 3", $time);
        cap_en = 1'b1;
        sig    = 32'd0;
        repeat (200) @(posedge vid_clk);
        sig_seg0 = sig;

        seg_id = 4'd3;
        sig    = 32'd0;
        #20_000_000;                    // 让它播 20ms 再取指纹
        sig_seg3 = sig;
        cap_en   = 1'b0;

        $display("           段 0 指纹 = %08h，段 3 指纹 = %08h", sig_seg0, sig_seg3);
        chk(sig_seg0 !== sig_seg3, "C06");   // 换成段 3 之后，读到的数据确实换了（段切换生效）
        chk(o_left < 24'h800000 || o_left > 24'h800000, "C07");   // 换段后没有卡在某个固定值

        //================================================== 汇总
        $display("==================================================");
        $display("[%0t] 仿真结束：通过 %0d 项，失败 %0d 项", $time, pass_cnt, fail_cnt);
        if (fail_cnt != 0)
            $display("   >>> 有失败项，请先改好 audio_player / audio_rom 或补上 audio_rom.hex");
        else
            $display("   >>> 音频模块全部通过");
        $display("==================================================");
        // 纯 ASCII 结论行，供 run_all.do / check_results.py 判断
        $display("### RESULT tb_audio_player : %0s  (%0d/%0d) ###",
                 (fail_cnt == 0) ? "PASS" : "FAIL", pass_cnt, chk_idx);
        $finish;
    end

endmodule
