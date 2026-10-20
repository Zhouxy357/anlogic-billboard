//============================================================================
// tb_audio_stream.v  ——  TF 卡音频流读取自检
//---------------------------------------------------------------------------
// 验证点：
//   C01 没有音频源（audio_sec_cnt=0）时完全不占用总线
//   C02 有源后按水位开始读，首个扇区地址 = audio_sec
//   C03 字节拼样本正确（小端：先到的字节是低 8 位），每扇区 256 个样本
//   C04 扇区地址连续递增
//   C05 水位到高水位就停（b_req 与 sec_read 一起撤），不是一直霸占总线
//   C06 水位回落低水位后重新要货（迟滞有效）
//   C07 jump 跳到对应格子的起始扇区（audio_sec + cell*1875）
//   C08 jump 越界时回退到 audio_sec（不读到图片区）
//   C09 读到音频区末尾回卷到开头
//   C10 SD 卡掉线（sd_init_done=0）立刻安静
//============================================================================
`timescale 1ns / 1ps

module tb_audio_stream;

    localparam integer LEVEL_W = 12;
    localparam integer DEPTH   = 2048;

    reg          clk, rst;
    reg          sd_init_done;
    reg  [31:0]  audio_sec, audio_sec_cnt;
    reg          jump;
    reg  [2:0]   jump_cell;

    wire         b_req;
    wire         sec_read;
    wire [31:0]  sec_addr;
    wire [7:0]   data;
    wire         valid, eos;

    wire         wr_en;
    wire [15:0]  wr_data;

    reg  [LEVEL_W-1:0] level;
    reg          wr_full;
    reg  [3:0]   ddiv;

    integer n_chk, n_ok, bad, i;
    integer exp_i, sector_wr;
    reg [31:0] sec_cur;
    reg        hit256;

    // 字节图案：和扇区号、字节序号都相关，能抓出地址串位与大小端错误
    function [7:0] pat;
        input [31:0] s;
        input integer k;
        begin
            pat = (s[7:0] + k * 7 + 3) & 8'hFF;
        end
    endfunction

    //----------------------------------------------------------- DUT
    audio_stream #(
        .CELL_SEC   (1875),
        .LOW_WATER  (768),
        .HIGH_WATER (1536),
        .LEVEL_W    (LEVEL_W)
    ) dut (
        .clk          (clk),
        .rst          (rst),
        .sd_init_done (sd_init_done),
        .audio_sec    (audio_sec),
        .audio_sec_cnt(audio_sec_cnt),
        .jump         (jump),
        .jump_cell    (jump_cell),
        .b_req        (b_req),
        .sec_read     (sec_read),
        .sec_addr     (sec_addr),
        .data         (data),
        .valid        (valid),
        .end_of_sec   (eos),
        .wr_en        (wr_en),
        .wr_data      (wr_data),
        .wr_full      (wr_full),
        .wr_level     (level)
    );

    always begin #5 clk = 1'b1; #5 clk = 1'b0; end

    //----------------------------------------------------------- 假 FIFO
    // 水位模型：写 1 加 1，每 8 拍排掉 1 个（把 48kHz 的慢速消耗加速 8 倍，
    // 否则仿真要跑几千万拍）。只影响“多久填满”，不影响正确性。
    wire drain = (ddiv == 4'd7);

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            ddiv  <= 4'd0;
            level <= {LEVEL_W{1'b0}};
        end else begin
            ddiv  <= ddiv + 4'd1;
            level <= level
                   + ((wr_en && !wr_full) ? {{(LEVEL_W-1){1'b0}}, 1'b1} : {LEVEL_W{1'b0}})
                   - ((drain && (level != 0)) ? {{(LEVEL_W-1){1'b0}}, 1'b1} : {LEVEL_W{1'b0}});
        end
    end

    always @(*) wr_full = (level >= DEPTH[LEVEL_W-1:0]);

    // 记录水位峰值：C05 要判“到高水位就停”，而判断那一刻水位已经被消耗掉一些，
    // 直接看瞬时值会误判（踩过），所以看峰值。
    reg [LEVEL_W-1:0] peak;
    always @(posedge clk) if (level > peak) peak <= level;

    //----------------------------------------------------------- 假 SD 卡
    reg        busy;
    integer    cnt;
    reg        card_valid, card_eos;
    reg  [7:0] card_data;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            busy <= 1'b0; cnt <= 0; card_valid <= 1'b0; card_eos <= 1'b0;
            sec_cur <= 32'd0; card_data <= 8'd0;
        end else begin
            card_valid <= 1'b0;
            card_eos   <= 1'b0;
            if (!busy) begin
                if (sec_read === 1'b1) begin
                    busy    <= 1'b1;
                    cnt     <= 0;
                    sec_cur <= sec_addr;
                end
            end else begin
                card_valid <= 1'b1;
                card_data  <= pat(sec_cur, cnt);   // ★ 必须和 valid 同拍寄存，
                                                   //   否则 valid 首拍会漏掉字节 0
                if (cnt == 511) begin
                    card_eos <= 1'b1;
                    busy     <= 1'b0;
                end
                cnt <= cnt + 1;
            end
        end
    end

    assign data  = card_data;
    assign valid = card_valid;
    assign eos   = card_eos;

    //----------------------------------------------------------- 逐样本对账
    reg vd;
    // ★ 对账必须用“最后一个字节所属的扇区”，不能用 sec_cur：
    //   一个扇区第 256 个样本的写入比该扇区最后一个字节晚 1 拍，
    //   而这一拍假卡（和真实卡一样）已经把地址换成下一扇区了。
    //   直接用 sec_cur 会把每个扇区的末样本判成错 —— 是 tb 记账 bug，不是 RTL 的。
    reg [31:0] byte_sec;

    always @(posedge clk) begin
        vd <= valid;
        if (valid) byte_sec <= sec_cur;
        if (valid && !vd) begin          // 扇区首字节 → 该扇区样本计数归零
            exp_i     = 0;
            sector_wr = 0;
        end
        if (wr_en) begin
            sector_wr = sector_wr + 1;
            if (wr_data !== {pat(byte_sec, 2*exp_i + 1), pat(byte_sec, 2*exp_i)}) begin
                bad = bad + 1;
                if (bad <= 4)
                    $display("   [mismatch] t=%0t sec=%0d i=%0d got=%h exp=%h",
                             $time, byte_sec, exp_i, wr_data,
                             {pat(byte_sec, 2*exp_i + 1), pat(byte_sec, 2*exp_i)});
            end
            exp_i = exp_i + 1;
        end
        if (sector_wr == 256) hit256 <= 1'b1;
    end

    //----------------------------------------------------------- 地址监视
    reg [31:0] last_sa;
    reg        seen_6625, seen_1001, seen_back1000, wrap_en;

    always @(posedge clk) begin
        if (sec_addr !== last_sa) begin
            last_sa <= sec_addr;
            if (sec_addr == 32'd6625) seen_6625 <= 1'b1;
            if (wrap_en && (sec_addr == 32'd1001)) seen_1001 <= 1'b1;
            if (wrap_en && seen_1001 && (sec_addr == 32'd1000)) seen_back1000 <= 1'b1;
        end
    end

    //----------------------------------------------------------- 检查工具
    task chk;
        input cond;
        input [1023:0] name;
        begin
            n_chk = n_chk + 1;
            if (cond) n_ok = n_ok + 1;
            else      $display("### FAIL idx=%0d %0s  (t=%0t)", n_chk, name, $time);
        end
    endtask

    //----------------------------------------------------------- 主流程
    integer to;

    initial begin
        n_chk = 0; n_ok = 0; bad = 0; to = 0;
        clk = 0; rst = 1;
        sd_init_done = 0;
        audio_sec = 32'd1000; audio_sec_cnt = 32'd15000;
        jump = 0; jump_cell = 3'd0;
        wrap_en = 0; seen_6625 = 0; seen_1001 = 0; seen_back1000 = 0;
        last_sa = 32'hFFFF_FFFF;
        hit256 = 0;
        peak   = 0;

        $display("");
        $display("  ---- audio_stream : TF 卡音频流读取 ----");

        repeat (4) @(posedge clk);
        rst = 0;
        repeat (4) @(posedge clk);

        //-------------------------------------------------- C01 无源时安静
        for (to = 0; to < 300; to = to + 1) @(posedge clk);
        chk(b_req    === 1'b0, "C01a");
        chk(sec_read === 1'b0, "C01b");
        chk(level    === 0,    "C01c");

        //-------------------------------------------------- C02 有源 → 开始读
        sd_init_done = 1;
        peak = 0;
        to = 0;
        while ((b_req !== 1'b1) && (to < 100)) begin
            @(posedge clk); to = to + 1;
        end
        chk(b_req === 1'b1, "C02a");
        to = 0;
        while ((sec_read !== 1'b1) && (to < 100)) begin
            @(posedge clk); to = to + 1;
        end
        chk(sec_read === 1'b1, "C02b");
        chk(sec_addr === 32'd1000, "C02c");

        //-------------------------------------------------- C03/C04 读几个扇区对账
        bad = 0;
        for (to = 0; to < 6000; to = to + 1) @(posedge clk);
        chk(bad == 0, "C03a");                 // 逐样本比对（含大小端）
        chk(hit256 === 1'b1, "C03b");          // 有整扇区正好 256 个样本
        chk(sec_addr >= 32'd1001, "C04a");     // 地址已前进

        //-------------------------------------------------- C05 到高水位就停
        to = 0;
        while ((b_req === 1'b1) && (to < 60000)) begin
            @(posedge clk); to = to + 1;
        end
        chk(b_req === 1'b0, "C05a");
        chk(peak >= 1536, "C05b");
        to = 0;
        while ((sec_read === 1'b1) && (to < 3000)) begin
            @(posedge clk); to = to + 1;
        end
        chk(sec_read === 1'b0, "C05c");        // 扇区结束时把总线还回去

        //-------------------------------------------------- C06 水位回落再要货
        to = 0;
        while ((b_req === 1'b0) && (to < 60000)) begin
            @(posedge clk); to = to + 1;
        end
        chk(b_req === 1'b1, "C06a");
        chk(level < 775,   "C06b");

        //-------------------------------------------------- C07 跳格
        bad = 0;
        @(negedge clk);
        jump = 1'b1; jump_cell = 3'd3;
        @(negedge clk);
        jump = 1'b0;
        for (to = 0; to < 30000; to = to + 1) @(posedge clk);
        chk(seen_6625 === 1'b1, "C07a");       // 1000 + 3*1875 = 6625
        chk(bad == 0, "C07b");

        //-------------------------------------------------- C08 越界回退
        // audio_sec_cnt 改成 13000：7*1875=13125，13125+1875 > 13000 → 回退到 1000
        @(negedge clk);
        audio_sec_cnt = 32'd13000;
        jump = 1'b1; jump_cell = 3'd7;
        @(negedge clk);
        jump = 1'b0;
        to = 0;
        while ((sec_addr != 32'd1000) && (to < 30000)) begin
            @(posedge clk); to = to + 1;
        end
        chk(to < 30000, "C08a");

        //-------------------------------------------------- C09 回卷
        wrap_en = 1'b1;
        @(negedge clk);
        audio_sec_cnt = 32'd2;                 // 只有 2 个扇区
        jump = 1'b1; jump_cell = 3'd0;
        @(negedge clk);
        jump = 1'b0;
        for (to = 0; to < 30000; to = to + 1) @(posedge clk);
        chk(seen_1001      === 1'b1, "C09a");
        chk(seen_back1000  === 1'b1, "C09b");  // 1001 之后回到 1000
        chk(bad == 0,               "C09c");

        //-------------------------------------------------- C10 掉卡立刻安静
        @(negedge clk);
        sd_init_done = 0;
        repeat (20) @(posedge clk);
        chk(b_req    === 1'b0, "C10a");
        chk(sec_read === 1'b0, "C10b");

        //-------------------------------------------------- 结论
        if (n_ok == n_chk)
            $display("### RESULT tb_audio_stream : PASS  (%0d/%0d) ###", n_ok, n_chk);
        else
            $display("### RESULT tb_audio_stream : FAIL  (%0d/%0d) ###", n_ok, n_chk);
        $finish;
    end

    initial begin
        #50_000_000;
        $display("### RESULT tb_audio_stream : FAIL  (超时) ###");
        $finish;
    end

endmodule
