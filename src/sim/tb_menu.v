`timescale 1ns/1ps
//============================================================================
// 显示参数调节 (SW3) 仿真
//  1. player_ctrl: SW3 消抖后进入菜单, 按键改为 选项 / +1 / -1 (长按连发) / 复位,
//     菜单中不换图、不切换轮播/特效; 关闭 SW3 后按键恢复原功能
//  2. video_compositor: 导出菜单画面与不同亮度/对比度的画面 (frames/mNN.hex),
//     check_menu.py 逐像素核对亮度/对比度公式 (第十四讲), 默认值必须直通
//  3. audio_i2s_player: 各音量级别下输出 = 样本 * 增益 (增益表 2 dB/级)
//============================================================================
module tb_menu;

reg clk = 0;                // video_clk 25M
reg mclk = 0;               // audio_mclk 12.288M
always #20 clk  = ~clk;
always #40.69 mclk = ~mclk;
reg rst = 1;
integer errors = 0;

//---------------------------------------------------------------------------
// 1. player_ctrl (CLK_HZ 缩小到 100 kHz: 1 ms = 100 周期, 按键时序照常按 ms 计)
//---------------------------------------------------------------------------
reg  key1_n = 1, key2_n = 1, sw4 = 0, sw3 = 0;
reg  fe = 0;
wire [3:0] c_cur_img;
wire       c_auto_on;
wire [3:0] c_eff_sel;
wire       c_menu_on;
wire [2:0] c_menu_sel;
wire [1:0] c_pmode;
wire [4:0] c_bri, c_con, c_vol, c_tmp, c_gam;
wire       c_req_toggle;
player_ctrl #(.CLK_HZ(100_000)) u_ctrl(
    .clk(clk), .rst(rst), .key1_n(key1_n), .key2_n(key2_n), .sw4(sw4), .sw3(sw3), .sw2(1'b0),
    .frame_end(fe), .ld_status(3'd2), .img_count(5'd5),
    .req_toggle(c_req_toggle), .req_img(), .cur_slot(),
    .ack_toggle(1'b0), .ack_slot(3'd0), .ack_ok(1'b0), .ack_img(4'd0), .ack_dur(8'd0),
    .base_a(), .base_b(), .b_en(), .p(), .eff_now(), .eff_sel(c_eff_sel),
    .auto_on(c_auto_on), .amode(), .splash_on(), .bar_on(), .waiting(), .msg_bad(),
    .cur_img(c_cur_img),
    .menu_on(c_menu_on), .menu_sel(c_menu_sel), .pmode(c_pmode), .bri_lvl(c_bri), .con_lvl(c_con),
    .temp_lvl(c_tmp), .gam_lvl(c_gam), .vol_lvl(c_vol), .wave_on(),
    .sw1(1'b0), .key3_n(1'b1), .smoke_n(1'b1), .fire_in(1'b1), .term_tgl(1'b0), .term_op(4'd0), .term_arg(5'd0), .alarm_on(), .alm_bcd(), .alm_src(), .preheat()
);

task wait_ms(input integer n);
    repeat (n * 100) @(posedge clk);
endtask
task press(input integer k, input integer ms);   // k = 1 / 2
    begin
        if (k == 1) key1_n = 0; else key2_n = 0;
        wait_ms(ms);
        if (k == 1) key1_n = 1; else key2_n = 1;
        wait_ms(40);
    end
endtask
// 菜单项: 0 模式 1 亮度 2 对比度 3 色温 4 伽马 5 音量 6 复位
task expect_lvl(input [4:0] b, input [4:0] c, input [4:0] t, input [4:0] g, input [4:0] v,
                input [2:0] sel, input [1:0] pm);
    begin
        if (c_bri !== b || c_con !== c || c_tmp !== t || c_gam !== g || c_vol !== v ||
            c_menu_sel !== sel || c_pmode !== pm) begin
            $display("ERROR ctrl: bri=%0d con=%0d tmp=%0d gam=%0d vol=%0d sel=%0d mode=%0d, expect %0d %0d %0d %0d %0d %0d %0d",
                     c_bri, c_con, c_tmp, c_gam, c_vol, c_menu_sel, c_pmode, b, c, t, g, v, sel, pm);
            errors = errors + 1;
        end else
            $display("  ctrl ok: bri=%0d con=%0d tmp=%0d gam=%0d vol=%0d sel=%0d mode=%0d",
                     c_bri, c_con, c_tmp, c_gam, c_vol, c_menu_sel, c_pmode);
    end
endtask

task test_ctrl;
    reg [3:0] eff0;
    reg       auto0, req0;
    begin
        $display("---- player_ctrl ----");
        wait_ms(5);
        expect_lvl(8, 8, 8, 8, 16, 0, 0);
        eff0 = c_eff_sel; auto0 = c_auto_on; req0 = c_req_toggle;
        sw3 = 1; wait_ms(30);
        if (!c_menu_on) begin $display("ERROR menu not on"); errors = errors + 1; end
        // 模式: 短按 -> 日间 (11/10/9/7), 长按 -> 回到正常, 再短按两次 -> 夜间 (5/7/4/10)
        press(2, 50);
        expect_lvl(11, 10, 9, 7, 16, 0, 1);
        press(2, 850);
        expect_lvl(8, 8, 8, 8, 16, 0, 0);
        press(2, 50); press(2, 50);
        expect_lvl(5, 7, 4, 10, 16, 0, 2);
        // 模式长按往回: 夜间 -> 日间 -> 正常 -> 绕到护眼 (7/8/1/8), 再短按 3 次绕回夜间
        press(2, 850); press(2, 850); press(2, 850);
        expect_lvl(7, 8, 1, 8, 16, 0, 3);
        press(2, 50); press(2, 50); press(2, 50);
        expect_lvl(5, 7, 4, 10, 16, 0, 2);
        // 下一项 -> 亮度 +3
        press(1, 50);
        press(2, 50); press(2, 50); press(2, 50);
        expect_lvl(8, 7, 4, 10, 16, 1, 2);
        // 下一项 -> 对比度, 长按 KEY2 1.3 s: 0.8 s 一次 + 连发 3 次 (0.95/1.1/1.25 s) = -4
        press(1, 50);
        press(2, 1300);
        expect_lvl(8, 3, 4, 10, 16, 2, 2);
        // 色温 +1, 伽马 +1
        press(1, 50); press(2, 50);
        expect_lvl(8, 3, 5, 10, 16, 3, 2);
        press(1, 50); press(2, 50);
        expect_lvl(8, 3, 5, 11, 16, 4, 2);
        // 下一项 -> 音量, +1 到上限不溢出; 长按 -1
        press(1, 50);
        press(2, 50);
        expect_lvl(8, 3, 5, 11, 16, 5, 2);
        press(2, 850);
        expect_lvl(8, 3, 5, 11, 15, 5, 2);
        // KEY1 长按 -> 上一项 x3 (对比度)
        press(1, 900); press(1, 900); press(1, 900);
        expect_lvl(8, 3, 5, 11, 15, 2, 2);
        // 对比度一直减到 0 不下溢
        press(2, 2000);
        expect_lvl(8, 0, 5, 11, 15, 2, 2);
        // 菜单中按键不能换图 / 切换轮播 / 特效
        if (c_eff_sel !== eff0 || c_auto_on !== auto0 || c_req_toggle !== req0) begin
            $display("ERROR keys leaked to player in menu"); errors = errors + 1;
        end
        // 复位项 (上一项 x3: 2 -> 1 -> 0 -> 6, 从模式往回绕)
        press(1, 900); press(1, 900); press(1, 900);
        expect_lvl(8, 0, 5, 11, 15, 6, 2);
        press(2, 50);
        expect_lvl(8, 8, 8, 8, 16, 6, 0);
        // 调好再关菜单: 参数保持, 按键恢复原功能 (复位 -> 模式 -> 亮度, +2)
        press(1, 50); press(1, 50); press(2, 50); press(2, 50);
        expect_lvl(10, 8, 8, 8, 16, 1, 0);
        sw3 = 0; wait_ms(30);
        if (c_menu_on) begin $display("ERROR menu still on"); errors = errors + 1; end
        press(2, 50);                                   // KEY2 短按 = 轮播开关
        if (c_auto_on === auto0) begin $display("ERROR KEY2 not back to auto toggle"); errors = errors + 1; end
        expect_lvl(10, 8, 8, 8, 16, 1, 0);
        // 再次打开从模式开始
        sw3 = 1; wait_ms(30);
        expect_lvl(10, 8, 8, 8, 16, 0, 0);
        sw3 = 0; wait_ms(30);
    end
endtask

//---------------------------------------------------------------------------
// 2. video_compositor
//---------------------------------------------------------------------------
wire hs0, vs0, de0;
wire rreq;
reg vrst = 1;
video_timing_data u_tim(
    .video_clk(clk), .rst(vrst),
    .read_req(rreq), .read_req_ack(rreq),
    .hs(hs0), .vs(vs0), .de(de0)
);

wire        ren_a, ren_b;
reg  [31:0] data_a = 0;
reg  [9:0]  ax = 0;
reg  [8:0]  ay = 0;
reg         vs0_d = 1;
// 图案: 灰阶横条 + 彩色竖条, 覆盖 0~255 全范围
function [23:0] pat_a(input [9:0] x, input [8:0] y);
    reg [7:0] v;
    begin
        v = x * 255 / 639;
        if (y < 136)      pat_a = {v, v, v};
        else if (y < 272) pat_a = {v, 8'd255 - v, 8'd128};
        else              pat_a = {8'd20, v, 8'd240};
    end
endfunction
always @(posedge clk) begin
    vs0_d <= vs0;
    if (vs0_d & ~vs0) begin ax <= 0; ay <= 0; end
    if (ren_a) begin
        data_a <= {pat_a(ax, ay), 8'h00};
        if (ax == 639) begin ax <= 0; ay <= ay + 1; end else ax <= ax + 1;
    end
end

reg        splash_on = 0, bar_on = 0, menu_on = 0;
reg  [2:0] menu_sel = 0;
reg  [1:0] pmode = 0;
reg  [4:0] bri = 8, con = 8, vol = 16, tmp = 8, gam = 8;
reg  [2:0] ld_status = 3'd2;
wire       frame_end, hs, vs, de;
wire [23:0] rgb;
video_compositor dut(
    .clk(clk), .rst(vrst),
    .hs_in(hs0), .vs_in(vs0), .de_in(de0),
    .read_en_a(ren_a), .data_a(data_a), .read_en_b(ren_b), .data_b(32'd0),
    .splash_on(splash_on), .bar_on(bar_on), .auto_on(1'b1), .waiting(1'b0), .msg_bad(1'b0),
    .cur_img(4'd0), .eff_sel(4'd8), .eff_now(3'd0), .p(9'd0), .b_en(1'b0), .amode(2'd0),
    .menu_on(menu_on), .menu_sel(menu_sel), .pmode(pmode), .bri_lvl(bri), .con_lvl(con),
    .temp_lvl(tmp), .gam_lvl(gam), .vol_lvl(vol),
    .wave_on(1'b0), .aud_tgl(1'b0), .aud_l(16'd0), .aud_r(16'd0), .alarm_on(1'b0), .alm_bcd(16'd0), .alm_src(2'd0),
    .ld_status(ld_status), .img_count(5'd5), .load_img(4'd0), .load_prog(8'd0),
    .wav_ok(1'b1), .rate_code(3'd6), .txt_ok(1'b0), .txt_len(10'd0),
    .wclk(clk), .txt_we(1'b0), .txt_waddr(10'd0), .txt_wdata(8'd0),
    .fnt_we(1'b0), .fnt_waddr(11'd0), .fnt_wdata(8'd0), .fnt_ok(1'b0),
    .frame_end(frame_end), .hs_out(hs), .vs_out(vs), .de_out(de), .rgb_out(rgb)
);

integer fd, npix, nfr = 0, list;
task grab(input [8*24-1:0] tag);
    reg [8*64-1:0] fn;
    begin
        $sformat(fn, "frames/m%02d.hex", nfr);
        fd = $fopen(fn, "w");
        $fdisplay(list, "m%02d %0s menu=%0d sel=%0d bri=%0d con=%0d tmp=%0d gam=%0d vol=%0d mode=%0d splash=%0d",
                  nfr, tag, menu_on, menu_sel, bri, con, tmp, gam, vol, pmode, splash_on);
        @(negedge vs);
        npix = 0;
        while (npix < 640 * 400) begin
            @(posedge clk);
            if (de) begin $fdisplay(fd, "%06h", rgb); npix = npix + 1; end
        end
        $fclose(fd);
        $display("[%0t] frame m%02d %0s", $time, nfr, tag);
        nfr = nfr + 1;
        @(posedge frame_end);
    end
endtask

// 帧内改参数: 在第 200 行改亮度, 本帧必须保持旧值 (帧边界锁存)
task grab_midchange(input [8*24-1:0] tag, input [4:0] b_new);
    reg [8*64-1:0] fn;
    begin
        $sformat(fn, "frames/m%02d.hex", nfr);
        fd = $fopen(fn, "w");
        $fdisplay(list, "m%02d %0s menu=%0d sel=%0d bri=%0d con=%0d tmp=%0d gam=%0d vol=%0d mode=%0d splash=%0d",
                  nfr, tag, menu_on, menu_sel, bri, con, tmp, gam, vol, pmode, splash_on);
        @(negedge vs);
        npix = 0;
        while (npix < 640 * 400) begin
            @(posedge clk);
            if (npix == 640 * 200) bri = b_new;
            if (de) begin $fdisplay(fd, "%06h", rgb); npix = npix + 1; end
        end
        $fclose(fd);
        $display("[%0t] frame m%02d %0s", $time, nfr, tag);
        nfr = nfr + 1;
        @(posedge frame_end);
    end
endtask

task test_video;
    begin
        $display("---- video_compositor ----");
        list = $fopen("frames/mlist.txt", "w");
        vrst = 0;
        @(posedge frame_end);
        grab("bypass");                                         // m00 默认 = 直通
        bri = 12; con = 8;  grab("bright");                     // m01
        bri = 8;  con = 13; grab("contrast");                   // m02
        bri = 16; con = 16; grab("sat");                        // m03 两端饱和
        bri = 8;  con = 0;  grab("con0_grey");                  // m04 对比度 0 = 中灰
        bri = 5;  con = 11; menu_on = 1; menu_sel = 2; vol = 10;
        grab("menu");                                           // m05 菜单 (对比度选中)
        menu_sel = 6; splash_on = 1; ld_status = 3'd1; bri = 8; con = 8;
        grab("menu_splash");                                    // m06 开机画面上的菜单 (复位选中)
        menu_on = 0; splash_on = 0; bri = 8; con = 8;
        grab_midchange("midframe", 5'd4);                       // m07 帧内改参数
        grab("after_change");                                   // m08 下一帧才生效
        // 画面模式: 色温 / 伽马 / 预设 (查找表逐像素核对)
        bri = 8;  con = 8;  tmp = 2;  gam = 8;  grab("warm");   // m09 偏暖 (护眼方向)
        tmp = 14;                               grab("cool");   // m10 偏冷
        tmp = 8;  gam = 4;                      grab("gamma4"); // m11 伽马 1.41 (压暗暗部)
        gam = 12;                               grab("gamma12");// m12 伽马 0.71 (提亮暗部)
        bri = 5;  con = 7;  tmp = 4;  gam = 10; grab("night");  // m13 夜间预设
        bri = 7;  con = 8;  tmp = 1;  gam = 8;  pmode = 3;
        menu_on = 1; menu_sel = 0;              grab("menu_mode"); // m14 菜单: 模式行 (护眼) 选中
        menu_on = 0; pmode = 0; bri = 8; con = 8; tmp = 8; gam = 8;
        $fclose(list);
    end
endtask

//---------------------------------------------------------------------------
// 3. audio_i2s_player 音量
//---------------------------------------------------------------------------
reg  [4:0] a_vol = 16;
reg        arst = 1;
audio_i2s_player #(.AW(4)) u_aud(
    .I_mclk(mclk), .I_rst(arst), .amode(2'd1), .wav_ok(1'b0), .wav_rate(17'd48000),
    .vol_lvl(a_vol),
    .fifo_rd(), .fifo_data(32'd0), .fifo_empty(1'b1), .fifo_level(5'd0),
    .vu(), .xrun(), .buzz(), .O_i2s_BCLK(), .O_i2s_LRCK(), .O_i2s_DOUT()
);

function integer gain_ref(input integer l);
    case (l)
        0: gain_ref = 0;   1: gain_ref = 8;   2: gain_ref = 10;  3: gain_ref = 13;
        4: gain_ref = 16;  5: gain_ref = 20;  6: gain_ref = 26;  7: gain_ref = 32;
        8: gain_ref = 41;  9: gain_ref = 51;  10: gain_ref = 64; 11: gain_ref = 81;
        12: gain_ref = 102; 13: gain_ref = 128; 14: gain_ref = 162; 15: gain_ref = 203;
        default: gain_ref = 256;
    endcase
endfunction

task test_audio;
    integer l, n, bad, exp_v, got;
    begin
        $display("---- audio volume ----");
        #1000 arst = 0;
        for (l = 16; l >= 0; l = l - 1) begin
            a_vol = l;
            repeat (20) @(posedge mclk);        // 同步 + 增益寄存
            bad = 0;
            for (n = 0; n < 200; n = n + 1) begin
                // next_l 为上一拍 src_l * gain 的寄存
                @(posedge mclk); #1;
                exp_v = $signed(u_aud.src_l) * gain_ref(l);
                @(posedge mclk); #1;
                got   = $signed(u_aud.next_l);
                if (got != exp_v) bad = bad + 1;
                repeat (97) @(posedge mclk);
            end
            if (bad) begin $display("ERROR vol %0d: %0d mismatches", l, bad); errors = errors + bad; end
        end
        if (l < 0) $display("  audio volume: 17 levels checked");
    end
endtask

initial begin
    #200 rst = 0;
    fork
        test_audio;
        begin test_ctrl; test_video; end
    join
    if (errors == 0) $display("==== tb_menu PASS ====");
    else             $display("==== tb_menu FAIL (%0d errors) ====", errors);
    $finish;
end

endmodule
