//============================================================================
// key_debounce.v  ——  4 路按键消抖（M1 模块）
//---------------------------------------------------------------------------
// 作用：
//   把机械按键的抖动滤掉，输出“每按一次只产生 1 个时钟周期的高电平脉冲”。
//   下游状态机只要在 press_pulse 为 1 的那一拍做动作即可，不用关心抖动。
//
// 按键电平约定：
//   本板按键未按下时被上拉为 1，按下时为 0（见 pin.adc 的 PULLTYPE = PULLUP）。
//
// 为什么不用例程的消抖模块：
//   例程的 ax_debounce / key_remove_shakes 是给 SD 卡扫描用的，接口与本工程
//   不同。这里自己写一个更直观的版本，方便单模块仿真。
//============================================================================
`timescale 1ns / 1ps

module key_debounce #(
    parameter integer CLK_FREQ_HZ = 100_000_000,  // 模块工作时钟频率
    parameter integer DEBOUNCE_MS = 20,           // 消抖时间(ms)
    parameter integer KEY_NUM     = 4             // 按键路数
)(
    input  wire               clk,
    input  wire               rst,                // 高电平复位
    input  wire [KEY_NUM-1:0] key_in,             // 按键原始输入，按下 = 0
    output wire [KEY_NUM-1:0] press_pulse,        // 按下瞬间输出 1 拍高电平
    output wire [KEY_NUM-1:0] key_down            // 消抖后的按住状态，按住 = 1
);

    // 消抖所需计数值：DEBOUNCE_MS 毫秒 @ CLK_FREQ_HZ
    // ★ 2026-10-18 修正单位：原来是 (CLK_FREQ_HZ/1000)*DEBOUNCE_MS，
    //   隐含"每次计数 1ms"，实际每拍都计一次，导致 20ms 变成 20 个时钟周期
    //   （100MHz 下仅 200ns，等于没消抖）。改成下面的乘除顺序，直接得到"拍数"。
    //   用乘法先做、最后再除，避免整数除法的毫秒截断误差。
    localparam integer CNT_MAX = (CLK_FREQ_HZ * DEBOUNCE_MS) / 1000;

    genvar i;
    generate
        for (i = 0; i < KEY_NUM; i = i + 1) begin : g_key

            reg [1:0]  sync_r;     // 两级同步，消除亚稳态
            reg        stable;     // 消抖后的电平（按下 = 0）
            reg [31:0] cnt;
            reg        press_r;

            always @(posedge clk) begin
                if (rst) begin
                    sync_r  <= 2'b11;
                    stable  <= 1'b1;
                    cnt     <= 32'd0;
                    press_r <= 1'b0;
                end else begin
                    sync_r  <= {sync_r[0], key_in[i]};
                    press_r <= 1'b0;                     // 默认没有按下

                    if (sync_r[1] == stable) begin
                        // 输入和已确认电平一致，计数清零
                        cnt <= 32'd0;
                    end else if (cnt >= CNT_MAX - 1) begin
                        // 输入和已确认电平不一致，且持续了整整 20ms → 认定变化
                        cnt <= 32'd0;
                        if (stable == 1'b1 && sync_r[1] == 1'b0)
                            press_r <= 1'b1;             // 1 → 0 表示“按下”
                        stable <= sync_r[1];
                    end else begin
                        cnt <= cnt + 32'd1;
                    end
                end
            end

            assign press_pulse[i] = press_r;
            assign key_down[i]    = ~stable;             // 按住时输出 1

        end
    endgenerate

endmodule
