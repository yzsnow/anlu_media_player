`timescale 1ns/1ps
//============================================================================
// audio_spectrum_osd : 音频频谱柱可视化, 沉浸式 (第十二讲音频可视化 + 赛题解析 FFT/DFT 频谱方向)
//
//  音源: HDMI 实际输出的音频 (I2S_receiver 解出的样本, 已含音量), 左右声道平均.
//        顶层在 pix_clk 域锁存样本并翻转 aud_tgl; pix_clk 与 video_clk 同源 (4:1),
//        样本保持 1/48k s, 这里检测 toggle 边沿后直接取用.
//
//  处理 (全部在 video_clk 18.75 MHz 下顺序完成, 只用 1 个 FFT 蝶形):
//    1. 样本写入 1024 点环形缓冲 (BRAM)
//    2. 每帧开始 (VS 下降沿) 且 SW2 打开时: 取最近 1024 个样本 (21 ms, 帧间重叠),
//       乘 Hann 窗, 按位反序写入数据 RAM                               (约 1 千拍)
//    3. 1024 点原位基 2 DIT FFT, 10 级 x 512 蝶形, 每级结果除 2 防溢出  (约 4.1 万拍 = 2.2 ms)
//       旋转因子与 Hann 窗共用一张 1/4 周期正弦表 (257 x 15 bit)
//    4. 24 个对数频段 (约 50 Hz ~ 16 kHz, fft_tables.vh): 每段取各点幅度 (max + min/2 近似) 的最大值,
//       转成 dB (1/4 倍频程分辨率 = 1.5 dB/格, 32 格 = 48 dB), 加倾斜补偿 (+3 dB/倍频程)
//    5. 下一帧开始时 (消隐期) 统一更新显示: 柱高 快速上升 / 每帧回落 1 格,
//       峰值帽 保持 HOLD 帧后每帧回落 1 格 -> 显示值只在帧边界变化, 不撕裂
//    SW2 关闭时不做 FFT (省电), 柱子逐帧回落到 0
//
//  显示 (640x400 坐标, 背景完全透明):
//    频谱区 x 128~511, y 332~363: 24 根柱, 每根 16 像素宽 (柱 12 + 间隙 4), 高 0~32 行,
//    颜色 绿 (0~19 行) / 黄 (20~25) / 红 (26~31), 峰值帽为白色细线
//    两端细竖条: 左右声道电平 (L x 120~122, R x 517~519)
//  输入 xc/yc 与合成器 S0 同拍, 输出延迟 2 拍 (与 of2 对齐)
//============================================================================
module audio_spectrum_osd #(
    parameter integer LG_OFF = 24,          // dB 零点: 满幅 1 kHz 正弦 = 32 格
    parameter [4:0]   HOLD   = 5'd20        // 峰值帽保持帧数
)(
    input             clk,          // video_clk
    input             rst,
    input             enable,       // SW2
    input             vs_in,        // 低有效, 下降沿 = 帧开始
    input      [9:0]  xc,           // 合成器 S0 坐标
    input      [8:0]  yc,
    input             aud_tgl,      // 每个新样本翻转一次 (pix_clk 域寄存器)
    input      [15:0] aud_l,
    input      [15:0] aud_r,
    output reg [2:0]  w2            // 0 无 / 1 绿 / 2 黄 / 3 红 / 4 白 (峰值帽)
);

`include "fft_tables.vh"

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

// 环形缓冲: 最近 1024 个样本
(* ram_style = "bram" *) reg [15:0] ibuf [0:1023];
reg  [9:0]  iwp, ira;
reg  [15:0] iq;
always @(posedge clk) begin
    if (ev) ibuf[iwp] <= sm;
    iq <= ibuf[ira];
end
always @(posedge clk or posedge rst) begin
    if (rst)     iwp <= 10'd0;
    else if (ev) iwp <= iwp + 10'd1;
end

//---------------------------------------------------------------------------
// 数据 RAM (1024 x {re18, im18}) 与正弦表
//---------------------------------------------------------------------------
(* ram_style = "bram" *) reg [35:0] dram [0:1023];
reg         dwe;
reg  [9:0]  dwa, dra;
reg  [35:0] dwd, dq;
always @(posedge clk) begin
    if (dwe) dram[dwa] <= dwd;
    dq <= dram[dra];
end

reg  [8:0]  sa;
reg  [14:0] sq;
always @(posedge clk) sq <= sin_q(sa);

//---------------------------------------------------------------------------
// 帧开始 / 电平表
//---------------------------------------------------------------------------
reg         vs_d;
wire        fs = vs_d & ~vs_in;
reg  [4:0]  pk_l, pk_r, len_l, len_r;
always @(posedge clk or posedge rst) begin
    if (rst) begin
        vs_d <= 1'b1; pk_l <= 5'd0; pk_r <= 5'd0; len_l <= 5'd0; len_r <= 5'd0;
    end else begin
        vs_d <= vs_in;
        if (fs) begin
            len_l <= (pk_l > len_l) ? pk_l : (len_l != 5'd0) ? len_l - 5'd1 : 5'd0;
            len_r <= (pk_r > len_r) ? pk_r : (len_r != 5'd0) ? len_r - 5'd1 : 5'd0;
            pk_l  <= 5'd0;
            pk_r  <= 5'd0;
        end else if (ev) begin
            if (al > pk_l) pk_l <= al;
            if (ar > pk_r) pk_r <= ar;
        end
    end
end

//---------------------------------------------------------------------------
// 幅度 -> 高度 (0~32 格)
//---------------------------------------------------------------------------
function [5:0] hgt;
    input [17:0]       v;
    input signed [5:0] tilt;
    integer            i;
    reg   [4:0]        p;
    reg   [1:0]        f;
    reg   [17:0]       sh;
    reg   signed [8:0] l;
    begin
        p = 5'd0;
        for (i = 0; i < 18; i = i + 1)
            if (v[i]) p = i;
        sh = v >> ((p >= 5'd2) ? (p - 5'd2) : 5'd0);
        f  = (p >= 5'd2) ? sh[1:0] : 2'd0;
        l  = (v == 18'd0) ? -9'sd64 : $signed({2'b00, p, f}) - LG_OFF + tilt;
        hgt = (l < 0) ? 6'd0 : (l > 32) ? 6'd32 : l[5:0];
    end
endfunction

//---------------------------------------------------------------------------
// 主状态机
//---------------------------------------------------------------------------
localparam [3:0] S_IDLE = 4'd0, S_UPD = 4'd1, S_LOAD = 4'd2,
                 S_F0 = 4'd3, S_F1 = 4'd4, S_F2 = 4'd5, S_F3 = 4'd6,
                 S_F4 = 4'd7, S_F5 = 4'd8, S_F6 = 4'd9, S_F7 = 4'd10,
                 S_B0 = 4'd11, S_B1 = 4'd12, S_B2 = 4'd13;

reg  [3:0]  st;
reg  [4:0]  ub;                         // UPD 频段号
reg  [5:0]  nh   [0:NBAND-1];           // 本帧 FFT 结果 (高度)
reg  [5:0]  disp [0:NBAND-1];           // 显示柱高
reg  [5:0]  cap  [0:NBAND-1];           // 峰值帽
reg  [4:0]  hold [0:NBAND-1];
reg         run;                        // 本帧是否做 FFT (SW2)

// LOAD 流水线: L0 发地址 -> L1 读 RAM/ROM -> L2 求 cos -> L3 乘窗 -> L4 写数据 RAM
reg  [10:0] ln;                         // 发出读的序号 0..1023, 1024 = 发完
reg  [9:0]  lbase;
reg  [9:0]  ln1, ln2, ln3, ln4;
reg         lv1, lv2, lv3, lv4;
reg  [1:0]  lq1, lq2;                   // 象限 (cos 符号)
reg  signed [16:0] cosv;
reg  signed [15:0] iq3;
wire [15:0] wn = (17'sd32768 - cosv) >>> 1;      // Hann 窗 = (1 - cos) / 2, 0..32767
reg  signed [31:0] lprod;

// FFT
reg  [3:0]  fs_s;                        // 级 0..9
reg  [8:0]  fj;                          // 蝶形号 0..511
wire [9:0]  hmask = (10'd1 << fs_s) - 10'd1;
wire [9:0]  jj    = {1'b0, fj};
wire [9:0]  fa    = ((jj & ~hmask) << 1) | (jj & hmask);
wire [9:0]  fk    = jj & hmask;
wire [8:0]  fm    = fk << (4'd9 - fs_s);
reg  [9:0]  ba, bb;
reg  [8:0]  bm;
reg  signed [17:0] Ar, Ai, Br, Bi;
reg  signed [16:0] cw;
reg  [14:0] sw;
reg  signed [34:0] p1, p2, p3, p4;
reg  signed [19:0] tr, ti;
wire signed [20:0] sar = Ar + tr + 21'sd1;
wire signed [20:0] sai = Ai + ti + 21'sd1;
wire signed [20:0] sbr = Ar - tr + 21'sd1;
wire signed [20:0] sbi = Ai - ti + 21'sd1;

// 频段
reg  [8:0]  kb;
reg  [4:0]  bi;
reg  [17:0] bmax;
wire signed [17:0] dre = dq[35:18];
wire signed [17:0] dim = dq[17:0];
wire [17:0] are  = dre[17] ? -dre : dre;
wire [17:0] aim  = dim[17] ? -dim : dim;
wire [17:0] mx   = (are > aim) ? are : aim;
wire [17:0] mn   = (are > aim) ? aim : are;
wire [17:0] mag  = mx + (mn >> 1);
wire [17:0] bm_n = (mag > bmax) ? mag : bmax;

// 柱高更新
wire [5:0]  un   = run ? nh[ub] : 6'd0;
wire [5:0]  ud   = disp[ub];
wire [5:0]  dnew = (un > ud) ? un : (ud != 6'd0) ? ud - 6'd1 : 6'd0;

function [9:0] bitrev10;
    input [9:0] x;
    integer i;
    for (i = 0; i < 10; i = i + 1) bitrev10[i] = x[9 - i];
endfunction

integer z;
always @(posedge clk or posedge rst) begin
    if (rst) begin
        st <= S_IDLE; ub <= 5'd0; run <= 1'b0;
        ln <= 11'd0; lbase <= 10'd0; ln1 <= 10'd0; ln2 <= 10'd0; lv1 <= 1'b0; lv2 <= 1'b0;
        ln3 <= 10'd0; ln4 <= 10'd0; lv3 <= 1'b0; lv4 <= 1'b0; iq3 <= 16'sd0;
        lq1 <= 2'd0; lq2 <= 2'd0; cosv <= 17'sd0; lprod <= 32'sd0;
        ira <= 10'd0; dra <= 10'd0; dwe <= 1'b0; dwa <= 10'd0; dwd <= 36'd0; sa <= 9'd0;
        fs_s <= 4'd0; fj <= 9'd0; ba <= 10'd0; bb <= 10'd0; bm <= 9'd0;
        Ar <= 18'sd0; Ai <= 18'sd0; Br <= 18'sd0; Bi <= 18'sd0; cw <= 17'sd0; sw <= 15'd0;
        p1 <= 35'sd0; p2 <= 35'sd0; p3 <= 35'sd0; p4 <= 35'sd0; tr <= 20'sd0; ti <= 20'sd0;
        kb <= 9'd0; bi <= 5'd0; bmax <= 18'd0;
        for (z = 0; z < NBAND; z = z + 1) begin
            nh[z] <= 6'd0; disp[z] <= 6'd0; cap[z] <= 6'd0; hold[z] <= 5'd0;
        end
    end else begin
        dwe <= 1'b0;
        case (st)
        S_IDLE: if (fs) begin
            ub <= 5'd0;
            st <= S_UPD;
        end
        //---------------- 帧边界更新显示值 (24 拍, 消隐期内) ----------------
        S_UPD: begin
            disp[ub] <= dnew;
            if (un >= cap[ub]) begin
                cap[ub] <= un; hold[ub] <= HOLD;
            end else if (hold[ub] != 5'd0)
                hold[ub] <= hold[ub] - 5'd1;
            else
                cap[ub] <= (cap[ub] > dnew) ? cap[ub] - 6'd1 : dnew;
            if (ub == NBAND - 1) begin
                run <= enable;
                if (enable) begin
                    ln <= 11'd0; lbase <= iwp;
                    lv1 <= 1'b0; lv2 <= 1'b0; lv3 <= 1'b0; lv4 <= 1'b0;
                    st <= S_LOAD;
                end else
                    st <= S_IDLE;
            end else
                ub <= ub + 5'd1;
        end
        //---------------- 取样 x Hann 窗, 位反序写入 ----------------
        S_LOAD: begin
            // L0: 发读地址 (最旧的样本在 lbase; cos 表按象限取)
            if (!ln[10]) begin
                ira <= lbase + ln[9:0];
                sa  <= ln[8] ? {1'b0, ln[7:0]} : 9'd256 - {1'b0, ln[7:0]};
                ln  <= ln + 11'd1;
            end
            lv1 <= !ln[10]; ln1 <= ln[9:0]; lq1 <= ln[9:8];
            // L1: 样本 RAM 与正弦表读出中
            lv2 <= lv1; ln2 <= ln1; lq2 <= lq1;
            // L2: iq / sq 有效 -> cos
            lv3  <= lv2; ln3 <= ln2; iq3 <= iq;
            cosv <= (lq2[1] ^ lq2[0]) ? -$signed({2'b00, sq}) : $signed({2'b00, sq});
            // L3: 乘 Hann 窗
            lv4   <= lv3; ln4 <= ln3;
            lprod <= iq3 * $signed({1'b0, wn});
            // L4: 位反序写入 (实部 = 窗后样本 >> 14, 虚部 0)
            if (lv4) begin
                dwe <= 1'b1; dwa <= bitrev10(ln4); dwd <= {lprod[31:14], 18'd0};
            end
            if (ln[10] && !lv1 && !lv2 && !lv3 && !lv4) begin
                fs_s <= 4'd0; fj <= 9'd0;
                st <= S_F0;
            end
        end
        //---------------- FFT 蝶形 ----------------
        S_F0: begin
            ba <= fa; bb <= fa | (10'd1 << fs_s); bm <= fm;
            dra <= fa;
            sa  <= fm[8] ? {1'b0, fm[7:0]} : 9'd256 - {1'b0, fm[7:0]};     // cos
            st  <= S_F1;
        end
        S_F1: begin
            dra <= bb;
            sa  <= bm[8] ? 9'd256 - {1'b0, bm[7:0]} : {1'b0, bm[7:0]};     // sin
            st  <= S_F2;
        end
        S_F2: begin
            Ar <= dre; Ai <= dim;
            cw <= bm[8] ? -$signed({2'b00, sq}) : $signed({2'b00, sq});
            st <= S_F3;
        end
        S_F3: begin
            Br <= dre; Bi <= dim;
            sw <= sq;
            st <= S_F4;
        end
        S_F4: begin
            // W = cos - j sin:  t = W * B = (c*br + s*bi) + j(c*bi - s*br)
            p1 <= cw * Br;
            p2 <= $signed({2'b00, sw}) * Bi;
            p3 <= cw * Bi;
            p4 <= $signed({2'b00, sw}) * Br;
            st <= S_F5;
        end
        S_F5: begin
            tr <= (p1 + p2) >>> 15;
            ti <= (p3 - p4) >>> 15;
            st <= S_F6;
        end
        S_F6: begin
            dwe <= 1'b1; dwa <= ba; dwd <= {sar[18:1], sai[18:1]};
            st  <= S_F7;
        end
        S_F7: begin
            dwe <= 1'b1; dwa <= bb; dwd <= {sbr[18:1], sbi[18:1]};
            fj  <= fj + 9'd1;
            if (fj == 9'd511) begin
                if (fs_s == 4'd9) begin
                    kb <= BIN_LO; bi <= 5'd0; bmax <= 18'd0;
                    st <= S_B0;
                end else begin
                    fs_s <= fs_s + 4'd1;
                    st   <= S_F0;
                end
            end else
                st <= S_F0;
        end
        //---------------- 频段能量 -> 高度 ----------------
        S_B0: begin dra <= {1'b0, kb}; st <= S_B1; end
        S_B1: st <= S_B2;
        S_B2: begin
            if (kb == band_end(bi)) begin
                nh[bi] <= hgt(bm_n, band_tilt(bi));
                bmax   <= 18'd0;
                bi     <= bi + 5'd1;
            end else
                bmax <= bm_n;
            kb <= kb + 9'd1;
            st <= (kb == BIN_HI) ? S_IDLE : S_B0;
        end
        default: st <= S_IDLE;
        endcase
    end
end

//---------------------------------------------------------------------------
// 显示: S0 区域判断 + 取柱高 -> S1 比较 -> S2 输出
//---------------------------------------------------------------------------
wire [9:0] px = xc - PX0;
wire [8:0] py = yc - PY0;
wire in_y    = (yc >= PY0) && (py < 9'd32);
wire in_plot = in_y && (xc >= PX0) && (px < 10'd384);
wire [4:0] bix = px[8:4];
wire [3:0] bcx = px[3:0];
wire [4:0] h   = 5'd31 - py[4:0];               // 高度坐标 (底 = 0)
wire in_vl   = in_y && (xc >= VLX) && (xc < VLX + 10'd3);
wire in_vr   = in_y && (xc >= VRX) && (xc < VRX + 10'd3);
wire [4:0] vlen = in_vl ? len_l : len_r;
wire [2:0] hcol = (h < 5'd20) ? 3'd1 : (h < 5'd26) ? 3'd2 : 3'd3;

reg  [5:0] dsel, csel;
reg        bar1;
reg  [4:0] h1;
reg  [2:0] hc1, vu1;
always @(posedge clk) begin
    dsel <= disp[bix];
    csel <= cap[bix];
    bar1 <= enable && in_plot && (bcx >= 4'd2) && (bcx < 4'd14);
    h1   <= h;
    hc1  <= hcol;
    vu1  <= (enable && (in_vl || in_vr) && (h < vlen)) ? hcol : 3'd0;
end

wire [4:0] crow = (csel > 6'd31) ? 5'd31 : csel[4:0];
wire       capp = bar1 && (csel != 6'd0) && (h1 == crow);
wire       lit  = bar1 && ({1'b0, h1} < dsel);

always @(posedge clk or posedge rst) begin
    if (rst) w2 <= 3'd0;
    else     w2 <= capp ? 3'd4 : lit ? hc1 : vu1;
end

endmodule
