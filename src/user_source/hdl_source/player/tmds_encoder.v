//---------------------------------------------------------------------------
// TMDS 8b/10b 编码 (DVI 1.0 第 3.2 节), 终端屏 HDMI1 用 (DVI 模式, 无音频数据岛)
//   第 1 拍: 跳变最少化 (XOR / XNOR) 得到 q_m[8:0], 统计 1 的个数
//   第 2 拍: 直流平衡 (按累计偏差决定是否取反) / 消隐期输出控制码 {c1, c0}
//   输出 q[0] 先发送 (hdmi_phy_wrapper 内部再按位倒序送给 MSB 先出的串行器)
//---------------------------------------------------------------------------
module tmds_encoder(
    input             clk,
    input             rst,
    input             de,
    input             c0,
    input             c1,
    input      [7:0]  d,
    output reg [9:0]  q
);

function [3:0] ones8;
    input [7:0] x;
    integer i;
    begin
        ones8 = 4'd0;
        for (i = 0; i < 8; i = i + 1) ones8 = ones8 + x[i];
    end
endfunction

// ---- 第 1 拍 ----
wire [3:0] n1d = ones8(d);
wire       use_xnor = (n1d > 4'd4) || (n1d == 4'd4 && !d[0]);
reg  [8:0] qm_w;
integer k;
always @(*) begin
    qm_w[0] = d[0];
    for (k = 1; k < 8; k = k + 1)
        qm_w[k] = use_xnor ? ~(qm_w[k - 1] ^ d[k]) : (qm_w[k - 1] ^ d[k]);
    qm_w[8] = ~use_xnor;
end

reg [8:0] qm;
reg [3:0] n1q;
reg       de1, c01, c11;
always @(posedge clk) begin
    qm  <= qm_w;
    n1q <= ones8(qm_w[7:0]);
    de1 <= de;
    c01 <= c0;
    c11 <= c1;
end

// ---- 第 2 拍 ----
reg  signed [4:0] cnt;                         // 累计偏差 (1 的个数 - 0 的个数), 偶数, -8 ~ +8
wire signed [4:0] diff = $signed({1'b0, n1q, 1'b0}) - 5'sd8;   // n1q - n0q = 2*n1q - 8
always @(posedge clk) begin
    if (rst) begin
        q   <= 10'b1101010100;
        cnt <= 5'sd0;
    end else if (!de1) begin
        cnt <= 5'sd0;
        case ({c11, c01})
            2'b00: q <= 10'b1101010100;
            2'b01: q <= 10'b0010101011;
            2'b10: q <= 10'b0101010100;
            2'b11: q <= 10'b1010101011;
        endcase
    end else if (cnt == 5'sd0 || diff == 5'sd0) begin
        q   <= {~qm[8], qm[8], qm[8] ? qm[7:0] : ~qm[7:0]};
        cnt <= qm[8] ? cnt + diff : cnt - diff;
    end else if ((cnt > 5'sd0 && diff > 5'sd0) || (cnt < 5'sd0 && diff < 5'sd0)) begin
        q   <= {1'b1, qm[8], ~qm[7:0]};
        cnt <= cnt + {3'b0, qm[8], 1'b0} - diff;
    end else begin
        q   <= {1'b0, qm[8], qm[7:0]};
        cnt <= cnt - {3'b0, ~qm[8], 1'b0} + diff;
    end
end

endmodule
