//============================================================================
// audio_stream.v  ——  TF 卡音频流读取（M1c 模块）
//---------------------------------------------------------------------------
// 【它干什么】
//   把 TF 卡容器里那一段 PCM 音频，按扇区一个接一个读出来，拼成 16bit 样本
//   塞进 audio_fifo，供 audio_player_stream 按 48kHz 匀速取用。
//
// 【容器里的音频布局（和 tools/gen_container.py 必须一致）】
//   音频区紧跟所有图片的像素区，起始绝对扇区 = audio_sec（由 ebm_reader 从
//   容器头 0x10 处解析后送进来），总长度 = audio_sec_cnt 个扇区。
//   一个 10 秒格子 = 48000×10×2 字节 = 960000 字节 = 1875 个扇区（正好整除，
//   这也是选 16bit 而不是 8bit 的原因：8bit 时 10 秒 = 937.5 个扇区，对不齐）。
//
// 【为什么要 jump】
//   换图那一瞬间，音频必须跳到“这张图对应的那 10 秒”的开头，否则用户手动
//   切图后声音和画面就对不上了。jump 是 1 拍脉冲，jump_cell 是图号 0..7。
//   jump 只在扇区边界生效（不能中途改地址，否则数据会串）。
//
// 【水位控制：双门限迟滞 + 一次补满】
//   want（= 送给仲裁器的 b_req）不是简单的“低于某个水位”，而是带迟滞的：
//       水位 < LOW_WATER  → want 拉高（开始要货）
//       水位 ≥ HIGH_WATER → want 拉低（要够了，把总线还给图像）
//   中间那段保持不变。这样一次补货是 (HIGH-LOW) 个样本，补完就闭嘴，
//   不会和水位抖动打架（否则会退化成“一个扇区一抢”的 50% 平分，见
//   sd_arbiter.v 头注释里的实测分析）。
//   当前参数：LOW=768（16ms）、HIGH=1536（32ms）、FIFO 深 2048（43ms）。
//   一次补 768 个样本 = 3 个扇区 ≈ 0.5ms，之后安静 16ms 不打扰图像（占用 3%）。
//   ★ HIGH_WATER 必须离深度留出余量（这里 2048-1536=512 个样本 = 10.7ms）：
//     一个扇区会一口气写进 256 个样本，如果 HIGH 贴着 2048，那一串写入会撞到
//     wr_full 被丢掉 —— 实测会从第 36 个样本开始整段错位。
//
// 【容错】
//   * 卡没初始化好、或者容器里没有音频（audio_sec_cnt=0）→ 一个请求都不发，
//     播放器读不到数就输出静音，画面照常。
//   * 读到音频区末尾自动回卷到开头，形成无缝循环。
//============================================================================
`timescale 1ns / 1ps

module audio_stream #(
    parameter integer CELL_SEC   = 1875,    // 一个 10s 格子的扇区数
    parameter integer LOW_WATER  = 768,     // 低水位（样本）：低于它开始要货
    parameter integer HIGH_WATER = 1536,    // 高水位（样本）：到它就停止要货
    parameter integer LEVEL_W    = 12       // 与 audio_fifo 的 wr_level 位宽一致
)(
    input  wire        clk,            // sd_card_clk 100MHz
    input  wire        rst,            // 高有效

    input  wire        sd_init_done,   // SD 卡初始化完成
    input  wire [31:0] audio_sec,      // 音频区起始绝对扇区
    input  wire [31:0] audio_sec_cnt,  // 音频区总扇区数（0 = 无音频）

    input  wire        jump,           // 1 拍：跳到某张图的音频开头
    input  wire [2:0]  jump_cell,      // 目标图号 0..7

    //---------------- SD 卡读（接 sd_arbiter 的 B 侧）----------------
    output wire        b_req,          // 想占用总线（水位低，带迟滞）
    output reg         sec_read,       // 实际扇区读请求
    output reg  [31:0] sec_addr,
    input  wire [7:0]  data,
    input  wire        valid,
    input  wire        end_of_sec,

    //---------------- 写 FIFO ---------------------------------------
    output reg         wr_en,
    output reg  [15:0] wr_data,
    input  wire        wr_full,
    input  wire [LEVEL_W-1:0] wr_level
);

    localparam [1:0] S_IDLE = 2'd0;
    localparam [1:0] S_REQ  = 2'd1;

    reg [1:0]  state;
    reg [31:0] addr;            // 下一个要读的绝对扇区
    reg [31:0] end_sec;         // 音频区结束扇区（不含）
    reg        pend_jump;
    reg        half;            // 扇区内字节奇偶：0=低字节, 1=高字节
    reg [7:0]  lo;

    //----------------------------------------------------------- 有效音频源
    wire src_ok = sd_init_done && (audio_sec_cnt != 32'd0);

    //----------------------------------------------------------- 水位迟滞
    reg want_r;
    always @(posedge clk or posedge rst) begin
        if (rst)
            want_r <= 1'b0;
        else if ((!src_ok) || wr_full)
            want_r <= 1'b0;                                  // 没源 / 满了：别要货
        else if (wr_level < LOW_WATER[LEVEL_W-1:0])
            want_r <= 1'b1;                                  // 水库见底：开始要
        else if (wr_level >= HIGH_WATER[LEVEL_W-1:0])
            want_r <= 1'b0;                                  // 要够了：还总线
    end

    assign b_req = want_r;

    //----------------------------------------------------------- 跳转目标
    // CELL_SEC = 1875，写死成乘法；综合器会拆成移位加法，不占 DSP。
    wire [31:0] jofs     = {29'd0, jump_cell} * CELL_SEC[31:0];
    wire [31:0] jtarget  = ((jofs + CELL_SEC[31:0]) <= audio_sec_cnt) ?
                           (audio_sec + jofs) : audio_sec;

    //----------------------------------------------------------- 字节拼样本
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            wr_en   <= 1'b0;
            wr_data <= 16'd0;
            half    <= 1'b0;
            lo      <= 8'd0;
        end else begin
            wr_en <= 1'b0;                      // 默认只出 1 拍
            if (sec_read && valid) begin
                if (!half) begin
                    lo   <= data;               // 先来的字节是低 8 位（小端）
                    half <= 1'b1;
                end else begin
                    half <= 1'b0;
                    if (!wr_full) begin
                        wr_data <= {data, lo};
                        wr_en   <= 1'b1;
                    end
                end
            end else if (sec_read && end_of_sec) begin
                half <= 1'b0;                   // 兜底：整扇区 512 字节必为偶数，
                                                // 正常走不到这里，防止异常后错位
            end
        end
    end

    //----------------------------------------------------------- 主状态机
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            state     <= S_IDLE;
            addr      <= 32'd0;
            end_sec   <= 32'd0;
            sec_read  <= 1'b0;
            sec_addr  <= 32'd0;
            pend_jump <= 1'b0;
        end else if (!src_ok) begin
            // 没卡 / 没音频：彻底安静，不占用总线
            state     <= S_IDLE;
            sec_read  <= 1'b0;
            sec_addr  <= audio_sec;
            addr      <= audio_sec;
            end_sec   <= audio_sec;
            pend_jump <= 1'b0;
        end else begin
            end_sec <= audio_sec + audio_sec_cnt;

            if (jump)
                pend_jump <= 1'b1;              // 记下跳转请求，扇区边界再生效

            case (state)

                //============================================== 空闲：看要不要开张
                S_IDLE: begin
                    sec_read <= 1'b0;
                    if (pend_jump && (!wr_full)) begin
                        // 换图了：立刻抢一次，把地址拉到新格子（哪怕水库还满）
                        pend_jump <= 1'b0;
                        addr      <= jtarget;
                        sec_addr  <= jtarget;
                        sec_read  <= 1'b1;
                        state     <= S_REQ;
                    end else if (want_r && (!wr_full)) begin
                        sec_addr <= addr;
                        sec_read <= 1'b1;
                        state    <= S_REQ;
                    end
                end

                //============================================== 连续读，直到补满
                S_REQ: begin
                    sec_read <= 1'b1;
                    if (end_of_sec) begin
                        // ① 地址前进（到末尾回卷，形成 80 秒循环）
                        if ((addr + 32'd1) >= end_sec)
                            addr <= audio_sec;
                        else
                            addr <= addr + 32'd1;

                        // ② 要够了就把总线还给图像，否则无缝接下一个扇区
                        //    注意 sec_addr 用非阻塞赋值，下一拍才生效，
                        //    而卡正是在下一拍（S_WAIT）重新采样，时序刚好。
                        if ((!want_r) || wr_full) begin
                            sec_read <= 1'b0;
                            state    <= S_IDLE;
                        end else begin
                            sec_addr <= ((addr + 32'd1) >= end_sec) ?
                                        audio_sec : (addr + 32'd1);
                        end
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
