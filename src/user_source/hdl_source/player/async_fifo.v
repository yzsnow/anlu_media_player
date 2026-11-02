`timescale 1ns/1ps
//============================================================================
// async_fifo : 通用异步 FIFO (格雷码指针, 推断双口 RAM, 同步读)
//   rd_en 后一拍 rd_data 有效; 空时读无效
//   wr_level : 写时钟域的数据量 (偏大, 可安全用于流控)
//   rd_level : 读时钟域的数据量 (偏小)
//============================================================================
module async_fifo #(
    parameter DW = 32,
    parameter AW = 11,
    parameter RAM_STYLE = "bram"    // TD: "bram" / "bram_9k" / "bram_32k"
)(
    input               wr_clk,
    input               wr_rst,
    input               wr_en,
    input      [DW-1:0] wr_data,
    output     [AW:0]   wr_level,
    input               rd_clk,
    input               rd_rst,
    input               rd_en,
    output reg [DW-1:0] rd_data,
    output              rd_empty,
    output     [AW:0]   rd_level
);

(* ram_style = RAM_STYLE *) reg [DW-1:0] mem [0:(1<<AW)-1];

function [AW:0] b2g; input [AW:0] b; b2g = b ^ (b >> 1); endfunction
function [AW:0] g2b;
    input [AW:0] g;
    integer k;
    begin
        g2b[AW] = g[AW];
        for (k = AW - 1; k >= 0; k = k - 1) g2b[k] = g2b[k+1] ^ g[k];
    end
endfunction

reg [AW:0] wptr, wgray;
reg [AW:0] rptr, rgray;
reg [AW:0] wg_r0, wg_r1;

// 写侧 (对方指针格雷码转二进制后再打一拍, 缩短满判定到 RAM 写使能的路径;
//        指针只会显得更旧, 满/空判定更保守, 不影响正确性)
// 满标志也寄存: 用上一拍的数据量与 2^AW-2 比较. 一拍内最多写入 1 个,
// 所以 wfull=0 时本拍写入后数据量不超过 2^AW; 代价是少用 2 个单元.
// (组合满判定 = 格雷码转换 + 减法 + 比较, 直接驱动 BRAM 写使能, 100 MHz 下时序不够)
// 注意位宽: 数据量必须按 AW+1 位取模. 若写成 (wptr - rptr_w) >= ((1 << AW) - 2),
// 常数是 32 位, 整个比较按 32 位做, 写指针回绕后 (数值小于读指针) 差值变成
// 很大的数, 满标志误报, 直到读指针也回绕前的所有写入都被丢掉 (每 2^(AW+1) 个样本
// 丢一大段并读空 -> 音乐跳段 + 断音).
localparam [AW:0] FULL_LVL = (1 << AW) - 2;
reg [AW:0] rg_w0, rg_w1, rptr_w;
reg        wfull;
assign wr_level = wptr - rptr_w;

always @(posedge wr_clk) begin
    if (wr_en && !wfull) mem[wptr[AW-1:0]] <= wr_data;
end
always @(posedge wr_clk or posedge wr_rst) begin
    if (wr_rst) begin
        wptr <= 0; wgray <= 0; rg_w0 <= 0; rg_w1 <= 0; rptr_w <= 0; wfull <= 1'b0;
    end else begin
        rg_w0 <= rgray; rg_w1 <= rg_w0; rptr_w <= g2b(rg_w1);
        wfull <= (wr_level >= FULL_LVL);
        if (wr_en && !wfull) begin
            wptr  <= wptr + 1'b1;
            wgray <= b2g(wptr + 1'b1);
        end
    end
end

// 读侧
reg  [AW:0] wptr_r;
assign rd_empty = (wptr_r == rptr);
assign rd_level = wptr_r - rptr;

always @(posedge rd_clk) begin
    rd_data <= mem[rptr[AW-1:0]];
end
always @(posedge rd_clk or posedge rd_rst) begin
    if (rd_rst) begin
        rptr <= 0; rgray <= 0; wg_r0 <= 0; wg_r1 <= 0; wptr_r <= 0;
    end else begin
        wg_r0 <= wgray; wg_r1 <= wg_r0; wptr_r <= g2b(wg_r1);
        if (rd_en && !rd_empty) begin
            rptr  <= rptr + 1'b1;
            rgray <= b2g(rptr + 1'b1);
        end
    end
end

endmodule
