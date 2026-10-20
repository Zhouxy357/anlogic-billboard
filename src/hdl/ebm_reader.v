//============================================================================
// ebm_reader.v  ——  私有素材容器 EBM1 的解析与装载（M2 模块）
//---------------------------------------------------------------------------
// 【与官方例程的差别，答辩时要讲清楚】
//   例程 bmp_read.v：在 TF 卡的 FAT32 文件系统里“扫描目录”，逐个扇区嗅探
//                    文件头 42 4D（"BM"）去找图片，靠猜。
//   本工程        ：不用文件系统。PC 端工具把若干张图打包成一个私有容器
//                    EBM1，写在 TF 卡的固定扇区区；FPGA 端读取容器头和索引
//                    表后，按索引表里的绝对扇区号“定长寻址”直接取像素，
//                    并顺带做完整性校验。装载模型与例程完全不同，且更鲁棒。
//
// 【容器 EBM1 磁盘布局】  起始扇区 CONTAINER_LBA（默认 1048576，即 512MiB 偏移）
//   为什么放这么靠后：这个位置在所有常见容量 SD 卡的 FAT32 元数据和数据区之后，
//   所以把容器写进卡里之后，卡插回电脑仍然能被正常识别（不会被当成坏卡）。
//   注意 PC 端 tools/gen_container.py 的 --lba 必须和这里的 CONTAINER_LBA 一致。
//   LBA+0 : 头部 512 字节
//       偏移 0x00  char[4] magic = "EBM1"
//       偏移 0x04  u16     version = 1
//       偏移 0x06  u16     image_count
//       偏移 0x08  u16     width  = 1280
//       偏移 0x0A  u16     height = 720
//       偏移 0x0C  u8      bytes_per_pixel = 3
//       偏移 0x0D  u8      checksum_mode = 1（Fletcher 变体，模 256）
//   LBA+1 : 索引表 512 字节，最多 32 项，每项 16 字节
//       偏移 +0   u8  id
//       偏移 +1   u8  flags
//       偏移 +2..3    reserved
//       偏移 +4..7  u32 pixel_sector（像素数据起始绝对扇区号，小端）
//       偏移 +8..11 u32 byte_len（像素字节数，小端）
//       偏移 +12..15 u32 cksum（低 16 位有效：{sum2, sum1}）
//   LBA+2 起 ：各图片像素数据，顺序连续存放
//
// 【像素数据格式】= BMP 像素区原样搬运：
//   每像素 3 字节，顺序 B、G、R；行自下而上；每行字节数 4 字节对齐
//   （1280×3 = 3840 已是 4 的倍数，所以没有填充）。
//   这样下游 frame_read_write 的 WRITE_V_FLIP=1 可直接把画面翻正，
//   与例程使用完全相同的已验证通路。
//
// 【校验算法】Fletcher 变体（模 256），对像素区每个字节依次做：
//       s1 = (s1 + byte) & 0xFF
//       s2 = (s2 + s1)     & 0xFF
//   校验值 = {s2, s1}。校验不通过只在数码管上报警告（bit5），画面照常显示，
//   避免因为一个算法细节把整个系统卡死。
//============================================================================
`timescale 1ns / 1ps

module ebm_reader #(
    // 容器起始扇区。1048576 = 512MiB 偏移，这个位置在所有常见容量 SD 卡的
    // FAT32 文件系统数据区之后，所以写完容器后卡还能被电脑认出来。
    // 如果换成别的位置，记得 PC 端工具 gen_container.py 的 --lba 参数要一致。
    parameter [31:0] CONTAINER_LBA = 32'd1048576,
    parameter integer MAX_IMG      = 8,            // 支持的最大图片数
    parameter [31:0] PIX_BYTES     = 32'd2764800,  // 1280*720*3
    parameter integer TIMEOUT_CYC  = 8_000_000     // 单次扇区操作超时（80ms@100MHz）
)(
    input  wire        clk,               // sd_card_clk 100MHz
    input  wire        rst,
    input  wire        sd_init_done,      // SD 卡初始化完成

    //---- 与调度器交互 ----
    input  wire        start,             // 1 拍：读取容器头 + 索引表
    output reg         index_ready,       // 索引表已就绪（保持到下次 start）
    output reg  [15:0] img_count,         // 容器里实际图片数
    output reg  [15:0] err_code,          // 错误码，见文件头注释
    output reg  [3:0]  state_code,        // 状态码，给数码管
    output reg         busy,              // 读卡器忙

    input  wire        load_start,        // 1 拍：开始装载一张图
    input  wire [3:0]  load_id,           // 要装载的图片 id
    output reg         load_busy,         // 装载中
    output reg         load_done,         // 1 拍：像素已全部送进写 FIFO
    output reg         load_error,        // 1 拍：装载失败

    //---- 音频区信息（EBM2 新增；EBM1 容器时为 0，表示没有音频）----
    output reg  [31:0] audio_sec,         // 音频区起始绝对扇区
    output reg  [31:0] audio_sec_cnt,     // 音频区总扇区数（0 = 无音频）
    output reg         audio_ok,          // 容器里确实带了音频

    //---- 写 SDRAM 通路：直接对接 frame_read_write 的 write_* 接口 ----
    output reg         write_req,
    input  wire        write_req_ack,
    output reg         write_en,
    // write_data 是用 assign 连续赋值驱动的（像素拼装完就直接送出去，
    // 不需要再打一拍），所以这里必须声明成 wire。
    // 如果写成 output reg，ModelSim/TD 会报
    // “Register is illegal in left-hand side of continuous assignment”。
    output wire [31:0] write_data,

    //---- SD 扇区读：直接对接 sd_card_top ----
    output reg         sd_sec_read,
    output reg  [31:0] sd_sec_read_addr,
    input  wire [7:0]  sd_sec_read_data,
    input  wire        sd_sec_read_data_valid,
    input  wire        sd_sec_read_end
);

    //----------------------------------------------------------- 状态编码
    localparam [3:0] ST_IDLE  = 4'd0;
    localparam [3:0] ST_HDR   = 4'd1;
    localparam [3:0] ST_IDX   = 4'd2;
    localparam [3:0] ST_LWAIT = 4'd3;
    localparam [3:0] ST_LDATA = 4'd4;
    localparam [3:0] ST_DONE  = 4'd5;

    //----------------------------------------------------------- 错误位定义
    localparam [15:0] E_MAGIC  = 16'h0001;   // "EBM1" 不匹配
    localparam [15:0] E_VER    = 16'h0002;   // 版本不支持
    localparam [15:0] E_FORMAT = 16'h0004;   // 宽/高/位深不符
    localparam [15:0] E_COUNT  = 16'h0008;   // 图片数为 0 或超上限
    localparam [15:0] E_ID     = 16'h0010;   // 请求的 id 越界
    localparam [15:0] E_CKSUM  = 16'h0020;   // 校验和不匹配（仅警告）
    localparam [15:0] E_TIMEOUT= 16'h0040;   // SD 读超时
    localparam [15:0] E_NOTIDX = 16'h0080;   // 索引表尚未就绪

    //----------------------------------------------------------- 寄存器
    reg [3:0]  state;

    reg [9:0]  rd_cnt;                 // 扇区内已收到的字节序号
    reg [31:0] bcnt;                   // 像素区已收到的字节数
    reg [1:0]  bidx;                   // 像素内字节序号 0/1/2
    reg [23:0] rgb;                    // 拼装中的像素

    // 头部字段
    reg [31:0] hdr_magic;
    reg [15:0] hdr_ver;
    reg [15:0] hdr_cnt;
    reg [15:0] hdr_w;
    reg [15:0] hdr_h;
    reg [7:0]  hdr_bpp;
    reg [7:0]  hdr_ckm;

    // EBM2 新增：音频区描述（0x10 音频起始扇区 / 0x14 音频字节数）
    reg [31:0] hdr_asec;
    reg [31:0] hdr_alen;

    // 索引表缓存
    reg [3:0]  ent_id  [0:MAX_IMG-1];
    reg [31:0] ent_sec [0:MAX_IMG-1];
    reg [31:0] ent_len [0:MAX_IMG-1];
    reg [15:0] ent_ck  [0:MAX_IMG-1];

    // 本次装载参数
    reg [31:0] cur_sec;
    reg [31:0] cur_len;
    reg [15:0] cur_ck;
    reg [3:0]  cur_id;

    // Fletcher 校验累加器
    reg [7:0]  s1, s2;
    wire [7:0] s1_nxt = s1 + sd_sec_read_data;

    // 超时保护：只要在等 SD 卡而长期没有推进就中止，保证系统不会卡死
    reg [31:0] tout;

    wire pix_byte_vld = (state == ST_LDATA) &&
                        (sd_sec_read_data_valid == 1'b1) &&
                        (bcnt < cur_len);

    assign write_data = {rgb[23:16], rgb[15:8], rgb[7:0], 8'b0};

    //----------------------------------------------------------- 字节序号
    always @(posedge clk or posedge rst) begin
        if (rst)
            rd_cnt <= 10'd0;
        else if ((state == ST_HDR) || (state == ST_IDX)) begin
            if (sd_sec_read_data_valid)
                rd_cnt <= rd_cnt + 10'd1;
            else if (sd_sec_read_end)
                rd_cnt <= 10'd0;
        end else
            rd_cnt <= 10'd0;
    end

    //----------------------------------------------------------- 头部解析
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            hdr_magic <= 32'd0;
            hdr_ver   <= 16'd0;
            hdr_cnt   <= 16'd0;
            hdr_w     <= 16'd0;
            hdr_h     <= 16'd0;
            hdr_bpp   <= 8'd0;
            hdr_ckm   <= 8'd0;
            hdr_asec  <= 32'd0;
            hdr_alen  <= 32'd0;
        end else if ((state == ST_HDR) && sd_sec_read_data_valid) begin
            case (rd_cnt)
                10'd0: hdr_magic[7:0]   <= sd_sec_read_data;
                10'd1: hdr_magic[15:8]  <= sd_sec_read_data;
                10'd2: hdr_magic[23:16] <= sd_sec_read_data;
                10'd3: hdr_magic[31:24] <= sd_sec_read_data;
                10'd4: hdr_ver[7:0]     <= sd_sec_read_data;
                10'd5: hdr_ver[15:8]    <= sd_sec_read_data;
                10'd6: hdr_cnt[7:0]     <= sd_sec_read_data;
                10'd7: hdr_cnt[15:8]    <= sd_sec_read_data;
                10'd8: hdr_w[7:0]       <= sd_sec_read_data;
                10'd9: hdr_w[15:8]      <= sd_sec_read_data;
                10'd10: hdr_h[7:0]      <= sd_sec_read_data;
                10'd11: hdr_h[15:8]     <= sd_sec_read_data;
                10'd12: hdr_bpp         <= sd_sec_read_data;
                10'd13: hdr_ckm         <= sd_sec_read_data;
                //---- EBM2 音频字段（EBM1 容器这里是 0，效果等价于“没有音频”）
                10'd16: hdr_asec[7:0]   <= sd_sec_read_data;
                10'd17: hdr_asec[15:8]  <= sd_sec_read_data;
                10'd18: hdr_asec[23:16] <= sd_sec_read_data;
                10'd19: hdr_asec[31:24] <= sd_sec_read_data;
                10'd20: hdr_alen[7:0]   <= sd_sec_read_data;
                10'd21: hdr_alen[15:8]  <= sd_sec_read_data;
                10'd22: hdr_alen[23:16] <= sd_sec_read_data;
                10'd23: hdr_alen[31:24] <= sd_sec_read_data;
                default: ;
            endcase
        end
    end

    //----------------------------------------------------------- 索引解析
    integer k;
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            for (k = 0; k < MAX_IMG; k = k + 1) begin
                ent_id[k]  <= 4'd0;
                ent_sec[k] <= 32'd0;
                ent_len[k] <= 32'd0;
                ent_ck[k]  <= 16'd0;
            end
        end else if ((state == ST_IDX) && sd_sec_read_data_valid &&
                     (rd_cnt[8:4] < MAX_IMG)) begin
            case (rd_cnt[3:0])
                4'd0:  ent_id [rd_cnt[8:4]]        <= sd_sec_read_data[3:0];
                4'd4:  ent_sec[rd_cnt[8:4]][7:0]   <= sd_sec_read_data;
                4'd5:  ent_sec[rd_cnt[8:4]][15:8]  <= sd_sec_read_data;
                4'd6:  ent_sec[rd_cnt[8:4]][23:16] <= sd_sec_read_data;
                4'd7:  ent_sec[rd_cnt[8:4]][31:24] <= sd_sec_read_data;
                4'd8:  ent_len[rd_cnt[8:4]][7:0]   <= sd_sec_read_data;
                4'd9:  ent_len[rd_cnt[8:4]][15:8]  <= sd_sec_read_data;
                4'd10: ent_len[rd_cnt[8:4]][23:16] <= sd_sec_read_data;
                4'd11: ent_len[rd_cnt[8:4]][31:24] <= sd_sec_read_data;
                4'd12: ent_ck [rd_cnt[8:4]][7:0]   <= sd_sec_read_data;
                4'd13: ent_ck [rd_cnt[8:4]][15:8]  <= sd_sec_read_data;
                default: ;
            endcase
        end
    end

    //----------------------------------------------------------- 像素字节拼装
    always @(posedge clk or posedge rst) begin
        if (rst)
            bidx <= 2'd0;
        else if (state != ST_LDATA)
            bidx <= 2'd0;                       // 只在一次装载内连续计数
        else if (sd_sec_read_data_valid)
            bidx <= (bidx == 2'd2) ? 2'd0 : (bidx + 2'd1);
    end

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            write_en <= 1'b0;
            rgb      <= 24'd0;
        end else if (state != ST_LDATA) begin
            write_en <= 1'b0;
        end else if (pix_byte_vld) begin
            case (bidx)
                2'd0: begin write_en <= 1'b0; rgb[7:0]   <= sd_sec_read_data; end
                2'd1: begin write_en <= 1'b0; rgb[15:8]  <= sd_sec_read_data; end
                2'd2: begin write_en <= 1'b1; rgb[23:16] <= sd_sec_read_data; end
                default: write_en <= 1'b0;
            endcase
        end else begin
            write_en <= 1'b0;
        end
    end

    //----------------------------------------------------------- Fletcher 校验
    // 注意：s1/s2 只能在这一个 always 块里赋值（TD 不允许一个 reg 被两个块驱动）。
    // 非 ST_LDATA 状态一律清零，等价于原来在主状态机 ST_IDLE / 装载启动处的清零。
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            s1 <= 8'd0;
            s2 <= 8'd0;
        end else if (state != ST_LDATA) begin
            s1 <= 8'd0;
            s2 <= 8'd0;
        end else if (pix_byte_vld) begin
            s1 <= s1_nxt;
            s2 <= s2 + s1_nxt;
        end
    end

    //----------------------------------------------------------- 字节计数
    always @(posedge clk or posedge rst) begin
        if (rst)
            bcnt <= 32'd0;
        else if (state != ST_LDATA)
            bcnt <= 32'd0;
        else if (sd_sec_read_data_valid)
            bcnt <= bcnt + 32'd1;
    end

    //----------------------------------------------------------- 超时计数
    always @(posedge clk or posedge rst) begin
        if (rst)
            tout <= 32'd0;
        else if ((state == ST_LWAIT) || (state == ST_LDATA)) begin
            if (sd_sec_read_data_valid || sd_sec_read_end || write_req_ack)
                tout <= 32'd0;
            else if (tout != 32'hFFFFFFFF)
                tout <= tout + 32'd1;
        end else
            tout <= 32'd0;
    end

    //----------------------------------------------------------- 主状态机
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            state       <= ST_IDLE;
            state_code  <= 4'd0;
            index_ready <= 1'b0;
            img_count   <= 16'd0;
            err_code    <= 16'd0;
            busy        <= 1'b0;
            load_busy   <= 1'b0;
            load_done   <= 1'b0;
            load_error  <= 1'b0;
            write_req   <= 1'b0;
            sd_sec_read <= 1'b0;
            sd_sec_read_addr <= 32'd0;
            cur_sec     <= 32'd0;
            cur_len     <= 32'd0;
            cur_ck      <= 16'd0;
            cur_id      <= 4'd0;
            audio_sec     <= 32'd0;
            audio_sec_cnt <= 32'd0;
            audio_ok      <= 1'b0;
        end else if (!sd_init_done) begin
            // SD 卡还没初始化好：全部回到起点，不产生任何请求
            state       <= ST_IDLE;
            state_code  <= 4'd0;
            index_ready <= 1'b0;
            busy        <= 1'b0;
            load_busy   <= 1'b0;
            load_done   <= 1'b0;
            load_error  <= 1'b0;
            write_req   <= 1'b0;
            sd_sec_read <= 1'b0;
            err_code    <= 16'd0;
            img_count   <= 16'd0;
            audio_sec     <= 32'd0;
            audio_sec_cnt <= 32'd0;
            audio_ok      <= 1'b0;
        end else begin
            // 默认每拍都会拉低的脉冲信号
            load_done  <= 1'b0;
            load_error <= 1'b0;

            case (state)

                //============================================== 空闲
                ST_IDLE: begin
                    state_code  <= 4'd1;
                    busy        <= 1'b0;
                    sd_sec_read <= 1'b0;

                    if (start) begin
                        state       <= ST_HDR;
                        busy        <= 1'b1;
                        index_ready <= 1'b0;
                        err_code    <= 16'd0;
                        img_count   <= 16'd0;
                        sd_sec_read_addr <= CONTAINER_LBA;
                    end else if (load_start) begin
                        if (!index_ready) begin
                            err_code   <= err_code | E_NOTIDX;
                            load_error <= 1'b1;
                        end else if ((load_id >= img_count) || (load_id >= MAX_IMG)) begin
                            err_code   <= err_code | E_ID;
                            load_error <= 1'b1;
                        end else begin
                            cur_id  <= load_id;
                            cur_sec <= ent_sec[load_id];
                            cur_len <= ent_len[load_id];
                            cur_ck  <= ent_ck[load_id];
                            write_req <= 1'b1;
                            load_busy <= 1'b1;
                            state     <= ST_LWAIT;
                        end
                    end
                end

                //============================================== 读容器头
                ST_HDR: begin
                    state_code  <= 4'd2;
                    busy        <= 1'b1;
                    sd_sec_read <= 1'b1;

                    if (sd_sec_read_end) begin
                        sd_sec_read <= 1'b0;
                        // 兼容两种容器：
                        //   EBM1 / ver=1 → 只有图片（老卡还能用）
                        //   EBM2 / ver=2 → 图片 + 音频区
                        if ((hdr_magic != 32'h314D4245) &&      // "EBM1"
                            (hdr_magic != 32'h324D4245))        // "EBM2"
                            err_code <= err_code | E_MAGIC;
                        if ((hdr_ver != 16'd1) && (hdr_ver != 16'd2))
                            err_code <= err_code | E_VER;
                        if ((hdr_w != 16'd1280) || (hdr_h != 16'd720) || (hdr_bpp != 8'd3))
                            err_code <= err_code | E_FORMAT;
                        if ((hdr_cnt == 16'd0) || (hdr_cnt > MAX_IMG))
                            err_code <= err_code | E_COUNT;

                        // 音频区：只有 EBM2 且长度非 0 才算有音频
                        if ((hdr_ver == 16'd2) && (hdr_alen != 32'd0)) begin
                            audio_sec     <= hdr_asec;
                            // 向上取整到整扇区
                            audio_sec_cnt <= (hdr_alen + 32'd511) >> 9;
                            audio_ok      <= 1'b1;
                        end else begin
                            audio_sec     <= 32'd0;
                            audio_sec_cnt <= 32'd0;
                            audio_ok      <= 1'b0;
                        end

                        sd_sec_read_addr <= CONTAINER_LBA + 32'd1;
                        state            <= ST_IDX;
                    end
                end

                //============================================== 读索引表
                ST_IDX: begin
                    state_code  <= 4'd2;
                    busy        <= 1'b1;
                    sd_sec_read <= 1'b1;

                    if (sd_sec_read_end) begin
                        sd_sec_read <= 1'b0;
                        state       <= ST_IDLE;
                        busy        <= 1'b0;
                        if (hdr_cnt > MAX_IMG)
                            img_count <= MAX_IMG[15:0];
                        else
                            img_count <= hdr_cnt;
                        index_ready <= 1'b1;
                    end
                end

                //============================================== 等待写握手
                ST_LWAIT: begin
                    state_code <= 4'd3;
                    busy       <= 1'b1;

                    if (write_req_ack) begin
                        write_req        <= 1'b0;
                        sd_sec_read      <= 1'b1;
                        sd_sec_read_addr <= cur_sec;
                        state            <= ST_LDATA;
                    end else if (tout >= TIMEOUT_CYC) begin
                        write_req  <= 1'b0;
                        load_busy  <= 1'b0;
                        load_error <= 1'b1;
                        err_code   <= err_code | E_TIMEOUT;
                        state      <= ST_IDLE;
                    end
                end

                //============================================== 逐扇区读像素
                ST_LDATA: begin
                    state_code  <= 4'd4;
                    busy        <= 1'b1;
                    sd_sec_read <= 1'b1;

                    if (sd_sec_read_end) begin
                        if (bcnt >= cur_len) begin
                            // 整张图读完（write_en 由像素拼装块负责清零，
                            // 不能在这里再赋值，否则一个 reg 被两个 always 驱动，TD 报错）
                            sd_sec_read <= 1'b0;
                            load_busy   <= 1'b0;
                            load_done   <= 1'b1;
                            if ({s2, s1} != cur_ck)
                                err_code <= err_code | E_CKSUM;
                            state <= ST_DONE;
                        end else begin
                            // 还有下一个扇区
                            sd_sec_read_addr <= sd_sec_read_addr + 32'd1;
                        end
                    end else if (tout >= TIMEOUT_CYC) begin
                        sd_sec_read <= 1'b0;
                        load_busy   <= 1'b0;
                        load_error  <= 1'b1;
                        err_code    <= err_code | E_TIMEOUT;
                        state       <= ST_IDLE;
                    end
                end

                //============================================== 收尾
                ST_DONE: begin
                    state_code <= 4'd5;
                    busy       <= 1'b0;
                    state      <= ST_IDLE;
                end

                default: begin
                    state       <= ST_IDLE;
                    state_code  <= 4'd0;
                    sd_sec_read <= 1'b0;
                    write_req   <= 1'b0;
                end
            endcase
        end
    end

endmodule
