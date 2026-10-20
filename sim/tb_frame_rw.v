//============================================================================
// tb_frame_rw.v  ——  帧缓存链路（frame_read_write = 写FIFO + 读FIFO + 两套状态机）
//---------------------------------------------------------------------------
// 被测对象：
//   frame_read_write
//     ├─ wfifo_32_32_512   异步写 FIFO（写侧 write_clk / 读侧 mem_clk）
//     ├─ frame_fifo_write  写突发状态机（含本项目的 WRITE_V_FLIP 地址重映射）
//     ├─ rfifo_32_32_512   异步读 FIFO
//     └─ frame_fifo_read   读突发状态机
//
// 为什么要仿真它：
//   ① WRITE_V_FLIP 是【本项目自己加的改动】（BMP 是自下而上存的，写 SDRAM 时
//      要把行序翻过来）。地址映射一旦算错，屏幕上就是黑屏/错行，必须验。
//   ② 双缓冲：write_addr_index / read_addr_index 选 BUF0 / BUF1，选错就串帧。
//   ③ 一帧数据量巨大，靠人眼看波形根本看不出来丢字/重复。
//
// 怎么验：
//   · 挂一个【行为级 SDRAM】：App_wr_en 时写进去并记录地址，App_rd_en 时
//     延迟 LAT 拍把数据吐出来（Sdr_rd_en + Sdr_rd_dout）。
//   · 用一个小帧（FRAME_WIDTH=8, FRAME_HEIGHT=4 → 32 个像素）跑完整的
//     "写一整帧 → 读一整帧"，既不慢又能把 V_FLIP 的行翻转逻辑全部覆盖。
//   · 期望地址：流里的第 i 个像素应落在 (FH-1-i/FW)*FW + (i%FW)。
//
// 注意：为了不改变设计里的位宽关系（避免一堆位宽告警），ADDR_BITS 仍取 21，
//       只把 FRAME_WIDTH/FRAME_HEIGHT/BURST_SIZE 缩小。
//
// 怎么跑（在 sim 目录下，用 Git Bash）：
//   ./run_iverilog.sh frame
//============================================================================
`timescale 1ns / 1ps

//============================================================ 行为级 SDRAM
module sdr_beh #(
    parameter ADDR_BITS = 21,
    parameter DATA_BITS = 32,
    parameter LAT       = 4          // 读命令 → 数据有效 的拍数
)(
    input  wire                  clk,
    input  wire                  rst,
    input  wire                  App_wr_en,
    input  wire [ADDR_BITS-1:0]  App_wr_addr,
    input  wire [DATA_BITS-1:0]  App_wr_din,
    input  wire                  App_rd_en,
    input  wire [ADDR_BITS-1:0]  App_rd_addr,
    output wire                  Sdr_rd_en,
    output wire [DATA_BITS-1:0]  Sdr_rd_dout
);
    reg [DATA_BITS-1:0] mem [0:(1<<ADDR_BITS)-1];

    //--------------------------------------------- 给 tb 看的写记录
    reg [ADDR_BITS-1:0]           wlog  [0:4095];
    reg [DATA_BITS-1:0]           wdlog [0:4095];
    integer                       n_wr = 0;

    //--------------------------------------------- 读流水线
    reg [LAT-1:0]        vld;
    reg [ADDR_BITS-1:0]  ap [0:LAT-1];
    integer              q;

    always @(posedge clk) begin
        if (rst) begin
            n_wr = 0;
            vld  <= {LAT{1'b0}};
            for (q = 0; q < LAT; q = q + 1) ap[q] <= {ADDR_BITS{1'b0}};
        end else begin
            if (App_wr_en) begin
                mem[App_wr_addr] = App_wr_din;
                if (n_wr < 4096) begin
                    wlog[n_wr]  = App_wr_addr;
                    wdlog[n_wr] = App_wr_din;
                end
                n_wr = n_wr + 1;
            end
            // 读命令流水：vld 与地址同步往后推
            vld[0] <= App_rd_en;
            ap[0]  <= App_rd_addr;
            for (q = 1; q < LAT; q = q + 1) begin
                vld[q] <= vld[q-1];
                ap[q]  <= ap[q-1];
            end
        end
    end

    // 数据用组合方式取出，保证与 Sdr_rd_en 同一拍对齐（FIFO 是 we/di 同拍采样）
    assign Sdr_rd_en   = vld[LAT-1];
    assign Sdr_rd_dout = mem[ap[LAT-1]];

endmodule


//============================================================================
module tb_frame_rw;

    localparam integer MEM_BITS   = 32;
    localparam integer AB         = 21;
    localparam integer BURST_BITS = 9;
    localparam integer BURST_SIZE = 8;
    localparam integer FW         = 8;        // 小帧：宽 8
    localparam integer FH         = 4;        //         高 4
    localparam integer NPIX       = FW * FH;  // 32 个像素

    localparam [AB-1:0] BUF0 = {AB{1'b0}} + NPIX*0;
    localparam [AB-1:0] BUF1 = {AB{1'b0}} + NPIX*1;

    //---------------------------------------------------------- 时钟 / 复位
    reg clk = 1'b0;
    always #5 clk = ~clk;              // 100 MHz（与 ext_mem_clk 一致）

    reg rst = 1'b1;

    //---------------------------------------------------------- 被测信号
    reg         Sdr_init_done    = 1'b0;
    reg         Sdr_init_ref_vld = 1'b0;
    reg         Sdr_busy         = 1'b0;

    wire        App_rd_en;
    wire [AB-1:0] App_rd_addr;
    wire        App_wr_en;
    wire [AB-1:0] App_wr_addr;
    wire [MEM_BITS-1:0] App_wr_din;
    wire [3:0]  App_wr_dm;
    wire        Sdr_rd_en;
    wire [MEM_BITS-1:0] Sdr_rd_dout;

    reg         write_req       = 1'b0;
    wire        write_req_ack;
    wire        write_finish;
    reg  [1:0]  write_addr_index= 2'd0;
    reg  [AB-1:0] write_len     = NPIX;
    reg         write_en        = 1'b0;
    reg  [MEM_BITS-1:0] write_data = {MEM_BITS{1'b0}};

    reg         read_req        = 1'b0;
    wire        read_req_ack;
    wire        read_finish;
    reg  [1:0]  read_addr_index = 2'd0;
    reg  [AB-1:0] read_len      = NPIX;
    reg         read_en         = 1'b0;
    wire [MEM_BITS-1:0] read_data;

    frame_read_write #(
        .MEM_DATA_BITS   (MEM_BITS  ),
        .READ_DATA_BITS  (MEM_BITS  ),
        .WRITE_DATA_BITS (MEM_BITS  ),
        .ADDR_BITS       (AB        ),
        .BURST_BITS      (BURST_BITS),
        .BURST_SIZE      (BURST_SIZE),
        .WRITE_V_FLIP    (1         ),
        .FRAME_WIDTH     (FW        ),
        .FRAME_HEIGHT    (FH        )
    ) dut (
        .rst              (rst              ),
        .mem_clk          (clk              ),
        .Sdr_init_done    (Sdr_init_done    ),
        .Sdr_init_ref_vld (Sdr_init_ref_vld ),
        .Sdr_busy         (Sdr_busy         ),

        .App_rd_en        (App_rd_en        ),
        .App_rd_addr      (App_rd_addr      ),
        .Sdr_rd_en        (Sdr_rd_en        ),
        .Sdr_rd_dout      (Sdr_rd_dout      ),

        .read_clk         (clk              ),
        .read_req         (read_req         ),
        .read_req_ack     (read_req_ack     ),
        .read_finish      (read_finish      ),
        .read_addr_0      (BUF0             ),
        .read_addr_1      (BUF1             ),
        .read_addr_2      ({AB{1'b0}}       ),
        .read_addr_3      ({AB{1'b0}}       ),
        .read_addr_index  (read_addr_index  ),
        .read_len         (read_len         ),
        .read_en          (read_en          ),
        .read_data        (read_data        ),

        .App_wr_en        (App_wr_en        ),
        .App_wr_addr      (App_wr_addr      ),
        .App_wr_din       (App_wr_din       ),
        .App_wr_dm        (App_wr_dm        ),

        .write_clk        (clk              ),
        .write_req        (write_req        ),
        .write_req_ack    (write_req_ack    ),
        .write_finish     (write_finish     ),
        .write_addr_0     (BUF0             ),
        .write_addr_1     (BUF1             ),
        .write_addr_2     ({AB{1'b0}}       ),
        .write_addr_3     ({AB{1'b0}}       ),
        .write_addr_index (write_addr_index ),
        .write_len        (write_len        ),
        .write_en         (write_en         ),
        .write_data       (write_data       )
    );

    sdr_beh #(
        .ADDR_BITS (AB        ),
        .DATA_BITS (MEM_BITS  ),
        .LAT       (4         )
    ) u_sdr (
        .clk         (clk         ),
        .rst         (rst         ),
        .App_wr_en   (App_wr_en   ),
        .App_wr_addr (App_wr_addr ),
        .App_wr_din  (App_wr_din  ),
        .App_rd_en   (App_rd_en   ),
        .App_rd_addr (App_rd_addr ),
        .Sdr_rd_en   (Sdr_rd_en   ),
        .Sdr_rd_dout (Sdr_rd_dout )
    );

    //====================================================================
    // 期望值模型
    //====================================================================
    // 流里第 i 个像素的值
    function [MEM_BITS-1:0] pix;
        input integer i;
        begin
            pix = 32'hA5A5_0000 | (i & 16'hFFFF);
        end
    endfunction

    // 流里第 i 个像素应写到的 SDRAM 地址（V_FLIP：行序翻过来）
    function integer map_addr;
        input integer i;
        integer row, col;
        begin
            row = i / FW;
            col = i % FW;
            map_addr = (FH - 1 - row) * FW + col;
        end
    endfunction

    //====================================================================
    // 检查框架
    //====================================================================
    integer chk_idx  = 0;
    integer fail_cnt = 0;

    task chk;
        input cond;
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

    //====================================================================
    // 激励
    //====================================================================
    integer k, guard, ok;

    task do_write;
        input [1:0] idx;
        integer i;
        begin
            write_addr_index = idx;
            write_len        = NPIX;
            @(negedge clk);
            write_req = 1'b1;
            guard = 0;
            while ((write_req_ack !== 1'b1) && guard < 100000) begin
                @(negedge clk); guard = guard + 1;
            end
            repeat (2) @(negedge clk);
            write_req = 1'b0;
            guard = 0;
            while ((write_req_ack !== 1'b0) && guard < 100000) begin
                @(negedge clk); guard = guard + 1;
            end
            // ★ 关键：S_ACK 结束时才对 FIFO 撤销异步复位（fifo_aclr），而 FIFO
            //   内部要把复位同步到两个时钟域，得等几拍才真正放干净。这段窗口里
            //   写进去的数据会被丢掉。真实设计里数据源是 ebm_reader，它在
            //   write_req_ack 之后还要先读一整扇区 SD 卡数据才发像素（几千拍），
            //   所以天然安全；tb 直接紧接着发数据就必须自己等。
            repeat (20) @(negedge clk);
            // 逐个像素送进去
            for (i = 0; i < NPIX; i = i + 1) begin
                write_en   = 1'b1;
                write_data = pix(i);
                @(negedge clk);
            end
            write_en = 1'b0;
            // 等整帧写完
            guard = 0;
            while ((write_finish !== 1'b1) && guard < 100000) begin
                @(negedge clk); guard = guard + 1;
            end
            @(negedge clk);
        end
    endtask

    reg [MEM_BITS-1:0] rbuf [0:NPIX-1];

    task do_read;
        input [1:0] idx;
        integer n;
        begin
            read_addr_index = idx;
            read_len        = NPIX;
            @(negedge clk);
            read_req = 1'b1;
            guard = 0;
            while ((read_req_ack !== 1'b1) && guard < 100000) begin
                @(negedge clk); guard = guard + 1;
            end
            repeat (2) @(negedge clk);
            read_req = 1'b0;
            guard = 0;
            while ((read_req_ack !== 1'b0) && guard < 100000) begin
                @(negedge clk); guard = guard + 1;
            end
            // 等整帧读进 FIFO
            guard = 0;
            while ((read_finish !== 1'b1) && guard < 100000) begin
                @(negedge clk); guard = guard + 1;
            end
            @(negedge clk);
            // 把 NPIX 个字抽出来
            read_en = 1'b1;
            for (n = 0; n < NPIX; n = n + 1) begin
                @(negedge clk);
                rbuf[n] = read_data;
            end
            read_en = 1'b0;
            @(negedge clk);
        end
    endtask

    //====================================================================
    // 主流程
    //====================================================================
    initial begin
        $timeformat(-9, 0, " ns", 12);
        $display("==================================================");
        $display(" tb_frame_rw : 帧缓存链路（V_FLIP 地址映射 + 双缓冲 + 读写整帧）");
        $display(" 小帧 %0dx%0d = %0d 像素，BURST_SIZE=%0d，ADDR_BITS=%0d",
                 FW, FH, NPIX, BURST_SIZE, AB);
        $display("==================================================");

        rst = 1'b1;
        repeat (10) @(negedge clk);
        rst = 1'b0;
        repeat (5) @(negedge clk);
        Sdr_init_done = 1'b1;
        repeat (5) @(negedge clk);

        //============================================== 写 BUF0
        $display("");
        $display("---------------- 写一整帧到 BUF0（index=0） ----------------");
        do_write(2'd0);

        $display("        实际写 %0d 次；SDRAM 里前 8 个地址的内容：", u_sdr.n_wr);
        for (k = 0; k < 8; k = k + 1)
            $display("          mem[%0d] = %08h", k, u_sdr.mem[BUF0 + k]);

        chk(u_sdr.n_wr === NPIX, "C01-write-count-equals-frame-pixels");

        ok = 1;
        for (k = 0; k < NPIX; k = k + 1)
            if (u_sdr.mem[BUF0 + k] !== pix(map_addr(k))) ok = 0;
        if (ok !== 1) begin
            $display("        V_FLIP 地址映射不符，逐像素对照：");
            for (k = 0; k < NPIX; k = k + 1)
                $display("          addr[%0d]=%08h 期望 %08h",
                         BUF0 + k, u_sdr.mem[BUF0 + k], pix(map_addr(k)));
        end
        chk(ok === 1, "C02-vflip-address-mapping-correct");

        // 写地址必须全部落在 BUF0 区间内
        ok = 1;
        for (k = 0; k < u_sdr.n_wr && k < 4096; k = k + 1)
            if (u_sdr.wlog[k] < BUF0 || u_sdr.wlog[k] >= BUF0 + NPIX) ok = 0;
        chk(ok === 1, "C03-all-write-addr-inside-BUF0");

        // 每一行的首地址应当逐行往上翻
        $display("        行首地址：%0d %0d %0d %0d",
                 BUF0+u_sdr.wlog[0], BUF0+u_sdr.wlog[FW],
                 BUF0+u_sdr.wlog[2*FW], BUF0+u_sdr.wlog[3*FW]);
        chk(u_sdr.wlog[0]        === BUF0 + (FH-1)*FW &&
            u_sdr.wlog[FW]       === BUF0 + (FH-2)*FW &&
            u_sdr.wlog[2*FW]     === BUF0 + (FH-3)*FW &&
            u_sdr.wlog[3*FW]     === BUF0 + (FH-4)*FW,
            "C04-row-start-address-flipped");

        //============================================== 读 BUF0
        $display("");
        $display("---------------- 从 BUF0 读回一整帧（index=0） ----------------");
        do_read(2'd0);

        ok = 1;
        for (k = 0; k < NPIX; k = k + 1)
            if (rbuf[k] !== pix(map_addr(k))) ok = 0;
        if (ok !== 1) begin
            $display("        读回的数据（打印 8 个）：");
            for (k = 0; k < 8; k = k + 1)
                $display("          rbuf[%0d]=%08h 期望 %08h",
                         k, rbuf[k], pix(map_addr(k)));
        end
        chk(ok === 1, "C05-read-back-data-matches-frame");

        //============================================== 写 BUF1
        $display("");
        $display("---------------- 写一整帧到 BUF1（index=1） ----------------");
        do_write(2'd1);

        ok = 1;
        for (k = 0; k < NPIX; k = k + 1)
            if (u_sdr.mem[BUF1 + k] !== pix(map_addr(k))) ok = 0;
        chk(ok === 1, "C06-BUF1-data-correct");

        // BUF0 不能被破坏（双缓冲互不干扰）
        ok = 1;
        for (k = 0; k < NPIX; k = k + 1)
            if (u_sdr.mem[BUF0 + k] !== pix(map_addr(k))) ok = 0;
        chk(ok === 1, "C07-BUF0-still-intact-after-BUF1-write");

        // 第二帧的写地址必须全部落在 BUF1 区间内（第 1 帧的 32 条记录跳过）
        ok = 1;
        for (k = NPIX; k < NPIX*2 && k < 4096; k = k + 1)
            if (u_sdr.wlog[k] < BUF1 || u_sdr.wlog[k] >= BUF1 + NPIX) ok = 0;
        chk(ok === 1, "C08-all-write-addr-inside-BUF1");

        //============================================== 读 BUF1
        $display("");
        $display("---------------- 从 BUF1 读回一整帧（index=1） ----------------");
        do_read(2'd1);

        ok = 1;
        for (k = 0; k < NPIX; k = k + 1)
            if (rbuf[k] !== pix(map_addr(k))) ok = 0;
        chk(ok === 1, "C09-BUF1-read-back-correct");

        //============================================== 收尾
        $display("");
        $display("        SDRAM 累计被写入 %0d 个字（两帧共 %0d）", u_sdr.n_wr, 2*NPIX);
        chk(u_sdr.n_wr === 2*NPIX, "C10-two-frames-written-in-total");

        $display("");
        $display("==================================================");
        $display("[%0t] 仿真结束：通过 %0d 项，失败 %0d 项",
                 $time, chk_idx - fail_cnt, fail_cnt);
        $display("==================================================");
        $display("### RESULT tb_frame_rw : %0s  (%0d/%0d) ###",
                 (fail_cnt == 0) ? "PASS" : "FAIL", chk_idx - fail_cnt, chk_idx);
        $finish;
    end

    initial begin
        #5_000_000;
        $display("### RESULT tb_frame_rw : FAIL  (超时) ###");
        $finish;
    end

endmodule
