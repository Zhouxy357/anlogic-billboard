//============================================================================
// sd_arbiter.v  ——  SD 卡读通道仲裁（M2b 模块）
//---------------------------------------------------------------------------
// 【为什么需要它】
//   TF 卡控制器（sd_card_top）只有【一条】读通道：谁拉高 sd_sec_read，
//   卡就按 sd_sec_read_addr 读一个 512 字节扇区吐回来。
//   本工程有两个主设备要读卡：
//     ① EBM 容器解析器 ebm_reader —— 换图时突然读 5400 个扇区（2.76MB）
//     ② 音频流 audio_stream      —— 每 5.3ms 就要一个扇区，一刻不能停
//   所以必须仲裁。
//
// 【仲裁策略：扇区级抢占，音频优先 + 连续补满才还】
//   * 默认把总线给 A（图像），行为与改造前完全一致。
//   * A 每读完一个扇区会出 1 拍 sd_sec_read_end，此刻卡正好回到“等待”状态，
//     下一拍就会重新采样 sd_sec_read / sd_sec_read_addr —— 这是唯一能安全
//     换主人的时刻。本模块就抓这个时刻。
//   * ★ B 一旦抢到总线，会【一直占用到它把 FIFO 补满为止】（b_req 拉低才还），
//     而不是只读一个扇区。原因见下面“为什么不能只给一个扇区”。
//   * A 被抢时它的 sd_sec_read 仍然保持高、地址不变，恢复后卡会按同一地址
//     重新发 CMD17，A 只是“多等了一会儿”，远小于 ebm_reader 内部的 80ms
//     超时保护，不会误判错误。
//
// 【为什么不能只给一个扇区（2026-10-19 修正，重要）】
//   音频 48kHz×16bit 单声道 = 96KB/s，而 SD 单扇区上限约 1.67MB/s。
//   一个扇区只有 512 字节 = 256 个样本 = 5.33ms 播放时长。
//   如果“每抢一个扇区就还给 A”，B 的请求会立刻重新拉高，实际效果是
//   A、B 两个扇区轮流 —— 音频拿走 50% 带宽（远超它需要的 3%），
//   图像装载速度却被砍半（5400 扇区从 1.6s 变成 3.2s），两头都亏。
//   正确做法是让 B 一次补满（一次约 8 个扇区 ≈ 1.3ms），
//   然后安安静静播 43ms 不打扰 A。实测总线占用只有 3%，
//   图像装载只慢约 3%，音频永不欠载。
//
// 【时序细节（重要，改代码前必看）】
//   sd_card_sec_read_write 的状态机：
//       S_READ --(block_read_req_ack)--> S_READ_END --(无条件)--> S_WAIT
//   而 S_WAIT 里当拍就采样 sd_sec_read / sd_sec_read_addr。
//   也就是说：end 有效的那一拍（S_READ_END）之后的下一拍，卡就已经在
//   看输入了。所以 grant 必须在“end 那一拍”就切换到新主人（寄存器在
//   时钟沿更新，正好赶上下一拍）。
//   因此 end 这一拍仍然归属旧主人（a_end/b_end 用 grant 的旧值门控），
//   下一拍新主人接管 —— 两边都刚好。
//
// 【两个请求信号的区别】
//   b_req  = B“想占用总线”（由 FIFO 水位决定，带迟滞，可以长时间保持）
//   b_rd   = B“此刻正在读这个扇区”（状态机输出，扇区内必须保持 1）
//   换主人只在扇区边界，所以 C 侧的 c_req 必须用 b_rd（不能用水位信号，
//   否则扇区读到一半水位跨过门槛，c_req 会抖掉，那一帧数据就废了）。
//   而“该不该还”只看 b_req。
//============================================================================
`timescale 1ns / 1ps

module sd_arbiter (
    input  wire        clk,
    input  wire        rst,           // 高有效

    //---------------- 主设备 A：图像（EBM 解析器）----------------
    input  wire        a_req,
    input  wire [31:0] a_addr,
    output wire [7:0]  a_data,
    output wire        a_valid,
    output wire        a_end,

    //---------------- 主设备 B：音频流 ---------------------------
    input  wire        b_req,         // 想占用总线（水位低）
    input  wire        b_rd,          // 实际的扇区读请求
    input  wire [31:0] b_addr,
    output wire [7:0]  b_data,
    output wire        b_valid,
    output wire        b_end,

    //---------------- 卡侧 ---------------------------------------
    output wire        c_req,
    output wire [31:0] c_addr,
    input  wire [7:0]  c_data,
    input  wire        c_valid,
    input  wire        c_end
);

    // 0 = A 占用，1 = B 占用
    reg grant_b;

    always @(posedge clk or posedge rst) begin
        if (rst)
            grant_b <= 1'b0;
        else if (grant_b) begin
            // B 补满了（b_req 撤掉）就让回 A。
            // 只认 end 那一拍 —— 扇区读一半不能换人。
            if (c_end && (b_req == 1'b0))
                grant_b <= 1'b0;
            // ★ 死锁兜底：B 既不想占用、也没有在读（比如 FIFO 满了 / 卡被拔），
            //   就立刻撒手。否则 A 会永远等一个不会再来的 c_end，画面直接卡死。
            //   正常补货期间 b_req 一直是 1，这一条不会误伤。
            else if ((b_req == 1'b0) && (b_rd == 1'b0))
                grant_b <= 1'b0;
        end else begin
            // A 空闲（卡不在读）或者 A 刚读完一个扇区 → 可以让给 B
            if (b_req && ((a_req == 1'b0) || (c_end == 1'b1)))
                grant_b <= 1'b1;
        end
    end

    //----------------------------------------------------------- 卡侧多路选择
    assign c_req  = grant_b ? b_rd   : a_req;
    assign c_addr = grant_b ? b_addr : a_addr;

    //----------------------------------------------------------- 数据分发
    // 注意：c_end 那一拍 grant_b 仍是被授予者的值（寄存器尚未更新），
    //       所以 a_end / b_end 不会互相串扰。
    assign a_data  = c_data;
    assign b_data  = c_data;
    assign a_valid = c_valid & ~grant_b;
    assign b_valid = c_valid &  grant_b;
    assign a_end   = c_end   & ~grant_b;
    assign b_end   = c_end   &  grant_b;

endmodule
