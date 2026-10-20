//============================================================================
// audio_fifo.v  ——  音频样本跨时钟域 FIFO（M1b 模块，TF 卡音频流的“水库”）
//---------------------------------------------------------------------------
// 【为什么需要它】
//   音频样本从 TF 卡来（sd_card_clk 100MHz 域，成批到达：一个扇区 256 个样本
//   一口气写完），却被 12.288MHz 的音频主时钟按 48kHz 匀速取走。
//   一边是"突发写"，一边是"匀速读"，必须中间垫一个异步 FIFO。
//
// 【容量怎么定的】
//   AW=11 → 2048 个样本 × 16bit = 32Kbit，正好 1 块块 RAM（不占 LUT）。
//   2048 / 48000 = 42.7ms，足够吸收 SD 卡换扇区（约 200~400us）
//   以及被图像装载抢占总线时的等待（sd_arbiter 保证音频最多等一个扇区）。
//   ★ 2026-10-19 从 AW=13 降到 12：原来想用 170ms 硬扛换图装载的 1.6 秒，
//     那是错的思路（170ms 怎么都不够）；改成仲裁器给音频优先权后，
//     音频根本不会欠载，缓冲只需要吸收“抢总线的一来一回”，85ms 有 200 倍余量，
//     同时省下一半片上存储。
//   实际取数门槛（低水位）由 audio_stream 控制，本模块只负责存。
//
// 【实现要点】
//   * 真双口：写口在 wr_clk 域，读口在 rd_clk 域，两套指针各自独立。
//   * 指针用格雷码跨域 + 两级同步，保证每个时钟沿只变 1 位，不会采到乱值。
//   * wr_full / rd_empty 都在自己域内判断，不跨域组合使用。
//   * wr_level 给出"当前存了多少个样本"，给写域做低水位判断用。
//============================================================================
`timescale 1ns / 1ps

module audio_fifo #(
    parameter integer DATA_W = 16,
    parameter integer AW     = 13          // 深度 = 2^AW
)(
    //---------------- 写侧（SD 卡时钟域）----------------
    input  wire              wr_clk,
    input  wire              wr_rst,       // 高有效，同步于 wr_clk
    input  wire              wr_en,
    input  wire [DATA_W-1:0] wr_data,
    output wire              wr_full,
    output wire [AW:0]       wr_level,     // 已存样本数（0..2^AW）

    //---------------- 读侧（音频主时钟域）---------------
    input  wire              rd_clk,
    input  wire              rd_rst,       // 高有效，同步于 rd_clk
    input  wire              rd_en,
    output reg  [DATA_W-1:0] rd_data,      // rd_en 之后 1 拍有效
    output wire              rd_empty
);

    localparam integer DEPTH = (1 << AW);

    // ★ TD 块 RAM 推断：必须和厂商 IP 的写法逐字一致，缺一项就会退化成
    //   分布式 LUT RAM（2048 深吃掉约 5000 个 LUT，占整片 1/4）。
    //   参考 TD 自带 ip/depot/RS(528,514)FECOnly.../asyn_clk_fifo.v 第 511 行：
    //     reg [MIN_WIDTH-1:0] memory [MAX_DEPTH-1:0];
    //         /* fehdl force_ram=1, ram_style="bram(fast)" */
    //   三个要点（少一个就失败）：
    //     ① ram_style 要写 "bram(fast)"，不能只写 "bram"；
    //        2026-10-19 实测只写 "bram" 时 TD 把存储展开成门级，
    //        实例数 19214 → 152850，综合直接崩在 Post-LUT-mapping。
    //     ② 读必须【同步读】，且读出的数据寄存器不能带复位
    //        （见下面 rd_data 那个 always，单独成块、无 rd_rst 分支）。
    //     ③ 读地址是寄存器（rbin），不是表达式。
    reg [DATA_W-1:0] mem [0:DEPTH-1];  /* fehdl force_ram=1, ram_style="bram(fast)" */

    reg  [AW:0] wbin, wgray;
    reg  [AW:0] rbin, rgray;
    reg  [AW:0] rgray_w1, rgray_w2;        // 读指针 → 写域
    reg  [AW:0] wgray_r1, wgray_r2;        // 写指针 → 读域
    reg  [AW:0] rbin_w;                    // 写域里还原成二进制，算水位
    integer     gi;

    //----------------------------------------------------------- 二进制 ↔ 格雷码
    function [AW:0] bin2gray;
        input [AW:0] b;
        begin
            bin2gray = b ^ (b >> 1);
        end
    endfunction

    always @(*) begin
        rbin_w[AW] = rgray_w2[AW];
        for (gi = AW-1; gi >= 0; gi = gi - 1)
            rbin_w[gi] = rbin_w[gi+1] ^ rgray_w2[gi];
    end

    //----------------------------------------------------------- 写侧
    always @(posedge wr_clk) begin
        if (wr_rst) begin
            wbin  <= {(AW+1){1'b0}};
            wgray <= {(AW+1){1'b0}};
        end else if (wr_en && !wr_full) begin
            mem[wbin[AW-1:0]] <= wr_data;
            wbin              <= wbin + 1'b1;
            wgray             <= bin2gray(wbin + 1'b1);
        end
    end

    // 满：格雷码高两位相反、其余相同（异步 FIFO 的经典判据）
    assign wr_full  = (wgray == {~rgray_w2[AW:AW-1], rgray_w2[AW-2:0]});
    assign wr_level = wbin - rbin_w;

    //----------------------------------------------------------- 读侧
    // 数据寄存单独一块、【不带复位】—— 带复位 TD 就不认这是块 RAM 的输出寄存器。
    // 上电后头几拍 rd_data 是 X，但此时 FIFO 是空的，rd_empty 会挡掉，不会播出去。
    always @(posedge rd_clk) begin
        if (rd_en && !rd_empty)
            rd_data <= mem[rbin[AW-1:0]];
    end

    // 读指针
    always @(posedge rd_clk) begin
        if (rd_rst) begin
            rbin  <= {(AW+1){1'b0}};
            rgray <= {(AW+1){1'b0}};
        end else if (rd_en && !rd_empty) begin
            rbin  <= rbin + 1'b1;
            rgray <= bin2gray(rbin + 1'b1);
        end
    end

    assign rd_empty = (rgray == wgray_r2);

    //----------------------------------------------------------- 指针跨域
    always @(posedge wr_clk) begin
        if (wr_rst) begin
            rgray_w1 <= {(AW+1){1'b0}};
            rgray_w2 <= {(AW+1){1'b0}};
        end else begin
            rgray_w1 <= rgray;
            rgray_w2 <= rgray_w1;
        end
    end

    always @(posedge rd_clk) begin
        if (rd_rst) begin
            wgray_r1 <= {(AW+1){1'b0}};
            wgray_r2 <= {(AW+1){1'b0}};
        end else begin
            wgray_r1 <= wgray;
            wgray_r2 <= wgray_r1;
        end
    end

endmodule
