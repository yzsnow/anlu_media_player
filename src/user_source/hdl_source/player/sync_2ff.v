`timescale 1ns/1ps
// 单比特电平两级同步器 (第六讲 Flash 固化与上电自启)
// 只用于单比特、慢变电平 (如 Sdr_init_done); 多位总线 / 单拍脉冲不能直接用
// RESET_VAL: 复位时的输出电平, 取信号空闲态
module sync_2ff #(
    parameter RESET_VAL = 1'b0
)(
    input  clk,         // 目的时钟域
    input  rst_n,       // 目的域低有效复位
    input  async_in,    // 源域电平
    output sync_out
);
(* async_reg = "true" *) reg s1, s2;
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        s1 <= RESET_VAL;
        s2 <= RESET_VAL;
    end else begin
        s1 <= async_in;
        s2 <= s1;
    end
end
assign sync_out = s2;
endmodule
