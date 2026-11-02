`timescale 1ns/1ps
// 异步复位、同步释放
module reset_sync(
    input  clk,
    input  arst,
    output rst
);
reg [2:0] sh;
always @(posedge clk or posedge arst) begin
    if (arst) sh <= 3'b111;
    else      sh <= {sh[1:0], 1'b0};
end
assign rst = sh[2];
endmodule
