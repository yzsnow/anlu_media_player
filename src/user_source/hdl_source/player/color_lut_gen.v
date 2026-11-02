`timescale 1ns/1ps
//============================================================================
// color_lut_gen (video_clk 域)
//  画面调节查找表: 每帧 VS 下降沿 (start) 按本帧参数重算 256 项, 每项 R/G/B 各 8 bit:
//     y   = sat(x * bri >> 7)                         亮度 (bri = 级别 * 16, 128 = 原样)
//     z   = sat(((y - 128) * con >>> 7) + 128)        对比度 (con 同上)
//     w_c = sat(z * gain_c >> 8)                      色温 (每通道增益, 256 = 1.0, color_temp.vh)
//     q_c = gamma_rom[gam][w_c]                       伽马 (gamma_rom.v, 级别 8 为恒等)
//  亮度/对比度与原 video_compositor S6/S7 的公式逐位相同; 色温 8 / 伽马 8 时结果与原来完全一致.
//  一个乘法器分时复用, 每项 10 拍, 256 项共 2560 拍. VS 下降沿到第一行有效像素有
//  11 行 x 760 = 8360 拍, 表在本帧开始显示前就已写完, 整帧一致 (显示期间不写表).
//============================================================================
module color_lut_gen(
    input             clk,
    input             rst,
    input             start,          // 单拍, VS 下降沿
    input      [8:0]  bri,            // 0~256
    input      [8:0]  con,            // 0~256
    input      [4:0]  temp_lvl,       // 0~16, 8 = 原样
    input      [4:0]  gam_lvl,        // 0~16, 8 = 原样
    output reg        we,
    output reg [7:0]  waddr,
    output reg [23:0] wdata,          // {R, G, B}
    output reg        busy
);

`include "color_temp.vh"

reg [8:0]  bri_r, con_r;
reg [26:0] gain_r;
reg [4:0]  gam_r;
reg [7:0]  x;
reg [3:0]  ph;
reg [7:0]  y, z, qr, qg;

// 分时乘法器 (输入寄存, 乘积在下一拍使用)
reg  signed [9:0]  ma, mb;
wire signed [19:0] mp = ma * mb;
wire signed [11:0] cv = (mp >>> 7) + 12'sd128;
wire [7:0]         wt = mp[16] ? 8'd255 : mp[15:8];      // 色温: z * gain >> 8

// 伽马 ROM, 1 拍同步读: 第 n 拍给地址, 第 n+2 拍使用 g_q
reg  [12:0] g_addr;
wire [7:0]  g_q;
gamma_rom u_gamma(.clk(clk), .addr(g_addr), .q(g_q));

always @(posedge clk or posedge rst) begin
    if (rst) begin
        we <= 1'b0; waddr <= 8'd0; wdata <= 24'd0; busy <= 1'b0;
        bri_r <= 9'd128; con_r <= 9'd128; gain_r <= {9'd256, 9'd256, 9'd256}; gam_r <= 5'd8;
        x <= 8'd0; ph <= 4'd0; y <= 8'd0; z <= 8'd0; qr <= 8'd0; qg <= 8'd0;
        ma <= 10'sd0; mb <= 10'sd0; g_addr <= 13'd0;
    end else begin
        we <= 1'b0;
        if (start) begin
            bri_r  <= bri;
            con_r  <= con;
            gain_r <= temp_gain(temp_lvl);
            gam_r  <= (gam_lvl > 5'd16) ? 5'd16 : gam_lvl;
            x      <= 8'd0;
            ph     <= 4'd0;
            busy   <= 1'b1;
        end else if (busy) begin
            ph <= ph + 4'd1;
            case (ph)
            4'd0: begin ma <= $signed({2'b00, x});            mb <= $signed({1'b0, bri_r}); end
            4'd1: y <= (mp[16:15] != 2'b00) ? 8'd255 : mp[14:7];                 // 同原 bri_px
            4'd2: begin ma <= $signed({2'b00, y}) - 10'sd128; mb <= $signed({1'b0, con_r}); end
            4'd3: z <= (cv < 12'sd0) ? 8'd0 : (cv > 12'sd255) ? 8'd255 : cv[7:0];  // 同原 con_px
            4'd4: begin ma <= $signed({2'b00, z}); mb <= $signed({1'b0, gain_r[26:18]}); end
            4'd5: begin g_addr <= {gam_r, wt};    mb <= $signed({1'b0, gain_r[17:9]}); end   // R
            4'd6: begin g_addr <= {gam_r, wt};    mb <= $signed({1'b0, gain_r[8:0]});  end   // G
            4'd7: begin g_addr <= {gam_r, wt}; qr <= g_q; end                                // B, 取 R
            4'd8: qg <= g_q;
            default: begin                                                                   // 9: 取 B, 写表
                we    <= 1'b1;
                waddr <= x;
                wdata <= {qr, qg, g_q};
                ph    <= 4'd0;
                x     <= x + 8'd1;
                if (x == 8'd255) busy <= 1'b0;
            end
            endcase
        end
    end
end

endmodule
