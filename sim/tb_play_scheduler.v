//============================================================================
// tb_play_scheduler.v  ——  三层优先级调度器 的行为仿真
//---------------------------------------------------------------------------
// 用“假的” ebm_reader 和“假的”转场控制器，把调度器单独拉出来测。
// 这样测起来快，也容易定位问题。
//
// 测什么：
//   ① 上电后能自动装载第 0 张图，并正确切换缓冲区指针（写 1 显示 0 → 写 0 显示 1 …）；
//   ② key1 手动下一张；
//   ③ key4 进应急 → 切到应急画面；再按一次解除 → 回到轮播序列；
//   ④ key2 关掉自动轮播后，等再久也不会自动换图；
//   ⑤ key3 切换轮播周期档位；
//   ⑥ 自动轮播开着时，到了周期会自己换图。
//
// 怎么跑：
//   vlog ../src/hdl/play_scheduler.v tb_play_scheduler.v
//   vsim -c tb_play_scheduler -do "run -all; quit"
//============================================================================
`timescale 1ns / 1ps

module tb_play_scheduler;

    reg clk = 1'b0;
    always #5 clk = ~clk;              // 100MHz

    reg rst = 1'b1;

    //---------------- 帧脉冲发生器（每 8 拍来一下，方便在仿真里“加速”）
    reg        tick_en  = 1'b0;
    reg [3:0]  tick_div = 4'd0;
    reg        frame_tick = 1'b0;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            frame_tick <= 1'b0;
            tick_div   <= 4'd0;
        end else begin
            frame_tick <= 1'b0;
            if (tick_en) begin
                if (tick_div == 4'd7) begin
                    tick_div   <= 4'd0;
                    frame_tick <= 1'b1;
                end else
                    tick_div <= tick_div + 4'd1;
            end
        end
    end

    // 打 n 个帧脉冲
    task tick_n;
        input integer n;
        begin
            tick_en = 1'b1;
            repeat (n * 8) @(posedge clk);
            tick_en = 1'b0;
            repeat (4) @(posedge clk);
        end
    endtask

    //---------------- 被测模块端口 ----------------
    reg         sd_init_done = 1'b0;
    reg  [3:0]  key_press    = 4'b0000;

    wire        idx_start;
    reg         index_ready  = 1'b0;
    reg  [15:0] img_count    = 16'd3;
    reg  [15:0] err_code     = 16'd0;

    wire        load_start;
    wire [3:0]  load_id;
    reg         load_done    = 1'b0;
    reg         write_done   = 1'b0;
    reg         load_error   = 1'b0;

    wire [1:0]  write_buf_idx;
    wire [1:0]  disp_buf_idx;

    wire        req_switch;
    reg         ack_switch   = 1'b0;

    wire [3:0]  audio_seg;
    wire        audio_seg_tgl;

    wire [3:0]  state_code;
    wire [3:0]  cur_id;
    wire [3:0]  normal_id;
    wire        auto_en;
    wire        emerg_en;
    wire [1:0]  dwell_sel;
    wire [15:0] last_err;

    integer err_cnt = 0;
    integer chk_idx = 0;
    integer ptr_bad = 0;    // 缓冲区指针超出 0/1 的次数（专防取反写错）
    reg [1:0] dwell_before = 2'd0;   // 抗连击测试用：记录按键前的档位
                                     // （提到模块级是为了 iverilog 兼容：
                                     //  在 begin:label 块里声明 reg 只有 SystemVerilog 允许）

    // 缓冲区指针监视器：本工程只有 BUF0 / BUF1 两块帧缓存，
    // 指针一旦出现 2 或 3，说明取反/加一写错了，上板必然花屏。
    // 这个监视器在整个仿真过程中一直盯着，任何时刻越界都会记账。
    always @(posedge clk)
        if ((disp_buf_idx > 2'd1) || (write_buf_idx > 2'd1)) begin
            ptr_bad = ptr_bad + 1;
            if (ptr_bad == 1)
                $display("  [%0t] 【告警】缓冲区指针越界：disp=%0d write=%0d（只允许 0/1）",
                         $time, disp_buf_idx, write_buf_idx);
        end

    play_scheduler #(
        .EMERG_ID (4'd0),
        .BOOT_DLY (200),        // 仿真里缩短上电等待
        .IMG_MAX  (8)
    ) dut (
        .clk            (clk),
        .rst            (rst),
        .sd_init_done   (sd_init_done),
        .frame_tick     (frame_tick),
        .key_press      (key_press),
        .idx_start      (idx_start),
        .index_ready    (index_ready),
        .img_count      (img_count),
        .err_code       (err_code),
        .load_start     (load_start),
        .load_id        (load_id),
        .load_busy      (1'b0),
        .load_done      (load_done),
        .write_done     (write_done),
        .load_error     (load_error),
        .write_buf_idx  (write_buf_idx),
        .disp_buf_idx   (disp_buf_idx),
        .req_switch     (req_switch),
        .ack_switch     (ack_switch),
        .audio_seg      (audio_seg),
        .audio_seg_tgl  (audio_seg_tgl),
        .state_code     (state_code),
        .cur_id         (cur_id),
        .normal_id      (normal_id),
        .auto_en        (auto_en),
        .emerg_en       (emerg_en),
        .dwell_sel      (dwell_sel),
        .last_err       (last_err)
    );

    //=========================================================== 假的 ebm_reader
    reg [7:0] idx_dly;
    reg       idx_go;
    reg       ld_go;
    reg [7:0] ld_dly;
    reg [3:0] ld_id_seen;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            index_ready <= 1'b0;
            idx_go      <= 1'b0;
            idx_dly     <= 8'd0;
            ld_go       <= 1'b0;
            ld_dly      <= 8'd0;
            load_done   <= 1'b0;
            write_done  <= 1'b0;
            ld_id_seen  <= 4'd0;
        end else begin
            load_done  <= 1'b0;
            write_done <= 1'b0;

            // --- 索引响应：收到 idx_start 后 20 拍给出 index_ready ---
            if (idx_start) begin
                index_ready <= 1'b0;
                idx_go      <= 1'b1;
                idx_dly     <= 8'd0;
            end else if (idx_go) begin
                if (idx_dly == 8'd20) begin
                    index_ready <= 1'b1;
                    idx_go      <= 1'b0;
                end else
                    idx_dly <= idx_dly + 8'd1;
            end

            // --- 装载响应：load_done 在第 20 拍，write_done 在第 40 拍 ---
            if (load_start) begin
                ld_go      <= 1'b1;
                ld_dly     <= 8'd0;
                ld_id_seen <= load_id;
            end else if (ld_go) begin
                if (ld_dly == 8'd20) load_done  <= 1'b1;
                if (ld_dly == 8'd40) begin
                    write_done <= 1'b1;
                    ld_go      <= 1'b0;
                end else
                    ld_dly <= ld_dly + 8'd1;
            end
        end
    end

    //=========================================================== 假的转场控制器
    //   只对 req_switch 的**上升沿**回应一次 ack。
    //   真实 transition_ctrl 也是这样：一次请求只给一个 ack，
    //   所以这里必须把“已经为这次请求发过 ack”锁存下来，
    //   否则 req_switch 还是高电平时会再次启动一次倒计时，多吐一个 ack。
    reg [7:0] ack_dly;
    reg       ack_go;
    reg       req_lat;      // 记住当前这个 req 已经处理过了

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            ack_switch <= 1'b0;
            ack_go     <= 1'b0;
            ack_dly    <= 8'd0;
            req_lat    <= 1'b0;
        end else begin
            ack_switch <= 1'b0;

            if (!req_switch) begin
                req_lat <= 1'b0;        // 请求撤销，允许下一次
            end

            if (req_switch && !req_lat && !ack_go) begin
                ack_go  <= 1'b1;
                ack_dly <= 8'd0;
                req_lat <= 1'b1;        // 这次请求已经受理，别再受理第二次
            end else if (ack_go) begin
                if (ack_dly == 8'd50) begin
                    ack_switch <= 1'b1;
                    ack_go     <= 1'b0;
                end else
                    ack_dly <= ack_dly + 8'd1;
            end
        end
    end

    //=========================================================== 打印与检查
    always @(posedge clk)
        if (load_start)
            $display("  [%0t] 调度器请求装载图片 id=%0d", $time, load_id);

    always @(posedge clk)
        if (req_switch)
            $display("  [%0t] 调度器请求换帧，当前 disp=%0d write=%0d",
                     $time, disp_buf_idx, write_buf_idx);

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
                // 纯 ASCII 失败标记（防中文乱码时看不出结果）
                $display("### FAIL idx=%0d ###", chk_idx);
                err_cnt = err_cnt + 1;
            end
        end
    endtask

    // 按一次键，产生**严格 1 个时钟周期**的高电平。
    // 在负沿设置、负沿撤销，中间正好夹一个正沿，不会有竞争，也不会有连击。
    // 这和上板时 key_debounce 输出的 press_pulse（1 拍）完全一致。
    task press;
        input [3:0] k;
        begin
            @(negedge clk);
            key_press = k;
            @(negedge clk);
            key_press = 4'b0000;
            @(negedge clk);
        end
    endtask

    // 按键高电平保持 n 个周期的“坏波形”，专门用来验证
    // play_scheduler 内部的上升沿检测能不能扛住，不会连击。
    task press_wide;
        input [3:0]    k;
        input integer  n;
        begin
            @(negedge clk);
            key_press = k;
            repeat (n) @(negedge clk);
            key_press = 4'b0000;
            @(negedge clk);
        end
    endtask

    // 等待一次完整的装载+换帧过程结束
    task wait_stable;
        begin
            repeat (400) @(posedge clk);
        end
    endtask

    initial begin
        // 让日志里的时间按 ns 显示，不然 %0t 会按仿真精度（ps）打印，
        // 满屏都是 [16285000] 这种要自己换算的大数字。
        $timeformat(-9, 1, " ns", 12);

        $display("==================================================");
        $display(" play_scheduler 行为仿真");
        $display("==================================================");

        #100;
        rst = 1'b0;
        #100;
        sd_init_done = 1'b1;

        //------------------------------------------------- ① 上电自动装载
        wait_stable;
        $display("[%0t] 测试1：上电后应显示 id=0，disp=1，write=0", $time);
        chk(cur_id       == 4'd0, "C01");
        chk(disp_buf_idx == 2'd1, "C02");   // disp_buf_idx 已切到刚写好的 BUF1
        chk(write_buf_idx== 2'd0, "C03");   // write_buf_idx 换成 BUF0，准备下一张

        //------------------------------------------------- ② key1 手动下一张
        $display("--------------------------------------------------");
        $display("[%0t] 测试2：按 key1 手动下一张", $time);
        press(4'b0001);
        wait_stable;
        chk(cur_id        == 4'd1, "C04");
        chk(disp_buf_idx  == 2'd0, "C05");   // disp_buf_idx 切回 BUF0
        chk(write_buf_idx == 2'd1, "C06");   // write_buf_idx 换成 BUF1

        //------------------------------------------------- ③ key4 进应急
        $display("--------------------------------------------------");
        $display("[%0t] 测试3：按 key4 进入应急，应显示 EMERG_ID=0", $time);
        press(4'b1000);
        wait_stable;
        chk(emerg_en == 1'b1, "C07");
        chk(cur_id   == 4'd0, "C08");   // cur_id = 0（应急画面）
        chk(normal_id== 4'd1, "C09");   // normal_id 仍然停在 1，没有被应急打乱

        //------------------------------------------------- ④ key4 解除应急
        $display("--------------------------------------------------");
        $display("[%0t] 测试4：再按 key4 解除应急，应回到 normal_id=1", $time);
        press(4'b1000);
        wait_stable;
        chk(emerg_en == 1'b0, "C10");
        chk(cur_id   == 4'd1, "C11");   // cur_id 回到 1

        //------------------------------------------------- ⑤ key2 关自动
        $display("--------------------------------------------------");
        $display("[%0t] 测试5：按 key2 关掉自动轮播", $time);
        press(4'b0010);
        @(posedge clk);
        chk(auto_en == 1'b0, "C12");

        // 关掉之后连打 2000 个帧脉冲，也不应该换图
        tick_n(2000);
        chk(cur_id == 4'd1, "C13");   // 2000 帧过去，画面仍然是 1（自动已关）

        //------------------------------------------------- ⑥ key3 切周期档位
        $display("--------------------------------------------------");
        $display("[%0t] 测试6：按 key3 切换轮播周期档位", $time);
        press(4'b0100);
        @(posedge clk);
        chk(dwell_sel == 2'd3, "C14");   // dwell_sel 从 2 变成 3（20 秒档）

        //------------------------------------------------- ⑦ 开自动，等它自己换
        $display("--------------------------------------------------");
        $display("[%0t] 测试7：按 key2 打开自动轮播（20 秒档=1200 帧）", $time);
        press(4'b0010);
        @(posedge clk);
        chk(auto_en == 1'b1, "C15");

        $display("  ... 打 1300 个帧脉冲，等它自己换一张 ...");
        tick_n(1300);
        wait_stable;
        chk(cur_id == 4'd2, "C16");   // 自动轮播生效，cur_id 从 1 走到 2

        //------------------------------------------------- ⑧ 抗连击
        // 故意给一个“保持 6 拍”的坏按键波形。
        // 如果 play_scheduler 里没有上升沿检测，key3 会被执行 6 次，
        // dwell_sel 会跳好几个档位。这里要求它只算一次。
        $display("--------------------------------------------------");
        $display("[%0t] 测试8：给一个保持 6 拍的 key3 坏波形，应只算一次", $time);
        begin : wide_press_test
            dwell_before = dwell_sel;
            press_wide(4'b0100, 6);
            repeat (4) @(posedge clk);
            $display("           dwell_sel: %0d -> %0d", dwell_before, dwell_sel);
            chk(dwell_sel == (dwell_before + 2'd1), "C17");   // dwell_sel 只加了一次（没有连击）
        end

        //------------------------------------------------- ⑨ 指针越界总检查
        $display("--------------------------------------------------");
        $display("[%0t] 全程缓冲区指针越界次数 = %0d（期望 0）", $time, ptr_bad);
        chk(ptr_bad == 0, "C18");   // 缓冲区指针始终只在 0/1 之间（没有指到没分配的 2/3 号块）

        //------------------------------------------------- 汇总
        $display("==================================================");
        if (err_cnt == 0)
            $display(" 全部测试通过！");
        else
            $display(" 有 %0d 项测试失败，请看上面的【失败】提示。", err_cnt);
        $display("==================================================");
        // 纯 ASCII 结论行
        $display("### RESULT tb_play_scheduler : %0s  (%0d/%0d) ###",
                 (err_cnt == 0) ? "PASS" : "FAIL",
                 chk_idx - err_cnt, chk_idx);
        $finish;
    end

endmodule
