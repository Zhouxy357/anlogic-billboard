//============================================================================
// tb_sd_card.v  ——  SD 卡读取全链路（sd_card_top）的行为仿真
//---------------------------------------------------------------------------
// 被测对象：
//   sd_card_top 里面串了三块：
//     sd_card_sec_read_write  高层协议（CMD0/8/55/41/16 初始化、CMD17/24 读写）
//     sd_card_cmd             命令层（把 48bit 命令拆成 6 字节发出去、收响应、
//                             收 512 字节数据、写数据令牌 0xFE + 数据 + CRC）
//     spi_master              SPI 位级收发（模式 3）
//   所以这一个 tb 就把 SD 卡那条链一次全测了。
//
// 关键：光看波形看不出对错。必须挂一个【会应答的假卡】sd_card_model：
//   · 收下主机的命令字节，把命令号 / 参数 / CS 状态记录下来；
//   · 按协议把 R1（以及 CMD8 的 R7、CMD17 的 0xFE+512 字节+CRC、
//     CMD24 的 0x05 写响应）发回去；
//   · 故意让前 3 次 ACMD41 回"忙(0x01)"，逼出上层的 CMD55→ACMD41 重试分支。
//
// 为了让 tb 跑得快，把 SPI 低速分频参数从 248 改成 3（协议对错与分频无关，
// 分频公式本身已经由 tb_spi_master 单独验过 3/1/248/0 四档）。高速档保持
// 与真实工程一致 = 0。
//
// 怎么跑（在 sim 目录下，用 Git Bash）：
//   ./run_iverilog.sh sd
//============================================================================
`timescale 1ns / 1ps

module tb_sd_card;

    //====================================================================
    // 时钟与复位（50 MHz，与开发板一致）
    //====================================================================
    reg clk = 1'b0;
    always #10 clk = ~clk;

    reg rst = 1'b1;

    //====================================================================
    // 被测顶层
    //====================================================================
    localparam [15:0] LOW_DIV  = 16'd3;   // 真实工程是 248，这里缩小以便快速仿真
    localparam [15:0] HIGH_DIV = 16'd0;   // 与真实工程一致

    wire        SD_nCS, SD_DCLK, SD_MOSI;
    wire        SD_MISO;

    wire        sd_init_done;
    reg  [31:0] sd_sec_read_addr  = 32'd0;
    reg         sd_sec_read       = 1'b0;
    wire [7:0]  sd_sec_read_data;
    wire        sd_sec_read_data_valid;
    wire        sd_sec_read_end;
    reg         sd_sec_write      = 1'b0;
    reg  [31:0] sd_sec_write_addr = 32'd0;
    reg  [7:0]  sd_sec_write_data = 8'd0;
    wire        sd_sec_write_data_req;
    wire        sd_sec_write_end;

    sd_card_top #(
        .SPI_LOW_SPEED_DIV  (LOW_DIV ),
        .SPI_HIGH_SPEED_DIV (HIGH_DIV)
    ) u_top (
        .clk                    (clk                   ),
        .rst                    (rst                   ),
        .SD_nCS                 (SD_nCS                ),
        .SD_DCLK                (SD_DCLK               ),
        .SD_MOSI                (SD_MOSI               ),
        .SD_MISO                (SD_MISO               ),
        .sd_init_done           (sd_init_done          ),
        .sd_sec_read            (sd_sec_read           ),
        .sd_sec_read_addr       (sd_sec_read_addr      ),
        .sd_sec_read_data       (sd_sec_read_data      ),
        .sd_sec_read_data_valid (sd_sec_read_data_valid),
        .sd_sec_read_end        (sd_sec_read_end       ),
        .sd_sec_write           (sd_sec_write          ),
        .sd_sec_write_addr      (sd_sec_write_addr     ),
        .sd_sec_write_data      (sd_sec_write_data     ),
        .sd_sec_write_data_req  (sd_sec_write_data_req ),
        .sd_sec_write_end       (sd_sec_write_end      )
    );

    //====================================================================
    // 假卡
    //====================================================================
    sd_card_model u_card (
        .sys_clk (clk     ),
        .rst     (rst     ),
        .DCLK    (SD_DCLK ),
        .MOSI    (SD_MOSI ),
        .nCS     (SD_nCS  ),
        .MISO    (SD_MISO )
    );

    //====================================================================
    // 读数据源 / 写数据源
    //   读：rd_mem[k] 预置进假卡，假卡发出去时还会异或扇区号低 8 位，
    //       所以 tb 期望值 = rsrc[k] ^ addr[7:0]，这样地址传错马上能看出来。
    //   写：tb 从 wsrc[] 里按 sd_sec_write_data_req 逐个喂给被测模块。
    //====================================================================
    integer   ii;
    reg [7:0] rsrc [0:511];
    reg [7:0] wsrc [0:511];

    initial begin
        for (ii = 0; ii < 512; ii = ii + 1) begin
            rsrc[ii] = (ii[7:0] ^ 8'h3C) ^ ((ii >= 256) ? 8'h77 : 8'h00);
            wsrc[ii] = (ii[7:0] ^ 8'hA5) ^ ((ii >= 256) ? 8'h11 : 8'h00);
        end
    end

    initial begin
        #1;                                   // 让假卡自己的 initial 先把 rd_mem 清零
        for (ii = 0; ii < 512; ii = ii + 1)
            u_card.rd_mem[ii] = rsrc[ii];
    end

    //---------------------------------------------------- 写数据供给
    //   注意这里必须是【寄存器输出 + 非阻塞取旧指针】，即"下一拍才有效"：
    //   sd_card_cmd 的数据约定就是 block_write_data_rd 拉高的【下一拍】数据才算数
    //   （见 sd_card_cmd 端口注释 "next clock is valid"）。
    reg [8:0] wr_ptr = 9'd0;
    always @(posedge clk) begin
        if (rst) begin
            wr_ptr <= 9'd0;
            sd_sec_write_data <= 8'd0;
        end else begin
            if (sd_sec_write_data_req) wr_ptr <= wr_ptr + 9'd1;
            sd_sec_write_data <= wsrc[wr_ptr];      // 用旧指针 → 天然延迟一拍
        end
    end

    //---------------------------------------------------- 读数据收集
    integer   rd_cnt = 0;
    reg [7:0] rbuf [0:511];
    always @(posedge clk) begin
        if (sd_sec_read_data_valid && rd_cnt < 512) begin
            rbuf[rd_cnt] = sd_sec_read_data;
            rd_cnt = rd_cnt + 1;
        end
    end

    //---------------------------------------------------- 结束脉冲计数
    integer rd_end_cnt = 0;
    integer wr_end_cnt = 0;
    always @(posedge clk) begin
        if (sd_sec_read_end)  rd_end_cnt = rd_end_cnt + 1;
        if (sd_sec_write_end) wr_end_cnt = wr_end_cnt + 1;
    end

    //---------------------------------------------------- 命令错误脉冲计数
    integer err_cnt = 0;
    reg     err_d   = 1'b0;
    always @(posedge clk) begin
        err_d <= u_top.cmd_req_error;
        if (u_top.cmd_req_error && !err_d) err_cnt = err_cnt + 1;
    end

    //---------------------------------------------------- SPI 分频观测
    integer div_low_seen  = 0;
    integer div_high_seen = 0;
    always @(posedge clk) begin
        if (!rst) begin
            if (u_top.sd_card_cmd_m0.clk_div === LOW_DIV)  div_low_seen  = 1;
            if (u_top.sd_card_cmd_m0.clk_div === HIGH_DIV) div_high_seen = 1;
        end
    end

    //====================================================================
    // 检查框架与小工具
    //====================================================================
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

    // 统计前 11 条命令里 CMD55 出现几次
    function integer count55;
        integer n, q;
        begin
            n = 0;
            for (q = 0; q < 11; q = q + 1)
                if (u_card.cmd_log[q] === 6'd55) n = n + 1;
            count55 = n;
        end
    endfunction

    task print_init_cmds;
        begin
            $display("        第 i 条命令 = %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d",
                     u_card.cmd_log[0],  u_card.cmd_log[1],  u_card.cmd_log[2],
                     u_card.cmd_log[3],  u_card.cmd_log[4],  u_card.cmd_log[5],
                     u_card.cmd_log[6],  u_card.cmd_log[7],  u_card.cmd_log[8],
                     u_card.cmd_log[9],  u_card.cmd_log[10]);
        end
    endtask

    //====================================================================
    // 主流程
    //====================================================================
    integer   k, ok, guard, idx17, idx24;
    reg [31:0] addr_rd;
    reg [31:0] addr_wr;

    reg [5:0] exp_cmd [0:10];

    initial begin
        exp_cmd[0]  = 6'd0 ;  exp_cmd[1]  = 6'd8 ;  exp_cmd[2]  = 6'd55;
        exp_cmd[3]  = 6'd41;  exp_cmd[4]  = 6'd55;  exp_cmd[5]  = 6'd41;
        exp_cmd[6]  = 6'd55;  exp_cmd[7]  = 6'd41;  exp_cmd[8]  = 6'd55;
        exp_cmd[9]  = 6'd41;  exp_cmd[10] = 6'd16;
    end

    initial begin
        $timeformat(-9, 0, " ns", 12);
        $display("==================================================");
        $display(" tb_sd_card : SD 卡全链路（读卡器+命令层+SPI 主机）");
        $display(" 低速分频=%0d（真实工程 248，此处缩小以提速），高速分频=%0d",
                 LOW_DIV, HIGH_DIV);
        $display("==================================================");

        //-------------------------------------------------- 复位
        rst = 1'b1;
        repeat (10) @(negedge clk);
        rst = 1'b0;

        $display("");
        $display("[%0t] 等初始化序列跑完（CMD0/8/55/41x4/16）...", $time);

        //-------------------------------------------------- 等 sd_init_done
        guard = 0;
        while ((sd_init_done !== 1'b1) && guard < 400000) begin
            @(posedge clk); guard = guard + 1;
        end
        chk(guard < 400000, "C00-init-done-within-timeout");

        //-------------------------------------------------- 等回到空闲等待态
        guard = 0;
        while ((u_top.sd_card_sec_read_write_m0.state !== 5'd17) && guard < 200000) begin
            @(posedge clk); guard = guard + 1;
        end
        repeat (10) @(posedge clk);
        chk(guard < 200000, "C01-init-returns-to-wait-state");
        $display("[%0t] 初始化完成，共收到 %0d 条命令", $time, u_card.n_rx_cmd);

        //================================================== 初始化序列检查
        $display("");
        $display("---------------- 初始化序列 ----------------");
        print_init_cmds();

        ok = 1;
        for (k = 0; k < 11; k = k + 1)
            if (u_card.cmd_log[k] !== exp_cmd[k]) ok = 0;
        chk(ok === 1, "C02-init-cmd-sequence-(0,8,55,41x4,16)");

        // 上电至少 74 个 SPI 时钟（11 字节 0xFF）才能发第一条命令
        $display("        第一条命令之前收到 %0d 个空字节", u_card.byte_at_cmd[0]);
        chk(u_card.byte_at_cmd[0] >= 16'd11, "C03-power-on-sends-11-idle-bytes");

        // 每条命令的 CS 都应该是低
        ok = 1;
        for (k = 0; k < 11; k = k + 1)
            if (u_card.cs_low_at_cmd[k] !== 1'b1) ok = 0;
        chk(ok === 1, "C04-ncs-low-during-every-command");

        // ACMD41 回忙 → 上层要重试（CMD55 出现 4 次）+ 出现过 cmd_req_error
        $display("        ACMD41 忙重试(CMD55 条数)=%0d，cmd_req_error 脉冲=%0d",
                 count55(), err_cnt);
        chk(err_cnt >= 3,    "C05-acmd41-busy-triggers-error-path");
        chk(count55() === 4, "C06-cmd55-resent-when-busy");

        // 命令参数（CMD0 的 4 个参数本来就是全 0，0x95 是它的 CRC 字节）
        $display("        cmd0 arg=%08h crc=%02h  cmd8 arg=%08h crc=%02h",
                 u_card.arg_log[0], u_card.crc_log[0],
                 u_card.arg_log[1], u_card.crc_log[1]);
        $display("        acmd41 arg=%08h  cmd16 arg=%08h",
                 u_card.arg_log[3], u_card.arg_log[10]);
        chk(u_card.arg_log[0]  === 32'h0000_0000, "C07a-cmd0-arg-all-zero");
        chk(u_card.crc_log[0]  === 8'h95,         "C07b-cmd0-crc-95");
        chk(u_card.crc_log[1]  === 8'h87,         "C07c-cmd8-crc-87");
        chk(u_card.arg_log[1]  === 32'h0000_01AA, "C08-cmd8-arg-voltage-1AA");
        chk(u_card.arg_log[3]  === 32'h4000_0000, "C09-acmd41-hcs-bit-set");
        chk(u_card.arg_log[10] === 32'h0000_0200, "C10-cmd16-block-len-512");

        chk(sd_init_done === 1'b1, "C11-sd-init-done-high");

        // 分频：初始化用低速，进入读写真用后切到高速
        chk(div_low_seen  === 1, "C12-spi-low-div-used-during-init");
        chk(div_high_seen === 1, "C13-spi-high-div-used-after-init");
        chk(u_top.sd_card_cmd_m0.clk_div === HIGH_DIV, "C14-clk-div-0-in-wait-state");

        //================================================== 单扇区读
        $display("");
        $display("---------------- 单扇区读 CMD17 ----------------");
        addr_rd = 32'h0001_2A5C;
        @(negedge clk);
        sd_sec_read_addr <= addr_rd;
        sd_sec_read      <= 1'b1;
        repeat (40) @(negedge clk);
        sd_sec_read      <= 1'b0;

        guard = 0;
        while ((rd_end_cnt === 0) && guard < 300000) begin
            @(posedge clk); guard = guard + 1;
        end
        repeat (10) @(posedge clk);

        // 动态找 CMD17 / CMD24 的位置（别忘了前方可能因为重试多几条命令）
        idx17 = -1;
        for (k = 0; k < 32; k = k + 1)
            if (u_card.cmd_log[k] === 6'd17) begin idx17 = k; k = 32; end

        $display("        读到 %0d 字节，read_end 脉冲 %0d 次；CMD17 在第 %0d 条，参数 = %08h",
                 rd_cnt, rd_end_cnt, idx17,
                 (idx17 >= 0) ? u_card.arg_log[idx17] : 32'hdead_beef);
        chk(rd_end_cnt === 1, "C15-read-end-pulse-once");
        chk(rd_cnt === 512,   "C16-read-512-bytes");
        chk(idx17 >= 0 && u_card.arg_log[idx17] === addr_rd, "C17-cmd17-sector-addr-passed");

        ok = 1;
        for (k = 0; k < 512; k = k + 1)
            if (rbuf[k] !== (rsrc[k] ^ addr_rd[7:0])) ok = 0;
        if (ok !== 1) begin
            $display("        数据不符，前 8 个：");
            for (k = 0; k < 8; k = k + 1)
                $display("          [%0d] got=%02h exp=%02h",
                         k, rbuf[k], rsrc[k] ^ addr_rd[7:0]);
        end
        chk(ok === 1, "C18-read-data-512-bytes-match");

        //================================================== 单扇区写
        $display("");
        $display("---------------- 单扇区写 CMD24 ----------------");
        addr_wr = 32'h0005_7B00;
        @(negedge clk);
        sd_sec_write_addr <= addr_wr;
        sd_sec_write      <= 1'b1;
        repeat (40) @(negedge clk);
        sd_sec_write      <= 1'b0;

        guard = 0;
        while ((wr_end_cnt === 0) && guard < 300000) begin
            @(posedge clk); guard = guard + 1;
        end
        repeat (10) @(posedge clk);

        idx24 = -1;
        for (k = 0; k < 32; k = k + 1)
            if (u_card.cmd_log[k] === 6'd24) begin idx24 = k; k = 32; end

        $display("        卡收到 %0d 次写扇区，write_end 脉冲 %0d 次；CMD24 在第 %0d 条，参数 = %08h",
                 u_card.n_wr_sector, wr_end_cnt, idx24,
                 (idx24 >= 0) ? u_card.arg_log[idx24] : 32'hdead_beef);
        chk(wr_end_cnt === 1,         "C19-write-end-pulse-once");
        chk(u_card.n_wr_sector === 1, "C20-card-accepted-1-sector-write");
        chk(idx24 >= 0 && u_card.arg_log[idx24] === addr_wr, "C21-cmd24-sector-addr-passed");

        ok = 1;
        for (k = 0; k < 512; k = k + 1)
            if (u_card.wr_mem[k] !== wsrc[k]) ok = 0;
        if (ok !== 1) begin
            $display("        写入数据不符，前 8 个：");
            for (k = 0; k < 8; k = k + 1)
                $display("          [%0d] got=%02h exp=%02h", k, u_card.wr_mem[k], wsrc[k]);
        end
        chk(ok === 1, "C22-written-512-bytes-match");

        //================================================== 收尾检查
        $display("");
        $display("---------------- 收尾 ----------------");
        $display("        共收到 %0d 条命令，最后两条 = %0d, %0d",
                 u_card.n_rx_cmd,
                 u_card.cmd_log[u_card.n_rx_cmd-2], u_card.cmd_log[u_card.n_rx_cmd-1]);
        chk(u_card.n_rx_cmd === 13, "C23-total-13-commands-no-extra");
        chk(u_card.cmd_log[u_card.n_rx_cmd-2] === 6'd17 &&
            u_card.cmd_log[u_card.n_rx_cmd-1] === 6'd24,
            "C24-last-two-commands-are-cmd17-cmd24");

        $display("");
        $display("==================================================");
        $display("[%0t] 仿真结束：通过 %0d 项，失败 %0d 项",
                 $time, chk_idx - fail_cnt, fail_cnt);
        $display("==================================================");
        $display("### RESULT tb_sd_card : %0s  (%0d/%0d) ###",
                 (fail_cnt == 0) ? "PASS" : "FAIL", chk_idx - fail_cnt, chk_idx);
        $finish;
    end

    initial begin
        #200_000_000;
        $display("### RESULT tb_sd_card : FAIL  (超时) ###");
        $finish;
    end

endmodule
