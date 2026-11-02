`timescale 1ns/1ps
//============================================================================
// tb_alarm : 应急报警 (SW1 布防 + KEY3 模拟传感器) 仿真
//  1. player_ctrl: SW1 = 0 时 KEY3 不触发; SW1 = 1 时 KEY3 触发并锁存 (松开不解除),
//     报警期间 KEY1 / KEY2 / SW3 菜单不响应, amode = 3; 计时 mm:ss 进位与 99:59 封顶;
//     SW1 拨回 0 解除, amode 恢复;
//     外接传感器: 预热期内烟雾不触发; 火焰 100 ms 短脉冲不触发, 闪烁 (30 ms 有效 / 10 ms 无效) 累计到门限触发;
//     烟雾 500 ms 不触发, 持续 1 s 触发; 传感器仍有效时撤防再布防立即重新触发; alm_src 记录来源
//  2. video_compositor + alarm_screen: 导出画面 frames/aNN.hex, check_alarm.py 按 RTL 算法
//     逐整帧核对报警画面 (文字 / 三角 / 斜纹 / 脉动底 / 计时数字, 不叠加频谱), 核对帧边界硬切 (触发所在帧
//     整帧正常, 下一帧整帧报警), 解除后恢复原图, 开机画面上也能报警; 火焰 / 烟雾触发时说明行换成对应文字
//  3. audio_i2s_player: 警笛 600 ~ 1500 Hz 往返扫频 (按过零点测频), 幅度 +/-16383,
//     音量 0 (静音) 时也照常输出; 蜂鸣器方波与警笛同频; 报警期间 WAV 不读 FIFO,
//     解除后样本序列接着断点继续
//  视频时钟只在 1、2 部分运行 (第 3 部分停掉以加快仿真)
//============================================================================
module tb_alarm;

reg vclk_on = 1'b1;
reg clk = 0;                // video_clk 25M
reg mclk = 0;               // audio_mclk 12.288M
always #20 clk = vclk_on ? ~clk : clk;
always #40.69 mclk = ~mclk;
reg rst = 1;
integer errors = 0;

task fail(input [8*64-1:0] msg);
    begin
        errors = errors + 1;
        $display("[%0t] ERROR: %0s", $time, msg);
    end
endtask

//---------------------------------------------------------------------------
// player_ctrl (CLK_HZ 缩小到 100 kHz: 1 ms = 100 周期)
//---------------------------------------------------------------------------
reg  key1_n = 1, key2_n = 1, key3_n = 1, sw1 = 0, sw3 = 0;
reg  smoke_n = 1, fire_in = 1;              // 均低有效
wire [1:0] c_src;
wire       c_pre;
wire       c_auto_on, c_menu_on, c_alarm;
wire [3:0] c_eff_sel;
wire [2:0] c_menu_sel;
wire [1:0] c_amode;
wire [15:0] c_bcd;
wire       frame_end;
player_ctrl #(.CLK_HZ(100_000), .PREHEAT_MS(2000)) u_ctrl(
    .clk(clk), .rst(rst), .key1_n(key1_n), .key2_n(key2_n), .sw4(1'b1), .sw3(sw3), .sw2(1'b0),
    .sw1(sw1), .key3_n(key3_n), .smoke_n(smoke_n), .fire_in(fire_in), .term_tgl(1'b0), .term_op(4'd0), .term_arg(5'd0),
    .frame_end(frame_end), .ld_status(3'd2), .img_count(5'd5),
    .req_toggle(), .req_img(), .cur_slot(),
    .ack_toggle(1'b0), .ack_slot(3'd0), .ack_ok(1'b0), .ack_img(4'd0), .ack_dur(8'd0),
    .base_a(), .base_b(), .b_en(), .p(), .eff_now(), .eff_sel(c_eff_sel),
    .auto_on(c_auto_on), .amode(c_amode), .splash_on(), .bar_on(), .waiting(), .msg_bad(),
    .cur_img(), .menu_on(c_menu_on), .menu_sel(c_menu_sel), .pmode(), .bri_lvl(), .con_lvl(), .temp_lvl(), .gam_lvl(), .vol_lvl(),
    .wave_on(), .alarm_on(c_alarm), .alm_bcd(c_bcd), .alm_src(c_src), .preheat(c_pre)
);

task wait_ms(input integer n);
    repeat (n * 100) @(posedge clk);
endtask
task press(input integer k, input integer ms);   // k = 1 / 2 / 3
    begin
        if (k == 1) key1_n = 0; else if (k == 2) key2_n = 0; else key3_n = 0;
        wait_ms(ms);
        if (k == 1) key1_n = 1; else if (k == 2) key2_n = 1; else key3_n = 1;
        wait_ms(40);
    end
endtask

//---------------------------------------------------------------------------
// video_compositor (图片 = tb_menu 同款测试图案, 音频 = 1 kHz 正弦, SW2 频谱打开: 报警时不应出现)
//---------------------------------------------------------------------------
wire hs0, vs0, de0;
wire rreq;
reg  vrst = 1;
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

// 1 kHz 正弦, 48 kHz 样本
reg        aud_tgl = 0;
reg [15:0] aud_s = 0;
real       at = 0.0;
always begin
    #20833.33;
    if (vclk_on) begin
        at = at + 1.0 / 48000.0;
        aud_s   = $rtoi(16000.0 * $sin(6.283185307 * 1000.0 * at));
        aud_tgl = ~aud_tgl;
    end
end

reg        splash_on = 0;
reg        wave_on = 0;         // 报警帧中打开 SW2, 频谱不应叠加在报警画面上
wire       hs, vs, de;
wire [23:0] rgb;
video_compositor dut(
    .clk(clk), .rst(vrst),
    .hs_in(hs0), .vs_in(vs0), .de_in(de0),
    .read_en_a(ren_a), .data_a(data_a), .read_en_b(ren_b), .data_b(32'd0),
    .splash_on(splash_on), .bar_on(1'b0), .auto_on(1'b1), .waiting(1'b0), .msg_bad(1'b0),
    .cur_img(4'd0), .eff_sel(4'd8), .eff_now(3'd0), .p(9'd0), .b_en(1'b0), .amode(c_amode),
    .menu_on(c_menu_on), .menu_sel(c_menu_sel), .pmode(2'd0), .bri_lvl(5'd8), .con_lvl(5'd8),
    .temp_lvl(5'd8), .gam_lvl(5'd8), .vol_lvl(5'd16),
    .wave_on(wave_on), .aud_tgl(aud_tgl), .aud_l(aud_s), .aud_r(aud_s),
    .alarm_on(c_alarm), .alm_bcd(c_bcd), .alm_src(c_src),
    .ld_status(3'd1), .img_count(5'd5), .load_img(4'd0), .load_prog(8'd0),
    .wav_ok(1'b1), .rate_code(3'd6), .txt_ok(1'b0), .txt_len(10'd0),
    .wclk(clk), .txt_we(1'b0), .txt_waddr(10'd0), .txt_wdata(8'd0),
    .fnt_we(1'b0), .fnt_waddr(11'd0), .fnt_wdata(8'd0), .fnt_ok(1'b0),
    .frame_end(frame_end), .hs_out(hs), .vs_out(vs), .de_out(de), .rgb_out(rgb)
);

// 画面导出: 列表记录本帧的 alm_f / fc / 锁存的计时 (帧中途采样, 均为帧开始锁存值)
integer fd, npix, nfr = 0, list;
reg     k3_at_row = 0;     // 1 = 在本帧第 100 行按下 KEY3 (测帧边界硬切)
task grab(input [8*24-1:0] tag);
    reg [8*64-1:0] fn;
    begin
        $sformat(fn, "frames/a%02d.hex", nfr);
        fd = $fopen(fn, "w");
        @(negedge vs);
        npix = 0;
        while (npix < 640 * 400) begin
            @(posedge clk);
            if (de) begin
                $fdisplay(fd, "%06h", rgb); npix = npix + 1;
                if (npix == 640 * 100 && k3_at_row) begin key3_n = 0; k3_at_row = 0; end
                if (npix == 640 * 200)
                    $fdisplay(list, "a%02d %0s alm=%0d fc=%0d t=%04h sc=%0d splash=%0d menu=%0d src=%0d",
                              nfr, tag, dut.alm_f, dut.u_alarm.fc, dut.u_alarm.t_f, dut.u_alarm.sc,
                              splash_on, c_menu_on, c_src);
            end
        end
        $fclose(fd);
        $display("[%0t] frame a%02d %0s alm=%0d t=%04h", $time, nfr, tag, dut.alm_f, dut.u_alarm.t_f);
        nfr = nfr + 1;
        @(posedge frame_end);
    end
endtask

task test_ctrl_video;
    reg [3:0] eff0;
    reg       auto0;
    integer   t_fire;
    begin
        list = $fopen("frames/alist.txt", "w");
        vrst = 0;
        wait_ms(5);
        // MQ-2 预热 (2 s) 期间: 布防且烟雾持续有效也不触发
        if (!c_pre) fail("preheat not active after reset");
        sw1 = 1; smoke_n = 0;
        wait_ms(1500);
        if (c_alarm) fail("smoke triggered during preheat");
        smoke_n = 1; sw1 = 0;
        wait_ms(600);
        if (c_pre) fail("preheat not finished");
        @(posedge frame_end);

        // a00: 未布防, 按 KEY3 不触发
        press(3, 50);
        if (c_alarm) fail("alarm without SW1");
        grab("normal");

        // 布防, 在 a01 第 100 行按下 KEY3: a01 整帧正常, a02 整帧报警 (帧边界硬切)
        sw1 = 1; wait_ms(30);
        if (c_alarm) fail("alarm on arm without KEY3");
        k3_at_row = 1;
        grab("trigger_frame");
        if (!c_alarm) fail("KEY3 did not trigger");
        if (c_amode !== 2'd3) fail("amode != 3 in alarm");
        key3_n = 1;
        grab("alarm_first");

        // 松开 KEY3 仍锁存; KEY1 / KEY2 / SW3 菜单不响应
        eff0 = c_eff_sel; auto0 = c_auto_on;
        wait_ms(50);
        press(2, 50);          // KEY2 短按 = 轮播开关
        press(2, 900);         // KEY2 长按 = 切换特效
        sw3 = 1; wait_ms(30);
        if (!c_alarm) fail("alarm not latched after KEY3 release");
        if (c_menu_on) fail("menu opened during alarm");
        if (c_auto_on !== auto0 || c_eff_sel !== eff0) fail("KEY2 leaked during alarm");
        wave_on = 1;
        repeat (3) @(posedge frame_end);
        grab("alarm_sw3");                                  // 报警中 SW3 = 1 / SW2 = 1, 不应出现菜单和频谱
        wave_on = 0;
        sw3 = 0; wait_ms(30);

        // 计时 BCD 进位: 09:59 -> 10:00, 99:59 封顶
        @(c_bcd);
        u_ctrl.alm_bcd = 16'h0959; #1;
        @(c_bcd); #1;
        if (c_bcd !== 16'h1000) begin $display("  bcd %04h", c_bcd); fail("bcd carry 09:59"); end
        @(c_bcd);
        u_ctrl.alm_bcd = 16'h9959;
        wait_ms(2500);
        if (c_bcd !== 16'h9959) begin $display("  bcd %04h", c_bcd); fail("bcd cap 99:59"); end
        u_ctrl.alm_bcd = 16'h0107;
        @(posedge frame_end);
        grab("alarm_timer");                                // 计时 01:07 或 01:08

        // 解除: SW1 拨回 0 -> 下一帧恢复原图, 按键恢复
        sw1 = 0; wait_ms(30);
        if (c_alarm) fail("alarm not cleared by SW1");
        if (c_amode !== 2'd1) fail("amode not restored");
        press(2, 50);
        if (c_auto_on === auto0) fail("KEY2 not restored after alarm");
        @(posedge frame_end);
        grab("cleared");

        // 开机画面上报警 (TF 卡未就绪也能报警)
        splash_on = 1;
        sw1 = 1; wait_ms(30);
        press(3, 50);
        if (!c_alarm) fail("alarm on splash");
        if (c_bcd !== 16'h0000) fail("timer not restarted");
        @(posedge frame_end);
        grab("alarm_on_splash");
        if (c_src !== 2'd0) fail("src != KEY1");
        sw1 = 0; wait_ms(30);
        splash_on = 0;

        // 火焰: 100 ms 短脉冲不触发; 闪烁 30 ms 有效 / 10 ms 无效 (净 +20 / 40 ms) 约 400 ms 累计到 200 触发
        sw1 = 1; wait_ms(30);
        fire_in = 0; wait_ms(100); fire_in = 1;
        wait_ms(300);
        if (c_alarm) fail("fire glitch triggered");
        t_fire = 0;
        while (!c_alarm && t_fire < 2000) begin
            fire_in = 0; wait_ms(30); fire_in = 1; wait_ms(10);
            t_fire = t_fire + 40;
        end
        $display("  fire flicker -> alarm after %0d ms", t_fire);
        if (!c_alarm || t_fire < 320 || t_fire > 560) fail("fire flicker not accumulated");
        if (c_src !== 2'd2) fail("src != fire");
        @(posedge frame_end);
        grab("alarm_fire");                                  // 说明行: 检测到明火
        sw1 = 0; wait_ms(30);
        if (c_alarm) fail("fire alarm not cleared");
        wait_ms(300);                                        // 积分回落到 0

        // 烟雾: 500 ms 不触发 (回落后) ; 持续有效 1 s 触发
        sw1 = 1; wait_ms(30);
        smoke_n = 0; wait_ms(500); smoke_n = 1;
        wait_ms(600);
        if (c_alarm) fail("short smoke triggered");
        smoke_n = 0; wait_ms(900);
        if (c_alarm) fail("smoke triggered too early");
        wait_ms(200);
        if (!c_alarm) fail("smoke did not trigger");
        if (c_src !== 2'd1) fail("src != smoke");
        @(posedge frame_end);
        grab("alarm_smoke");                                 // 说明行: 检测到烟雾
        // 烟雾仍有效: 撤防解除, 再布防立即重新报警
        sw1 = 0; wait_ms(30);
        if (c_alarm) fail("smoke alarm not cleared");
        sw1 = 1; wait_ms(30);
        if (!c_alarm || c_src !== 2'd1) fail("smoke still present but no re-alarm");
        sw1 = 0; smoke_n = 1; wait_ms(30);
        $fclose(list);
    end
endtask

//---------------------------------------------------------------------------
// audio_i2s_player: 警笛 / 蜂鸣器 / WAV 暂停与续播
//---------------------------------------------------------------------------
reg  [1:0]  a_mode = 0;
reg         arst = 1;
reg  [15:0] wcnt = 0;
wire        f_rd, buzz;
audio_i2s_player #(.AW(4)) u_aud(
    .I_mclk(mclk), .I_rst(arst), .amode(a_mode), .wav_ok(1'b1), .wav_rate(17'd48000),
    .vol_lvl(5'd0),                                     // 静音: 警笛不受影响, WAV 听不到
    .fifo_rd(f_rd), .fifo_data({wcnt, wcnt}), .fifo_empty(1'b0), .fifo_level(5'd15),
    .vu(), .xrun(), .buzz(buzz), .O_i2s_BCLK(), .O_i2s_LRCK(), .O_i2s_DOUT()
);
always @(posedge mclk) if (f_rd) wcnt <= wcnt + 16'd1;   // fifo_rd 后一拍数据有效: 读到的是读之前的值

// 每个 48k 帧: 过零 / 蜂鸣器上升沿计数, 幅度统计, 增益旁路核对
integer nfrm = 0, zc = 0, bz = 0, pmax = -99999, pmin = 99999, gbad = 0;
reg signed [15:0] prev = 0;
reg     prev_bz = 0;
always @(posedge mclk) if (u_aud.frame_tick) begin
    nfrm = nfrm + 1;
    if (prev < 0 && u_aud.siren >= 0) zc = zc + 1;
    prev = u_aud.siren;
    if (buzz && !prev_bz) bz = bz + 1;
    prev_bz = buzz;
    if (a_mode == 2'd3) begin
        if (u_aud.siren > pmax) pmax = u_aud.siren;
        if (u_aud.siren < pmin) pmin = u_aud.siren;
        if (u_aud.gain !== 9'd256) gbad = gbad + 1;
    end
end

task win(input integer frames, output real fz, output real fb);
    integer z0, b0, n0;
    begin
        z0 = zc; b0 = bz; n0 = nfrm;
        while (nfrm < n0 + frames) @(posedge mclk);
        fz = (zc - z0) * 48000.0 / frames;
        fb = (bz - b0) * 48000.0 / frames;
    end
endtask

task test_audio;
    real    fz, fb;
    integer r0, t0;
    reg [15:0] last;
    begin
        $display("---- audio: siren / buzzer / WAV pause ----");
        #1000 arst = 0;
        // WAV 播放 (音量 0 听不到, 但照常读 FIFO)
        a_mode = 2'd0;
        t0 = nfrm; while (nfrm < t0 + 2000) @(posedge mclk);
        if (wcnt < 1500) fail("wav not playing");
        // 报警
        a_mode = 2'd3;
        t0 = nfrm; while (nfrm < t0 + 4) @(posedge mclk);      // 同步
        r0 = wcnt; last = u_aud.s1l;
        win(4800, fz, fb);  $display("  0.0-0.1 s: siren %.0f Hz, buzzer %.0f Hz (expect ~645)", fz, fb);
        if (fz < 600.0 || fz > 700.0 || fb < 600.0 || fb > 700.0) fail("siren start freq");
        t0 = nfrm; while (nfrm < t0 + 40800) @(posedge mclk);
        win(4800, fz, fb);  $display("  0.95-1.05 s: siren %.0f Hz, buzzer %.0f Hz (expect ~1455)", fz, fb);
        if (fz < 1380.0 || fz > 1510.0 || fb < 1380.0 || fb > 1510.0) fail("siren top freq");
        t0 = nfrm; while (nfrm < t0 + 43200) @(posedge mclk);
        win(4800, fz, fb);  $display("  1.95-2.05 s: siren %.0f Hz, buzzer %.0f Hz (expect ~645)", fz, fb);
        if (fz < 590.0 || fz > 720.0) fail("siren sweep back");
        $display("  siren peak %0d / %0d, gain bypass errors %0d, wav reads during alarm %0d",
                 pmax, pmin, gbad, wcnt - r0);
        if (pmax != 16383 || pmin != -16383) fail("siren amplitude");
        if (gbad) fail("gain not bypassed in alarm");
        if (wcnt != r0) fail("wav read during alarm");
        // 解除: 警笛 / 蜂鸣器停, WAV 从断点继续 (解除后第一次取样: 前一样本 = 报警前最后一个, 新样本 = 其下一个)
        a_mode = 2'd0;
        wait (u_aud.rs == 3'd3);                            // R_POPD
        @(posedge mclk); #1;
        if (u_aud.s0l !== last || u_aud.s1l !== last + 16'd1) begin
            $display("  resume: s0l=%0d s1l=%0d, last before alarm=%0d", u_aud.s0l, u_aud.s1l, last);
            fail("wav not resumed from break point");
        end else
            $display("  wav resumed: %0d -> %0d (no skip)", u_aud.s0l, u_aud.s1l);
        t0 = nfrm; while (nfrm < t0 + 20) @(posedge mclk);
        if (buzz || u_aud.siren != 0) fail("siren / buzzer not stopped");
    end
endtask

initial begin
    #200 rst = 0;
    // +audio_only: 只跑第 3 部分 (画面部分约 20 分钟)
    if (!$test$plusargs("audio_only")) test_ctrl_video;
    vclk_on = 1'b0;
    // +video_only: 跳过第 3 部分 (音频约 2 分钟, 但要仿真 2 s 的 mclk)
    if (!$test$plusargs("video_only")) test_audio;
    if (errors == 0) $display("==== tb_alarm PASS ====");
    else             $display("==== tb_alarm FAIL (%0d errors) ====", errors);
    $finish;
end

endmodule
