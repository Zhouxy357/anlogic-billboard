
module video_rgb_to_axis_640x480(
    input  wire        I_clk,
    input  wire        I_rst,
    input  wire        I_vs,
    input  wire        I_de,
    input  wire [23:0] I_rgb,

    output reg         O_video_user,
    output reg         O_video_valid,
    output reg         O_video_last,
    output reg  [23:0] O_video_data
);

reg        S_vs_1d;
reg        S_de_1d;
reg        S_frame_arm;
reg [10:0] S_x_cnt;

always @(posedge I_clk or posedge I_rst) begin
    if (I_rst) begin
        S_vs_1d       <= 1'b0;
        S_de_1d       <= 1'b0;
        S_frame_arm   <= 1'b1;
        S_x_cnt       <= 11'd0;
        O_video_user  <= 1'b0;
        O_video_valid <= 1'b0;
        O_video_last  <= 1'b0;
        O_video_data  <= 24'd0;
    end
    else begin
        S_vs_1d <= I_vs;
        S_de_1d <= I_de;

        O_video_user  <= 1'b0;
        O_video_valid <= I_de;
        O_video_last  <= 1'b0;
        O_video_data  <= I_rgb;

        // 任意一次 VS 跳变后，把“下一次 active video 的首像素”当成 SOF
        if (S_vs_1d != I_vs)
            S_frame_arm <= 1'b1;

        if (I_de) begin
            if (!S_de_1d) begin
                // 一行首像素
                S_x_cnt <= 11'd0;
                if (S_frame_arm) begin
                    O_video_user <= 1'b1;
                    S_frame_arm  <= 1'b0;
                end
            end
            else begin
                S_x_cnt <= S_x_cnt + 11'd1;
            end

            // 1280x720 最后一个有效像素
            // 【已知问题 · 2026-10-12 实测确认】S_x_cnt 比真实像素号滞后 1 拍，
            //   所以它永远到不了 1279 —— O_video_last 实际【从不拉高】。
            //   这是官方原例程就有的写法（官方阈值 639，同样滞后一拍）；
            //   iverilog 实测：喂 2 行 × 1280 像素，last 脉冲数 = 0（user 脉冲正常 = 1）。
            //   现在【故意不改】：官方另一个参考视频源 video_source_test.v 是每行
            //   产一次 last，而本工程所用 HDMI 核在 last 恒 0 时到底正不正常，
            //   在没有实测条件的当下无法判定，贸然改成 1278 有打乱核内部行计数的风险。
            //   如果将来出现"配置正常、其它环节都对，但 HDMI 就是没输出"，
            //   这里（改成 11'd1278）是第一个该试的地方。
            if (S_x_cnt == 11'd1279)
                O_video_last <= 1'b1;
        end
        else begin
            S_x_cnt <= 11'd0;
        end
    end
end

endmodule
