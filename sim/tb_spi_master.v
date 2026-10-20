//============================================================================
// tb_spi_master.v  ——  SPI 主机（spi_master）的行为仿真
//---------------------------------------------------------------------------
// 模块干什么：
//   把一个字节按 SPI 时序发出去，同时把 MISO 上的字节收回来（全双工）。
//   一次传输 = 16 个 DCLK 跳变（8 个 SPI 时钟周期），MSB 先发。
//   clk_div 决定速度：DCLK 的【半周期】= clk_div+2 个 sys_clk（官方公式
//   = clk/((clk_div+2)*2)）。CPOL/CPHA 可配，本工程实际用的是
//   CPOL=1 / CPHA=1（SPI 模式 3），所以模式 3 是主测路径，模式 0 一起验。
//
// 怎么验（这是本 tb 的关键）：
//   不是只看波形，而是挂一个【SPI 从机模型】：
//     · 在 DCLK 上升沿采 MOSI（两种模式下主机都在下降沿换数据，上升沿之前
//       数据已经稳了）；
//     · 在 DCLK 下降沿换 MISO（模式 0：MSB 在第一个上升沿之前就摆好；
//       模式 3：MSB 在第一个下降沿才摆出）；
//   于是"主机发出去的字节"和"从机回的字节"两头都能对账。
//
// 三个实例：
//   dut_a  模式 3（CPOL=1/CPHA=1）
//   dut_b  模式 0（CPOL=0/CPHA=0）
//   两实例共用同一套 clk_div 与激励节奏（分相位切换）。
//
// 怎么跑（在 sim 目录下，用 Git Bash）：
//   ./run_iverilog.sh spi
//============================================================================
`timescale 1ns / 1ps

//============================================================ SPI 从机模型
module spi_slave_model #(
    parameter integer MODE3 = 1        // 1 = CPOL1/CPHA1，0 = CPOL0/CPHA0
)(
    input  wire       sys_clk,
    input  wire       rst,
    input  wire       DCLK,
    input  wire       MOSI,
    output reg        MISO,
    input  wire [7:0] tx_byte,         // 从机要回给主机的字节
    input  wire       load,            // 一次传输前拉高 1 拍，把它装进去
    output reg [7:0]  rx_byte          // 从机从 MOSI 收到的字节
);
    reg       dclk_d    = 1'b0;
    reg [7:0] sr        = 8'h00;
    reg       m3_loaded = 1'b0;
    reg [7:0] rx        = 8'h00;

    always @(posedge sys_clk) begin
        dclk_d <= DCLK;

        if (rst) begin
            sr = 8'h00; rx = 8'h00; m3_loaded = 1'b0;
            MISO = 1'b0; rx_byte <= 8'h00;
        end else begin
            if (load) begin
                sr        = tx_byte;
                rx        = 8'h00;
                m3_loaded = 1'b0;
                MISO      = tx_byte[7];      // 模式 0：MSB 必须在第一个上升沿前就摆好
            end else if (dclk_d !== DCLK) begin
                if (DCLK === 1'b1) begin
                    // 上升沿：主机/从机都在这条沿采数据
                    rx = {rx[6:0], MOSI};
                end else begin
                    // 下降沿：从机换下一位 MISO
                    if (MODE3 != 0 && !m3_loaded) begin
                        sr        = tx_byte;      // 模式 3：MSB 在第一个下降沿摆出
                        m3_loaded = 1'b1;
                    end else begin
                        sr = {sr[6:0], 1'b0};
                    end
                    MISO = sr[7];
                end
            end
            rx_byte <= rx;
        end
    end
endmodule

//============================================================ DCLK 监视器
module dclk_monitor (
    input wire sys_clk,
    input wire res,
    input wire dclk
);
    reg       d       = 1'b0;
    integer   edges   = 0;             // 跳变次数（一次传输应为 16）
    integer   gap     = 0;
    integer   min_gap = 999999;
    integer   max_gap = 0;
    integer   started = 0;

    always @(posedge sys_clk) begin
        d <= dclk;
        if (res) begin
            edges = 0; gap = 0; started = 0;
            min_gap = 999999; max_gap = 0;
        end else begin
            if (d !== dclk) begin
                edges = edges + 1;
                if (started) begin
                    if (gap < min_gap) min_gap = gap;
                    if (gap > max_gap) max_gap = gap;
                end
                started = 1;
                gap     = 1;           // 本拍算第 1 拍 → 记录值正好=两次跳变之间的拍数
            end else if (started) begin
                gap = gap + 1;
            end
        end
    end
endmodule

//============================================================================
module tb_spi_master;

    //---------------------------------------------------------- 时钟与复位
    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg rst = 1'b1;

    //---------------------------------------------------------- 实例 A：模式 3
    reg  [15:0] div_a = 16'd3;
    reg         ncs_a = 1'b1;
    reg         req_a = 1'b0;
    reg  [7:0]  din_a = 8'h00;
    wire        ack_a;
    wire [7:0]  dout_a;
    wire        dclk_a, mosi_a, ncs_o_a;
    wire        miso_a;
    reg  [7:0]  tx_a = 8'h00;
    reg         ld_a = 1'b0;
    reg         res_a = 1'b0;

    spi_master dut_a (
        .sys_clk (clk), .rst (rst),
        .nCS (ncs_o_a), .DCLK (dclk_a), .MOSI (mosi_a), .MISO (miso_a),
        .CPOL (1'b1), .CPHA (1'b1), .nCS_ctrl (ncs_a),
        .clk_div (div_a), .wr_req (req_a), .wr_ack (ack_a),
        .data_in (din_a), .data_out (dout_a)
    );

    spi_slave_model #(.MODE3(1)) slv_a (
        .sys_clk (clk), .rst (rst), .DCLK (dclk_a), .MOSI (mosi_a),
        .MISO (miso_a), .tx_byte (tx_a), .load (ld_a), .rx_byte ()
    );

    dclk_monitor mon_a (.sys_clk (clk), .res (res_a), .dclk (dclk_a));

    //---------------------------------------------------------- 实例 B：模式 0
    reg  [15:0] div_b = 16'd1;
    reg         ncs_b = 1'b1;
    reg         req_b = 1'b0;
    reg  [7:0]  din_b = 8'h00;
    wire        ack_b;
    wire [7:0]  dout_b;
    wire        dclk_b, mosi_b, ncs_o_b;
    wire        miso_b;
    reg  [7:0]  tx_b = 8'h00;
    reg         ld_b = 1'b0;
    reg         res_b = 1'b0;

    spi_master dut_b (
        .sys_clk (clk), .rst (rst),
        .nCS (ncs_o_b), .DCLK (dclk_b), .MOSI (mosi_b), .MISO (miso_b),
        .CPOL (1'b0), .CPHA (1'b0), .nCS_ctrl (ncs_b),
        .clk_div (div_b), .wr_req (req_b), .wr_ack (ack_b),
        .data_in (din_b), .data_out (dout_b)
    );

    spi_slave_model #(.MODE3(0)) slv_b (
        .sys_clk (clk), .rst (rst), .DCLK (dclk_b), .MOSI (mosi_b),
        .MISO (miso_b), .tx_byte (tx_b), .load (ld_b), .rx_byte ()
    );

    dclk_monitor mon_b (.sys_clk (clk), .res (res_b), .dclk (dclk_b));

    //---------------------------------------------------------- wr_ack 宽度监视
    reg ack_a_d = 0, ack_b_d = 0;
    integer wide_a = 0, wide_b = 0;

    always @(posedge clk) begin
        ack_a_d <= ack_a;
        ack_b_d <= ack_b;
        // 连续两拍都高 → 宽度 > 1 拍（正常应该恒为 1 拍）
        if (ack_a === 1'b1 && ack_a_d === 1'b1) wide_a = wide_a + 1;
        if (ack_b === 1'b1 && ack_b_d === 1'b1) wide_b = wide_b + 1;
    end

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

    //---------------------------------------------------------- 一次全双工传输
    //   hold_req=0 → ack 后立刻松 req（单字节，sd_card_cmd 就是这么用的）
    //   hold_req=1 → ack 后继续拉住 req + 给从机重装数据 → 自动连发第二个字节
    task xfer_a;
        input [7:0] send;
        input [7:0] resp;
        input       hold_req;
        integer     tt;
        reg         got1, got2;
        begin
            res_a = 1'b1; ld_a = 1'b1; tx_a = resp; ncs_a = 1'b0;
            @(negedge clk);
            res_a = 1'b0; ld_a = 1'b0;

            req_a = 1'b1; din_a = send;
            got1 = 0; got2 = 0; tt = 0;
            while (tt < 60000 && !(got1 && (hold_req ? got2 : 1'b1))) begin
                @(negedge clk);
                tt = tt + 1;
                if (ack_a === 1'b1) begin
                    if (!got1) begin
                        got1 = 1'b1;
                        if (!hold_req) req_a = 1'b0;
                        else begin
                            ld_a = 1'b1;              // 给第二个字节重装从机数据
                            @(negedge clk);
                            ld_a = 1'b0;
                        end
                    end else if (!got2) begin
                        got2 = 1'b1;
                    end
                end
            end
            req_a = 1'b0;
            repeat (3) @(negedge clk);
            ncs_a = 1'b1;
        end
    endtask

    task xfer_b;
        input [7:0] send;
        input [7:0] resp;
        integer     tt;
        reg         got1;
        begin
            res_b = 1'b1; ld_b = 1'b1; tx_b = resp; ncs_b = 1'b0;
            @(negedge clk);
            res_b = 1'b0; ld_b = 1'b0;

            req_b = 1'b1; din_b = send;
            got1 = 0; tt = 0;
            while (tt < 60000 && !got1) begin
                @(negedge clk);
                tt = tt + 1;
                if (ack_b === 1'b1) begin
                    got1 = 1'b1;
                    req_b = 1'b0;
                end
            end
            req_b = 1'b0;
            repeat (3) @(negedge clk);
            ncs_b = 1'b1;
        end
    endtask

    //=====================================================================
    // 主流程
    //=====================================================================
    initial begin
        $timeformat(-9, 0, " ns", 12);

        //--------------------------------------------- 复位
        // 用 #1002（两个时钟沿之间），避免和时钟块在同一时间步抢
        #1002;
        $display("");
        $display("[%0t] 复位：DCLK / wr_ack 都应为 0", $time);
        $display("        dut_a: dclk=%b ack=%b   dut_b: dclk=%b ack=%b",
                 dclk_a, ack_a, dclk_b, ack_b);
        chk(ack_a === 1'b0 && ack_b === 1'b0, "C01-rst-ack-low");

        rst = 1'b0;
        repeat (4) @(negedge clk);
        $display("        空闲时 DCLK：dut_a=%b（CPOL=1）dut_b=%b（CPOL=0）", dclk_a, dclk_b);
        chk(dclk_a === 1'b1, "C02-mode3-idle-dclk-equals-cpol1");
        chk(dclk_b === 1'b0, "C03-mode0-idle-dclk-equals-cpol0");

        //=========================================== 阶段 1：模式 3，clk_div=3
        $display("");
        $display("[%0t] 阶段 1：模式 3（CPOL=1/CPHA=1），clk_div=3，半周期应为 5 拍", $time);
        div_a = 16'd3;
        xfer_a(8'h5A, 8'hA5, 1'b0);

        $display("        发 5A / 从机回过 A5：dut 收=%02h 从机收=%02h；DCLK 跳变 %0d 次，半周期 %0d..%0d 拍",
                 dout_a, slv_a.rx, mon_a.edges, mon_a.min_gap, mon_a.max_gap);
        chk(slv_a.rx === 8'h5A,               "C04-mode3-slave-got-sent-byte");
        chk(dout_a  === 8'hA5,                "C05-mode3-master-got-response");
        chk(mon_a.edges === 16,               "C06-mode3-16-dclk-edges-per-byte");
        chk(mon_a.min_gap === 5 && mon_a.max_gap === 5, "C07-mode3-half-period-is-clkdiv2");
        chk(dclk_a === 1'b1 && ack_a === 1'b0, "C08-mode3-dclk-back-to-idle");
        chk(wide_a === 0,                     "C09-wr_ack-is-1-cycle-wide");

        //---- 第二次传输（换字节），验证状态机回到 IDLE 后还能再干活 ----
        xfer_a(8'hC3, 8'h3C, 1'b0);
        $display("        第二次：dut 收=%02h 从机收=%02h", dout_a, slv_a.rx);
        chk(slv_a.rx === 8'hC3 && dout_a === 8'h3C, "C10-mode3-second-transfer-ok");

        //---- 拉住 req → 连发两个字节 ----
        $display("");
        $display("[%0t] 阶段 1b：拉住 wr_req 连发两个字节（0x3C / 从机回 0xC3）", $time);
        req_a = 1'b1;
        xfer_a(8'h3C, 8'hC3, 1'b1);
        $display("        连发后：dut 收=%02h 从机收=%02h", dout_a, slv_a.rx);
        chk(slv_a.rx === 8'h3C && dout_a === 8'hC3, "C11-mode3-back-to-back-two-bytes");

        //=========================================== 阶段 2：模式 0，clk_div=1
        $display("");
        $display("[%0t] 阶段 2：模式 0（CPOL=0/CPHA=0），clk_div=1，半周期应为 3 拍", $time);
        div_b = 16'd1;
        xfer_b(8'h96, 8'h69);
        $display("        发 96 / 从机回过 69：dut 收=%02h 从机收=%02h；DCLK 跳变 %0d 次，半周期 %0d..%0d 拍",
                 dout_b, slv_b.rx, mon_b.edges, mon_b.min_gap, mon_b.max_gap);
        chk(slv_b.rx === 8'h96,               "C12-mode0-slave-got-sent-byte");
        chk(dout_b  === 8'h69,                "C13-mode0-master-got-response");
        chk(mon_b.edges === 16,               "C14-mode0-16-dclk-edges-per-byte");
        chk(mon_b.min_gap === 3 && mon_b.max_gap === 3, "C15-mode0-half-period-is-clkdiv2");
        chk(wide_b === 0,                     "C16-mode0-wr_ack-is-1-cycle-wide");

        //=========================================== 阶段 3：真实分频 248
        $display("");
        $display("[%0t] 阶段 3：模式 3 用工程真实分频 clk_div=248（半周期应 250 拍）", $time);
        div_a = 16'd248;
        xfer_a(8'h01, 8'h80, 1'b0);
        $display("        dut 收=%02h 从机收=%02h；DCLK 跳变 %0d 次，半周期 %0d..%0d 拍",
                 dout_a, slv_a.rx, mon_a.edges, mon_a.min_gap, mon_a.max_gap);
        chk(slv_a.rx === 8'h01 && dout_a === 8'h80, "C17-div248-full-duplex-ok");
        chk(mon_a.min_gap === 250 && mon_a.max_gap === 250, "C18-div248-half-period-250");
        chk(mon_a.edges === 16,               "C19-div248-16-dclk-edges");

        //=========================================== 阶段 4：最快分频 clk_div=0
        $display("");
        $display("[%0t] 阶段 4：clk_div=0（最快，半周期 2 拍）", $time);
        div_a = 16'd0;
        xfer_a(8'hAA, 8'h55, 1'b0);
        $display("        dut 收=%02h 从机收=%02h；DCLK 跳变 %0d 次，半周期 %0d..%0d 拍",
                 dout_a, slv_a.rx, mon_a.edges, mon_a.min_gap, mon_a.max_gap);
        chk(slv_a.rx === 8'hAA && dout_a === 8'h55, "C20-div0-full-duplex-ok");
        chk(mon_a.min_gap === 2 && mon_a.max_gap === 2, "C21-div0-half-period-2");
        chk(mon_a.edges === 16,               "C22-div0-16-dclk-edges");

        //=========================================== nCS 直通 + MATLAB 收尾
        ncs_a = 1'b0; repeat (2) @(negedge clk);
        chk(ncs_o_a === 1'b0, "C23-ncs-passthrough-low");
        ncs_a = 1'b1; repeat (2) @(negedge clk);
        chk(ncs_o_a === 1'b1, "C24-ncs-passthrough-high");

        $display("");
        $display("==================================================");
        $display("[%0t] 仿真结束：通过 %0d 项，失败 %0d 项",
                 $time, chk_idx - fail_cnt, fail_cnt);
        $display("==================================================");
        $display("### RESULT tb_spi_master : %0s  (%0d/%0d) ###",
                 (fail_cnt == 0) ? "PASS" : "FAIL", chk_idx - fail_cnt, chk_idx);
        $finish;
    end

    initial begin
        #60_000_000;
        $display("### RESULT tb_spi_master : FAIL  (超时) ###");
        $finish;
    end

endmodule
