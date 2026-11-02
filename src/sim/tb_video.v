`timescale 1ns/1ps
//============================================================================
// video_compositor 画面仿真
//  video_timing_data (640x400 内容时序, VIDEO_640_400_2X) 驱动 video_compositor, A/B 两路帧数据由
//  图案发生器提供 (与 check_video.py 中的公式相同). 每个测试帧以十六进制
//  文本导出到 frames/fNN.hex, 再由 check_video.py 转成 PNG 并逐像素核对转场混合结果.
//============================================================================
module tb_video;

reg clk = 0;                // video_clk (硬件 18.75M; 仿真只关心拍数)
reg wclk = 0;               // sd_card_clk 100M (文本 RAM 写口)
always #20 clk  = ~clk;
always #5  wclk = ~wclk;
reg rst = 1;

wire hs0, vs0, de0;
wire rreq;
video_timing_data u_tim(
    .video_clk(clk), .rst(rst),
    .read_req(rreq), .read_req_ack(rreq),
    .hs(hs0), .vs(vs0), .de(de0)
);

//---------------------------------------------------------------------------
// 帧数据: 与 SDRAM 读 FIFO 相同, read_en 后一拍给出数据
//---------------------------------------------------------------------------
wire        ren_a, ren_b;
reg  [31:0] data_a = 0, data_b = 0;
reg  [9:0]  ax = 0, bx = 0;
reg  [8:0]  ay = 0, by = 0;
reg         vs0_d = 1;

function [23:0] pat_a(input [9:0] x, input [8:0] y);
    integer r, g;
    begin
        r = x * 255 / 639;
        g = y * 255 / 399;
        pat_a = {r[7:0], g[7:0], 8'd64};
    end
endfunction
function [23:0] pat_b(input [9:0] x, input [8:0] y);
    reg [7:0] c, bl;
    begin
        c  = (x[5] ^ y[5]) ? 8'd230 : 8'd30;
        bl = x[7:0] + y[7:0];
        pat_b = {c, 8'd255 - c, bl};
    end
endfunction

always @(posedge clk) begin
    vs0_d <= vs0;
    if (vs0_d & ~vs0) begin ax <= 0; ay <= 0; bx <= 0; by <= 0; end
    if (ren_a) begin
        data_a <= {pat_a(ax, ay), 8'h00};
        if (ax == 639) begin ax <= 0; ay <= ay + 1; end else ax <= ax + 1;
    end
    if (ren_b) begin
        data_b <= {pat_b(bx, by), 8'h00};
        if (bx == 639) begin bx <= 0; by <= by + 1; end else bx <= bx + 1;
    end
end

//---------------------------------------------------------------------------
// DUT
//---------------------------------------------------------------------------
reg        splash_on = 1, bar_on = 0, auto_on = 0, waiting = 0, msg_bad = 0;
reg  [3:0] cur_img = 0, eff_sel = 0, load_img = 0;
reg  [2:0] eff_now = 0, ld_status = 3'd1, rate_code = 3'd4;
reg  [8:0] p = 0;
reg        b_en = 0;
reg  [1:0] amode = 0;
reg  [4:0] img_count = 0;
reg  [7:0] load_prog = 0;
reg        wav_ok = 1, txt_ok = 0, fnt_ok = 0;
reg  [9:0] txt_len = 0;
reg        txt_we = 0;
reg  [9:0] txt_waddr = 0;
reg  [7:0] txt_wdata = 0;

wire        frame_end, hs, vs, de;
wire [23:0] rgb;

video_compositor dut(
    .clk(clk), .rst(rst),
    .hs_in(hs0), .vs_in(vs0), .de_in(de0),
    .read_en_a(ren_a), .data_a(data_a), .read_en_b(ren_b), .data_b(data_b),
    .splash_on(splash_on), .bar_on(bar_on), .auto_on(auto_on), .waiting(waiting), .msg_bad(msg_bad),
    .cur_img(cur_img), .eff_sel(eff_sel), .eff_now(eff_now), .p(p), .b_en(b_en), .amode(amode),
    .menu_on(1'b0), .menu_sel(3'd0), .pmode(2'd0), .bri_lvl(5'd8), .con_lvl(5'd8),
    .temp_lvl(5'd8), .gam_lvl(5'd8), .vol_lvl(5'd16),
    .wave_on(1'b0), .aud_tgl(1'b0), .aud_l(16'd0), .aud_r(16'd0), .alarm_on(1'b0), .alm_bcd(16'd0), .alm_src(2'd0),
    .ld_status(ld_status), .img_count(img_count), .load_img(load_img), .load_prog(load_prog),
    .wav_ok(wav_ok), .rate_code(rate_code), .txt_ok(txt_ok), .txt_len(txt_len),
    .wclk(wclk), .txt_we(txt_we), .txt_waddr(txt_waddr), .txt_wdata(txt_wdata),
    .fnt_we(1'b0), .fnt_waddr(11'd0), .fnt_wdata(8'd0), .fnt_ok(fnt_ok),
    .frame_end(frame_end), .hs_out(hs), .vs_out(vs), .de_out(de), .rgb_out(rgb)
);

//---------------------------------------------------------------------------
// 帧导出
//---------------------------------------------------------------------------
integer fd, npix, nfr = 0;
integer list;

task write_txt(input integer addr, input [8*8-1:0] s);
    integer j;
    begin
        for (j = 0; j < 8; j = j + 1) begin
            @(posedge wclk);
            txt_we <= 1'b1; txt_waddr <= addr + j; txt_wdata <= s[8*(7-j) +: 8];
        end
        @(posedge wclk); txt_we <= 1'b0;
    end
endtask

// 在消隐期设置好参数后调用: 等下一帧开始, 导出 640x400 个有效像素
task grab(input [8*24-1:0] tag);
    reg [8*64-1:0] fn;
    begin
        $sformat(fn, "frames/f%02d.hex", nfr);
        fd = $fopen(fn, "w");
        $fdisplay(list, "f%02d %0s eff=%0d p=%0d splash=%0d bar=%0d b_en=%0d",
                  nfr, tag, eff_now, p, splash_on, bar_on, b_en);
        @(negedge vs);
        npix = 0;
        while (npix < 640 * 400) begin
            @(posedge clk);
            if (de) begin $fdisplay(fd, "%06h", rgb); npix = npix + 1; end
        end
        $fclose(fd);
        $display("[%0t] frame f%02d %0s", $time, nfr, tag);
        nfr = nfr + 1;
        @(posedge frame_end);       // 本帧结束, 进入消隐期
    end
endtask

integer e;
initial begin
    list = $fopen("frames/list.txt", "w");
    #200 rst = 0;
    write_txt(512 + 0 * 8, "IMG_A   ");
    write_txt(512 + 1 * 8, "SUNSET  ");
    write_txt(512 + 2 * 8, "IMG_C   ");
    write_txt(768 + 0 * 16, "640x400 ");  write_txt(768 + 0 * 16 + 8, "        ");   // 分辨率文字
    write_txt(768 + 1 * 16, "1920x108");  write_txt(768 + 1 * 16 + 8, "0       ");
    write_txt(768 + 2 * 16, "4096x409");  write_txt(768 + 2 * 16 + 8, "6       ");
    @(posedge frame_end);

    // 1. 开机画面: 扫描中 / 加载首图中
    ld_status = 3'd1;
    grab("splash_scan");
    ld_status = 3'd2; img_count = 5'd3; load_img = 4'd0; load_prog = 8'd160;
    grab("splash_load");

    // 2. 8 种转场, 进度 p = 128 (黑场过渡另取 64 / 192)
    splash_on = 0; bar_on = 1; b_en = 1; cur_img = 0; auto_on = 1;
    force dut.scroll = 13'd700;                 // 滚动字幕滚入画面
    for (e = 0; e < 8; e = e + 1) begin
        eff_now = e; eff_sel = e;
        p = (e == 7) ? 9'd64 : 9'd128;
        grab("transition");
    end
    eff_now = 7; eff_sel = 8; p = 9'd192;
    grab("transition");

    // 3. 转场端点与普通显示
    eff_now = 3; eff_sel = 3; p = 9'd256;
    grab("end_of_transition");
    b_en = 0; p = 0; cur_img = 1; auto_on = 0; amode = 1;
    grab("static_osd");
    waiting = 1; load_prog = 8'd100; cur_img = 2; amode = 0;
    grab("loading");
    waiting = 0; msg_bad = 1; amode = 2;
    grab("bad_image");
    msg_bad = 0; amode = 0; wav_ok = 0; cur_img = 1;
    grab("bar_nowav");
    wav_ok = 1; bar_on = 0;
    grab("bar_hidden");

    $fclose(list);
    $display("==== tb_video done, %0d frames ====", nfr);
    $finish;
end

endmodule
