//============================================================================
// transition_ctrl.v  ——  转场（淡出 → 全黑切帧 → 淡入）控制器（M4 模块）
//---------------------------------------------------------------------------
// 【为什么需要它】
//   本工程 SDRAM 只有 1 个读端口，同一时刻只能读一帧。要做出“淡入淡出”，
//   最稳的做法是：
//       ① 先把当前画面整体调暗到全黑            (P_FADE_OUT)
//       ② 在全黑的那一瞬间切换显示缓冲区        (P_SWITCH)
//       ③ 再多停一帧，让读取侧确实看到新指针    (P_HOLD)
//       ④ 最后把新画面整体调亮到正常            (P_FADE_IN)
//   整个过程只需要 1 个读端口，而且绝对不会撕裂。
//
// 【接口约定】
//   req     —— 调度器说“我准备好了，可以换帧”。保持高电平，直到收到 ack。
//   ack     —— 本模块在全黑瞬间给出 1 拍脉冲，调度器收到后立刻切换缓冲区指针。
//   blend   —— 0..256 的亮度系数，送给 osd_mixer 做乘算。256 表示全亮。
//   phase   —— 当前阶段，给数码管/调试用。
//
// 【为什么 req 用“电平”而不用“上升沿”】
//   调度器可能在你还在淡入的过程中就提出下一次换帧请求（比如连按按键）。
//   如果只认上升沿，这个请求会被漏掉，画面就卡住了。
//   所以 P_IDLE / P_STEADY 都直接看 req 的电平；req 一定会在收到 ack 后
//   由调度器拉低，所以不会重复触发。
//
// frame_tick 接视频场同步的上升沿脉冲，所以每帧只调整一次亮度，
// 视觉上是连续渐变（STEP=16 时约 16 帧 ≈ 0.27 秒完成一次淡变）。
//============================================================================
`timescale 1ns / 1ps

module transition_ctrl #(
    parameter [8:0] STEP = 9'd16     // 每帧亮度变化量
)(
    input  wire       clk,          // video_clk 75MHz
    input  wire       rst,          // 高有效复位
    input  wire       frame_tick,   // 每帧 1 拍（接 vs 上升沿）
    input  wire       req,          // 请求换帧（电平，保持到 ack）
    output reg        ack,          // 全黑瞬间 1 拍回应
    output reg [8:0]  blend,        // 0..256 亮度系数
    output reg [2:0]  phase         // 当前阶段
);

    localparam [2:0] P_IDLE     = 3'd0;   // 上电后还没有画面，全黑
    localparam [2:0] P_FADE_IN  = 3'd1;   // 渐亮
    localparam [2:0] P_STEADY   = 3'd2;   // 正常显示
    localparam [2:0] P_FADE_OUT = 3'd3;   // 渐暗
    localparam [2:0] P_SWITCH   = 3'd4;   // 全黑，输出 ack
    localparam [2:0] P_HOLD     = 3'd5;   // 全黑多停一帧，等缓冲区指针生效

    localparam [8:0] FULL = 9'd256;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            phase <= P_IDLE;
            blend <= 9'd0;
            ack   <= 1'b0;
        end else begin
            ack <= 1'b0;          // 默认每拍拉低，只在 P_SWITCH 置起

            case (phase)

                //----------------------------------------------- 还没画面
                P_IDLE: begin
                    blend <= 9'd0;
                    // 第一次装载完成后调度器会拉起 req，这里直接完成一次换帧
                    if (req)
                        phase <= P_SWITCH;
                end

                //----------------------------------------------- 渐亮
                P_FADE_IN: begin
                    if (frame_tick) begin
                        if (blend >= (FULL - STEP)) begin
                            blend <= FULL;
                            phase <= P_STEADY;
                        end else begin
                            blend <= blend + STEP;
                        end
                    end
                end

                //----------------------------------------------- 正常显示
                P_STEADY: begin
                    blend <= FULL;
                    if (req)
                        phase <= P_FADE_OUT;
                end

                //----------------------------------------------- 渐暗
                P_FADE_OUT: begin
                    if (frame_tick) begin
                        if (blend <= STEP) begin
                            blend <= 9'd0;
                            phase <= P_SWITCH;
                        end else begin
                            blend <= blend - STEP;
                        end
                    end
                end

                //----------------------------------------------- 全黑并回应
                P_SWITCH: begin
                    blend <= 9'd0;
                    ack   <= 1'b1;          // 只在全黑这一拍给出
                    phase <= P_HOLD;
                end

                //----------------------------------------------- 多停一帧
                P_HOLD: begin
                    blend <= 9'd0;
                    if (frame_tick)
                        phase <= P_FADE_IN;
                end

                default: phase <= P_IDLE;
            endcase
        end
    end

endmodule
