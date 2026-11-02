`timescale 1ns/1ps
//============================================================================
// audio_wave_osd : 音频波形可视化, 沉浸式 (参考第十二讲 promax_audio_waveform)
//
//  音源: HDMI 实际输出的音频 (I2S_receiver 解出的样本, 已含音量), 所见即所听.
//        顶层在 pix_clk 域锁存样本并翻转 aud_tgl; pix_clk 与 video_clk 同源 (4:1),
//        样本保持 1/48k s, 这里检测 toggle 边沿后直接取用.
//
//  采集:
//    左右声道平均 -> 每 DECIMATE 个样本取 1 个 -> NPTS 点 (384 点, 抽取 2 时 16 ms)
//    触发: 先等信号低于 -TRIG_TH, 再等它回到 >= 0 (上升过零) 才开始采集,
//          周期信号 (如测试音) 每次都从同一相位开始, 画面稳定不滚动;
//          TRIG_TO 个样本内等不到过零 (静音/噪声) 就直接开始, 画面照常刷新.
//    双缓冲: 写 bank 采满后, 在下一个帧开始 (VS 下降沿) 与显示 bank 交换, 不撕裂.
//    电平: 左右声道每帧峰值 (0~31 格), 显示值取 max(本帧峰值, 上帧显示值 - 1).
//
//  显示 (沉浸式: 无底框/边框/标签, 背景完全透明, 只画曲线):
//    波形区 x 128~511 (384 列), y 332~363 (32 行), 位于底部字幕上方、水平居中
//    每列画出 [上一列, 本列] 两个样本点之间的竖线段, 相邻点连成连续曲线;
//    曲线上下各 1 行为 "阴影" (合成器把该处图像亮度减半), 亮图上也看得清
//    电平条: 波形两端的细竖条 (L x 120~122, R x 517~519), 从底向上, 绿 / 黄 / 红
//  输入 xc/yc 与合成器 S0 同拍, 输出延迟 2 拍 (与 of2 对齐)
//============================================================================
module audio_wave_osd #(
    parameter integer  DECIMATE = 2,
    parameter [8:0]    NPTS     = 9'd384,
    parameter [15:0]   TRIG_TH  = 16'd512,      // 触发迟滞 (满幅 32768)
    parameter [11:0]   TRIG_TO  = 12'd2400      // 等待过零的最长样本数 (50 ms)
)(
    input             clk,          // video_clk
    input             rst,
    input             enable,       // 显示使能 (采集一直进行)
    input             vs_in,        // 低有效, 下降沿 = 帧开始
    input      [9:0]  xc,           // 合成器 S0 坐标
    input      [8:0]  yc,
    input             aud_tgl,      // 每个新样本翻转一次 (pix_clk 域寄存器)
    input      [15:0] aud_l,
    input      [15:0] aud_r,
    output reg [3:0]  w2            // {阴影, 曲线, 电平条[1:0] (0 无 1 绿 2 黄 3 红)}
);

localparam [9:0] PX0 = 10'd128;
localparam [8:0] PY0 = 9'd332;
localparam [9:0] VLX = 10'd120, VRX = 10'd517;

//---------------------------------------------------------------------------
// 样本输入
//---------------------------------------------------------------------------
reg  [1:0]  tg;
reg         ev;
reg  signed [15:0] sm;          // 左右平均
reg  [4:0]  al, ar;             // |L|, |R| 的 0~31 格
wire signed [16:0] sum = $signed(aud_l) + $signed(aud_r);

function [4:0] mag5;            // |x| >> 10, 饱和到 31
    input [15:0] x;
    reg   [15:0] a;
    begin
        a    = x[15] ? (~x + 16'd1) : x;
        mag5 = (x == 16'h8000 || a[15]) ? 5'd31 : a[14:10];
    end
endfunction

always @(posedge clk or posedge rst) begin
    if (rst) begin
        tg <= 2'b00; ev <= 1'b0; sm <= 16'sd0; al <= 5'd0; ar <= 5'd0;
    end else begin
        tg <= {tg[0], aud_tgl};
        ev <= tg[1] ^ tg[0];
        if (tg[1] ^ tg[0]) begin
            sm <= sum[16:1];
            al <= mag5(aud_l);
            ar <= mag5(aud_r);
        end
    end
end

//---------------------------------------------------------------------------
// 采集状态机 + 双缓冲
//---------------------------------------------------------------------------
localparam [1:0] C_ARM = 2'd0, C_CAP = 2'd1, C_FULL = 2'd2;

(* ram_style = "bram" *) reg [4:0] wram [0:1023];

reg  [1:0]  cst;
reg         wbank, dbank, dvalid;
reg         neg;
reg  [11:0] to_cnt;
reg  [8:0]  widx;
reg  [3:0]  dc;
reg         we;
reg  [9:0]  wa;
reg  [4:0]  wd;
reg         vs_d;
wire        fs = vs_d & ~vs_in;
wire [4:0]  rr = 5'd15 - sm[15:11];         // 行号: +满幅 -> 0 (顶), -满幅 -> 31 (底)
wire        trig = (neg && !sm[15]) || (to_cnt >= TRIG_TO);

reg  [4:0]  pk_l, pk_r, len_l, len_r;

always @(posedge clk) begin
    if (we) wram[wa] <= wd;
end

always @(posedge clk or posedge rst) begin
    if (rst) begin
        cst <= C_ARM; wbank <= 1'b0; dbank <= 1'b1; dvalid <= 1'b0;
        neg <= 1'b0; to_cnt <= 12'd0; widx <= 9'd0; dc <= 4'd0;
        we <= 1'b0; wa <= 10'd0; wd <= 5'd0; vs_d <= 1'b1;
        pk_l <= 5'd0; pk_r <= 5'd0; len_l <= 5'd0; len_r <= 5'd0;
    end else begin
        vs_d <= vs_in;
        we   <= 1'b0;
        if (fs) begin
            // 电平: 每帧更新一次, 快速上升、每帧回落 1 格
            len_l <= (pk_l > len_l) ? pk_l : (len_l != 5'd0) ? len_l - 5'd1 : 5'd0;
            len_r <= (pk_r > len_r) ? pk_r : (len_r != 5'd0) ? len_r - 5'd1 : 5'd0;
            pk_l  <= 5'd0;
            pk_r  <= 5'd0;
        end else if (ev) begin
            if (al > pk_l) pk_l <= al;
            if (ar > pk_r) pk_r <= ar;
        end

        if (fs && cst == C_FULL) begin
            dbank  <= wbank;
            wbank  <= ~wbank;
            dvalid <= 1'b1;
            cst    <= C_ARM;
            neg    <= 1'b0;
            to_cnt <= 12'd0;
        end else if (ev) begin
            case (cst)
                C_ARM: begin
                    to_cnt <= to_cnt + 12'd1;
                    if (sm < -$signed({1'b0, TRIG_TH})) neg <= 1'b1;
                    if (trig) begin
                        we   <= 1'b1; wa <= {wbank, 9'd0}; wd <= rr;
                        widx <= 9'd1;
                        dc   <= (DECIMATE > 1) ? 4'd1 : 4'd0;
                        cst  <= C_CAP;
                    end
                end
                C_CAP: begin
                    if (dc == 4'd0) begin
                        we   <= 1'b1; wa <= {wbank, widx}; wd <= rr;
                        widx <= widx + 9'd1;
                        if (widx == NPTS - 9'd1) cst <= C_FULL;
                    end
                    dc <= (dc == DECIMATE - 1) ? 4'd0 : dc + 4'd1;
                end
                default: ;
            endcase
        end
    end
end

//---------------------------------------------------------------------------
// 显示: S0 区域判断 + 读 RAM -> S1 连线/阴影判断 -> S2 输出
//---------------------------------------------------------------------------
wire [9:0] px = xc - PX0;
wire [8:0] py = yc - PY0;
wire in_y    = (yc >= PY0) && (py < 9'd32);
wire in_plot = in_y && (xc >= PX0) && (px < {1'b0, NPTS});
wire [4:0] h = 5'd31 - py[4:0];             // 电平条高度坐标 (底 = 0)
wire in_vl   = in_y && (xc >= VLX) && (xc < VLX + 10'd3);
wire in_vr   = in_y && (xc >= VRX) && (xc < VRX + 10'd3);
wire [4:0] vlen = in_vl ? len_l : len_r;
reg  [1:0] vu0;
always @(*) begin
    vu0 = 2'd0;
    if ((in_vl || in_vr) && h < vlen)
        vu0 = (h < 5'd20) ? 2'd1 : (h < 5'd26) ? 2'd2 : 2'd3;
end

reg  [4:0] q, q_p;
reg        plot1, plot1_d;
reg  [4:0] ry1;
reg  [1:0] vu1;
always @(posedge clk) begin
    q       <= wram[{dbank, px[8:0]}];
    q_p     <= q;
    plot1   <= enable & dvalid & in_plot;
    plot1_d <= plot1;
    ry1     <= py[4:0];
    vu1     <= enable ? vu0 : 2'd0;
end

wire [4:0] prv  = plot1_d ? q_p : q;          // 本行第一列没有上一点, 用本点
wire [4:0] lo   = (prv < q) ? prv : q;
wire [4:0] hi   = (prv < q) ? q : prv;
wire       wave = plot1 && (ry1 >= lo) && (ry1 <= hi);
wire       halo = plot1 && !wave && ({1'b0, ry1} + 6'd1 >= {1'b0, lo}) && ({1'b0, ry1} <= {1'b0, hi} + 6'd1);

always @(posedge clk or posedge rst) begin
    if (rst) w2 <= 4'd0;
    else     w2 <= {halo, wave, vu1};
end

endmodule
