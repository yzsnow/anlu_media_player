`timescale 1ns/1ps
//============================================================================
// 第二屏终端命令 -> player_ctrl 仿真
//   加载器应答模型: 收到 req_toggle 后 2000 拍应答 (ack_img = req_img, ok), 帧结束每 400 拍一次 (转场 64 帧)
//   核对: show n 跳到第 n 张 (SHOW / 等待中改目标 / 转场中挂起), next / prev 回绕, show 越界忽略,
//         mode / bright / vol / eff / auto 生效, alarm 需布防且触发后锁存, 报警中全部命令忽略,
//         参数菜单打开时换图命令照常 (KEY1 此时归菜单), 原有按键功能不受影响
//         播放列表秒数: 应答附带 ack_dur (第 2 张 2 s, 第 3 张 0 = 默认 240 帧, 其余 1 s), 自动轮播按各自时长
//============================================================================
module tb_termcmd;

reg clk = 0;
always #20 clk = ~clk;
reg rst = 1;
integer errors = 0;

reg  key1_n = 1, key2_n = 1, sw3 = 0, sw1 = 0, key3_n = 1;
reg  fe = 0;
reg  t_tgl = 0; reg [3:0] t_op = 0; reg [4:0] t_arg = 0;
wire [3:0] cur_img, eff_sel, req_img;
wire       auto_on, menu_on, alarm_on, req_toggle;
wire [1:0] pmode;
wire [4:0] bri, con, tmp, gam, vol;
reg        ack_t = 0;
reg  [3:0] ack_i = 0;
reg  [7:0] ack_d = 0;
player_ctrl #(.CLK_HZ(100_000)) u_ctrl(
    .clk(clk), .rst(rst), .key1_n(key1_n), .key2_n(key2_n), .sw4(1'b0), .sw3(sw3), .sw2(1'b0),
    .frame_end(fe), .ld_status(3'd2), .img_count(5'd6),
    .req_toggle(req_toggle), .req_img(req_img), .cur_slot(),
    .ack_toggle(ack_t), .ack_slot(3'd1), .ack_ok(1'b1), .ack_img(ack_i), .ack_dur(ack_d),
    .base_a(), .base_b(), .b_en(), .p(), .eff_now(), .eff_sel(eff_sel),
    .auto_on(auto_on), .amode(), .splash_on(), .bar_on(), .waiting(), .msg_bad(),
    .cur_img(cur_img),
    .menu_on(menu_on), .menu_sel(), .pmode(pmode), .bri_lvl(bri), .con_lvl(con),
    .temp_lvl(tmp), .gam_lvl(gam), .vol_lvl(vol), .wave_on(),
    .sw1(sw1), .key3_n(key3_n), .smoke_n(1'b1), .fire_in(1'b1), .term_tgl(t_tgl), .term_op(t_op), .term_arg(t_arg),
    .alarm_on(alarm_on), .alm_bcd(), .alm_src(), .preheat()
);

// 帧结束
integer fcnt = 0;
always @(posedge clk) begin
    fcnt <= (fcnt == 399) ? 0 : fcnt + 1;
    fe   <= (fcnt == 399);
end
// 加载器应答
reg req_q = 0;
integer ack_dly = -1;
always @(posedge clk) begin
    req_q <= req_toggle;
    if (req_toggle != req_q) ack_dly <= 2000;
    else if (ack_dly > 0) ack_dly <= ack_dly - 1;
    else if (ack_dly == 0) begin
        ack_i <= req_img; ack_t <= ~ack_t; ack_dly <= -1;
        ack_d <= (req_img == 4'd2) ? 8'd2 : (req_img == 4'd3) ? 8'd0 : 8'd1;
    end
end
// 每张图在 P_SHOW 停留的帧数
integer show_fr = 0;
always @(posedge clk) if (fe) show_fr <= (u_ctrl.ps == 3'd4) ? show_fr + 1 : 0;

// 等到显示 img 并离开 P_SHOW, 核对停留帧数 (自动轮播: 计满 lim 帧后的下一帧发请求)
task check_dur(input [3:0] img, input integer lim);
    integer n;
    begin
        while (!(cur_img == img && u_ctrl.ps == 3'd4)) @(posedge clk);
        n = 0;
        while (u_ctrl.ps == 3'd4) begin @(posedge clk); if (fe) n = n + 1; end
        if (n < lim || n > lim + 1) begin
            $display("ERROR img %0d 显示 %0d 帧, 期望 %0d", img, n, lim); errors = errors + 1;
        end else $display("ok  img %0d 自动轮播 %0d 帧 (期望 %0d)", img, n, lim);
    end
endtask
task wait_clk(input integer n);
    repeat (n) @(posedge clk);
endtask
task cmd(input [3:0] op, input [4:0] arg);
    begin
        @(posedge clk); t_op <= op; t_arg <= arg;
        @(posedge clk); t_tgl <= ~t_tgl;
        wait_clk(20);
    end
endtask
task press(input integer k, input integer ms);
    begin
        if (k == 1) key1_n = 0; else key2_n = 0;
        wait_clk(ms * 100);
        if (k == 1) key1_n = 1; else key2_n = 1;
        wait_clk(4000);
    end
endtask
// 等到显示状态 (转场结束)
task settle;
    begin
        wait_clk(10);
        while (u_ctrl.ps != 3'd4) @(posedge clk);
    end
endtask
task expect_img(input [3:0] n, input [8*24-1:0] what);
    begin
        settle;
        if (cur_img !== n) begin $display("ERROR %0s: cur_img = %0d, 应为 %0d", what, cur_img, n); errors = errors + 1; end
        else $display("ok  %0s: cur_img = %0d", what, cur_img);
    end
endtask

initial begin
    #200 rst = 0;
    // 开机首图 0; 关闭自动轮播以免干扰
    settle;
    cmd(4'd8, 5'd0);
    if (auto_on !== 1'b0) begin $display("ERROR auto 0"); errors = errors + 1; end
    expect_img(0, "boot");
    cmd(4'd1, 5'd4);   expect_img(4, "show 5");
    cmd(4'd2, 5'd0);   expect_img(5, "next");
    cmd(4'd2, 5'd0);   expect_img(0, "next wrap");
    cmd(4'd3, 5'd0);   expect_img(5, "prev wrap");
    cmd(4'd1, 5'd6);   wait_clk(3000);
    if (u_ctrl.ps !== 3'd4 || cur_img !== 4'd5) begin $display("ERROR show 越界未被忽略"); errors = errors + 1; end
    else $display("ok  show 7 (越界) 忽略");
    // 等待中改目标: show 2 后立即 show 3
    cmd(4'd1, 5'd1);   cmd(4'd1, 5'd2);   expect_img(2, "show while waiting");
    // 转场中挂起: next 后等进入转场再 show 1
    cmd(4'd2, 5'd0);
    while (u_ctrl.ps != 3'd3) @(posedge clk);
    cmd(4'd1, 5'd0);   expect_img(3, "next before trans");
    settle; wait_clk(100);
    while (u_ctrl.ps != 3'd4) @(posedge clk);
    expect_img(0, "show 1 pending in trans");
    // 参数
    cmd(4'd4, 5'd2);
    if (pmode !== 2'd2 || bri !== 5 || con !== 7 || tmp !== 4 || gam !== 10) begin
        $display("ERROR mode 2: %0d %0d %0d %0d %0d", pmode, bri, con, tmp, gam); errors = errors + 1; end
    else $display("ok  mode 2 (夜间)");
    cmd(4'd5, 5'd13);  cmd(4'd6, 5'd3);  cmd(4'd7, 5'd5);  cmd(4'd8, 5'd1);
    if (bri !== 13 || vol !== 3 || eff_sel !== 5 || auto_on !== 1'b1) begin
        $display("ERROR bright/vol/eff/auto: %0d %0d %0d %0d", bri, vol, eff_sel, auto_on); errors = errors + 1; end
    else $display("ok  bright 13 / vol 3 / eff 5 / auto 1");
    cmd(4'd7, 5'd8);
    if (eff_sel !== 8) begin $display("ERROR eff 8"); errors = errors + 1; end
    cmd(4'd8, 5'd0);
    // 菜单打开时: 换图命令有效, KEY1 归菜单
    sw3 = 1; wait_clk(3000);
    if (menu_on !== 1'b1) begin $display("ERROR menu"); errors = errors + 1; end
    cmd(4'd2, 5'd0);   expect_img(1, "next with menu open");
    press(1, 50);      wait_clk(3000);
    if (cur_img !== 4'd1 || u_ctrl.menu_sel !== 3'd1) begin $display("ERROR KEY1 in menu"); errors = errors + 1; end
    sw3 = 0; wait_clk(3000);
    // 原按键: KEY1 下一张
    press(1, 50);      expect_img(2, "KEY1 next");
    // 报警: 未布防不触发
    cmd(4'd9, 5'd0);   wait_clk(500);
    if (alarm_on !== 1'b0) begin $display("ERROR alarm 未布防也触发"); errors = errors + 1; end
    sw1 = 1; wait_clk(3000);
    cmd(4'd9, 5'd0);   wait_clk(500);
    if (alarm_on !== 1'b1) begin $display("ERROR alarm 未触发"); errors = errors + 1; end
    else $display("ok  alarm 触发");
    // 报警中: 命令全部忽略
    cmd(4'd2, 5'd0); cmd(4'd5, 5'd2); cmd(4'd4, 5'd0); cmd(4'd8, 5'd1);
    wait_clk(6000);
    if (cur_img !== 4'd2 || bri !== 13 || pmode !== 2'd2 || auto_on !== 1'b0 || u_ctrl.ps !== 3'd4) begin
        $display("ERROR 报警中命令未被忽略: img %0d bri %0d pmode %0d auto %0d", cur_img, bri, pmode, auto_on); errors = errors + 1; end
    else $display("ok  报警中命令忽略");
    sw1 = 0; wait_clk(3000);
    if (alarm_on !== 1'b0) begin $display("ERROR SW1 解除"); errors = errors + 1; end
    cmd(4'd3, 5'd0);   expect_img(1, "prev after alarm");
    // 播放列表秒数: 打开自动轮播, 记录每张图显示的帧数
    cmd(4'd8, 5'd1);
    check_dur(4'd2, 120);
    check_dur(4'd3, 240);
    check_dur(4'd4, 60);
    cmd(4'd8, 5'd0);
    if (errors == 0) $display("tb_termcmd PASS"); else $display("tb_termcmd FAIL (%0d errors)", errors);
    $finish;
end
initial begin #400_000_000; $display("tb_termcmd FAIL (timeout)"); $finish; end
endmodule
