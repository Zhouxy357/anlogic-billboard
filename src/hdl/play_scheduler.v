//============================================================================
// play_scheduler.v  ——  三层优先级调度器（M3 模块，整个系统的“大脑”）
//---------------------------------------------------------------------------
// 【与官方例程的差别，答辩时要讲清楚】
//   例程 sd_card_bmp.v：只有两个按键（key1 下一张 / key2 自动开关），
//                       逻辑写在一个大文件里，优先级只有“手动 > 自动”。
//   本工程           ：把调度单独抽成一个模块，做成三层优先级
//                       应急(最高) > 手动 > 自动轮播(最低)
//                       并且把“什么时候切缓冲区”这件事交给转场控制器决定，
//                       只有在画面淡到全黑的那一刻才真正换帧，所以不会撕裂。
//
// 【优先级怎么体现】
//   同一拍里如果多个按键都按下了，下面 if-else 链越靠前的越优先：
//       ① key4 应急开关      —— 保安/老板一键切到告警画面，并锁住不走轮播
//       ② key3 轮播周期切换   —— 2s / 5s / 10s / 20s 循环
//       ③ key2 自动轮播开关   —— 开/关
//       ④ key1 手动下一张     —— 只有当“非应急”时才生效
//       ⑤ 自动轮播到点        —— 最低优先级
//
// 【为什么要有 write_buf_idx / disp_buf_idx 两个指针】
//   SDRAM 里放了两块 1280x720 的帧缓存（BUF0 / BUF1），这是例程就有的双缓冲。
//   显示用一块(disp)，往另一块(write)写新图片；写完 + 转场到全黑 → 两个指针
//   互换。这样“读”和“写”永远不在同一块内存上，画面不会花。
//
// 【时钟域】
//   本模块工作在 sd_card_clk = 100MHz 域（和 SD 卡、ebm_reader 同一个域）。
//   与视频域(75MHz)、音频域(12.288MHz)之间的握手都在 top_billboard.v 里做，
//   本模块只负责发出/接收已经同步好的单拍脉冲。
//============================================================================
`timescale 1ns / 1ps

module play_scheduler #(
    parameter [3:0]   EMERG_ID   = 4'd0,        // 应急画面用的图片 id
    parameter integer BOOT_DLY   = 50_000_000,  // 上电等待 0.5s 再读卡
    parameter integer IMG_MAX    = 8            // 与 ebm_reader 的 MAX_IMG 保持一致
)(
    input  wire        clk,             // sd_card_clk 100MHz
    input  wire        rst,             // 高有效复位
    input  wire        sd_init_done,    // SD 卡初始化完成
    input  wire        frame_tick,      // 每显示完一帧给 1 拍（已在 top 里同步到本域）

    //---- 4 个按键：已消抖，按下瞬间给 1 拍高电平 ----
    //   必须是“1 拍脉冲”。本模块内部还做了一次上升沿检测（见 key_rise），
    //   所以即使上游不小心给成“按住多拍”，每次按下也只会算一次。
    input  wire [3:0]  key_press,       // [0]key1下一张 [1]key2自动开关 [2]key3周期 [3]key4应急

    //---- 与 ebm_reader 交互 ----
    output reg         idx_start,       // 1 拍：请求读容器头 + 索引表
    input  wire        index_ready,     // 索引表已就绪
    input  wire [15:0] img_count,       // 容器里的图片数
    input  wire [15:0] err_code,        // ebm_reader 的错误码（只看不改）

    output reg         load_start,      // 1 拍：开始装载一张图
    output reg  [3:0]  load_id,         // 要装载的图片 id
    input  wire        load_busy,       // 装载中
    input  wire        load_done,       // 1 拍：SD 侧已把整张图送进写 FIFO
    input  wire        write_done,      // 1 拍：SDRAM 侧确认这一帧真的写完了
    input  wire        load_error,      // 1 拍：装载失败

    //---- 给 frame_read_write 的两个缓冲区指针 ----
    output reg  [1:0]  write_buf_idx,
    output reg  [1:0]  disp_buf_idx,

    //---- 与 transition_ctrl 交互（中间由 top 做跨域同步）----
    output reg         req_switch,      // 请求换帧（保持到收到 ack）
    input  wire        ack_switch,      // 1 拍：转场已到全黑，可以换帧了

    //---- 给音频播放器：当前画面绑定的音效段 ----
    output reg  [3:0]  audio_seg,       // 段号 = 图片 id 的低 2 位（片内 4 段音效时代用）
    output reg         audio_seg_tgl,   // 段号变化时翻转（跨到音频域的握手信号）

    //---- 给 TF 卡音频流：当前画面应该播放哪一格语音 ----
    // audio_cell 是图片 id（0..7），每一格 = 10 秒；audio_cell_tgl 每换一次图翻转，
    // top 用它做边沿检测，得到 1 拍 jump 脉冲 → audio_stream 跳到该格开头。
    output reg  [3:0]  audio_cell,
    output reg         audio_cell_tgl,

    //---- 状态输出，给数码管和调试用 ----
    output reg  [3:0]  state_code,      // 0初始化 1读索引 2显示中 3装载 4换帧 5出错
    output reg  [3:0]  cur_id,          // 当前正在显示的图片 id
    output reg  [3:0]  normal_id,       // 轮播序列里的 id（应急时不变）
    output reg         auto_en,         // 自动轮播是否开启
    output reg         emerg_en,        // 是否处于应急状态
    output reg  [1:0]  dwell_sel,       // 轮播周期档位 0..3
    output reg  [15:0] last_err,        // 最近一次错误码（锁存）

    //---- 调试观察口（只读，不参与逻辑；给调试版顶层显示到数码管）----
    output wire [19:0] dbg_dwell_cnt,   // 当前图已显示的帧数
    output wire [19:0] dbg_dwell_tgt,   // 当前档位对应的目标帧数
    output wire [19:0] dbg_block_cnt    // 出错冷却剩余帧数
);

    //----------------------------------------------------------- 状态编码
    localparam [3:0] S_INIT = 4'd0;   // 等 SD 卡初始化 + 上电延时
    localparam [3:0] S_IDX  = 4'd1;   // 读容器头 + 索引表
    localparam [3:0] S_RUN  = 4'd2;   // 正常显示，等事件
    localparam [3:0] S_LOAD = 4'd3;   // 正在把某张图装进帧缓存
    localparam [3:0] S_SWAP = 4'd4;   // 等转场到全黑，然后切缓冲区
    localparam [3:0] S_ERR  = 4'd5;   // 出错了（比如容器里没有图）

    //----------------------------------------------------------- 轮播周期档位
    // 以“帧”为单位，视频是 60 帧/秒。
    // 按键在 4 个档位间循环：2s → 5s → 10s → 20s → 2s ...
    reg [19:0] dwell_target;
    always @(*) begin
        case (dwell_sel)
            2'd0:    dwell_target = 20'd120;    // 120 帧 ≈ 2 秒
            2'd1:    dwell_target = 20'd300;    // 300 帧 ≈ 5 秒
            2'd2:    dwell_target = 20'd600;    // 600 帧 ≈ 10 秒
            default: dwell_target = 20'd1200;   // 1200 帧 ≈ 20 秒
        endcase
    end

    //----------------------------------------------------------- 内部寄存器
    reg [25:0] boot_cnt;        // 上电/重试延时计数
    reg [19:0] dwell_cnt;       // 当前这张图已经显示了多久（帧）
    reg [19:0] block_cnt;       // 出错后的冷却期，冷却期内不自动换图
    reg [26:0] swap_tout;       // 换帧等待 ack 的超时保护（约 1 秒）
    reg [3:0]  want_id;         // 想要装载的图片 id
    reg [3:0]  state;

    // 这两个标志用来“记住”两件事都办完了，顺序先后都不会漏掉：
    //   load_done_lat  —— SD 侧已经把整张图送进写 FIFO
    //   write_done_lat —— SDRAM 侧确认这一帧写完了
    // 两个都是 1 才允许换帧，这样绝对不会显示到“只写了一半”的画面。
    reg        load_done_lat;
    reg        write_done_lat;

    //----------------------------------------------------------- 按键上升沿检测
    // 【为什么必须做这一步】
    //   key2（自动开关）和 key3（周期档位）这两个按键“不改变状态机状态”，
    //   所以如果 key_press 高电平不止 1 拍，同一个按键会在连续几拍里被反复
    //   执行：auto_en 翻两次等于没翻，dwell_sel 会从 2 一下跳到 0。
    //   这里用“本拍为 1 且上拍为 0”取出严格的一次按沿，彻底杜绝连击。
    reg  [3:0] key_d;
    wire [3:0] key_rise = key_press & ~key_d;

    always @(posedge clk or posedge rst) begin
        if (rst) key_d <= 4'b0000;
        else     key_d <= key_press;
    end

    //----------------------------------------------------------- 容器里的图片数
    // 取“容器声明的张数”和“本工程支持的上限 IMG_MAX”里较小的那个。
    // 注意不能写成 img_count[3:0] 直接截断：那样当张数是 16 的倍数时会变成 0。
    localparam [3:0] IMG_MAX4 = IMG_MAX;
    wire [3:0] n_img = (img_count > IMG_MAX) ? IMG_MAX4 : img_count[3:0];

    // 轮播序列里的“下一张”，到末尾自动绕回第 0 张
    wire [3:0] next_normal = ((normal_id + 4'd1) >= n_img) ? 4'd0 : (normal_id + 4'd1);

    //=========================================================== 主状态机
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            state          <= S_INIT;
            boot_cnt       <= 26'd0;
            dwell_cnt      <= 20'd0;
            block_cnt      <= 20'd0;
            swap_tout      <= 27'd0;
            load_done_lat  <= 1'b0;
            write_done_lat <= 1'b0;
            idx_start      <= 1'b0;
            load_start     <= 1'b0;
            load_id        <= 4'd0;
            req_switch     <= 1'b0;
            write_buf_idx  <= 2'd1;     // 上电先往 BUF1 写，显示 BUF0
            disp_buf_idx   <= 2'd0;
            audio_seg      <= 4'd0;
            audio_seg_tgl  <= 1'b0;
            audio_cell     <= 4'd0;
            audio_cell_tgl <= 1'b0;
            state_code     <= 4'd0;
            cur_id         <= 4'd0;
            normal_id      <= 4'd0;
            want_id        <= 4'd0;
            auto_en        <= 1'b1;     // 上电默认开启自动轮播
            emerg_en       <= 1'b0;
            dwell_sel      <= 2'd2;     // 默认 10 秒
            last_err       <= 16'd0;
        end
        else if (!sd_init_done) begin
            // SD 卡还没准备好：全部推回起点，别乱发请求
            state          <= S_INIT;
            boot_cnt       <= 26'd0;
            dwell_cnt      <= 20'd0;
            block_cnt      <= 20'd0;
            idx_start      <= 1'b0;
            load_start     <= 1'b0;
            req_switch     <= 1'b0;
            state_code     <= 4'd0;
            load_done_lat  <= 1'b0;
            write_done_lat <= 1'b0;
        end
        else begin
            // 这两个是“1 拍脉冲”，默认拉低，需要时在下面置起
            idx_start  <= 1'b0;
            load_start <= 1'b0;

            case (state)

            //================================================== 上电等待
            S_INIT: begin
                state_code <= 4'd0;
                if (boot_cnt >= BOOT_DLY) begin
                    boot_cnt  <= 26'd0;
                    idx_start <= 1'b1;      // 发一拍，让 ebm_reader 去读容器头
                    state     <= S_IDX;
                end else begin
                    boot_cnt <= boot_cnt + 26'd1;
                end
            end

            //================================================== 读索引
            S_IDX: begin
                state_code <= 4'd1;
                if (index_ready) begin
                    if (n_img != 4'd0) begin
                        // 有图：立刻装载第 0 张，先把画面点亮
                        normal_id  <= 4'd0;
                        want_id    <= 4'd0;
                        load_id    <= 4'd0;
                        load_start <= 1'b1;
                        dwell_cnt  <= 20'd0;
                        state      <= S_LOAD;
                    end else begin
                        // 容器里一张图都没有：报错，退回重试
                        last_err <= 16'h0008;   // E_COUNT
                        state    <= S_ERR;
                    end
                end
            end

            //================================================== 出错等待
            S_ERR: begin
                state_code <= 4'd5;
                // 等 2 秒再重试一次，免得对着坏卡疯狂读
                if (boot_cnt >= 26'd50_000_000) begin
                    boot_cnt <= 26'd0;
                    state    <= S_INIT;
                end else begin
                    boot_cnt <= boot_cnt + 26'd1;
                end
            end

            //================================================== 正常显示中
            S_RUN: begin
                state_code <= 4'd2;

                // 每显示一帧，驻留计时 +1
                if (frame_tick && dwell_cnt != 20'hFFFFF)
                    dwell_cnt <= dwell_cnt + 20'd1;

                // 出错冷却期递减
                if (block_cnt != 20'd0 && frame_tick)
                    block_cnt <= block_cnt - 20'd1;

                //---------- 按优先级从高到低判断 ----------
                // 用 key_rise（严格一次按沿），而不是 key_press 电平，
                // 保证“按住不放”也只会执行一次。
                if (key_rise[3]) begin
                    // ① key4：应急 开/关（最高优先级，随时可打断）
                    emerg_en  <= ~emerg_en;
                    dwell_cnt <= 20'd0;
                    if (~emerg_en) begin
                        // 即将进入应急 → 切到告警画面
                        if (EMERG_ID < n_img) begin
                            want_id    <= EMERG_ID;
                            load_id    <= EMERG_ID;
                            load_start <= 1'b1;
                            state      <= S_LOAD;
                        end
                    end else begin
                        // 即将解除应急 → 回到轮播序列里那张
                        if (normal_id < n_img) begin
                            want_id    <= normal_id;
                            load_id    <= normal_id;
                            load_start <= 1'b1;
                            state      <= S_LOAD;
                        end
                    end
                end
                else if (key_rise[2]) begin
                    // ② key3：切换轮播周期 2s→5s→10s→20s
                    dwell_sel <= dwell_sel + 2'd1;
                    dwell_cnt <= 20'd0;
                end
                else if (key_rise[1]) begin
                    // ③ key2：自动轮播 开/关
                    auto_en   <= ~auto_en;
                    dwell_cnt <= 20'd0;
                end
                else if (!emerg_en && key_rise[0]) begin
                    // ④ key1：手动下一张（应急状态下忽略）
                    normal_id  <= next_normal;
                    want_id    <= next_normal;
                    load_id    <= next_normal;
                    load_start <= 1'b1;
                    dwell_cnt  <= 20'd0;
                    state      <= S_LOAD;
                end
                else if (!emerg_en && auto_en && block_cnt == 20'd0 &&
                         dwell_cnt >= dwell_target) begin
                    // ⑤ 自动轮播到点
                    normal_id  <= next_normal;
                    want_id    <= next_normal;
                    load_id    <= next_normal;
                    load_start <= 1'b1;
                    dwell_cnt  <= 20'd0;
                    state      <= S_LOAD;
                end
            end

            //================================================== 装载一张图
            S_LOAD: begin
                state_code <= 4'd3;

                if (load_error) begin
                    // 装载失败：画面保持不动，记录错误，冷却一个轮播周期再试
                    last_err       <= err_code;
                    block_cnt      <= dwell_target;
                    dwell_cnt      <= 20'd0;
                    load_done_lat  <= 1'b0;
                    write_done_lat <= 1'b0;
                    state          <= S_RUN;
                end
                else begin
                    // 分别记住两件事，谁先到都没关系
                    if (load_done)  load_done_lat  <= 1'b1;
                    if (write_done) write_done_lat <= 1'b1;

                    if (load_done_lat && write_done_lat) begin
                        // 图确实完整写进 write 缓冲区了，
                        // 现在请转场控制器把画面淡到全黑
                        load_done_lat  <= 1'b0;
                        write_done_lat <= 1'b0;
                        req_switch     <= 1'b1;
                        swap_tout      <= 27'd0;
                        state          <= S_SWAP;
                    end
                end
            end

            //================================================== 全黑瞬间切缓冲
            S_SWAP: begin
                state_code <= 4'd4;
                if (ack_switch || (swap_tout >= 27'd100_000_000)) begin
                    // 正常情况走 ack_switch；
                    // 万一转场控制器没回应（理论上不会），1 秒后强制切换，
                    // 保证系统不会永久停在黑屏。
                    swap_tout      <= 27'd0;
                    req_switch     <= 1'b0;
                    disp_buf_idx   <= write_buf_idx;     // 显示刚写好的那块
                    // 【注意】这里千万不能写 write_buf_idx <= ~write_buf_idx !
                    // 这两个指针是 2bit（frame_read_write 最多支持 4 块缓冲），
                    // 而本工程只用第 0、1 块。对 2bit 取反得到的是 2 或 3，
                    // 指针就会指到根本没分配内存的 2/3 号缓冲区 → 上板必花屏。
                    // 正确做法是只把最低位取反，高位补 0。
                    write_buf_idx  <= {1'b0, ~write_buf_idx[0]};  // 0 -> 1 -> 0 ...
                    cur_id         <= want_id;
                    audio_seg      <= {2'b00, want_id[1:0]};
                    audio_seg_tgl  <= ~audio_seg_tgl;    // 通知音频域换段
                    audio_cell     <= want_id;           // 该播第几格语音
                    audio_cell_tgl <= ~audio_cell_tgl;   // 换格 → top 出 jump 脉冲
                    dwell_cnt      <= 20'd0;
                    load_done_lat  <= 1'b0;
                    write_done_lat <= 1'b0;
                    state          <= S_RUN;
                end else begin
                    swap_tout <= swap_tout + 27'd1;
                end
            end

            default: state <= S_INIT;
            endcase
        end
    end

    // 调试观察口
    assign dbg_dwell_cnt = dwell_cnt;
    assign dbg_dwell_tgt = dwell_target;
    assign dbg_block_cnt = block_cnt;

endmodule
