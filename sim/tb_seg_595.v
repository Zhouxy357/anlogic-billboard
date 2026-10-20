`timescale 1ns / 1ps
//============================================================================
// tb_seg_595.v —— 74HC595 数码管驱动模块的独立验证
//----------------------------------------------------------------------------
// 测什么：
//   P00 复位后三线全为低电平
//   P01 位选变化后，恰好送出 16 个移位时钟
//   P02 送出的 16 bit 内容正确（段码在前 + 位选转为高有效）
//   P03 一帧只产生 1 个锁存脉冲
//   P04 换一个位选，第二帧内容仍正确（累计 32 个移位时钟 / 2 个锁存）
//   P05 位选不变时不重复发帧（不会空转、不会多余锁存）
//   P06 帧与帧之间 RCLK / SRCLK 保持低电平
//   P07 SEG_SENT_FIRST=0 时字节顺序反过来（参数真的生效）
//   P08 位选低有效 → 高有效的转换正确（只选中 1 位）
//
// 说明：CHK 的标签只用 ASCII（中文经位向量参数在 iverilog 下会乱码），
//       中文解释写在行尾注释里。
//============================================================================

module tb_seg_595;

    reg clk   = 1'b0;
    reg rst_n = 1'b0;
    reg [7:0] sel = 8'hFF;
    reg [7:0] dat = 8'h00;

    wire ser, srclk, rclk;
    wire ser_r, srclk_r, rclk_r;

    // CLK_FREQ/SCLK_FREQ = 50 → HALF = 25 拍，仿真快
    seg_595 #(
        .CLK_FREQ       (50),
        .SCLK_FREQ      (1),
        .SEG_SENT_FIRST (1'b1),
        .DIGIT_POLARITY (1'b0)
    ) dut (
        .clk       (clk),
        .rst_n     (rst_n),
        .seg_sel_n (sel),
        .seg_data  (dat),
        .ser       (ser),
        .srclk     (srclk),
        .rclk      (rclk)
    );

    // 参数取反的对照实例：段码后送
    seg_595 #(
        .CLK_FREQ       (50),
        .SCLK_FREQ      (1),
        .SEG_SENT_FIRST (1'b0),
        .DIGIT_POLARITY (1'b0)
    ) dut_r (
        .clk       (clk),
        .rst_n     (rst_n),
        .seg_sel_n (sel),
        .seg_data  (dat),
        .ser       (ser_r),
        .srclk     (srclk_r),
        .rclk      (rclk_r)
    );

    //------------------------------------------------------------------------
    // 时钟
    //------------------------------------------------------------------------
    always #5 clk = ~clk;

    //------------------------------------------------------------------------
    // 采集：在 SRCLK 上升沿把 SER 串成 16 bit
    //------------------------------------------------------------------------
    reg [15:0] cap   = 16'd0;
    reg [15:0] cap_r = 16'd0;
    integer nb    = 0;
    integer nb_r  = 0;
    integer nlat  = 0;
    integer nlat_r= 0;

    always @(posedge srclk) begin
        cap <= {cap[14:0], ser};
        nb  <= nb + 1;
    end

    always @(posedge srclk_r) begin
        cap_r <= {cap_r[14:0], ser_r};
        nb_r  <= nb_r + 1;
    end

    always @(posedge rclk)   nlat   <= nlat   + 1;
    always @(posedge rclk_r) nlat_r <= nlat_r + 1;

    //------------------------------------------------------------------------
    // 打分
    //------------------------------------------------------------------------
    integer pass = 0;
    integer fail = 0;

    task chk(input cond, input [511:0] name);
        begin
            if (cond) begin
                pass = pass + 1;
                $display("  [PASS] %0s", name);
            end
            else begin
                fail = fail + 1;
                $display("  [FAIL] %0s", name);
            end
        end
    endtask

    task wait_latch;
        begin
            @(posedge rclk);
            repeat (3) @(posedge clk);
        end
    endtask

    //------------------------------------------------------------------------
    // 主流程
    //------------------------------------------------------------------------
    initial begin
        $display("==== tb_seg_595 start ====");

        rst_n = 1'b0;
        sel   = 8'hFF;
        dat   = 8'h00;
        repeat (10) @(posedge clk);
        rst_n = 1'b1;
        repeat (10) @(posedge clk);

        // P00 复位后三线全低
        chk(ser === 1'b0 && srclk === 1'b0 && rclk === 1'b0, "P00 idle-low-after-reset");
        chk(nlat === 0, "P00b no-spurious-latch");

        // ---------------- 第一帧：位选 digit0，段码 0 ----------------
        // seg_scan 低有效位选：bit0 = 0 表示选中第 1 位 → 8'hFE
        // 段码 8'hC0 = 共阳数码管显示 "0"
        sel = 8'hFE;
        dat = 8'hC0;
        wait_latch;

        // 期望：先送段码 8'hC0，再送位选（取反后 8'h01）→ 16'hC001
        chk(nb   === 16,       "P01 frame1-16-shift-clocks");
        chk(cap  === 16'hC001, "P02 frame1-payload");
        chk(nlat === 1,        "P03 frame1-one-latch");

        // ---------------- 第二帧：位选 digit1，段码 1 ----------------
        sel = 8'hFD;
        dat = 8'hF9;
        wait_latch;

        chk(nb   === 32,       "P04 frame2-total-32-clocks");
        chk(cap  === 16'hF902, "P04b frame2-payload");
        chk(nlat === 2,        "P04c frame2-two-latches");

        // ---------------- 位选不变 → 不应重复发帧 ----------------
        repeat (300) @(posedge clk);
        chk(nlat  === 2,        "P05 no-refire-when-sel-stable");
        chk(nb    === 32,       "P05b no-extra-shift-clocks");
        chk(rclk  === 1'b0,     "P06 rclk-low-between-frames");
        chk(srclk === 1'b0,     "P06b srclk-low-between-frames");

        // ---------------- 对照实例：字节顺序反了 ----------------
        // 同一帧（sel=0xFD, dat=0xF9）→ 期望 {位选, 段码} = 16'h02F9
        chk(nb_r   === 32,       "P07 reverse-instance-32-clocks");
        chk(cap_r  === 16'h02F9, "P07b reverse-instance-payload");
        chk(nlat_r === 2,        "P07c reverse-instance-two-latches");

        // ---------------- 位选极性：只选中 1 位 ----------------
        // cap 低位 8 位是位选字节，popcount 必须等于 1
        chk(cap[7:0] === 8'h02, "P08 digit-onehot");

        // ---------------- 汇总 ----------------
        $display("");
        if (fail == 0)
            $display("### RESULT tb_seg_595 : PASS (%0d/%0d) ###", pass, pass + fail);
        else
            $display("### RESULT tb_seg_595 : FAIL (%0d/%0d) ###", pass, pass + fail);
        $display("==== tb_seg_595 end ====");
        $finish;
    end

    // 超时保护：50us 还没跑完就是卡死了
    initial begin
        #500_000;
        $display("  [FAIL] TIMEOUT");
        $display("### RESULT tb_seg_595 : FAIL (timeout) ###");
        $finish;
    end

endmodule
