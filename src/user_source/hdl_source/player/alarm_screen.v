`timescale 1ns/1ps
//============================================================================
// alarm_screen : 应急报警全屏画面 (video_clk 域, 640x400 坐标)
//
//  第十六讲 "应急信息发布终端": 紧急插播不用转场, 直接硬切到报警页.
//  画面全部由逻辑实时生成, 不依赖 TF 卡 / SDRAM (卡拔出、图片未加载时照样能报警):
//    背景      深红 <-> 亮红 缓慢脉动 (约 1 s 一个周期, 远低于 3 Hz 闪烁安全限)
//    上下边    黄黑警示斜纹 (y 0~15 / 384~399), 每帧移动 2 像素
//    大标题    "紧急警报", 白 / 黄 每 0.5 s 交替; 两侧黄色警告三角 (内含黑色 "!")
//    文字      说明 / 英文 / "报警持续 mm:ss" 计时 / 操作提示 (点阵见 alarm_rom.v)
//    滚动字幕  y SB_Y0~SB_Y1 暗色字幕带 (上下黄线) 内, 预置疏散指引从右向左滚动, 每帧 1 像素;
//              报警开始的第一帧从屏幕右边外开始, 滚完一遍 (宽度 + 640 帧) 后重新进入
//  输入 xc/yc 与合成器 S0 同拍, 输出 rgb2 延迟 2 拍 (与 of2 / 频谱 w2 对齐)
//============================================================================
module alarm_screen(
    input             clk,
    input             rst,
    input             vs_in,        // 低有效, 下降沿 = 帧开始
    input             active,       // 本帧显示报警画面 (合成器 alm_f), 为 0 时滚动字幕回到起点
    input      [9:0]  xc,
    input      [8:0]  yc,
    input      [15:0] t_bcd,        // 报警持续时间 {分十, 分个, 秒十, 秒个}
    input      [1:0]  src,          // 触发来源 (alm_src): 说明行前半 0 有危险发生 1 检测到烟雾 2 检测到明火 (3 同 0)
    output reg [23:0] rgb2
);

`include "alarm_rom.vh"

// 帧计数: 背景脉动 / 标题闪烁 / 斜纹移动; 计时在帧开始锁存, 数字不会在一帧中途变化
reg        vs_d;
reg [5:0]  fc;
reg [15:0] t_f;
reg [10:0] sc;                              // 滚动字幕位置 (帧)
always @(posedge clk or posedge rst) begin
    if (rst) begin
        vs_d <= 1'b1; fc <= 6'd0; t_f <= 16'd0; sc <= 11'd0;
    end else begin
        vs_d <= vs_in;
        if (vs_d & ~vs_in) begin
            fc  <= fc + 6'd1;
            t_f <= t_bcd;
            // active 为上一帧的状态: 报警第一帧 sc = 0 (字幕整条在屏幕右边外)
            if (!active || sc >= {1'b0, AS_X} + 11'd639) sc <= 11'd0;
            else                                        sc <= sc + 11'd1;
        end
    end
end

//---------------------------------------------------------------------------
// S0: 文字项命中判断 + ROM 地址 (各项的 y 范围互不重叠, 只有 AL / AD 同行, A1 / AQ 同行)
//---------------------------------------------------------------------------
// 各项相对坐标 (行 ry, 列 rx), 命中 = 在矩形内, 地址 = 起始 + ry * 每行字节数 + rx / 8
wire [8:0] ry_t = yc - AT_Y;  wire [9:0] rx_t = xc - AT_X;
wire [8:0] ry_1 = yc - A1_Y;  wire [9:0] rx_1 = xc - A1_X;
wire [8:0] ry_q = yc - AQ_Y;  wire [9:0] rx_q = xc - AQ_X;
wire [8:0] ry_2 = yc - A2_Y;  wire [9:0] rx_2 = xc - A2_X;
wire [8:0] ry_l = yc - AL_Y;  wire [9:0] rx_l = xc - AL_X;
wire [8:0] ry_h = yc - AH_Y;  wire [9:0] rx_h = xc - AH_X;
wire h_t = (yc >= AT_Y) && (ry_t < AT_H) && (xc >= AT_X) && (rx_t[9:3] < AT_WB);
wire h_1 = (yc >= A1_Y) && (ry_1 < A1_H) && (xc >= A1_X) && (rx_1[9:3] < A1_WB);
wire h_q = (yc >= AQ_Y) && (ry_q < AQ_H) && (xc >= AQ_X) && (rx_q[9:3] < AQ_WB);
wire h_2 = (yc >= A2_Y) && (ry_2 < A2_H) && (xc >= A2_X) && (rx_2[9:3] < A2_WB);
wire h_l = (yc >= AL_Y) && (ry_l < AL_H) && (xc >= AL_X) && (rx_l[9:3] < AL_WB);
wire h_h = (yc >= AH_Y) && (ry_h < AH_H) && (xc >= AH_X) && (rx_h[9:3] < AH_WB);
wire [9:0] ddx  = xc - AD_X;
wire [8:0] ddy  = yc - AD_Y;
wire [4:0] dcell = ddx[8:4];
wire h_d = (yc >= AD_Y) && (ddy < AD_H) && (xc >= AD_X) && (dcell < 5'd5);
// 滚动字幕: 源列 sx = xc + sc - 640 (AS_X 为整条宽度)
wire [8:0]  ry_s = yc - AS_Y;
wire [11:0] sx   = {2'b00, xc} + {1'b0, sc} - 12'd640;
wire h_s = (yc >= AS_Y) && (ry_s < AS_H) && !sx[11] && (sx[10:0] < {1'b0, AS_X});
reg  [3:0] dch;                             // 字格内容: 0~9, 10 = ':'
always @(*) begin
    case (dcell[2:0])
        3'd0:    dch = t_f[15:12];
        3'd1:    dch = t_f[11:8];
        3'd2:    dch = 4'd10;
        3'd3:    dch = t_f[7:4];
        default: dch = t_f[3:0];
    endcase
end

wire [12:0] a1_off = (src == 2'd1) ? A1_SZ : (src == 2'd2) ? {A1_SZ[11:0], 1'b0} : 13'd0;

reg  [12:0] addr;
reg  [2:0]  bsel;
reg         hit;
reg  [2:0]  csel;                           // 0 标题 1 白 2 浅橙 3 浅黄 4 灰白
always @(*) begin
    addr = 13'd0; bsel = 3'd0; hit = 1'b1; csel = 3'd1;
    if (h_t) begin
        addr = AT_B + ry_t * AT_WB + rx_t[9:3]; bsel = rx_t[2:0]; csel = 3'd0;
    end else if (h_1) begin
        addr = A1_B + a1_off + ry_1 * A1_WB + rx_1[9:3]; bsel = rx_1[2:0];
    end else if (h_q) begin
        addr = AQ_B + ry_q * AQ_WB + rx_q[9:3]; bsel = rx_q[2:0];
    end else if (h_2) begin
        addr = A2_B + ry_2 * A2_WB + rx_2[9:3]; bsel = rx_2[2:0]; csel = 3'd2;
    end else if (h_l) begin
        addr = AL_B + ry_l * AL_WB + rx_l[9:3]; bsel = rx_l[2:0]; csel = 3'd3;
    end else if (h_d) begin
        addr = AD_B + dch * AD_GSZ + {ddy, 1'b0} + ddx[3]; bsel = ddx[2:0];
    end else if (h_h) begin
        addr = AH_B + ry_h * AH_WB + rx_h[9:3]; bsel = rx_h[2:0]; csel = 3'd4;
    end else if (h_s) begin
        addr = AS_B + ry_s * AS_WB + sx[10:3]; bsel = sx[2:0];
    end else
        hit = 1'b0;
end

wire [7:0] rq;
alarm_rom u_rom(.clk(clk), .addr(addr), .q(rq));

//---------------------------------------------------------------------------
// S1: 背景 (斜纹 / 三角 / 脉动红底)
//---------------------------------------------------------------------------
reg  [9:0] x1;
reg  [8:0] y1;
reg        hit1;
reg  [2:0] bsel1, csel1;
always @(posedge clk) begin
    x1 <= xc; y1 <= yc;
    hit1 <= hit; bsel1 <= bsel; csel1 <= csel;
end

wire [9:0] sp    = x1 + {1'b0, y1} + {3'b000, fc, 1'b0};
wire       strip = (y1 < 9'd16) || (y1 >= 9'd384);
wire       band  = (y1 >= SB_Y0) && (y1 < SB_Y1);
wire       bandl = (y1 == SB_Y0) || (y1 == SB_Y1 - 9'd1);
wire [8:0] tr    = y1 - TRI_Y;
wire       in_ty = (y1 >= TRI_Y) && (tr < 9'd56);
wire       lside = (x1 < 10'd320);
wire [9:0] tdx   = lside ? ((x1 >= TRI_LX) ? x1 - TRI_LX : TRI_LX - x1)
                         : ((x1 >= TRI_RX) ? x1 - TRI_RX : TRI_RX - x1);
wire [14:0] hw37 = tr[5:0] * 9'd37;
wire       tri_in = in_ty && (tdx <= {4'd0, hw37[11:6]});
wire       tri_ex = tri_in && (tdx < 10'd4) &&
                    (((tr >= 9'd18) && (tr < 9'd40)) || ((tr >= 9'd45) && (tr < 9'd52)));
wire [4:0] pul   = fc[5] ? ~fc[4:0] : fc[4:0];
wire [7:0] lvl   = 8'h50 + {1'b0, pul, 2'b00};          // 0x50 ~ 0xCC

reg [23:0] fg;
always @(*) begin
    case (csel1)
        3'd0:    fg = fc[5] ? 24'hFFE040 : 24'hFFFFFF;
        3'd2:    fg = 24'hFFD8A0;
        3'd3:    fg = 24'hFFE0A0;
        3'd4:    fg = 24'hE8E8E8;
        default: fg = 24'hFFFFFF;
    endcase
end

always @(posedge clk or posedge rst) begin
    if (rst) rgb2 <= 24'd0;
    else if (hit1 && rq[3'd7 - bsel1]) rgb2 <= fg;
    else if (tri_ex)                   rgb2 <= 24'h000000;
    else if (tri_in)                   rgb2 <= 24'hFFD000;
    else if (strip)                    rgb2 <= sp[4] ? 24'hFFC800 : 24'h181818;
    else if (bandl)                    rgb2 <= 24'hFFC800;
    else if (band)                     rgb2 <= 24'h280408;
    else                               rgb2 <= {lvl, 8'h00, 8'h18};
end

endmodule
