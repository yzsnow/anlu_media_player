`timescale 1ns/1ps
//============================================================================
// video_scale2x : 640x400 -> 1280x800, 每个像素横竖各复制一次 (2x2 最近邻放大)
//
//  合成器仍在 clk_s (video_clk 18.75MHz) 下按 640x400 工作, 本模块在 clk_f
//  (HDMI 像素时钟 75MHz = 4 x clk_s, 同一 PLL 输出, 同源同相) 下输出 1280x800:
//    内容 1 行 = 760 个 clk_s = 3040 个 clk_f = 输出 2 行 (H_TOT = 1520)
//    内容 1 帧 = 412 行        = 输出 824 行 (V_TOT),  整帧周期严格相等
//
//  行缓存: 2 行乒乓 (2 x 1024 x 24bit)
//    写 (clk_s): 合成器第 ly 个有效行写入 bank ly[0]
//    读 (clk_f): 输出第 vf 行显示内容第 vf>>1 行, 读 bank vf[1], 横坐标 hf>>1
//  输出比写入整整晚 1 个内容行: 读第 ly 行 (输出 2ly, 2ly+1 行) 时写的是 ly+1 行 (另一 bank),
//  读最早的像素也在写入后 >= 1700 个 clk_f, 最晚的像素在被 ly+2 覆盖前 >= 1500 个 clk_f.
//
//  帧对齐: clk_f 域检测合成器每帧第一个有效行的开始 (VS 之后第一个 DE 上升沿),
//  把输出计数器装载为 "输出第 0 行之前 2 行" 的位置. 由于周期严格相等,
//  只有上电后第一帧会真正改变计数器, 之后每帧装载值与计数值相同, 不会抖动.
//  clk_s -> clk_f 的信号都直接来自 clk_s 寄存器, 两时钟相关, 按同步路径做时序分析.
//
//  输出时序 (CVT-RB 1280x800 的行频 49.3kHz, 行消隐加长到 240 给 HDMI 音频数据岛):
//    行: 有效 1280, 前肩 48, 同步 32 (正极性), 后肩 160
//    场: 有效 800,  前肩 3,  同步 6  (负极性), 后肩 15
//============================================================================
module video_scale2x #(
    parameter [10:0] H_ACT  = 11'd1280,
    parameter [10:0] H_FP   = 11'd48,
    parameter [10:0] H_SYNC = 11'd32,
    parameter [10:0] H_TOT  = 11'd1520,
    parameter [9:0]  V_ACT  = 10'd800,
    parameter [9:0]  V_FP   = 10'd3,
    parameter [9:0]  V_SYNC = 10'd6,
    parameter [9:0]  V_TOT  = 10'd824
)(
    // 合成器输出 (clk_s 域, VS 低有效)
    input             clk_s,
    input             rst_s,
    input             vs_s,
    input             de_s,
    input      [23:0] rgb_s,
    // 放大后输出 (clk_f 域)
    input             clk_f,
    input             rst_f,
    output reg        hs_f,
    output reg        vs_f,
    output reg        de_f,
    output reg [23:0] rgb_f
);

//---------------------------------------------------------------------------
// 写侧 (clk_s)
//---------------------------------------------------------------------------
(* ram_style = "bram" *) reg [23:0] lbuf [0:2047];

reg [9:0] wx;
reg       wbank;
reg       de_sd, vs_sd;

always @(posedge clk_s) begin
    if (de_s) lbuf[{wbank, wx}] <= rgb_s;
end

always @(posedge clk_s or posedge rst_s) begin
    if (rst_s) begin
        wx <= 10'd0; wbank <= 1'b0; de_sd <= 1'b0; vs_sd <= 1'b1;
    end else begin
        de_sd <= de_s;
        vs_sd <= vs_s;
        if (de_s) wx <= wx + 10'd1;
        else      wx <= 10'd0;
        if (vs_sd & ~vs_s)      wbank <= 1'b0;      // 帧开始 (VS 下降沿): 第 0 行写 bank 0
        else if (de_sd & ~de_s) wbank <= ~wbank;    // 每行结束换 bank
    end
end

//---------------------------------------------------------------------------
// 读侧 (clk_f): 输出计数器 + 帧对齐
//---------------------------------------------------------------------------
reg        de_q, de_q1, vs_q, vs_q1;
reg        arm;
reg [10:0] hf;
reg [9:0]  vf;
wire       sync_ev = arm & de_q & ~de_q1;           // 合成器本帧第 0 行首像素

always @(posedge clk_f or posedge rst_f) begin
    if (rst_f) begin
        de_q <= 1'b0; de_q1 <= 1'b0; vs_q <= 1'b1; vs_q1 <= 1'b1; arm <= 1'b0;
        hf <= 11'd0; vf <= 10'd0;
    end else begin
        de_q  <= de_s;  de_q1 <= de_q;
        vs_q  <= vs_s;  vs_q1 <= vs_q;
        if (vs_q1 & ~vs_q) arm <= 1'b1;
        else if (sync_ev)  arm <= 1'b0;

        if (sync_ev) begin
            // 本拍记作 (hf=0, vf=V_TOT-2), 2 个输出行 (= 1 个内容行) 后到达输出第 0 行
            hf <= 11'd1;
            vf <= V_TOT - 10'd2;
        end else if (hf == H_TOT - 11'd1) begin
            hf <= 11'd0;
            vf <= (vf == V_TOT - 10'd1) ? 10'd0 : vf + 10'd1;
        end else
            hf <= hf + 11'd1;
    end
end

// F1: 读地址 / 时序标志
reg [10:0] ra;
reg        a1, hs1, vs1;
always @(posedge clk_f) begin
    ra  <= {vf[1], hf[10:1]};
    a1  <= (hf < H_ACT) && (vf < V_ACT);
    hs1 <= (hf >= H_ACT + H_FP) && (hf < H_ACT + H_FP + H_SYNC);
    vs1 <= ~((vf >= V_ACT + V_FP) && (vf < V_ACT + V_FP + V_SYNC));
end

// F2: 读 RAM
reg [23:0] q2;
reg        a2, hs2, vs2;
always @(posedge clk_f) begin
    q2  <= lbuf[ra];
    a2  <= a1;
    hs2 <= hs1;
    vs2 <= vs1;
end

// F3: 输出
always @(posedge clk_f or posedge rst_f) begin
    if (rst_f) begin
        hs_f <= 1'b0; vs_f <= 1'b1; de_f <= 1'b0; rgb_f <= 24'd0;
    end else begin
        hs_f  <= hs2;
        vs_f  <= vs2;
        de_f  <= a2;
        rgb_f <= a2 ? q2 : 24'd0;
    end
end

endmodule
