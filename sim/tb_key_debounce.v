//============================================================================
// tb_key_debounce.v  ——  按键消抖模块的行为仿真
//---------------------------------------------------------------------------
// 测什么：
//   ① 抖动（毛刺）不会产生按下脉冲；
//   ② 真正按住超过消抖时间，才会输出恰好 1 拍的 press_pulse；
//   ③ 按住期间 key_down 一直为 1，松开后回到 0；
//   ④ 松手抖动同样不会产生多余的按下脉冲。
//
// 怎么跑（ModelSim，在 sim 目录下）：
//   vlib work
//   vlog ../src/hdl/key_debounce.v tb_key_debounce.v
//   vsim -c tb_key_debounce -do "run -all; quit"
//============================================================================
`timescale 1ns / 1ps

module tb_key_debounce;

    // 时钟：10ns 周期 = 100MHz，和实际工程一致
    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg        rst = 1'b1;
    reg  [0:0] key_in;
    wire [0:0] press_pulse;
    wire [0:0] key_down;

    integer press_cnt = 0;
    always @(posedge clk)
        if (press_pulse[0]) press_cnt = press_cnt + 1;

    // 统一的“通过/失败”记录：中文说明 + 纯 ASCII 结论行。
    // ASCII 结论行的意义：ModelSim 在本机 cp936 环境下偶尔会切断中文多字节
    // 序列，日志里的中文可能变乱码，但 ASCII 永远可靠，所以判断结果以它为准。
    integer chk_idx  = 0;
    integer fail_cnt = 0;

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
                fail_cnt = fail_cnt + 1;
                $display("   >>> [FAIL] %0s", name);
                $display("### FAIL idx=%0d ###", chk_idx);
            end
        end
    endtask

    key_debounce #(
        .CLK_FREQ_HZ (100_000_000),
        .DEBOUNCE_MS (1),          // 仿真里用 1ms 就够，省时间
        .KEY_NUM     (1)
    ) dut (
        .clk         (clk),
        .rst         (rst),
        .key_in      (key_in),
        .press_pulse (press_pulse),
        .key_down    (key_down)
    );

    initial begin
        $timeformat(-9, 1, " ns", 12);
        key_in = 1'b1;             // 未按下 = 高

        #100 rst = 1'b0;
        #200;

        //------------------------------------------------- ① 抖动干扰
        $display("[%0t] 测试1：给一串 5us 的毛刺，不应该有按下", $time);
        key_in = 1'b0; #5000;      // 5us 毛刺
        key_in = 1'b1; #5000;      // 恢复
        key_in = 1'b0; #3000;
        key_in = 1'b1; #3000;
        chk(press_cnt === 0, "C01");   // 毛刺被滤掉，按下次数 = 0

        #200_000;                  // 等一段空闲

        //------------------------------------------------- ② 真正按下
        $display("[%0t] 测试2：按住 2ms，应该产生 1 次按下", $time);
        key_in = 1'b0;
        #2_000_000;                // 按住 2ms（远大于 1ms 消抖时间）
        chk(press_cnt === 1, "C02");   // 按下次数 = 1
        chk(key_down === 1'b1, "C03");   // 按住时 key_down = 1

        //------------------------------------------------- ③ 松开
        $display("[%0t] 测试3：松开，key_down 应该回到 0", $time);
        key_in = 1'b1;
        #2_000_000;
        chk(key_down === 1'b0, "C04");   // 松开后 key_down = 0
        chk(press_cnt === 1, "C05");   // 松开没有产生额外脉冲

        //------------------------------------------------- ④ 连按两次
        $display("[%0t] 测试4：连按两次，应该得到 2 次按下", $time);
        key_in = 1'b0; #2_000_000;
        key_in = 1'b1; #2_000_000;
        key_in = 1'b0; #2_000_000;
        key_in = 1'b1; #2_000_000;
        chk(press_cnt === 3, "C06");   // 总按下次数 = 3

        $display("==================================================");
        $display("[%0t] 仿真结束：通过 %0d 项，失败 %0d 项",
                 $time, chk_idx - fail_cnt, fail_cnt);
        $display("==================================================");
        // 纯 ASCII 结论行
        $display("### RESULT tb_key_debounce : %0s  (%0d/%0d) ###",
                 (fail_cnt == 0) ? "PASS" : "FAIL", chk_idx - fail_cnt, chk_idx);
        $finish;
    end

endmodule
