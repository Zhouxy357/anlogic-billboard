//============================================================================
// sd_card_model.v  ——  SD/TF 卡（SPI 模式）行为模型，专给本工程的 testbench 用
//---------------------------------------------------------------------------
// 为什么需要它：
//   sd_card_cmd / sd_card_sec_read_write / sd_card_top 是"协议栈"，光看波形
//   看不出对错。必须有一个会应答的"假卡"，把命令收下来、把响应和数据发回去，
//   才能真正验证初始化序列、扇区读写、错误处理。
//
// 只实现本工程用到的那部分协议：
//   收：CMD0(0) CMD8(8) CMD55(55) ACMD41(41) CMD16(16) CMD17(17) CMD24(24)
//   发：R1（1 字节）、R7（CMD8 后 4 字节）、数据令牌 0xFE + 512 字节 + 2 字节 CRC、
//       写数据响应 0x05 + 若干 0xFF（busy）
//
// 三个关键设计：
//   ① 位级：DCLK 上升沿采 MOSI、下降沿换 MISO（CPOL=1/CPHA=1，与本工程一致）；
//   ② 字节级：一个字节收完 → 交给"协议引擎"决定下一个字节发什么；
//   ③ 用一条【发送队列 txq】统一表达响应序列 —— 响应就是"往队列里塞字节"，
//      引擎每收一个字节就从队列头取一个发出去。队列空了就发 0xFF。
//      这样"R1 之后隔几拍再发数据令牌"这种时序天然就对，不会漏字节。
//
// 给 tb 看的接口（层次引用）：
//   cmd_log[i]  收到的第 i 条命令号（按顺序）
//   n_rx_cmd    一共收到几条命令
//   last_arg    最近一条命令的参数（CMD17/24 就是扇区号）
//   rd_mem[]    读数据源（tb 预置）
//   wr_mem[]    卡收到的写数据（tb 检查）
//   acmd41_busy 前几次 ACMD41 故意回"忙"，用来逼出重试分支（tb 可改）
//============================================================================

module sd_card_model #(
    parameter integer NBYTE = 512
)(
    input  wire sys_clk,
    input  wire rst,
    input  wire DCLK,
    input  wire MOSI,
    input  wire nCS,                // 片选（SD 协议要求命令必须在 CS 低电平期间发）
    output reg  MISO
);

    //------------------------------------------------ 存储器
    reg [7:0] rd_mem [0:NBYTE-1];       // 读数据源（tb 预置）
    reg [7:0] wr_mem [0:NBYTE-1];       // 收到的写数据

    //------------------------------------------------ 发送队列
    reg [7:0] txq [0:1400];
    integer   head = 0;
    integer   tail = 0;

    //------------------------------------------------ 位级
    reg       dclk_d  = 1'b0;
    reg       started  = 1'b0;      // 是否已经"醒"过来（丢掉复位后第一次跳变）
    reg [2:0] bitc    = 3'd0;
    reg [7:0] sh      = 8'h00;
    reg [7:0] tx_sr   = 8'hFF;
    reg [7:0] rx_b    = 8'h00;
    reg       pending = 1'b0;

    //------------------------------------------------ 命令解码
    reg [2:0]  cbyte      = 3'd0;
    reg [5:0]  cmd_idx    = 6'd0;
    reg [31:0] arg_sh     = 32'd0;
    reg [31:0] last_arg   = 32'd0;
    reg [31:0] cur_arg    = 32'd0;      // 本次解码出的参数（阻塞赋值，当拍就能用）
    reg        acmd55_prev= 1'b0;

    // ACMD41 前几次回"忙"(0x01)，之后才回 0x00 —— 用来验证上层的重试逻辑
    reg [3:0]  acmd41_busy = 4'd3;
    reg [3:0]  acmd41_cnt  = 4'd0;

    //------------------------------------------------ 接收模式
    localparam RX_CMD    = 2'd0;
    localparam RX_WRWAIT = 2'd1;    // 等写数据令牌 0xFE
    localparam RX_WRDATA = 2'd2;    // 收 512 字节
    localparam RX_WRCRC  = 2'd3;    // 收 2 字节 CRC

    reg [1:0]  rxmode  = RX_CMD;
    reg [9:0]  wr_idx  = 10'd0;
    reg        wr_crc  = 1'b0;

    //------------------------------------------------ 给 tb 看的统计
    reg [5:0]  cmd_log  [0:31];         // 收到的第 i 条命令号
    reg [31:0] arg_log  [0:31];         // 第 i 条命令的参数（CMD17/24 就是扇区号）
    reg [7:0]  crc_log  [0:31];         // 第 i 条命令的 CRC 字节（第 6 个字节）
    reg [15:0] byte_at_cmd [0:31];      // 第 i 条命令第一个字节之前，已收了多少字节
    reg        cs_low_at_cmd [0:31];    // 第 i 条命令起始时 CS 是否为低
    integer    n_rx_cmd = 0;
    integer    n_rx_byte = 0;           // 一共收到多少字节
    integer    n_cmd_start = 0;
    integer    n_wr_sector = 0;         // 完成的写入次数

    integer    i, k;

    initial begin
        for (i = 0; i < NBYTE; i = i + 1) begin
            rd_mem[i] = 8'h00;
            wr_mem[i] = 8'h00;
        end
        for (i = 0; i < 32; i = i + 1) begin
            cmd_log[i]       = 6'h3F;
            arg_log[i]       = 32'd0;
            crc_log[i]       = 8'd0;
            byte_at_cmd[i]   = 16'd0;
            cs_low_at_cmd[i] = 1'b0;
        end
    end

    //====================================================================
    // 主块：采样 / 发送 / 协议引擎
    //====================================================================
    always @(posedge sys_clk) begin
        dclk_d <= DCLK;

        if (rst) begin
            bitc <= 3'd0; sh <= 8'h00; tx_sr <= 8'hFF; MISO <= 1'b1;
            pending <= 1'b0; cbyte <= 3'd0; rxmode <= RX_CMD;
            started <= 1'b0;
            head = 0; tail = 0; cmd_idx <= 6'd0; arg_sh <= 32'd0;
            acmd55_prev <= 1'b0; acmd41_cnt <= 4'd0;
            wr_idx <= 10'd0; wr_crc <= 1'b0; n_rx_cmd = 0; n_wr_sector = 0;
            n_rx_byte = 0; n_cmd_start = 0;
        end
        else begin

            //========================================================
            // (1) 协议引擎：处理上一拍刚收完的那个字节
            //========================================================
            if (pending) begin
                pending <= 1'b0;

                case (rxmode)
                //---------------- 收命令 ----------------
                RX_CMD: begin
                    if (cbyte == 3'd0) begin
                        // 命令字节 = {01, cmd[5:0]}；0xFF 之类的杂字节直接忽略
                        if (rx_b[7:6] == 2'b01) begin
                            cmd_idx <= rx_b[5:0];
                            arg_sh  <= 32'd0;
                            cbyte   <= 3'd1;
                            if (n_cmd_start < 32) begin
                                byte_at_cmd[n_cmd_start]   = n_rx_byte;
                                cs_low_at_cmd[n_cmd_start] = (nCS === 1'b0);
                            end
                            n_cmd_start = n_cmd_start + 1;
                        end
                    end
                    else if (cbyte <= 3'd4) begin
                        arg_sh <= {arg_sh[23:0], rx_b};
                        cbyte  <= cbyte + 3'd1;
                    end
                    else begin
                        // 第 6 个字节 = CRC，命令收齐 → 决定响应
                        // 注意：前 4 个字节已经在 arg_sh 里攒好了（P0 P1 P2 P3），
                        //       这一拍 arg_sh 就是完整参数，不能再把 CRC 并进去，
                        //       否则参数整体右移一字节（低位变成 CRC）。
                        cbyte   <= 3'd0;
                        cur_arg  = arg_sh;                 // ★ 当拍就用，不能用 last_arg
                        last_arg <= cur_arg;
                        if (n_rx_cmd < 32) begin
                            cmd_log[n_rx_cmd] = cmd_idx;
                            arg_log[n_rx_cmd] = cur_arg;
                            crc_log[n_rx_cmd] = rx_b;        // 第 6 个字节 = CRC
                        end
                        n_rx_cmd = n_rx_cmd + 1;

                        head = 0; tail = 0;                 // 清队列，开始新的响应
                        case (cmd_idx)
                            6'd0: begin                     // CMD0 → R1 = 0x01
                                txq[tail] = 8'h01; tail = tail + 1;
                                acmd55_prev <= 1'b0;
                            end
                            6'd8: begin                     // CMD8 → R1=01 + R7(4字节)
                                txq[tail] = 8'h01; tail = tail + 1;
                                txq[tail] = 8'h00; tail = tail + 1;
                                txq[tail] = 8'h00; tail = tail + 1;
                                txq[tail] = 8'h01; tail = tail + 1;
                                txq[tail] = 8'hAA; tail = tail + 1;
                                acmd55_prev <= 1'b0;
                            end
                            6'd55: begin                    // CMD55 → R1 = 0x01
                                txq[tail] = 8'h01; tail = tail + 1;
                                acmd55_prev <= 1'b1;
                            end
                            6'd41: begin                    // ACMD41
                                if (acmd41_cnt < acmd41_busy) begin
                                    txq[tail] = 8'h01; tail = tail + 1;   // 还在忙
                                    acmd41_cnt <= acmd41_cnt + 4'd1;
                                end
                                else begin
                                    txq[tail] = 8'h00; tail = tail + 1;   // 就绪
                                end
                                acmd55_prev <= 1'b0;
                            end
                            6'd16: begin                    // CMD16(设块长) → R1 = 0x00
                                txq[tail] = 8'h00; tail = tail + 1;
                                acmd55_prev <= 1'b0;
                            end
                            6'd17: begin                    // CMD17(读扇区)
                                txq[tail] = 8'h00; tail = tail + 1;       // R1
                                txq[tail] = 8'hFE; tail = tail + 1;       // 数据令牌
                                // 数据里混入扇区号低 8 位 —— 这样 tb 一看数据
                                // 就知道地址有没有传对
                                for (k = 0; k < NBYTE; k = k + 1) begin
                                    txq[tail] = rd_mem[k] ^ cur_arg[7:0];
                                    tail = tail + 1;
                                end
                                txq[tail] = 8'hFF; tail = tail + 1;       // CRC
                                txq[tail] = 8'hFF; tail = tail + 1;
                                acmd55_prev <= 1'b0;
                            end
                            6'd24: begin                    // CMD24(写扇区)
                                txq[tail] = 8'h00; tail = tail + 1;       // R1
                                rxmode <= RX_WRWAIT;                      // 等令牌
                                wr_idx <= 10'd0; wr_crc <= 1'b0;
                                acmd55_prev <= 1'b0;
                            end
                            default: begin                  // 其它命令 → 非法(0x05)
                                txq[tail] = 8'h05; tail = tail + 1;
                                acmd55_prev <= 1'b0;
                            end
                        endcase
                    end
                end

                //---------------- 等写数据令牌 ----------------
                RX_WRWAIT: begin
                    if (rx_b == 8'hFE) begin
                        rxmode <= RX_WRDATA;
                        wr_idx <= 10'd0;
                    end
                end

                //---------------- 收 512 字节写数据 ----------------
                RX_WRDATA: begin
                    wr_mem[wr_idx] = rx_b;
                    if (wr_idx == NBYTE-1) begin
                        wr_idx <= 10'd0;
                        rxmode <= RX_WRCRC;
                    end
                    else wr_idx <= wr_idx + 10'd1;
                end

                //---------------- 收 2 字节 CRC → 回 0x05 + busy ----------------
                RX_WRCRC: begin
                    if (wr_crc == 1'b1) begin
                        wr_crc <= 1'b0;
                        rxmode <= RX_CMD;
                        n_wr_sector = n_wr_sector + 1;
                        head = 0; tail = 0;
                        txq[tail] = 8'h05; tail = tail + 1;      // 数据被接受
                        txq[tail] = 8'hFF; tail = tail + 1;      // busy
                        txq[tail] = 8'hFF; tail = tail + 1;
                        txq[tail] = 8'hFF; tail = tail + 1;
                    end
                    else wr_crc <= 1'b1;
                end
                endcase
            end

            if (pending) n_rx_byte = n_rx_byte + 1;

            //========================================================
            // (2) 取出下一个要发的字节（队列空就发 0xFF）
            //========================================================
            if (pending) begin
                if (head < tail) begin
                    tx_sr <= txq[head];
                    head  = head + 1;
                end
                else tx_sr <= 8'hFF;
            end

            //========================================================
            // (3) 位级：采 MOSI / 换 MISO
            //========================================================
            if (dclk_d !== DCLK) begin
                if (!started) begin
                    // 复位期间主机把 DCLK 拉在 0，复位一松开它立刻回到空闲电平
                    // （CPOL=1 → 一个 0→1 的跳变）。这不是数据位，必须丢掉，
                    // 否则整个字节的位相位会错开 1 位，收到的全是乱码。
                    started <= 1'b1;
                end
                else if (DCLK === 1'b1) begin
                    // 上升沿：采一位
                    sh <= {sh[6:0], MOSI};
                    if (bitc == 3'd7) begin
                        bitc    <= 3'd0;
                        rx_b    <= {sh[6:0], MOSI};
                        pending <= 1'b1;
                    end
                    else bitc <= bitc + 3'd1;
                end
                else begin
                    // 下降沿：摆出本字节的下一位（MSB 先）
                    MISO <= tx_sr[7];
                    // 本拍引擎刚把新字节装进 tx_sr 时不要再移位，否则会把新字节移跑
                    if (!pending) tx_sr <= {tx_sr[6:0], 1'b0};
                end
            end
        end
    end

endmodule
