//============================================================================
// top_billboard.v  ——  顶层整合（AC201 移植版）
//----------------------------------------------------------------------------
// ★ 本文件由 src/hdl/top_billboard.v 适配而来，仅改"对外引脚"这一层，
//   全部内部逻辑（33 个模块）与主工程逐字相同。改动清单：
//   ① key3/key4 端口 → 拨码开关 sw[1:0]（AC201 只有 3 个按键：
//      KEY0=F7 key1、KEY1=E7 key2、KEY2=H14 rst_n；拨一下开关=按一次键，
//      play_scheduler 的边沿检测照常工作）
//   ② seg_sel/seg_data 14 根直驱 → 3 根 595 串行（seg_ser/sclk/rclk），
//      经 seg_595 模块转换；seg_scan/seg_status 原样保留在片内
//   ③ led 输出取反（AC201 的 LED 是低电平点亮；HX4S20C 是高电平点亮）
//   ④ 删除 HDMI_DDC_SCL/SDA 端口（AC201 底板的 HDMI 座未把 DDC 接到
//      FPGA，官方 IO.adc 也没有这两个引脚）；HDMI 核的 DDC 端口悬空
//   ⑤ 其余：clk 仍是 50MHz（AC201 = K14，与主工程相同，两个 PLL 不动）
//
// 【这一层要做的事，按顺序看】
//   1. 生成所有时钟和复位
//        50MHz 输入 ─┬─ sys_pll   → 100MHz 读 SD 卡 / 125MHz SDRAM / 125MHz(移相)
//                    ├─ video_pll → 75MHz 像素时钟 / 375MHz HDMI 串行时钟
//                    └─ PLL_HDMI_AUDIO → 12.288MHz 音频主时钟
//   【分辨率】1280x720@60，时序参数在 support/color_bar.v 的 `VIDEO_1280_720 分支
//   2. 4 个按键消抖（在 100MHz 域做，20ms 消抖很准）
//   3. 数据链路：
//        TF 卡 ──spi── sd_card_top ──扇区数据── ebm_reader ──像素──┐
//                                                                  ├─ frame_read_write ─ SDRAM
//        play_scheduler ──调度────────────── 控制谁写哪块、显示哪块 ┘
//   4. 显示链路：
//        SDRAM ─frame_read_write─→ video_delay ─→ osd_mixer(亮度+字幕) ─→
//        video_rgb_to_axis ─→ HDMI 1.4b 发射核 ─→ hdmi_phy ─→ HDMI 口
//   5. 音频链路：
//        audio_player(PCM素材) ─→ audio_arc_calculate(算 ACR) ─→ HDMI 核
//   6. 人机界面：数码管显示状态，LED 显示灯语
//
// 【跨时钟域握手一览】—— 到处都要跨域，所以集中写在这一层
//   (a) 视频每帧脉冲   video(75M) → sd(100M)      ：翻转信号 + 打三拍做边沿检测
//   (b) 换帧请求 req   sd(100M) → video(25M)      ：电平，打两拍
//   (c) 换帧回应 ack   video(75M) → sd(100M)      ：单拍脉冲只有 13.3ns，比 sd 周期
//                                                   10ns 只快 1.33 倍，所以顶层先把脉冲
//                                                   展宽到 3 拍(40ns) 再交给 sd 域做边沿检测
//   (d) SDRAM 写完     mem(125M) → sd(100M)       ：翻转信号 + 边沿检测
//   (e) 音频段号       sd(100M) → mclk(12.288M)   ：4bit 打两拍
//   (f) disp_buf_idx   sd(100M) → mem/video       ：多位，但只在全黑时改一次，
//============================================================================
`timescale 1ns / 1ps

module top_billboard (
    input  wire        clk,            // 板载 50MHz
    input  wire        rst_n,          // 按键复位，低有效

    input  wire        key1,           // 手动下一张      AC201: KEY0 = F7
    input  wire        key2,           // 自动轮播 开/关  AC201: KEY1 = E7
    input  wire [1:0]  sw,             // sw[0]=轮播周期 2/5/10/20 秒（原 key3，N14）
                                       // sw[1]=应急画面 开/关     （原 key4，K12）

    output wire [3:0]  led,            // 4 只指示灯（AC201 低电平点亮）

    // 数码管：3 线 74HC595 串行（AC201: DIO=R14 / SCLK=T14 / RCLK=R12）
    output wire        seg_ser,        // 595 串行数据
    output wire        seg_sclk,       // 595 移位时钟
    output wire        seg_rclk,       // 595 锁存时钟

    // HDMI TMDS（AC201: CLK=B10 D0=D11 D1=C11 D2=F10，均为 LVDS33_E 差分对正端）
    output wire        HDMI_CLK_P,
    output wire        HDMI_D2_P,
    output wire        HDMI_D1_P,
    output wire        HDMI_D0_P,

    // 注意：AC201 底板未把 HDMI DDC 接到 FPGA（见官方 IO.adc），故无 DDC 端口

    // TF 卡（SPI 模式，AC201: CS=R2 CLK=M2 MOSI=L3 MISO=K6）
    output wire        sd_ncs,
    output wire        sd_dclk,
    output wire        sd_mosi,
    input  wire        sd_miso
);

    //=========================================================== 常量
    localparam MEM_DATA_BITS = 32;
    localparam ADDR_BITS     = 21;
    // 1 像素 = SDRAM 里 1 个 32bit 字（视频读回时取 [31:8] 当 RGB）
    localparam FRAME_PIXELS  = 24'd921600;      // 1280*720
    localparam BUF0_ADDR     = 24'd0;
    localparam BUF1_ADDR     = FRAME_PIXELS;    // 双缓冲共占 1,843,200 字
                                                // ADDR_BITS=21 -> 2,097,152 字，够放

    //=========================================================== 时钟与复位
    wire sys_pll_lock;
    wire video_pll_lock;
    wire audio_pll_lock;

    wire sd_card_clk;        // 100MHz  SD 卡 / 调度器 / 数码管扫描
    wire ext_mem_clk;        // 125MHz  SDRAM
    wire ext_mem_clk_sft;    // 125MHz  移相，SDRAM 芯片需要
    wire video_clk;          // 75MHz   像素时钟
    wire hdmi_5x_clk;        // 375MHz  HDMI 串行时钟（像素时钟 ×5）
    wire audio_mclk;         // 12.288MHz 音频主时钟

    wire rst_all;

    sys_pll u_sys_pll (
        .refclk   (clk),
        .reset    (1'b0),
        .extlock  (sys_pll_lock),
        .clk0_out (sd_card_clk),
        .clk1_out (ext_mem_clk),
        .clk2_out (ext_mem_clk_sft)
    );

    video_pll u_video_pll (
        .refclk   (clk),
        .reset    (1'b0),
        .extlock  (video_pll_lock),
        .clk0_out (video_clk),
        .clk1_out (hdmi_5x_clk)
    );

    PLL_HDMI_AUDIO u_audio_pll (
        .refclk   (clk),
        .reset    (1'b0),
        .extlock  (audio_pll_lock),
        .clk0_out (),
        .clk1_out (),
        .clk2_out (audio_mclk)
    );

    // 等三个 PLL 锁定并稳定 20ms 才放复位，避免上电瞬间乱跑；
    // 复位一旦放开就锁住，不再因为 PLL 抖动反复复位。
    // 【2026-10-12 加固】若 40ms 内 PLL 迟迟不齐，超时强行放行：
    //   宁可视频/音频带病运行，也要保证 LED 心跳和数码管能报告状态——
    //   否则一个 PLL 不锁就把整板"闷死"，上板时无从判断是没配置还是 PLL 问题。
    reg [20:0] rst_cnt;
    reg        rst_wait;

    always @(posedge clk) begin
        if (!rst_n) begin
            rst_cnt  <= 21'd0;
            rst_wait <= 1'b1;
        end else if (!rst_wait) begin
            rst_wait <= 1'b0;
        end else if (sys_pll_lock && video_pll_lock && audio_pll_lock) begin
            if (rst_cnt < 21'd1_000_000) begin
                rst_cnt  <= rst_cnt + 21'd1;
                rst_wait <= 1'b1;
            end else begin
                rst_wait <= 1'b0;              // 锁定后稳 20ms，正常放行
            end
        end else if (rst_cnt < 21'd2_000_000) begin
            rst_cnt  <= rst_cnt + 21'd1;       // PLL 未齐：继续等，最多 40ms
        end else begin
            rst_wait <= 1'b0;                  // 超时兜底：强行放行
        end
    end

    assign rst_all = rst_wait;

    //=========================================================== 按键消抖
    // AC201 只有 3 个按键：key1=KEY0、key2=KEY1、rst_n=KEY2。
    // 原 key3/key4 改用拨码开关：每拨动一次 = 产生一个"按下/松开"事件，
    // key_debounce 的 20ms 消抖与 play_scheduler 的边沿检测照常工作。
    wire key3 = sw[0];      // SW0（N14）：轮播周期 2/5/10/20 秒
    wire key4 = sw[1];      // SW1（K12）：应急画面 开/关

    wire [3:0] key_press;   // 按下瞬间 1 拍
    wire [3:0] key_down;    // 按住时 1

    key_debounce #(
        .CLK_FREQ_HZ (100_000_000),
        .DEBOUNCE_MS (20),
        .KEY_NUM     (4)
    ) u_key_debounce (
        .clk         (sd_card_clk),
        .rst         (rst_all),
        .key_in      ({key4, key3, key2, key1}),   // 按下 = 0
        .press_pulse (key_press),
        .key_down    (key_down)
    );

    //=========================================================== SD 卡底层
    wire        sd_init_done;
    wire        sd_sec_read;              // 卡侧（仲裁器 C 口）
    wire [31:0] sd_sec_read_addr;
    wire [7:0]  sd_sec_read_data;
    wire        sd_sec_read_data_valid;
    wire        sd_sec_read_end;

    //---- 仲裁器 A 侧：图像（ebm_reader）----
    wire        ebm_sec_read;
    wire [31:0] ebm_sec_read_addr;
    wire [7:0]  ebm_sec_read_data;
    wire        ebm_sec_read_data_valid;
    wire        ebm_sec_read_end;

    //---- 仲裁器 B 侧：音频（audio_stream）----
    wire        aud_bus_want;
    wire        aud_rd_req;
    wire [31:0] aud_rd_addr;
    wire [7:0]  aud_rd_data;
    wire        aud_rd_valid;
    wire        aud_rd_end;

    sd_card_top u_sd_card_top (
        .clk                    (sd_card_clk),
        .rst                    (rst_all),
        .SD_nCS                 (sd_ncs),
        .SD_DCLK                (sd_dclk),
        .SD_MOSI                (sd_mosi),
        .SD_MISO                (sd_miso),
        .sd_init_done           (sd_init_done),
        .sd_sec_read            (sd_sec_read),
        .sd_sec_read_addr       (sd_sec_read_addr),
        .sd_sec_read_data       (sd_sec_read_data),
        .sd_sec_read_data_valid (sd_sec_read_data_valid),
        .sd_sec_read_end        (sd_sec_read_end),
        .sd_sec_write           (1'b0),
        .sd_sec_write_addr      (32'd0),
        .sd_sec_write_data      (8'd0),
        .sd_sec_write_data_req  (),
        .sd_sec_write_end       ()
    );

    //=========================================================== 私有容器解析
    wire        idx_start;
    wire        index_ready;
    wire [15:0] img_count;
    wire [15:0] err_code;
    wire [3:0]  ebm_state;

    //---- EBM2 音频区（从容器头解析出来，直接喂给 audio_stream）----
    wire [31:0] audio_sec;
    wire [31:0] audio_sec_cnt;
    wire        audio_ok;

    wire        load_start;
    wire [3:0]  load_id;
    wire        load_done;
    wire        load_error;

    wire        sd_card_write_en;
    wire [31:0] sd_card_write_data;
    wire        sd_card_write_req;
    wire        sd_card_write_req_ack;

    ebm_reader #(
        .CONTAINER_LBA (32'd1048576),     // 512MiB 偏移，见 gen_container.py 的 --lba
        .MAX_IMG       (8),
        .PIX_BYTES     (32'd2764800),     // 1280*720*3
        .TIMEOUT_CYC   (8_000_000)        // 80ms @100MHz
    ) u_ebm_reader (
        .clk                    (sd_card_clk),
        .rst                    (rst_all),
        .sd_init_done           (sd_init_done),

        .start                  (idx_start),
        .index_ready            (index_ready),
        .img_count              (img_count),
        .err_code               (err_code),
        .state_code             (ebm_state),
        .busy                   (),

        .load_start             (load_start),
        .load_id                (load_id),
        .load_busy              (),
        .load_done              (load_done),
        .load_error             (load_error),

        //---- EBM2 音频区信息（EBM1 老卡读出 0，等价于没有音频）----
        .audio_sec              (audio_sec),
        .audio_sec_cnt          (audio_sec_cnt),
        .audio_ok               (audio_ok),

        .write_req              (sd_card_write_req),
        .write_req_ack          (sd_card_write_req_ack),
        .write_en               (sd_card_write_en),
        .write_data             (sd_card_write_data),

        .sd_sec_read            (ebm_sec_read),
        .sd_sec_read_addr       (ebm_sec_read_addr),
        .sd_sec_read_data       (ebm_sec_read_data),
        .sd_sec_read_data_valid (ebm_sec_read_data_valid),
        .sd_sec_read_end        (ebm_sec_read_end)
    );

    //=========================================================== SD 读通道仲裁
    // 卡只有一条读通道，现在两个主设备要抢：图像装载（A）和音频流（B）。
    // 策略：音频优先，但一次把 FIFO 补满才还总线，避免和图像各占一半带宽。
    // 对图像侧完全透明：A 被抢占时只是"多等一会儿"，地址保持不变。
    sd_arbiter u_sd_arbiter (
        .clk    (sd_card_clk),
        .rst    (rst_all),

        .a_req   (ebm_sec_read),
        .a_addr  (ebm_sec_read_addr),
        .a_data  (ebm_sec_read_data),
        .a_valid (ebm_sec_read_data_valid),
        .a_end   (ebm_sec_read_end),

        .b_req   (aud_bus_want),
        .b_rd    (aud_rd_req),
        .b_addr  (aud_rd_addr),
        .b_data  (aud_rd_data),
        .b_valid (aud_rd_valid),
        .b_end   (aud_rd_end),

        .c_req   (sd_sec_read),
        .c_addr  (sd_sec_read_addr),
        .c_data  (sd_sec_read_data),
        .c_valid (sd_sec_read_data_valid),
        .c_end   (sd_sec_read_end)
    );

    //=========================================================== 跨域信号准备
    // ---- (a) 视频帧脉冲：video 域 → sd 域 ----
    wire hs_0, vs_0, de_0;
    reg  vs_0_d;
    reg  frame_tick_vid;
    reg  frame_tgl_vid;

    always @(posedge video_clk or posedge rst_all) begin
        if (rst_all) begin
            vs_0_d         <= 1'b0;
            frame_tick_vid <= 1'b0;
            frame_tgl_vid  <= 1'b0;
        end else begin
            vs_0_d         <= vs_0;
            frame_tick_vid <= vs_0 & ~vs_0_d;
            if (vs_0 & ~vs_0_d)
                frame_tgl_vid <= ~frame_tgl_vid;
        end
    end

    reg [2:0] ftg_sync;
    always @(posedge sd_card_clk or posedge rst_all) begin
        if (rst_all) ftg_sync <= 3'b000;
        else         ftg_sync <= {ftg_sync[1:0], frame_tgl_vid};
    end
    wire frame_tick_sd = ftg_sync[2] ^ ftg_sync[1];

    // ---- (d) SDRAM 帧写完成：mem 域 → sd 域 ----
    wire frame_write_finish;
    reg  frame_write_tgl_mem;

    always @(posedge ext_mem_clk or posedge rst_all) begin
        if (rst_all)                      frame_write_tgl_mem <= 1'b0;
        else if (frame_write_finish)      frame_write_tgl_mem <= ~frame_write_tgl_mem;
    end

    reg [2:0] wfin_sync;
    always @(posedge sd_card_clk or posedge rst_all) begin
        if (rst_all) wfin_sync <= 3'b000;
        else         wfin_sync <= {wfin_sync[1:0], frame_write_tgl_mem};
    end
    wire write_done_sd = wfin_sync[2] ^ wfin_sync[1];

    //=========================================================== 调度器
    wire        req_switch;
    wire        ack_switch_sd;
    wire [1:0]  write_buf_idx;
    wire [1:0]  disp_buf_idx;
    wire [3:0]  audio_seg;
    wire        audio_seg_tgl;
    wire [3:0]  audio_cell;         // 当前图号 = 该播第几格语音（每格 10 秒）
    wire        audio_cell_tgl;     // 换格翻转，顶层取边沿得 1 拍 jump
    wire [3:0]  sched_state;
    wire [3:0]  cur_id;
    wire [3:0]  normal_id;
    wire        auto_en;
    wire        emerg_en;
    wire [1:0]  dwell_sel;
    wire [15:0] last_err;
    wire [19:0] dbg_dwell_cnt;      // 调试观察（主工程不使用）
    wire [19:0] dbg_dwell_tgt;
    wire [19:0] dbg_block_cnt;

    play_scheduler #(
        .EMERG_ID (4'd0),
        .BOOT_DLY (50_000_000),
        .IMG_MAX  (8)
    ) u_play_scheduler (
        .clk            (sd_card_clk),
        .rst            (rst_all),
        .sd_init_done   (sd_init_done),
        .frame_tick     (frame_tick_sd),

        .key_press      (key_press),

        .idx_start      (idx_start),
        .index_ready    (index_ready),
        .img_count      (img_count),
        .err_code       (err_code),

        .load_start     (load_start),
        .load_id        (load_id),
        .load_busy      (1'b0),
        .load_done      (load_done),
        .write_done     (write_done_sd),
        .load_error     (load_error),

        .write_buf_idx  (write_buf_idx),
        .disp_buf_idx   (disp_buf_idx),

        .req_switch     (req_switch),
        .ack_switch     (ack_switch_sd),

        .audio_seg      (audio_seg),
        .audio_seg_tgl  (audio_seg_tgl),
        .audio_cell     (audio_cell),
        .audio_cell_tgl (audio_cell_tgl),

        .state_code     (sched_state),
        .cur_id         (cur_id),
        .normal_id      (normal_id),
        .auto_en        (auto_en),
        .emerg_en       (emerg_en),
        .dwell_sel      (dwell_sel),
        .last_err       (last_err),
        .dbg_dwell_cnt  (dbg_dwell_cnt),
        .dbg_dwell_tgt  (dbg_dwell_tgt),
        .dbg_block_cnt  (dbg_block_cnt)
    );

    //=========================================================== 视频时序 + 帧缓存
    wire        video_read_req;
    wire        video_read_req_ack;
    wire        video_read_en;
    wire [31:0] video_read_data;

    wire App_rd_en;
    wire [ADDR_BITS-1:0]     App_rd_addr;
    wire                     Sdr_rd_en;
    wire [MEM_DATA_BITS-1:0] Sdr_rd_dout;
    wire                     App_wr_en;
    wire [ADDR_BITS-1:0]     App_wr_addr;
    wire [MEM_DATA_BITS-1:0] App_wr_din;
    wire [3:0]               App_wr_dm;

    wire Sdr_init_done;
    wire Sdr_init_ref_vld;
    wire Sdr_busy;

    wire [23:0] vout_data_raw;   // 从 SDRAM 出来的原始画面
    wire [23:0] vout_data;       // 叠了字幕、调了亮度之后的画面
    wire        hs, vs, de;      // 与 vout_data_raw 对齐
    wire        hs_m, vs_m, de_m;// 与 vout_data 对齐（混合器延迟 1 拍）

    video_timing_data u_video_timing_data (
        .video_clk    (video_clk),
        .rst          (rst_all),
        .read_req     (video_read_req),
        .read_req_ack (video_read_req_ack),
        .hs           (hs_0),
        .vs           (vs_0),
        .de           (de_0)
    );

    video_delay u_video_delay (
        .video_clk (video_clk),
        .rst       (rst_all),
        .read_en   (video_read_en),
        .read_data (video_read_data[31:8]),
        .hs        (hs_0),
        .vs        (vs_0),
        .de        (de_0),
        .hs_r      (hs),
        .vs_r      (vs),
        .de_r      (de),
        .vout_data (vout_data_raw)
    );

    frame_read_write #(
        .WRITE_V_FLIP (1),            // BMP 行是自下而上的，写的时候翻正
        .FRAME_WIDTH  (1280),
        .FRAME_HEIGHT (720)
    ) u_frame_read_write (
        .mem_clk          (ext_mem_clk),
        .rst              (rst_all),
        .Sdr_init_done    (Sdr_init_done),
        .Sdr_init_ref_vld (Sdr_init_ref_vld),
        .Sdr_busy         (Sdr_busy),

        .App_rd_en        (App_rd_en),
        .App_rd_addr      (App_rd_addr),
        .Sdr_rd_en        (Sdr_rd_en),
        .Sdr_rd_dout      (Sdr_rd_dout),

        .read_clk         (video_clk),
        .read_req         (video_read_req),
        .read_req_ack     (video_read_req_ack),
        .read_finish      (),
        .read_addr_0      (BUF0_ADDR[ADDR_BITS-1:0]),
        .read_addr_1      (BUF1_ADDR[ADDR_BITS-1:0]),
        .read_addr_2      ({ADDR_BITS{1'b0}}),
        .read_addr_3      ({ADDR_BITS{1'b0}}),
        .read_addr_index  (disp_buf_idx),
        .read_len         (FRAME_PIXELS[ADDR_BITS-1:0]),
        .read_en          (video_read_en),
        .read_data        (video_read_data),

        .App_wr_en        (App_wr_en),
        .App_wr_addr      (App_wr_addr),
        .App_wr_din       (App_wr_din),
        .App_wr_dm        (App_wr_dm),

        .write_clk        (sd_card_clk),
        .write_req        (sd_card_write_req),
        .write_req_ack    (sd_card_write_req_ack),
        .write_finish     (frame_write_finish),
        .write_addr_0     (BUF0_ADDR[ADDR_BITS-1:0]),
        .write_addr_1     (BUF1_ADDR[ADDR_BITS-1:0]),
        .write_addr_2     ({ADDR_BITS{1'b0}}),
        .write_addr_3     ({ADDR_BITS{1'b0}}),
        .write_addr_index (write_buf_idx),
        .write_len        (FRAME_PIXELS[ADDR_BITS-1:0]),
        .write_en         (sd_card_write_en),
        .write_data       (sd_card_write_data)
    );

    sdram u_sdram (
        .Clk              (ext_mem_clk),
        .Clk_sft          (ext_mem_clk_sft),
        .Rst              (rst_all),
        .Sdr_init_done    (Sdr_init_done),
        .Sdr_init_ref_vld (Sdr_init_ref_vld),
        .Sdr_busy         (Sdr_busy),
        .App_wr_en        (App_wr_en),
        .App_wr_addr      (App_wr_addr),
        .App_wr_dm        (App_wr_dm),
        .App_wr_din       (App_wr_din),
        .App_rd_en        (App_rd_en),
        .App_rd_addr      (App_rd_addr),
        .Sdr_rd_en        (Sdr_rd_en),
        .Sdr_rd_dout      (Sdr_rd_dout)
    );

    //=========================================================== 换帧握手（sd ↔ video）
    // ---- (b) req：sd 域 → video 域 ----
    reg [1:0] req_sync_v;
    always @(posedge video_clk or posedge rst_all) begin
        if (rst_all) req_sync_v <= 2'b00;
        else         req_sync_v <= {req_sync_v[0], req_switch};
    end
    wire tr_req = req_sync_v[1];

    // ---- 转场控制器（video 域） ----
    wire [8:0] blend;
    wire [2:0] tr_phase;
    wire       tr_ack;

    transition_ctrl u_transition_ctrl (
        .clk        (video_clk),
        .rst        (rst_all),
        .frame_tick (frame_tick_vid),
        .req        (tr_req),
        .ack        (tr_ack),
        .blend      (blend),
        .phase      (tr_phase)
    );

    // ---- (c) ack：video 域 → sd 域 ----
    // 75MHz(13.3ns) 相对 100MHz(10ns) 只快 1.33 倍，单拍 ack 有被漏采的风险，
    // 所以先在 video 域把 ack 展宽到 3 拍（40ns > 2×10ns），再交 sd 域做边沿检测。
    reg [1:0] ack_wide;
    always @(posedge video_clk or posedge rst_all) begin
        if (rst_all)                ack_wide <= 2'b00;
        else if (tr_ack)            ack_wide <= 2'b11;
        else if (ack_wide != 2'b00) ack_wide <= ack_wide - 2'd1;
    end
    wire tr_ack_wide = (ack_wide != 2'b00);

    reg [2:0] ack_sync_s;
    always @(posedge sd_card_clk or posedge rst_all) begin
        if (rst_all) ack_sync_s <= 3'b000;
        else         ack_sync_s <= {ack_sync_s[1:0], tr_ack_wide};
    end
    assign ack_switch_sd = ack_sync_s[2] & ~ack_sync_s[1];

    //=========================================================== 字幕滚动偏移
    reg [10:0] osd_ofs;
    always @(posedge video_clk or posedge rst_all) begin
        if (rst_all)                 osd_ofs <= 11'd0;
        else if (frame_tick_vid)     osd_ofs <= osd_ofs + 11'd2;   // 每帧右移 2 像素
    end

    //=========================================================== 混合 + 字幕
    osd_mixer #(
        .SCREEN_W (1280),
        .SCREEN_H (720),
        .OSD_H    (32),
        .FG_COLOR (24'hFFD24A),
        .BG_COLOR (24'h101828)
    ) u_osd_mixer (
        .clk      (video_clk),
        .rst      (rst_all),
        .rgb_in   (vout_data_raw),
        .de_in    (de),
        .vs_in    (vs),
        .blend    (blend),
        .osd_on   (1'b1),      // 想关掉字幕条就把它改成 1'b0
        .osd_ofs  (osd_ofs),
        .rgb_out  (vout_data),
        .de_out   (de_m),
        .vs_out   (vs_m)
    );

    //=========================================================== 音频
    // ---- (e) 音效段号：sd 域 → mclk 域 ----
    reg [3:0] seg_m0, seg_m1;
    always @(posedge audio_mclk or posedge rst_all) begin
        if (rst_all) begin
            seg_m0 <= 4'd0;
            seg_m1 <= 4'd0;
        end else begin
            seg_m0 <= audio_seg;
            seg_m1 <= seg_m0;
        end
    end

    wire        audio_valid;
    wire [23:0] audio_left_data;
    wire [23:0] audio_right_data;
    wire        acr_valid;
    wire [19:0] acr_cts;
    wire [19:0] acr_n;

    //=========================================================== 音频（TF 卡流式）
    // 数据流：TF 卡音频区 --audio_stream--> audio_fifo --> audio_player_stream --> HDMI
    // 原来那个片内 ROM 播放器（audio_player.v）在这里被替换；对外时序和 24bit
    // 输出格式完全不变，所以 HDMI 核的 audio / acr 连线一个字都不用改。

    //---- 换图 → 跳到该图对应的语音格（audio_cell_tgl 边沿取 1 拍脉冲）
    reg  auctgl_d;
    always @(posedge sd_card_clk or posedge rst_all) begin
        if (rst_all) auctgl_d <= 1'b0;
        else         auctgl_d <= audio_cell_tgl;
    end
    wire audio_jump = audio_cell_tgl ^ auctgl_d;

    //---- 播放使能：第一张图装载完成（画面即将出现）才开口
    reg audio_en;
    always @(posedge sd_card_clk or posedge rst_all) begin
        if (rst_all)          audio_en <= 1'b0;
        else if (load_done)   audio_en <= 1'b1;   // 置位后一直保持
    end

    wire        aud_fifo_wr_en;
    wire [15:0] aud_fifo_wr_data;
    wire        aud_fifo_wr_full;
    wire [11:0] aud_fifo_level;

    wire        aud_fifo_rd_en;
    wire [15:0] aud_fifo_rd_data;
    wire        aud_fifo_empty;

    //---- 读卡填 FIFO（100MHz 域）
    audio_stream #(
        .CELL_SEC   (1875),     // 10 秒 = 960000 字节 = 1875 个扇区（正好整除）
        .LOW_WATER  (768),      // 16ms 见底开始要货
        .HIGH_WATER (1536),     // 32ms 补满就还总线（一次补 3 个扇区 ≈ 0.5ms）
        .LEVEL_W    (12)
    ) u_audio_stream (
        .clk            (sd_card_clk),
        .rst            (rst_all),
        .sd_init_done   (sd_init_done),
        .audio_sec      (audio_sec),
        .audio_sec_cnt  (audio_sec_cnt),
        .jump           (audio_jump),
        .jump_cell      (audio_cell[2:0]),

        .b_req          (aud_bus_want),
        .sec_read       (aud_rd_req),
        .sec_addr       (aud_rd_addr),
        .data           (aud_rd_data),
        .valid          (aud_rd_valid),
        .end_of_sec     (aud_rd_end),

        .wr_en          (aud_fifo_wr_en),
        .wr_data        (aud_fifo_wr_data),
        .wr_full        (aud_fifo_wr_full),
        .wr_level       (aud_fifo_level)
    );

    //---- 跨时钟域样本缓冲（写 100MHz / 读 12.288MHz），2048 个样本
    audio_fifo #(
        .DATA_W (16),
        .AW     (11)
    ) u_audio_fifo (
        .wr_clk   (sd_card_clk),
        .wr_rst   (rst_all),
        .wr_en    (aud_fifo_wr_en),
        .wr_data  (aud_fifo_wr_data),
        .wr_full  (aud_fifo_wr_full),
        .wr_level (aud_fifo_level),

        .rd_clk   (audio_mclk),
        .rd_rst   (rst_all),
        .rd_en    (aud_fifo_rd_en),
        .rd_data  (aud_fifo_rd_data),
        .rd_empty (aud_fifo_empty)
    );

    //---- 按 48kHz 从 FIFO 取样本送给 HDMI 核（输出格式与旧播放器一致）
    audio_player_stream #(
        .MCLK_HZ   (12_288_000),
        .SAMPLE_HZ (48_000)
    ) u_audio_player_stream (
        .mclk           (audio_mclk),
        .rst_mclk       (rst_all),

        .fifo_rd_en     (aud_fifo_rd_en),
        .fifo_rd_data   (aud_fifo_rd_data),
        .fifo_empty     (aud_fifo_empty),

        .enable         (audio_en),

        .vid_clk        (video_clk),
        .rst_vid        (rst_all),
        .o_audio_valid  (audio_valid),
        .o_left         (audio_left_data),
        .o_right        (audio_right_data)
    );

    audio_arc_calculate #(
        .ACR_N (6144)
    ) u_audio_arc_calculate (
        .I_clk         (video_clk),
        .I_rst         (rst_all),
        .I_audio_valid (audio_valid),
        .O_acr_valid   (acr_valid),
        .O_acr_cts     (acr_cts),
        .O_acr_n       (acr_n)
    );

    //=========================================================== RGB/DE → AXIS
    wire        axis_s_user;
    wire        axis_s_valid;
    wire        axis_s_last;
    wire [23:0] axis_s_data;
    wire        axis_s_ready;

    video_rgb_to_axis_640x480 u_video_rgb_to_axis (
        .I_clk        (video_clk),
        .I_rst        (rst_all),
        .I_vs         (vs_m),
        .I_de         (de_m),
        .I_rgb        (vout_data),
        .O_video_user (axis_s_user),
        .O_video_valid(axis_s_valid),
        .O_video_last (axis_s_last),
        .O_video_data (axis_s_data)
    );

    //=========================================================== HDMI 发射
    // 【2026-10-18 AC201 修正 · 重要】
    // AC201 底板没有把 HDMI 的 DDC(SCL/SDA) 接到 FPGA（官方 IO.adc 里根本没有这两个脚）。
    // 原实现沿用 HX4S20C 的做法：上电 1.33ms 后自动发一次 EDID 读触发。
    // 在 AC201 上这等于让核的 I2C 主机去读一个不存在的从机：收不到 ACK，只能等超时，
    // 严重时会让核停在"等 EDID"状态而完全不输出 TMDS —— 表现就是显示黑屏/无信号。
    // 官方 AC201 参考实现把这一步交给按键（design_top_wrapper.v: I_edid_read_trig = S_key_trig），
    // 即"默认不读"。本工程同样固定为 0：核只用下面例化时显式给出的
    // HTOTAL/VTOTAL/VIC 等固定参数出图，完全不依赖 EDID。
    wire        edid_trig = 1'b0;
    wire        edid_valid;
    wire [7:0]  edid_data;

    wire [9:0]  tmds_ch0_data;
    wire [9:0]  tmds_ch1_data;
    wire [9:0]  tmds_ch2_data;
    wire [9:0]  tmds_clk_data;

    // startup_pulse 在 AC201 上不再使用：EDID 读被永久关闭（见上方说明）。
    // 模块文件保留，方便将来若接入 DDC 时改回"按键触发读 EDID"。

    hdmi_1_4b_transmitter_core_wrapper #(
        .DEVICE            ("EG"),
        .HTOTAL            (1650),
        .HSA               (40),
        .HFP               (110),
        .HBP               (220),
        .HACTIVE           (1280),
        .VTOTAL            (750),
        .VSA               (5),
        .VFP               (5),
        .VBP               (20),
        .VACTIVE           (720),
        // 【2026-10-18 AC201 修正】官方 AC201 的 1280x720 参考实现用的是 VIC=69
        // （见 ac201_docs/.../design_top_wrapper.v 第 137 行），不是 VIC=4。
        // 两者时序相同，但核内部按 VIC 生成 AVI InfoFrame；照抄官方值最保险。
        .VIDEO_VIC         (69),
        .VIDEO_TPG         ("Disable"),
        .VIDEO_FORMAT      ("RGB"),
        .AUDIO_SAMPLE_RATE ("48K"),
        .IIC_SCL_DIV       (125)
    ) u_hdmi_core (
        .I_pixel_clk        (video_clk),
        .I_rst              (rst_all),
        .I_edid_read_trig   (edid_trig),
        .O_edid_read_valid  (edid_valid),
        .O_edid_read_data   (edid_data),

        .I_axis_s_user      (axis_s_user),
        .I_axis_s_valid     (axis_s_valid),
        .I_axis_s_last      (axis_s_last),
        .I_axis_s_data      (axis_s_data),
        .O_axis_s_ready     (axis_s_ready),

        .I_audio_valid      (audio_valid),
        .I_audio_left_data  (audio_left_data),
        .I_audio_right_data (audio_right_data),
        .I_acr_valid        (acr_valid),
        .I_acr_cts          (acr_cts),
        .I_acr_n            (acr_n),

        .O_video_locked     (),
        // AC201 底板的 HDMI 座未把 DDC 接到 FPGA（官方 IO.adc 无此引脚），
        // 两个端口悬空不接；若上板发现 HDMI 核因等 EDID 而不出图，
        // 备选方案是给显示器强制当默认 EDID（见 port_ac201/README.md 风险 R2）。
        .O_ddc_scl          (),
        .IO_ddc_sda         (),

        .O_ch0_tmds_data    (tmds_ch0_data),
        .O_ch1_tmds_data    (tmds_ch1_data),
        .O_ch2_tmds_data    (tmds_ch2_data),
        .O_clk_tmds_data    (tmds_clk_data)
    );

    hdmi_phy_wrapper #(
        .DEVICE ("EG")
    ) u_hdmi_phy (
        .I_pixel_clk        (video_clk),
        .I_serial_clk       (hdmi_5x_clk),
        .I_rst              (rst_all),
        .I_tmds_channel_0   (tmds_ch0_data),
        .I_tmds_channel_1   (tmds_ch1_data),
        .I_tmds_channel_2   (tmds_ch2_data),
        .I_tmds_channel_clk (tmds_clk_data),
        .O_tmds_ch0_p       (HDMI_D0_P),
        .O_tmds_ch1_p       (HDMI_D1_P),
        .O_tmds_ch2_p       (HDMI_D2_P),
        .O_tmds_clk_p       (HDMI_CLK_P)
    );

    //=========================================================== 数码管
    wire [7:0] seg_d0, seg_d1, seg_d2, seg_d3, seg_d4, seg_d5;
    wire [5:0] seg_sel_w;               // AC201 版：seg_scan 输出改接片内
    wire [7:0] seg_data_w;

    seg_status u_seg_status (
        .state_code   (sched_state),
        .cur_id       (cur_id),
        .n_img        ((img_count > 16'd8) ? 4'd8 : img_count[3:0]),
        .auto_en      (auto_en),
        .emerg_en     (emerg_en),
        .sd_init_done (sd_init_done),
        .err_byte     (err_code[7:0] | last_err[7:0]),

        .seg_data_0   (seg_d0),
        .seg_data_1   (seg_d1),
        .seg_data_2   (seg_d2),
        .seg_data_3   (seg_d3),
        .seg_data_4   (seg_d4),
        .seg_data_5   (seg_d5)
    );

    seg_scan u_seg_scan (
        .clk        (clk),
        .rst_n      (rst_n),
        .seg_sel    (seg_sel_w),        // AC201 版：片内信号，经 seg_595 串行化
        .seg_data   (seg_data_w),
        .seg_data_0 (seg_d0),
        .seg_data_1 (seg_d1),
        .seg_data_2 (seg_d2),
        .seg_data_3 (seg_d3),
        .seg_data_4 (seg_d4),
        .seg_data_5 (seg_d5)
    );

    // AC201 数码管是 2 片 74HC595 串行驱动（3 根线），不是 HX4S20C 的 14 根直驱。
    // seg_595 把 {段码, 位选} 每次锁存成 16 bit 并行输出：
    //   - 段码直通（低有效，与 AC201 官方 HEX8 的段码极性一致）
    //   - 位选取反成高有效（AC201 官方 sel 是高有效一位选通）
    //   - 高 2 位补 1（未选通）：板上 8 位数码管只亮低 6 位，与原工程一致
    seg_595 #(
        .CLK_FREQ       (50_000_000),
        .SCLK_FREQ      (1_000_000),
        .SEG_SENT_FIRST (1'b1),         // 官方 HC595_Driver：{seg, sel} 段码字节先发
        .DIGIT_POLARITY (1'b0)          // 0 = 输出高有效位选（AC201 官方约定）
    ) u_seg_595 (
        .clk       (clk),
        .rst_n     (rst_n),
        .seg_sel_n ({2'b11, seg_sel_w}),   // 低有效，与 seg_scan 输出直接对接
        .seg_data  (seg_data_w),
        .ser       (seg_ser),
        .srclk     (seg_sclk),
        .rclk      (seg_rclk)
    );

    //=========================================================== 指示灯
    // 心跳灯直接用 50MHz 输入时钟、不受复位控制：
    // 只要 FPGA 配置成功、晶振在跑，LED[3] 就一定闪 —— 这是"程序活着"的硬判据。
    // （原实现挂在 video_clk 上且受 rst_all 复位，video PLL 一出问题灯就不亮，
    //   上板时会被误判成"程序没烧进去"。【2026-10-12 修正】）
    reg [23:0] hb_cnt = 24'd0;
    always @(posedge clk) hb_cnt <= hb_cnt + 24'd1;

    //=========================================================== 指示灯
    // AC201 的 4 只 LED 是低电平点亮（官方例程 led.v 用 4'b1110 流水点亮），
    // 而 HX4S20C 是高电平点亮 → 片内先算"亮 = 1"，出端口统一取反。
    wire [3:0] led_on;
    assign led = ~led_on;
    assign led_on[0] = sd_init_done;    // SD 卡初始化完成
    assign led_on[1] = auto_en;         // 自动轮播开着
    assign led_on[2] = emerg_en;        // 处于应急模式
    assign led_on[3] = hb_cnt[23];      // 心跳，50MHz 下约 0.17 秒翻转一次

endmodule
