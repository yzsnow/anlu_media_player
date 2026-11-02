`timescale 1ns/1ps
//---------------------------------------------------------------------------
// 第二屏运维终端 term_top 仿真
//   1) 状态源 (src_clk 18.75 MHz) 依次产生 19 个日志事件 (超过 15 行, 日志环回绕);
//      4x4 开关矩阵模型 -> kb_matrix4x4 (扫描 / 消抖) -> 命令行: A/B 选命令、数字、退格、# 执行 (成功 / 参数错误 /
//      未选命令 / 未布防 / 报警中), C/D 快捷, 两键同时按下; 逐条核对 cmd_tgl 输出的命令号与参数
//   2) 记录每条日志 (事件号 / 值 / 数值 / 时间) 与按键, 稳定后导出显存, 再抓一帧 1024x600
//      check_term.py 用 gen_term_rom.py 参考模型重放, 显存与整帧逐像素核对
//   3) 本文件内检查: 行/场时序 (1344 x 620, 同步宽度 / 位置, DE 1024 x 600),
//      TMDS 逐符号解码 = 编码前像素, 消隐期控制码 = {VS, HS}, 直流偏差有界
//---------------------------------------------------------------------------
module tb_term;
reg clk = 0, sclk = 0;
always #10    clk  = ~clk;                // 50 MHz
always #26.667 sclk = ~sclk;              // 18.75 MHz
reg rst = 1, srst = 1;

reg [2:0] st = 0;   reg [4:0] cnt = 0;  reg wav = 0, txt = 1, fnt = 0; reg [7:0] prog = 0;
reg [3:0] cur = 0, eff = 8;  reg aut = 1; reg [1:0] amode = 0; reg menu = 0; reg [1:0] pmode = 0;
reg [4:0] bri = 8, con = 8, temp = 8, gam = 8, vol = 16;
reg wave = 0, alarm = 0; reg [1:0] asrc = 0; reg pre = 0; reg [3:0] vu = 0; reg bad = 0; reg [2:0] fsm = 1, rate = 0; reg [3:0] sw = 0;
// 4x4 开关矩阵: 键 k = 4 * 行 + 列, 按下时行线被当前扫描列 (输出 0) 拉低, 行内部上拉
reg  [15:0] pressed = 16'd0;
wire [3:0]  kb_col;
wire [3:0]  kb_row;
genvar gr;
generate for (gr = 0; gr < 4; gr = gr + 1) begin : g_row
    assign kb_row[gr] = ~((pressed[gr*4+0] && kb_col[0] === 1'b0) || (pressed[gr*4+1] && kb_col[1] === 1'b0) ||
                          (pressed[gr*4+2] && kb_col[2] === 1'b0) || (pressed[gr*4+3] && kb_col[3] === 1'b0));
end endgenerate
wire       kb_vld;
wire [7:0] kb_ascii;
kb_matrix4x4 #(.COL_DIV(50), .DEB_N(4)) u_kb(.clk(clk), .rst(rst), .row(kb_row), .col(kb_col),
                                            .kb_vld(kb_vld), .kb_ascii(kb_ascii));
localparam K1 = 0, K2 = 1, K3 = 2, KA = 3, K4 = 4, K5 = 5, K6 = 6, KB = 7,
           K7 = 8, K8 = 9, K9 = 10, KC = 11, KS = 12, K0 = 13, KH = 14, KD = 15;

wire de, hs, vs; wire [23:0] rgb; wire [9:0] t0, t1, t2;
term_top #(.SEC_DIV(40_000), .SNAP_DIV(2_000), .BLINK(0)) u(
    .clk(clk), .rst(rst), .src_clk(sclk), .src_rst(srst),
    .st(st), .img_cnt(cnt), .wav_ok(wav), .txt_ok(txt), .fnt_ok(fnt), .load_prog(prog), .cur_img(cur),
    .eff_sel(eff), .auto_on(aut), .amode(amode), .menu_on(menu), .pmode(pmode),
    .bri(bri), .con(con), .temp(temp), .gam(gam), .vol(vol), .wave_on(wave), .alarm_on(alarm), .alm_src(asrc), .preheat(pre), .vu(vu),
    .msg_bad(bad), .fsm(fsm), .rate(rate), .sw(sw), .kb_vld(kb_vld), .kb_ascii(kb_ascii),
    .o_de(de), .o_hs(hs), .o_vs(vs), .o_rgb(rgb), .tmds0(t0), .tmds1(t1), .tmds2(t2),
    .cmd_tgl(cmd_tgl), .cmd_op(cmd_op), .cmd_arg(cmd_arg));
wire cmd_tgl; wire [3:0] cmd_op; wire [4:0] cmd_arg;

integer errs = 0, logf;

// ---- 日志 / 按键记录 ----
always @(posedge clk) begin
    if (u.ev_take)
        $fwrite(logf, "LOG %0d %0d %0d %0d %06x\n", u.ev_k, u.ev_val, u.ev_arg, u.ev_has, u.ev_t);
    if (u.es == 4'd9)
        $fwrite(logf, "KEY %0d\n", u.kb_char);
end

// ---- 命令输出核对 ----
localparam NCMD = 7;
reg [3:0] exp_op  [0:NCMD-1];
reg [4:0] exp_arg [0:NCMD-1];
initial begin
    exp_op[0] = 1; exp_arg[0] = 11;     // show 12
    exp_op[1] = 2; exp_arg[1] = 0;      // next
    exp_op[2] = 5; exp_arg[2] = 15;     // bright 15
    exp_op[3] = 2; exp_arg[3] = 0;      // D 下一张
    exp_op[4] = 3; exp_arg[4] = 0;      // C 上一张
    exp_op[5] = 9; exp_arg[5] = 0;      // alarm
    exp_op[6] = 1; exp_arg[6] = 3;      // show 4
end
integer ncmd = 0;
reg     tq = 0;
always @(posedge clk) begin
    tq <= cmd_tgl;
    if (!rst && cmd_tgl !== tq) begin
        if (ncmd >= NCMD || cmd_op !== exp_op[ncmd] || cmd_arg !== exp_arg[ncmd]) begin
            $display("命令 %0d 错误: op %0d arg %0d", ncmd, cmd_op, cmd_arg);
            errs = errs + 1;
        end else
            $display("命令 %0d: op %0d arg %0d", ncmd, cmd_op, cmd_arg);
        ncmd = ncmd + 1;
    end
end

// ---- TMDS 解码与时序检查 ----
function [7:0] tdec;
    input [9:0] q;
    reg [7:0] x;
    integer i;
    begin
        x = q[9] ? ~q[7:0] : q[7:0];
        tdec[0] = x[0];
        for (i = 1; i < 8; i = i + 1) tdec[i] = q[8] ? (x[i] ^ x[i-1]) : ~(x[i] ^ x[i-1]);
    end
endfunction
function [9:0] tctl;
    input [1:0] c;
    begin
        case (c)
            2'b00: tctl = 10'b1101010100;
            2'b01: tctl = 10'b0010101011;
            2'b10: tctl = 10'b0101010100;
            default: tctl = 10'b1010101011;
        endcase
    end
endfunction
function integer bal;      // 1 的个数 - 0 的个数
    input [9:0] q;
    integer i;
    begin
        bal = 0;
        for (i = 0; i < 10; i = i + 1) bal = bal + (q[i] ? 1 : -1);
    end
endfunction

reg [23:0] rgb_d1, rgb_d2;
reg de_d1, de_d2, hs_d1, hs_d2, vs_d1, vs_d2;
integer disp0 = 0, disp1 = 0, disp2 = 0, maxd = 0, tm_n = 0;
reg     tm_on = 0;                        // 只在抓帧期间核对 TMDS (逐拍调用函数很慢)
always @(posedge clk) begin
    rgb_d1 <= rgb; rgb_d2 <= rgb_d1;
    de_d1 <= de; de_d2 <= de_d1; hs_d1 <= hs; hs_d2 <= hs_d1; vs_d1 <= vs; vs_d2 <= vs_d1;
    if (tm_on) begin
        if (de_d2) begin
            tm_n = tm_n + 1;
            if ({tdec(t2), tdec(t1), tdec(t0)} !== rgb_d2) begin
                if (errs < 10) $display("TMDS 解码错误 %h != %h", {tdec(t2), tdec(t1), tdec(t0)}, rgb_d2);
                errs = errs + 1;
            end
            disp0 = disp0 + bal(t0); disp1 = disp1 + bal(t1); disp2 = disp2 + bal(t2);
            if (disp0 > maxd) maxd = disp0; if (-disp0 > maxd) maxd = -disp0;
            if (disp1 > maxd) maxd = disp1; if (-disp1 > maxd) maxd = -disp1;
            if (disp2 > maxd) maxd = disp2; if (-disp2 > maxd) maxd = -disp2;
        end else begin
            disp0 = 0; disp1 = 0; disp2 = 0;
            if (t0 !== tctl({vs_d2, hs_d2}) || t1 !== tctl(2'b00) || t2 !== tctl(2'b00)) begin
                if (errs < 10) $display("TMDS 控制码错误 t0=%b hs=%b vs=%b", t0, hs_d2, vs_d2);
                errs = errs + 1;
            end
        end
    end
end

// 时序: 从场同步下降沿起数到下一个场同步下降沿 (一帧), 统计 DE 行数 / 像素数、HS 低电平拍数、
//       VS 低电平行数、DE 结束到 HS 下降沿的距离 (行前沿 40 拍)
task check_frame_timing;
    integer n, lines, de_n, hsl, vsl, hsoff, hsbad;
    reg     pv, ph, pd;
    begin
        @(negedge vs); #1;
        n = 1; lines = 0; de_n = 0; hsl = !hs; vsl = 1; hsoff = -1; hsbad = 0;   // 含场同步下降沿这一拍
        pv = vs; ph = hs; pd = de;
        begin : frame_loop
        forever begin
            @(posedge clk); #1;
            if (!vs && pv) disable frame_loop;         // 下一帧开始
            n = n + 1;
            if (de) de_n = de_n + 1;
            if (!vs) vsl = vsl + 1;
            if (!hs) hsl = hsl + 1;
            if (!de && pd) begin lines = lines + 1; hsoff = 0; end
            else if (hsoff >= 0) hsoff = hsoff + 1;
            if (!hs && ph && hsoff >= 0) begin
                if (hsoff != 40) hsbad = hsbad + 1;
                hsoff = -1;
            end
            pd = de; ph = hs; pv = vs;
            if (n > 900000) begin $display("帧超时"); errs = errs + 1; disable check_frame_timing; end
        end
        end
        $display("一帧 %0d 拍 (应 833280), DE 行 %0d (600), DE 像素 %0d (614400), HS 低 %0d 拍 (620 x 128 = 79360), VS 低 %0d 拍 (6 x 1344 = 8064), HS 位置错 %0d 行",
                 n, lines, de_n, hsl, vsl, hsbad);
        if (n != 833280 || lines != 600 || de_n != 614400 || hsl != 79360 || vsl != 8064 || hsbad != 0) errs = errs + 1;
    end
endtask

// 按住 2000 拍 (扫描一圈 200 拍, 消抖 4 圈), 松开后再等 2000 拍
task kp(input integer k);
    begin
        pressed[k] = 1'b1; repeat (2000) @(posedge clk);
        pressed[k] = 1'b0; repeat (2000) @(posedge clk);
    end
endtask
task kp2(input integer a, input integer b);
    begin
        pressed[a] = 1'b1; pressed[b] = 1'b1; repeat (3000) @(posedge clk);
        pressed[a] = 1'b0; pressed[b] = 1'b0; repeat (2000) @(posedge clk);
    end
endtask

task gap;
    repeat (8000) @(posedge sclk);
endtask

integer i, fo;
initial begin
    logf = $fopen("frames/term_log.txt", "w");
    #200 rst = 0; srst = 0;
`ifdef QUICK
    check_frame_timing;
    if (errs == 0) $display("tb_term PASS"); else $display("tb_term FAIL (%0d errors)", errs);
    $finish;
`endif
    repeat (20000) @(posedge clk);
    $display("[%0t] 开始事件序列", $time); $fflush;
    // 事件序列 (一次只变一项)
    st = 1; gap;
    cnt = 12; st = 2; prog = 200; gap;
    wav = 1; rate = 7; gap;
    cur = 1; gap;
    menu = 1; fsm = 3; gap;
    pmode = 2; bri = 5; con = 7; temp = 4; gam = 10; gap;
    menu = 0; fsm = 0; gap;
    sw = 4'b0001; gap;
    asrc = 2; alarm = 1; gap;                            // 火焰触发
    amode = 3; gap;
    alarm = 0; gap;
    amode = 0; gap;
    eff = 3; gap;
    aut = 0; gap;
    wave = 1; sw = 4'b0011; gap;
    bad = 1; gap;
    bad = 0; st = 3; fsm = 4; gap;
    st = 2; fsm = 1; cur = 2; prog = 255; vu = 11; vol = 13; gap;
    $display("[%0t] 事件完成, 开始按键", $time); $fflush;
    // 键盘 (此时: 卡就绪 12 张, SW1 布防, 未报警)
    kp(KH);                                              // 未选命令 -> WARN
    kp(KA); kp(K1); kp(K2); kp(KH);                      // show 12
    kp(KA); kp(KA); kp(KH);                              // next
    kp(KB); kp(KS);                                      // 选 alarm 后退格清除
    kp(KA); kp(KA); kp(KA); kp(KA); kp(K7); kp(KH);      // mode 7 -> 参数错误
    kp(KA); kp(KA); kp(KA); kp(KA); kp(KA);              // bright
    kp(K1); kp(K6); kp(K9); kp(KS); kp(K5); kp(KH);      // 1 6 (9 超出 2 位忽略) 退格 5 -> bright 15
    kp(KA); kp(KA); kp(KA); kp(KA); kp(KH);              // mode 无参数 -> 参数错误
    kp(KD); kp(KC);                                      // 快捷 下一张 / 上一张
    kp(KB); kp(KH);                                      // alarm
    asrc = 1; alarm = 1; gap; kp(KD); alarm = 0; gap;    // 烟雾触发; 报警中 -> WARN
    sw = 4'b0010; gap; kp(KB); kp(KH); sw = 4'b0011; gap; // 未布防 -> WARN
    kp2(K3, KA); kp(K4); kp(KH);                         // 3 与 A 同时按: 3 (未选命令, 忽略) 后 A -> show 4
    kp(KA); kp(KA); kp(KA); kp(KA); kp(KA); kp(KA); kp(K8); // 留在命令行: vol 8
    pre = 1;                                             // 状态: MQ-2 未就绪
    repeat (20000) @(posedge clk);
    if (ncmd != NCMD) begin $display("命令数 %0d, 应为 %0d", ncmd, NCMD); errs = errs + 1; end
    // 稳定后: 等到状态程序刚跑完 (引擎回到空闲的第一拍), 导出显存
    @(posedge clk);
    while (!(u.es == 4'd0 && !u.task_log)) @(posedge clk);
    while (u.es == 4'd0) @(posedge clk);
    while (u.es != 4'd0) @(posedge clk);
    #1;
    $fwrite(logf, "SNAP %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d\n",
            u.s_st, u.s_cnt, u.s_wav, u.s_txt, u.s_fnt, u.s_prog, u.s_cur, u.s_eff, u.s_auto, u.s_wave, u.s_menu,
            u.s_amode, u.s_pmode, u.s_bri, u.s_con, u.s_temp, u.s_gam, u.s_vol, u.s_vu, u.s_rate, u.s_sw,
            u.s_alarm, u.s_fsm, u.log_total, u.s_pre);
    $fwrite(logf, "TIME %06x\nHEAD %0d %0d %0d\n", u.ev_t, u.log_wr, u.log_cnt, u.cur);
`ifdef __ICARUS__
    $writememh("frames/term_vram_c.hex", u.u_vram_c.mem);
    $writememh("frames/term_vram_a.hex", u.u_vram_a.mem);
`endif
    $display("[%0t] 显存已导出, 检查时序", $time); $fflush;
    // 时序 + 一帧像素
    check_frame_timing;
    @(posedge clk);
    while (!(u.hc == 0 && u.vc == 0)) @(posedge clk);
    $fwrite(logf, "FC %0d\n", u.fc);
    tm_on = 1;
    fo = $fopen("frames/term_frame.hex", "w");
    i = 0;
    while (i < 614400) begin
        @(posedge clk); #1;
        if (de) begin $fwrite(fo, "%06x\n", rgb); i = i + 1; end
    end
    $fclose(fo);
    $fclose(logf);
    $display("TMDS 已核对 %0d 个像素符号, 最大直流偏差 %0d", tm_n, maxd);
    if (maxd > 20) begin $display("直流偏差过大"); errs = errs + 1; end
    if (errs == 0) $display("tb_term PASS"); else $display("tb_term FAIL (%0d errors)", errs);
    $finish;
end
endmodule
