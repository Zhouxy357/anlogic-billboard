//============================================================================
// tb_ebm_reader.v  ——  私有容器 EBM1 解析与装载 的行为仿真
//---------------------------------------------------------------------------
// 这是整个工程里最复杂、最值得先仿真验证的模块，所以测试写得最细。
//
// 仿真里做了一块“假 SD 卡”：一个字节数组 mem[]，收到 sd_sec_read 就把对应
// 扇区的 512 字节依次吐出来。测试自己按 EBM1 的格式在数组里拼一个迷你容器，
// 然后驱动 ebm_reader 去读，检查：
//   ① 头部 magic / 版本 / 尺寸不对时，错误码有没有正确置位；
//   ② 索引表能不能正确解析（图片数、每张图的起始扇区和长度）；
//   ③ 装载时 write_en 的个数对不对（= 像素字节数 / 3）；
//   ④ write_data 的字节顺序对不对（应为 {R,G,B,8'h00}）；
//   ⑤ Fletcher 校验能通过；故意改坏一个字节后，E_CKSUM 位应该置起来。
//
// 怎么跑：
//   vlog ../src/hdl/ebm_reader.v tb_ebm_reader.v
//   vsim -c tb_ebm_reader -do "run -all; quit"
//============================================================================
`timescale 1ns / 1ps

module tb_ebm_reader;

    //---------------- 参数（和测试容器保持一致） ----------------
    localparam CONTAINER_LBA = 32'd8;
    localparam IMG_W         = 1280;
    localparam IMG_H         = 8;                  // 仿真里只做 8 行高，跑得快
    localparam PIX_BYTES     = IMG_W * IMG_H * 3;  // 1280*8*3 = 30720 字节 = 60 个扇区
    localparam SECT_PER_IMG  = PIX_BYTES / 512;    // 每张图占多少扇区（跟着 IMG_W 自动变）
    localparam MEM_BYTES     = 512 * 160;          // 1 头 + 1 索引 + 2 张图 × 60 扇区 = 122

    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg rst = 1'b1;

    //---------------- 假 SD 卡内存 ----------------
    reg [7:0] mem [0:MEM_BYTES-1];

    reg         sd_init_done = 1'b0;
    reg         start        = 1'b0;
    wire        index_ready;
    wire [15:0] img_count;
    wire [15:0] err_code;
    wire [3:0]  state_code;
    wire        busy;

    reg         load_start = 1'b0;
    reg  [3:0]  load_id    = 4'd0;
    wire        load_busy;
    wire        load_done;
    wire        load_error;

    wire        write_req;
    reg         write_req_ack = 1'b0;
    wire        write_en;
    wire [31:0] write_data;

    wire        sd_sec_read;
    wire [31:0] sd_sec_read_addr;
    reg  [7:0]  sd_sec_read_data;
    reg         sd_sec_read_data_valid;
    reg         sd_sec_read_end;

    integer err_cnt  = 0;
    integer chk_idx  = 0;
    integer wr_count = 0;
    integer wr_bad   = 0;
    reg [31:0] first_word;
    reg        got_first = 1'b0;

    //=========================================================== 假 SD 卡行为
    localparam [1:0] S_IDLE = 2'd0, S_DATA = 2'd1, S_END = 2'd2, S_WAIT = 2'd3;

    reg [1:0]  sd_st    = S_IDLE;
    reg [31:0] rd_lba   = 32'd0;
    reg [9:0]  rd_idx   = 10'd0;
    reg [2:0]  wait_cnt = 3'd0;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            sd_st                  <= S_IDLE;
            sd_sec_read_data       <= 8'd0;
            sd_sec_read_data_valid <= 1'b0;
            sd_sec_read_end        <= 1'b0;
            rd_lba                 <= 32'd0;
            rd_idx                 <= 10'd0;
        end else begin
            sd_sec_read_data_valid <= 1'b0;
            sd_sec_read_end        <= 1'b0;

            case (sd_st)
                S_IDLE: begin
                    if (sd_sec_read) begin
                        rd_lba <= sd_sec_read_addr;   // 锁存本次要读的扇区
                        rd_idx <= 10'd0;
                        sd_st  <= S_DATA;
                    end
                end

                S_DATA: begin
                    sd_sec_read_data       <= mem[rd_lba*512 + rd_idx];
                    sd_sec_read_data_valid <= 1'b1;
                    if (rd_idx == 10'd511)
                        sd_st <= S_END;
                    else
                        rd_idx <= rd_idx + 10'd1;
                end

                S_END: begin
                    sd_sec_read_end <= 1'b1;
                    wait_cnt        <= 3'd0;
                    sd_st           <= S_WAIT;
                end

                // 多等几拍，让 ebm_reader 把 sd_sec_read_addr 更新完
                S_WAIT: begin
                    if (wait_cnt == 3'd3)
                        sd_st <= S_IDLE;
                    else
                        wait_cnt <= wait_cnt + 3'd1;
                end
                default: sd_st <= S_IDLE;
            endcase
        end
    end

    //=========================================================== 被测模块
    ebm_reader #(
        .CONTAINER_LBA (CONTAINER_LBA),
        .MAX_IMG       (8),
        .PIX_BYTES     (32'd2764800),
        .TIMEOUT_CYC   (8_000_000)
    ) dut (
        .clk                    (clk),
        .rst                    (rst),
        .sd_init_done           (sd_init_done),
        .start                  (start),
        .index_ready            (index_ready),
        .img_count              (img_count),
        .err_code               (err_code),
        .state_code             (state_code),
        .busy                   (busy),
        .load_start             (load_start),
        .load_id                (load_id),
        .load_busy              (load_busy),
        .load_done              (load_done),
        .load_error             (load_error),
        .write_req              (write_req),
        .write_req_ack          (write_req_ack),
        .write_en               (write_en),
        .write_data             (write_data),
        .sd_sec_read            (sd_sec_read),
        .sd_sec_read_addr       (sd_sec_read_addr),
        .sd_sec_read_data       (sd_sec_read_data),
        .sd_sec_read_data_valid (sd_sec_read_data_valid),
        .sd_sec_read_end        (sd_sec_read_end)
    );

    // 假的下游：收到 write_req 就给 ack
    always @(posedge clk or posedge rst) begin
        if (rst) write_req_ack <= 1'b0;
        else     write_req_ack <= write_req && !write_req_ack;
    end

    // 统计 write_en 个数，并检查字节顺序
    always @(posedge clk) begin
        if (write_en) begin
            wr_count = wr_count + 1;
            if (!got_first) begin
                first_word = write_data;
                got_first  = 1'b1;
            end
            // 低 8 位必须是 0（frame_read_write 只认高 24 位）
            if (write_data[7:0] !== 8'h00) wr_bad = wr_bad + 1;
        end
    end

    //=========================================================== 工具任务
    task chk;
        input cond;
        // 【必须用 ASCII】中文不要通过这个参数传！
        // iverilog 把字符串打包进位向量时，非 ASCII 字节高位会补成 0xff，
        // 日志里就变成 "閫氳繃锛�" 这种乱码。中文说明请直接用 $display 打印。
        input [1023:0] name;
        begin
            chk_idx = chk_idx + 1;
            if (cond) $display("   >>> [PASS] %0s", name);
            else begin
                $display("   >>> [FAIL] %0s", name);
                // 下面这行是**纯 ASCII**的失败标记。
                // 原因：本机终端 / ModelSim 在 cp936 环境下，偶尔会把中文多字节
                // 序列切断，导致日志里的中文变成乱码。但 ASCII 永远不受影响，
                // 所以“到底过没过”以这种 ### 开头的行、以及最后的 RESULT 行为准。
                $display("### FAIL idx=%0d ###", chk_idx);
                err_cnt = err_cnt + 1;
            end
        end
    endtask

    // 发一次 start，并等索引表读好（或超时）
    task do_start;
        integer c;
        begin
            @(posedge clk); #1;
            start = 1'b1;
            @(posedge clk); #1;
            start = 1'b0;

            // 先等 index_ready 掉下去，说明确实开始读了
            c = 0;
            while (index_ready && (c < 400)) begin
                @(posedge clk); #1; c = c + 1;
            end
            // 再等它拉起来
            c = 0;
            while (!index_ready && (c < 40000)) begin
                @(posedge clk); #1; c = c + 1;
            end
        end
    endtask

    // 发一次装载请求，并等结束
    task do_load;
        input [3:0] id;
        integer c;
        begin
            wr_count  = 0;
            got_first = 1'b0;

            @(posedge clk); #1;
            load_start = 1'b1;
            load_id    = id;
            @(posedge clk); #1;
            load_start = 1'b0;

            c = 0;
            while (!load_done && !load_error && (c < 300000)) begin
                @(posedge clk); #1; c = c + 1;
            end
        end
    endtask

    //=========================================================== 容器拼装
    integer i, k;
    reg [7:0] f1, f2;             // Fletcher 累加器
    reg [7:0] pix_byte;
    reg [7:0] ck_lo [0:1];
    reg [7:0] ck_hi [0:1];

    // 索引表在内存里的起始字节偏移
    localparam [31:0] IDX_BASE = (CONTAINER_LBA + 1) * 512;

    task put_byte;
        input [31:0] off;
        input [7:0]  val;
        begin mem[off] = val; end
    endtask

    task put_u32_le;
        input [31:0] off;
        input [31:0] val;
        begin
            mem[off]     = val[7:0];
            mem[off + 1] = val[15:8];
            mem[off + 2] = val[23:16];
            mem[off + 3] = val[31:24];
        end
    endtask

    initial begin
        $display("==================================================");
        $display(" ebm_reader 行为仿真");
        $display("==================================================");

        //------------------------------------------------- 先把整块内存清 0
        for (i = 0; i < MEM_BYTES; i = i + 1) mem[i] = 8'h00;

        //------------------------------------------------- 拼头部（LBA 8）
        put_byte(CONTAINER_LBA*512 + 32'd0,  8'h45);   // 'E'
        put_byte(CONTAINER_LBA*512 + 32'd1,  8'h42);   // 'B'
        put_byte(CONTAINER_LBA*512 + 32'd2,  8'h4D);   // 'M'
        put_byte(CONTAINER_LBA*512 + 32'd3,  8'h31);   // '1'
        put_byte(CONTAINER_LBA*512 + 32'd4,  8'h01);   // version = 1
        put_byte(CONTAINER_LBA*512 + 32'd5,  8'h00);
        put_byte(CONTAINER_LBA*512 + 32'd6,  8'h02);   // image_count = 2
        put_byte(CONTAINER_LBA*512 + 32'd7,  8'h00);
        put_byte(CONTAINER_LBA*512 + 32'd8,  8'h00);   // width  = 1280 = 0x0500
        put_byte(CONTAINER_LBA*512 + 32'd9,  8'h05);
        put_byte(CONTAINER_LBA*512 + 32'd10, 8'hD0);   // height = 720 = 0x02D0
        put_byte(CONTAINER_LBA*512 + 32'd11, 8'h02);
        put_byte(CONTAINER_LBA*512 + 32'd12, 8'h03);   // bpp = 3
        put_byte(CONTAINER_LBA*512 + 32'd13, 8'h01);   // checksum_mode = 1

        //------------------------------------------------- 填两张图的像素
        // 图 0 从 LBA 10 开始，图 1 紧接着放
        for (i = 0; i < PIX_BYTES; i = i + 1) begin
            pix_byte = (i * 7 + 3) & 8'hFF;
            mem[(CONTAINER_LBA + 2)*512 + i]          = pix_byte;
            mem[(CONTAINER_LBA + 2)*512 + PIX_BYTES + i] = (pix_byte + 8'h01) & 8'hFF;
        end

        //------------------------------------------------- 分别算两张图的 Fletcher
        // 算法必须和 ebm_reader.v 里完全一致：
        //     s1 = (s1 + byte) & 0xFF
        //     s2 = (s2 + s1)   & 0xFF
        //     校验值 = {s2, s1}
        for (k = 0; k < 2; k = k + 1) begin
            f1 = 8'h00; f2 = 8'h00;
            for (i = 0; i < PIX_BYTES; i = i + 1) begin
                pix_byte = ((i * 7 + 3) + (k == 1 ? 1 : 0)) & 8'hFF;
                f1 = (f1 + pix_byte) & 8'hFF;
                f2 = (f2 + f1)       & 8'hFF;
            end
            ck_lo[k] = f1;
            ck_hi[k] = f2;
            $display("  图%0d Fletcher 校验值 = %02x_%02x", k, f2, f1);
        end

        //------------------------------------------------- 拼索引表（LBA 9）
        // 每项 16 字节：id(1) + flags(1) + 保留(2) + 起始扇区(4) + 字节数(4) + 校验(4)
        // 项 0
        put_byte (IDX_BASE + 32'd0,  8'h00);                            // id = 0
        put_byte (IDX_BASE + 32'd1,  8'h00);
        put_byte (IDX_BASE + 32'd2,  8'h00);
        put_byte (IDX_BASE + 32'd3,  8'h00);
        put_u32_le(IDX_BASE + 32'd4,  CONTAINER_LBA + 2);               // 起始扇区 = 10
        put_u32_le(IDX_BASE + 32'd8,  PIX_BYTES);                       // 字节数
        put_byte (IDX_BASE + 32'd12, ck_lo[0]);                         // 校验低
        put_byte (IDX_BASE + 32'd13, ck_hi[0]);                         // 校验高

        // 项 1
        put_byte (IDX_BASE + 32'd16, 8'h01);                            // id = 1
        put_byte (IDX_BASE + 32'd17, 8'h00);
        put_byte (IDX_BASE + 32'd18, 8'h00);
        put_byte (IDX_BASE + 32'd19, 8'h00);
        put_u32_le(IDX_BASE + 32'd20, CONTAINER_LBA + 2 + SECT_PER_IMG); // 起始扇区 = 40
        put_u32_le(IDX_BASE + 32'd24, PIX_BYTES);
        put_byte (IDX_BASE + 32'd28, ck_lo[1]);
        put_byte (IDX_BASE + 32'd29, ck_hi[1]);

        //------------------------------------------------- 开始仿真
        #100;
        rst = 1'b0;
        #100;
        sd_init_done = 1'b1;
        repeat (10) @(posedge clk);

        //============================== ① 正常读索引
        $display("--------------------------------------------------");
        $display("[%0t] 测试1：读容器头 + 索引表", $time);
        do_start;
        repeat (10) @(posedge clk);
        chk(index_ready      === 1'b1, "C01");   // index_ready 拉起来了
        chk(img_count        === 16'd2, "C02");   // 图片数解析正确 = 2
        chk(state_code       === 4'd1, "C03");   // 读完后回到空闲状态
        $display("  错误码 = %04h", err_code);
        chk(err_code[0] === 1'b0, "C04");   // magic 校验通过
        chk(err_code[1] === 1'b0, "C05");   // 版本校验通过
        chk(err_code[2] === 1'b0, "C06");   // 宽高/位深校验通过
        chk(err_code[3] === 1'b0, "C07");   // 图片数合法性通过

        //============================== ② 装载图 0
        $display("--------------------------------------------------");
        $display("[%0t] 测试2：装载图片 0", $time);
        do_load(4'd0);
        chk(load_done  === 1'b1, "C08");   // load_done 拉起来了
        chk(load_error === 1'b0, "C09");   // 没有报错
        chk(wr_count   === PIX_BYTES/3, "C10");   // 写入像素数正确（= 字节数/3）
        chk(wr_bad     === 0, "C11");   // 所有写入字的最低 8 位都是 0
        $display("  实际写入 %0d 个像素，期望 %0d", wr_count, PIX_BYTES/3);
        $display("  第一个写入字 = %08h（高 24 位应为 R,G,B）", first_word);
        chk(err_code[5] === 1'b0, "C12");   // Fletcher 校验通过

        //============================== ③ 装载不存在的 id
        $display("--------------------------------------------------");
        $display("[%0t] 测试3：请求一个越界的 id=5", $time);
        do_load(4'd5);
        chk(load_error  === 1'b1, "C13");   // 越界请求被拒绝
        chk(err_code[4] === 1'b1, "C14");   // E_ID 位被置起来

        //============================== ④ 故意改坏一个像素字节
        $display("--------------------------------------------------");
        $display("[%0t] 测试4：把图 1 的某个像素字节改坏，校验应该报警告", $time);
        mem[(CONTAINER_LBA + 2)*512 + PIX_BYTES + 100] =
            mem[(CONTAINER_LBA + 2)*512 + PIX_BYTES + 100] ^ 8'hFF;
        do_load(4'd1);
        chk(load_done   === 1'b1, "C15");   // 图还是读完了（校验失败不阻断显示）
        chk(err_code[5] === 1'b1, "C16");   // E_CKSUM 位被置起来

        //============================== ⑤ 头部 magic 错
        $display("--------------------------------------------------");
        $display("[%0t] 测试5：把 magic 改成 XXXX，应该报 E_MAGIC", $time);
        mem[CONTAINER_LBA*512 + 0] = 8'h58;   // 'X'
        do_start;
        chk(err_code[0] === 1'b1, "C17");   // E_MAGIC 位被置起来

        //============================== 汇总
        $display("==================================================");
        if (err_cnt == 0) $display(" 全部测试通过！");
        else              $display(" 有 %0d 项测试失败。", err_cnt);
        $display("==================================================");
        // 纯 ASCII 结论行。不管中文有没有乱码，这一行一定是对的，
        // run_all.do / check_results.py 就是靠它来判断结果的。
        $display("### RESULT tb_ebm_reader : %0s  (%0d/%0d) ###",
                 (err_cnt == 0) ? "PASS" : "FAIL",
                 chk_idx - err_cnt, chk_idx);
        $finish;
    end

    // 防止仿真卡死
    initial begin
        #50_000_000;
        $display("!! 仿真超时，说明状态机卡住了，请检查握手信号");
        $display("### RESULT tb_ebm_reader : FAIL  (TIMEOUT) ###");
        $finish;
    end

endmodule
