//---------------------------------------------------------------------------
// 4x4 轻触开关矩阵键盘扫描 (参照官方例程 2_DEMO/23_SCAN_4X4KEY K4X4.v: B 列扫描输出, A 行读入)
//
//   开关 r x c 接在 A[r] 与 B[c] 之间; 键位 (印字):
//            B0   B1   B2   B3
//       A0    1    2    3    A (下一条命令)
//       A1    4    5    6    B (上一条命令)
//       A2    7    8    9    C (上一张)
//       A3    *    0    #    D (下一张)
//   列输出开漏: 当前扫描列输出 0, 其余高阻 (同一行同时按两个键时两路输出不会对顶); 行输入内部上拉.
//   每列 COL_DIV 拍 (默认 250 us), 在本列末尾采样行 (前面留足建立时间); 每扫完一圈 (1 ms) 得到 16 位按键状态,
//   连续 DEB_N 圈相同才接受 (消抖 16 ms). 新按下的键 (编号小的优先, 每圈最多一个) 输出一拍 kb_vld 与键码:
//     '0'~'9', * = 0x08 (退格), # = 0x0D (回车), A/B/C/D = 0x11/0x12/0x13/0x14. 不做长按连发.
//---------------------------------------------------------------------------
module kb_matrix4x4 #(
    parameter COL_DIV = 12_500,           // 50 MHz: 250 us / 列
    parameter DEB_N   = 16
)(
    input             clk,
    input             rst,
    input      [3:0]  row,                // A[3:0], 低 = 有键按下
    output     [3:0]  col,                // B[3:0], 开漏
    output reg        kb_vld,
    output reg [7:0]  kb_ascii
);

reg  [1:0]  sc;                           // 当前扫描列
reg  [15:0] div;
reg  [3:0]  row_m, row_s;
reg  [15:0] raw, stable, acc, prev;
reg  [4:0]  deb;

assign col[0] = (sc == 2'd0) ? 1'b0 : 1'bz;
assign col[1] = (sc == 2'd1) ? 1'b0 : 1'bz;
assign col[2] = (sc == 2'd2) ? 1'b0 : 1'bz;
assign col[3] = (sc == 2'd3) ? 1'b0 : 1'bz;

// 键号 k = 4 * r + c -> 键码
function [7:0] key_code;
    input [3:0] k;
    begin
        case (k)
            4'd0:  key_code = "1";   4'd1:  key_code = "2";   4'd2:  key_code = "3";   4'd3:  key_code = 8'h11;
            4'd4:  key_code = "4";   4'd5:  key_code = "5";   4'd6:  key_code = "6";   4'd7:  key_code = 8'h12;
            4'd8:  key_code = "7";   4'd9:  key_code = "8";   4'd10: key_code = "9";   4'd11: key_code = 8'h13;
            4'd12: key_code = 8'h08; 4'd13: key_code = "0";   4'd14: key_code = 8'h0D; default: key_code = 8'h14;
        endcase
    end
endfunction

// 新按下的键中编号最小的
wire [15:0] fresh = acc & ~prev;
reg  [3:0]  pick;
integer     i;
always @(*) begin
    pick = 4'd0;
    for (i = 15; i >= 0; i = i - 1)
        if (fresh[i]) pick = i;
end

always @(posedge clk) begin
    if (rst) begin
        sc <= 2'd0; div <= 16'd0; row_m <= 4'hF; row_s <= 4'hF;
        raw <= 16'd0; stable <= 16'd0; acc <= 16'd0; prev <= 16'd0; deb <= 5'd0;
        kb_vld <= 1'b0; kb_ascii <= 8'd0;
    end else begin
        row_m  <= row;
        row_s  <= row_m;
        kb_vld <= 1'b0;
        if (div == COL_DIV - 1) begin
            div <= 16'd0;
            sc  <= sc + 2'd1;
            // 本列采样: 键 r*4 + sc
            raw[{2'd0, sc}]      <= ~row_s[0];
            raw[{2'd1, sc}]      <= ~row_s[1];
            raw[{2'd2, sc}]      <= ~row_s[2];
            raw[{2'd3, sc}]      <= ~row_s[3];
            if (sc == 2'd3) begin
                // 一圈完成 (raw 最后一列在本拍写入, 下一圈开头处理: 用 stable 比较上一圈的结果)
                stable <= {~row_s[3], raw[14:12], ~row_s[2], raw[10:8], ~row_s[1], raw[6:4], ~row_s[0], raw[2:0]};
                if ({~row_s[3], raw[14:12], ~row_s[2], raw[10:8], ~row_s[1], raw[6:4], ~row_s[0], raw[2:0]} != stable)
                    deb <= 5'd0;
                else if (deb != DEB_N - 1)
                    deb <= deb + 5'd1;
                else
                    acc <= stable;
            end
        end else
            div <= div + 16'd1;
        // 每圈 (1 ms) 最多输出一个新键 (终端一个键只需几十拍处理), 输出后记入 prev
        if (div == 16'd0 && sc == 2'd1 && fresh != 16'd0) begin
            kb_vld   <= 1'b1;
            kb_ascii <= key_code(pick);
            prev     <= prev | (16'd1 << pick);
        end else
            prev <= prev & acc;           // 松开的键清除
    end
end

endmodule
