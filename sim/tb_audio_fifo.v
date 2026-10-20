//============================================================================
// tb_audio_fifo.v  ——  音频跨时钟域 FIFO 自检
//---------------------------------------------------------------------------
// 验证点：
//   C01 复位后空、满/空标志正确
//   C02 写入后水位上涨、empty 撤销（跨域指针同步生效）
//   C03 读出的数据与写入顺序、数值完全一致
//   C04 写满时 full 拉高、水位 = 深度、继续写不覆盖
//   C05 读空后 empty 拉高
//   C06 指针回卷（写满再读空再写）不错位
//   C07 两个时钟频率差异下（100MHz / 12.288MHz）长期读写的顺序一致性
//============================================================================
`timescale 1ns / 1ps

module tb_audio_fifo;

    localparam integer DATA_W = 16;
    localparam integer AW     = 11;
    localparam integer DEPTH  = (1 << AW);

    reg              wr_clk, rd_clk;
    reg              wr_rst, rd_rst;
    reg              wr_en;
    reg  [DATA_W-1:0] wr_data;
    wire             wr_full;
    wire [AW:0]      wr_level;

    reg              rd_en;
    wire [DATA_W-1:0] rd_data;
    wire             rd_empty;

    integer n_chk, n_ok, i, errs;

    audio_fifo #(.DATA_W(DATA_W), .AW(AW)) dut (
        .wr_clk   (wr_clk),
        .wr_rst   (wr_rst),
        .wr_en    (wr_en),
        .wr_data  (wr_data),
        .wr_full  (wr_full),
        .wr_level (wr_level),
        .rd_clk   (rd_clk),
        .rd_rst   (rd_rst),
        .rd_en    (rd_en),
        .rd_data  (rd_data),
        .rd_empty (rd_empty)
    );

    // 100MHz 写侧 / 12.288MHz 读侧
    // ★ 不用 always #5 clk = ~clk：time 0 会和 initial 里的 clk=0 抢同一个变量，
    //   一旦 always 先执行，clk 会停在 x 上，整条仿真全 x（踩过一次）。
    always begin #5.0  wr_clk = 1'b1; #5.0  wr_clk = 1'b0; end
    always begin #40.7 rd_clk = 1'b1; #40.7 rd_clk = 1'b0; end

    //----------------------------------------------------------- 检查工具
    task chk;
        input cond;
        input [1023:0] name;     // 只传 ASCII 标签
        begin
            n_chk = n_chk + 1;
            if (cond) begin
                n_ok = n_ok + 1;
            end else begin
                $display("### FAIL idx=%0d %0s  (t=%0t)", n_chk, name, $time);
            end
        end
    endtask

    //----------------------------------------------------------- 写入 / 读出
    task wr_burst;                       // 连续写 n 个，值 = base+i
        input integer n;
        input integer base;
        integer k;
        begin
            @(negedge wr_clk);
            for (k = 0; k < n; k = k + 1) begin
                wr_en   = 1'b1;
                wr_data = base + k;
                @(negedge wr_clk);
            end
            wr_en = 1'b0;
        end
    endtask

    task rd_one;                         // 读 1 个，返回读到的值
        output [DATA_W-1:0] v;
        begin
            @(negedge rd_clk);
            rd_en = 1'b1;
            @(posedge rd_clk);
            #1;
            v = rd_data;
            @(negedge rd_clk);
            rd_en = 1'b0;
        end
    endtask

    //----------------------------------------------------------- 主流程
    reg [DATA_W-1:0] v;
    integer k;
    integer bad;

    initial begin
        n_chk = 0; n_ok = 0; bad = 0;
        wr_clk = 0; rd_clk = 0;
        wr_rst = 1; rd_rst = 1;
        wr_en  = 0; wr_data = 0;
        rd_en  = 0;

        $display("");
        $display("  ---- audio_fifo : 跨时钟域样本缓冲 ----");

        //-------------------------------------------------- C01 复位状态
        // ★ 复位必须跨过【慢时钟】的第一个上升沿才算数：
        //   rd_clk 40.7ns 才第一次跳变，如果只等几个 wr_clk 就撤复位，
        //   读侧永远看不到复位（rgray 会一直是 x）。
        repeat (3) @(posedge rd_clk);
        repeat (2) @(posedge wr_clk);
        wr_rst = 0; rd_rst = 0;
        repeat (6) @(posedge wr_clk);
        @(negedge rd_clk); #1;
        chk(rd_empty === 1'b1, "C01a");
        chk(wr_full  === 1'b0, "C01b");
        chk(wr_level === 0,    "C01c");

        //-------------------------------------------------- C02 写入 → 水位
        wr_burst(100, 1000);
        repeat (6) @(posedge wr_clk);     // 等跨域同步
        chk(wr_level === 13'd100, "C02a");
        chk(wr_full  === 1'b0,    "C02b");
        @(negedge rd_clk); /* 同步到读域 */ repeat (3) @(posedge rd_clk); #1;
        chk(rd_empty === 1'b0,    "C02c");

        //-------------------------------------------------- C03 顺序一致
        bad = 0;
        for (k = 0; k < 100; k = k + 1) begin
            rd_one(v);
            if (v !== (1000 + k)) bad = bad + 1;
        end
        chk(bad == 0, "C03a");
        repeat (3) @(posedge rd_clk); #1;
        chk(rd_empty === 1'b1, "C03b");

        //-------------------------------------------------- C04 写满
        wr_burst(DEPTH + 10, 0);          // 故意多写 10 个
        repeat (8) @(posedge wr_clk);
        chk(wr_full === 1'b1, "C04a");
        chk(wr_level === DEPTH[AW:0], "C04b");

        //-------------------------------------------------- C05 读空前 20 个仍然正确
        bad = 0;
        for (k = 0; k < 20; k = k + 1) begin
            rd_one(v);
            if (v !== k[DATA_W-1:0]) bad = bad + 1;
        end
        chk(bad == 0, "C05a");

        //-------------------------------------------------- C06 全部读空 + 指针回卷
        bad = 0;
        for (k = 20; k < DEPTH; k = k + 1) begin
            rd_one(v);
            if (v !== k[DATA_W-1:0]) bad = bad + 1;
        end
        repeat (3) @(posedge rd_clk); #1;
        chk(bad == 0, "C06a");
        chk(rd_empty === 1'b1, "C06b");

        // 回卷后再写再读，指针必须还对
        wr_burst(50, 30000);
        bad = 0;
        for (k = 0; k < 50; k = k + 1) begin
            rd_one(v);
            if (v !== (30000 + k)) bad = bad + 1;
        end
        chk(bad == 0, "C06c");

        //-------------------------------------------------- C07 长期交错读写
        // 写完 300 个立刻读走 300 个，来回 6 轮：检查不丢、不重、不乱序
        bad = 0;
        for (k = 0; k < 6; k = k + 1) begin
            wr_burst(300, k * 1000);
            for (i = 0; i < 300; i = i + 1) begin
                rd_one(v);
                if (v !== (k * 1000 + i)) bad = bad + 1;
            end
        end
        chk(bad == 0, "C07a");

        //-------------------------------------------------- 结论
        if (n_ok == n_chk)
            $display("### RESULT tb_audio_fifo : PASS  (%0d/%0d) ###", n_ok, n_chk);
        else
            $display("### RESULT tb_audio_fifo : FAIL  (%0d/%0d) ###", n_ok, n_chk);
        $finish;
    end

    // 超时保护
    initial begin
        #20_000_000;
        $display("### RESULT tb_audio_fifo : FAIL  (超时) ###");
        $finish;
    end

endmodule
