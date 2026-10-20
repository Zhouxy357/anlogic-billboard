//============================================================================
// tb_sd_arbiter.v  ——  SD 卡读通道仲裁器自检
//---------------------------------------------------------------------------
// 验证点：
//   C01 复位后总线归 A
//   C02 A 空闲时 B 请求，下一拍就拿到总线
//   C03 A 正在读扇区时 B 请求，必须等扇区结束（c_end）才切换 —— 中途不换人
//   C04 B 拿到总线后，即使跨过多个 c_end 也不还给 A（补满才还）
//   C05 B 撤掉 b_req 后，在下一个 c_end 归还 A
//   C06 数据分发门控：A 占用时 a_valid 出、b_valid 不出；反之亦然
//   C07 地址多路：c_addr 跟随当前主人
//   C08 c_end 那一拍仍归属旧主人（边沿归属不能错）
//============================================================================
`timescale 1ns / 1ps

module tb_sd_arbiter;

    reg         clk, rst;
    reg         a_req, b_req, b_rd;
    reg  [31:0] a_addr, b_addr;
    wire [7:0]  a_data, b_data;
    wire        a_valid, b_valid, a_end, b_end;
    wire        c_req;
    wire [31:0] c_addr;
    reg  [7:0]  c_data;
    reg         c_valid, c_end;

    integer n_chk, n_ok;

    sd_arbiter dut (
        .clk     (clk),
        .rst     (rst),
        .a_req   (a_req),
        .a_addr  (a_addr),
        .a_data  (a_data),
        .a_valid (a_valid),
        .a_end   (a_end),
        .b_req   (b_req),
        .b_rd    (b_rd),
        .b_addr  (b_addr),
        .b_data  (b_data),
        .b_valid (b_valid),
        .b_end   (b_end),
        .c_req   (c_req),
        .c_addr  (c_addr),
        .c_data  (c_data),
        .c_valid (c_valid),
        .c_end   (c_end)
    );

    always begin #5 clk = 1'b1; #5 clk = 1'b0; end

    task chk;
        input cond;
        input [1023:0] name;
        begin
            n_chk = n_chk + 1;
            if (cond) n_ok = n_ok + 1;
            else      $display("### FAIL idx=%0d %0s  (t=%0t)", n_chk, name, $time);
        end
    endtask

    // 模拟卡：吐一个扇区（发 3 拍数据 + 1 拍 end）
    task sect;
        begin
            c_valid = 1'b1; c_data = 8'hAA; c_end = 1'b0;
            @(posedge clk); #1;
            c_data = 8'hBB;
            @(posedge clk); #1;
            c_data = 8'hCC; c_end = 1'b1;      // 这一拍 end 与末字节同时有效
            @(posedge clk); #1;
            c_valid = 1'b0; c_end = 1'b0;
            @(posedge clk); #1;
        end
    endtask

    initial begin
        n_chk = 0; n_ok = 0;
        clk = 0; rst = 1;
        a_req = 0; a_addr = 32'd100; b_req = 0; b_rd = 0; b_addr = 32'd900;
        c_data = 0; c_valid = 0; c_end = 0;

        $display("");
        $display("  ---- sd_arbiter : 读通道仲裁 ----");

        repeat (3) @(posedge clk);
        rst = 0;
        repeat (2) @(posedge clk);

        //-------------------------------------------------- C01 复位后归 A
        chk(c_req === 1'b0, "C01a");           // a_req=0 → 无请求

        //-------------------------------------------------- C02 A 空闲 → B 立刻拿到
        b_req = 1'b1; b_rd = 1'b1;
        @(posedge clk); #1;
        chk(c_req === 1'b1, "C02a");
        chk(c_addr === 32'd900, "C02b");       // 地址跟随 B

        //-------------------------------------------------- C04 B 占用期间跨多个 end 不还
        sect;
        chk(c_req === 1'b1, "C04a");
        sect;
        chk(c_req === 1'b1, "C04b");
        sect;
        chk(c_req === 1'b1, "C04c");

        //-------------------------------------------------- C06/C07 B 占用时门控与地址
        a_req = 1'b1; a_addr = 32'd100;        // A 同时开始要
        @(posedge clk); #1;
        c_valid = 1'b1; c_data = 8'h5A;
        @(posedge clk); #1;
        chk(b_valid === 1'b1, "C06a");         // B 拿数据
        chk(a_valid === 1'b0, "C06b");         // A 拿不到
        chk(c_addr === 32'd900, "C07a");       // 地址仍是 B 的
        c_valid = 1'b0;
        @(posedge clk); #1;

        //-------------------------------------------------- C05 撤 b_req → 归还 A
        b_req = 1'b0;                          // 但 b_rd 还高（正在读扇区中途）
        @(posedge clk); #1;
        chk(c_addr === 32'd900, "C05a");       // 扇区没结束不能换人
        c_end = 1'b1;
        @(posedge clk); #1;
        c_end = 1'b0;
        chk(c_req === 1'b1, "C05b");           // 下一拍已经是 A 了
        chk(c_addr === 32'd100, "C05c");
        b_rd = 1'b0;

        //-------------------------------------------------- C03/C08 A 读扇区中途 B 抢不到
        // 此时 A 占用，开始一个扇区
        c_valid = 1'b1; c_data = 8'h11;
        @(posedge clk); #1;
        chk(a_valid === 1'b1, "C06c");         // A 拿数据
        chk(b_valid === 1'b0, "C06d");
        b_req = 1'b1; b_rd = 1'b1;             // B 中途来抢
        @(posedge clk); #1;
        chk(c_addr === 32'd100, "C03a");       // 必须还在 A
        chk(c_req === 1'b1, "C03b");
        // 扇区结束那一拍：end 仍归 A（边沿归属）
        c_end = 1'b1;
        #1;
        chk(a_end === 1'b1, "C08a");
        chk(b_end === 1'b0, "C08b");
        @(posedge clk); #1;
        c_end = 1'b0; c_valid = 1'b0;
        // 下一拍 B 接管
        chk(c_addr === 32'd900, "C03c");
        chk(c_req === 1'b1, "C03d");

        //-------------------------------------------------- 结论
        if (n_ok == n_chk)
            $display("### RESULT tb_sd_arbiter : PASS  (%0d/%0d) ###", n_ok, n_chk);
        else
            $display("### RESULT tb_sd_arbiter : FAIL  (%0d/%0d) ###", n_ok, n_chk);
        $finish;
    end

    initial begin
        #200_000;
        $display("### RESULT tb_sd_arbiter : FAIL  (超时) ###");
        $finish;
    end

endmodule
