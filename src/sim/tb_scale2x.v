`timescale 1ns/1ps
//============================================================================
// tb_scale2x : 640x400 (video_clk) -> 1280x800 (pix_clk) 放大与输出时序检查
//
//  video_timing_data (VIDEO_640_400_2X) -> 模拟合成器 (9 拍流水线, 像素值编码坐标)
//  -> video_scale2x -> 逐像素检查:
//    * 每行 1280 个有效像素, 每帧 800 个有效行, 行周期 1520, 场周期 824 行
//    * HS 正极性 32 拍, 位于 DE 下降沿后 48 拍; VS 负极性 6 行, 位于有效区后 3 行
//    * 输出像素 (fx, fy) = 内容像素 (fx>>1, fy>>1), 同一输出帧来自同一内容帧
//  video_clk 由 pix_clk 4 分频得到 (同源同相, 与硬件 PLL 一致)
//============================================================================
module tb_scale2x;

reg clk_f = 1'b0;
always #6.6667 clk_f = ~clk_f;          // 75 MHz
reg [1:0] div = 2'd0;
reg clk_s = 1'b0;                        // 18.75 MHz
always @(posedge clk_f) begin
    div <= div + 2'd1;
    if (div[0]) clk_s <= ~clk_s;
end

reg rst = 1'b1;
initial begin
    #500 rst = 1'b0;
end

//---------------------------------------------------------------------------
// 内容时序 + 模拟合成器
//---------------------------------------------------------------------------
wire rd_req;
wire hs0, vs0, de0;
video_timing_data u_tim(
    .video_clk    (clk_s),
    .rst          (rst),
    .read_req     (rd_req),
    .read_req_ack (rd_req),
    .hs           (hs0),
    .vs           (vs0),
    .de           (de0)
);

reg [9:0] xc;
reg [8:0] yc;
reg       de_d;
reg [7:0] fcnt;                          // 内容帧号
always @(posedge clk_s) begin
    if (rst) begin
        xc <= 0; yc <= 0; de_d <= 0; fcnt <= 0;
    end else begin
        de_d <= de0;
        if (de0) xc <= xc + 10'd1; else xc <= 10'd0;
        if (!vs0) yc <= 9'd0;
        else if (de_d & ~de0) yc <= yc + 9'd1;
        if (de_d & ~de0 && yc == 9'd399) fcnt <= fcnt + 8'd1;
    end
end

function [23:0] pat;
    input [9:0] x; input [8:0] y; input [7:0] f;
    pat = {y[7:0], x[7:0], f[4:0], y[8], x[9:8]};
endfunction

localparam D = 9;
reg [D-1:0] de_p, vs_p;
reg [23:0]  rgb_p [0:D-1];
integer k;
always @(posedge clk_s) begin
    de_p <= {de_p[D-2:0], de0};
    vs_p <= {vs_p[D-2:0], vs0};
    rgb_p[0] <= de0 ? pat(xc, yc, fcnt) : 24'd0;
    for (k = 1; k < D; k = k + 1) rgb_p[k] <= rgb_p[k-1];
end
wire        de_s  = de_p[D-1];
wire        vs_s  = vs_p[D-1];
wire [23:0] rgb_s = rgb_p[D-1];

//---------------------------------------------------------------------------
// DUT
//---------------------------------------------------------------------------
wire        hs_f, vs_f, de_f;
wire [23:0] rgb_f;
video_scale2x dut(
    .clk_s (clk_s), .rst_s (rst), .vs_s (vs_s), .de_s (de_s), .rgb_s (rgb_s),
    .clk_f (clk_f), .rst_f (rst), .hs_f (hs_f), .vs_f (vs_f), .de_f (de_f), .rgb_f (rgb_f)
);

//---------------------------------------------------------------------------
// 检查 (从第 2 个 VS 起; 第 1 帧内输出计数器会被帧对齐装载一次)
//---------------------------------------------------------------------------
integer errs = 0, nchk = 0, frames = 0, vs_starts = 0;
integer fx = 0, fy = 0;
integer hcyc = 0, hs_len = 0, last_de_fall = 0, t = 0;
integer vs_lines = 0, act_lines = 0;
reg     de_l = 1'b0, hs_l = 1'b0, vs_l = 1'b1, checking = 1'b0, have_prev = 1'b0;
reg [4:0]  ffrm, prev_ffrm;
reg [23:0] exp;

task err; input [8*64-1:0] msg; begin
    errs = errs + 1;
    if (errs <= 20) $display("[%0t] ERR %0s  fx=%0d fy=%0d", $time, msg, fx, fy);
end endtask

always @(posedge clk_f) if (!rst) begin
    t = t + 1;
    // ---- 行 ----
    if (hs_f && !hs_l) begin
        if (checking && hcyc != 1520) err("HS period != 1520");
        if (checking && t - last_de_fall < 1520 && t - last_de_fall != 48) err("HS not 48 clk after DE end");   // 只查有 DE 的行
        hcyc = 0; hs_len = 0;
    end
    hcyc = hcyc + 1;
    if (hs_f) hs_len = hs_len + 1;
    if (!hs_f && hs_l && checking && hs_len != 32) err("HS width != 32");
    // ---- 场 ----
    if (!vs_f && vs_l) begin                     // VS 开始
        if (checking) begin
            if (act_lines != 800) err("active lines != 800");
            frames = frames + 1;
        end
        vs_starts = vs_starts + 1;
        if (vs_starts >= 2) checking = 1'b1;
        act_lines = 0; vs_lines = 0;
    end
    if (!vs_f && hs_f && !hs_l) vs_lines = vs_lines + 1;
    if (vs_f && !vs_l && checking && vs_lines != 6) err("VS width != 6 lines");
    // ---- 像素 ----
    if (de_f) begin
        if (!de_l) fx = 0;
        if (fx == 0 && fy == 0) begin
            ffrm = rgb_f[7:3];                   // 本输出帧对应的内容帧号
            if (checking && have_prev && ffrm != prev_ffrm + 5'd1) err("content frame not consecutive");
            if (checking) begin prev_ffrm = ffrm; have_prev = 1'b1; end
        end
        exp = pat(fx >> 1, fy >> 1, {3'b000, ffrm});
        if (checking) begin
            nchk = nchk + 1;
            if (rgb_f !== exp) begin
                errs = errs + 1;
                if (errs <= 20) $display("[%0t] ERR pixel fx=%0d fy=%0d got %h exp %h", $time, fx, fy, rgb_f, exp);
            end
        end
        fx = fx + 1;
    end
    if (!de_f && de_l) begin
        if (checking && fx != 1280) err("active pixels != 1280");
        last_de_fall = t;
        fy = fy + 1; act_lines = act_lines + 1;
    end
    if (!vs_f) fy = 0;
    de_l = de_f; hs_l = hs_f; vs_l = vs_f;
end

initial begin
    // 4 帧 (每帧 1520*824 个 pix_clk = 16.7 ms)
    #(1520.0 * 824 * 13.3333 * 4.2);
    $display("frames checked=%0d pixels=%0d errors=%0d", frames, nchk, errs);
    if (errs == 0 && frames >= 2 && nchk >= 2 * 1280 * 800) $display("==== tb_scale2x PASS ====");
    else                                                  $display("==== tb_scale2x FAIL ====");
    $finish;
end

endmodule
