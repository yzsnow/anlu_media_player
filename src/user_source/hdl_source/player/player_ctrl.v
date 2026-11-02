`timescale 1ns/1ps
//============================================================================
// player_ctrl (video_clk 域)
//
//  按键 (低有效, 消抖 16ms). 板上 KEY1 / KEY3 功能互换: key1_n 接板上 KEY3 (翻页), key3_n 接板上 KEY1 (传感器):
//    KEY3 短按 : 下一张            KEY3 长按(0.8s) : 上一张
//    KEY2 短按 : 自动轮播 开/关     KEY2 长按(0.8s) : 切换转场特效 (0~7 / 轮换)
//  拨码开关 SW4 (消抖 16ms): 0 = WAV 播放, 1 = 测试音 (内置旋律)
//  应急报警 (第十六讲 应急信息发布终端): SW1 = 1 布防, KEY1 (模拟传感器, 低有效) 按下即触发.
//    报警锁存, 松开 KEY1 不解除 (传感器恢复不代表险情排除), 只有 SW1 拨回 0 才解除.
//    报警期间抢占一切: KEY3 / KEY2 / SW3 菜单全部不响应, 自动轮播暂停, 音源切到警笛 (amode 3);
//    播放状态机与加载器照常运行, 解除后回到原来的图片, WAV 从断点继续.
//    alm_bcd 为报警持续时间 {分十, 分个, 秒十, 秒个}, 最大 99:59
//  外接传感器 (J1-27 MQ-2 烟雾 DO 低有效, 未接时上拉为无效 / J1-28 火焰 DO 低有效 (FIRE_HI = 0), 未接时上拉为无效),
//    与 KEY1 并列触发报警:
//    每 1 ms 采样一次做漏桶积分 (有效 +1, 无效 -1, 不低于 0), 累计到门限才触发:
//    火焰 FIRE_MS (默认 200 ms, 火苗闪烁使 DO 抖动也能累计), 烟雾 SMOKE_MS (默认 1 s, 浓度在门限附近来回跳也能累计);
//    MQ-2 加热丝上电后需预热, 前 PREHEAT_MS (默认 60 s) 内忽略烟雾输入 (preheat = 1)
//    alm_src 记录触发来源 (锁存到报警解除): 0 KEY1  1 烟雾  2 火焰  3 终端 alarm 命令; 同时满足时 火焰 > 烟雾 > KEY1 > 终端
//  拨码开关 SW3 (消抖 16ms): 1 = 进入显示参数调节菜单 (屏幕中央 OSD), 此时按键改为:
//    KEY3 短按 : 下一项            KEY3 长按 : 上一项
//    KEY2 短按 : 数值 +1           KEY2 长按 : 数值 -1, 继续按住每 150 ms 再 -1
//    菜单项: 0 模式  1 亮度  2 对比度  3 色温  4 伽马  5 音量  6 复位 (KEY2 短按/长按均恢复默认)
//    模式 (画面预设, KEY2 短按下一个 / 长按上一个), 选中即同时设置 亮度/对比度/色温/伽马, 之后可再微调:
//        0 正常 8/8/8/8   1 日间 11/10/9/7   2 夜间 5/7/4/10 (暗 + 暖 + 提亮暗部)   3 护眼 7/8/1/8 (低蓝光)
//    其余各项 0~16 级, 默认 亮度 8 (x1.0) / 对比度 8 (x1.0) / 色温 8 (原色, 小 = 暖, 大 = 冷) /
//        伽马 8 (1.0, 大 = 提亮暗部) / 音量 16 (0 dB)
//    菜单打开期间暂停自动轮播计时, 不响应换图; 关闭 SW3 后参数保持
//
//  第二屏终端命令 (term_top, 4x4 矩阵键盘): term_tgl 翻转一次 = 一条命令, term_op / term_arg 保持;
//    1 show (跳到第 arg 张, 0 起)  2 next  3 prev  4 mode (预设 0~3)  5 bright  6 vol  7 eff (0~8)  8 auto (0/1)
//    9 alarm (等同 KEY1, 需 SW1 布防). 报警期间全部忽略; 换图命令在参数菜单打开时也有效 (按键此时归菜单).
//
//  顶部信息栏: 按键 / 拨动 SW4 / 按键换图完成 / 插卡后首图 时弹出, 无操作 5 s 自动隐藏;
//    自动轮播换图不弹出 (加载提示与进度条也只在按键换图时显示), 坏图提示照常显示
//
//  播放流程:
//    SPLASH --(卡就绪)--> 请求图片 --> WAIT(等待加载器应答)
//      --> TRANS (B 通道=新图, p 每帧 +4, 64 帧完成转场) --> SHOW
//    SHOW 状态下按键 / 自动轮播 (4s) 触发下一次请求.
//    转场期间的按键会被记住, 转场结束后立即执行.
//    图片损坏时显示提示并自动尝试下一张.
//============================================================================
module player_ctrl #(
    parameter integer CLK_HZ     = 25_000_000,
    parameter [8:0]   P_STEP     = 9'd4,        // 转场速度 (256/4 = 64 帧)
    parameter [8:0]   AUTO_FRAMES= 9'd240,      // 自动轮播间隔 (帧)
    parameter [8:0]   BAR_FRAMES = 9'd300,      // 信息栏显示时间 (帧)
    parameter integer FIRE_MS    = 200,         // 火焰传感器累计门限 (ms)
    parameter integer SMOKE_MS   = 1000,        // 烟雾传感器累计门限 (ms)
    parameter integer PREHEAT_MS = 60000,       // MQ-2 上电预热时间 (ms)
    parameter         FIRE_HI    = 1'b0         // 火焰传感器 DO 极性: 0 = 低电平有效 (所用模块), 1 = 高电平有效 (pin.adc 同时改 PULLDOWN)
)(
    input             clk,
    input             rst,
    input             key1_n,           // 板上 KEY3: 翻页 / 菜单选项 (低有效)
    input             key2_n,
    input             sw4,              // 拨码开关, 异步, 此处同步消抖
    input             sw3,              // 拨码开关: 参数调节菜单
    input             sw2,              // 拨码开关: 音频波形显示
    input             sw1,              // 拨码开关: 应急报警布防
    input             key3_n,           // KEY1: 模拟传感器 (低有效)
    input             smoke_n,          // MQ-2 烟雾传感器 DO (低有效, 异步)
    input             fire_in,          // 火焰传感器 DO (极性见 FIRE_HI, 异步)
    input             term_tgl,         // 第二屏终端命令 (term_clk 域 toggle, op/arg 随之保持), 此处同步
    input      [3:0]  term_op,
    input      [4:0]  term_arg,
    input             frame_end,
    // 加载器状态 (已同步)
    input      [2:0]  ld_status,
    input      [4:0]  img_count,
    // 加载器请求/应答
    output reg        req_toggle,
    output reg [3:0]  req_img,
    output reg [2:0]  cur_slot,
    input             ack_toggle,       // sd 域, 在此同步
    input      [2:0]  ack_slot,
    input             ack_ok,
    input      [3:0]  ack_img,
    input      [7:0]  ack_dur,          // 该图显示秒数 (TF 卡播放列表), 0 = 默认 AUTO_FRAMES
    // 显示控制
    output reg [20:0] base_a,
    output reg [20:0] base_b,
    output reg        b_en,
    output reg [8:0]  p,
    output reg [2:0]  eff_now,
    output reg [3:0]  eff_sel,
    output reg        auto_on,
    output reg [1:0]  amode,
    output reg        splash_on,
    output            bar_on,
    output            waiting,
    output            msg_bad,
    output reg [3:0]  cur_img,
    // 显示参数调节
    output reg        menu_on,
    output reg [2:0]  menu_sel,         // 0~6
    output reg [1:0]  pmode,            // 画面模式 (最近一次选择的预设)
    output reg [4:0]  bri_lvl,          // 0~16, 8 = 原亮度
    output reg [4:0]  con_lvl,          // 0~16, 8 = 原对比度
    output reg [4:0]  temp_lvl,         // 0~16, 8 = 原色温
    output reg [4:0]  gam_lvl,          // 0~16, 8 = 伽马 1.0
    output reg [4:0]  vol_lvl,          // 0~16, 16 = 原音量
    output reg        wave_on,          // SW2 消抖后: 1 = 显示音频波形
    // 应急报警
    output reg        alarm_on,
    output reg [15:0] alm_bcd,
    output reg [1:0]  alm_src,          // 触发来源: 0 KEY1  1 烟雾  2 火焰  3 终端命令
    output reg        preheat           // 1 = MQ-2 预热中 (烟雾输入被忽略)
);

localparam [2:0] ST_READY = 3'd2;

//---------------------------------------------------------------------------
// 按键
//---------------------------------------------------------------------------
localparam integer MS_DIV = CLK_HZ / 1000;
reg [15:0] ms_cnt;
reg        ms_tick;
always @(posedge clk or posedge rst) begin
    if (rst) begin ms_cnt <= 16'd0; ms_tick <= 1'b0; end
    else if (ms_cnt == MS_DIV - 1) begin ms_cnt <= 16'd0; ms_tick <= 1'b1; end
    else begin ms_cnt <= ms_cnt + 16'd1; ms_tick <= 1'b0; end
end

reg [1:0] k1_s, k2_s, sw_s, m_s, w_s, a_s, k3_s;
reg [3:0] k1_i, k2_i, sw_i, m_i, w_i, a_i, k3_i;
reg       k1, k2;           // 消抖后, 1 = 按下
reg       sw;               // 消抖后的 SW4
reg       msw;              // 消抖后的 SW3
reg       arm;              // 消抖后的 SW1 (报警布防)
reg       k3;               // 消抖后的 KEY1, 1 = 传感器触发
always @(posedge clk or posedge rst) begin
    if (rst) begin
        k1_s <= 2'b00; k2_s <= 2'b00; k1_i <= 4'd0; k2_i <= 4'd0; k1 <= 1'b0; k2 <= 1'b0;
        sw_s <= 2'b00; sw_i <= 4'd0; sw <= 1'b0;
        m_s  <= 2'b00; m_i  <= 4'd0; msw <= 1'b0;
        w_s  <= 2'b00; w_i  <= 4'd0; wave_on <= 1'b0;
        a_s  <= 2'b00; a_i  <= 4'd0; arm <= 1'b0;
        k3_s <= 2'b00; k3_i <= 4'd0; k3 <= 1'b0;
    end else begin
        k1_s <= {k1_s[0], ~key1_n};
        k2_s <= {k2_s[0], ~key2_n};
        sw_s <= {sw_s[0], sw4};
        m_s  <= {m_s[0], sw3};
        w_s  <= {w_s[0], sw2};
        a_s  <= {a_s[0], sw1};
        k3_s <= {k3_s[0], ~key3_n};
        if (ms_tick) begin
            if (a_s[1] != arm) begin
                a_i <= a_i + 4'd1;
                if (a_i == 4'd15) begin arm <= a_s[1]; a_i <= 4'd0; end
            end else a_i <= 4'd0;
            if (k3_s[1] != k3) begin
                k3_i <= k3_i + 4'd1;
                if (k3_i == 4'd15) begin k3 <= k3_s[1]; k3_i <= 4'd0; end
            end else k3_i <= 4'd0;
            if (w_s[1] != wave_on) begin
                w_i <= w_i + 4'd1;
                if (w_i == 4'd15) begin wave_on <= w_s[1]; w_i <= 4'd0; end
            end else w_i <= 4'd0;
            if (sw_s[1] != sw) begin
                sw_i <= sw_i + 4'd1;
                if (sw_i == 4'd15) begin sw <= sw_s[1]; sw_i <= 4'd0; end
            end else sw_i <= 4'd0;
            if (m_s[1] != msw) begin
                m_i <= m_i + 4'd1;
                if (m_i == 4'd15) begin msw <= m_s[1]; m_i <= 4'd0; end
            end else m_i <= 4'd0;
            if (k1_s[1] != k1) begin
                k1_i <= k1_i + 4'd1;
                if (k1_i == 4'd15) begin k1 <= k1_s[1]; k1_i <= 4'd0; end
            end else k1_i <= 4'd0;
            if (k2_s[1] != k2) begin
                k2_i <= k2_i + 4'd1;
                if (k2_i == 4'd15) begin k2 <= k2_s[1]; k2_i <= 4'd0; end
            end else k2_i <= 4'd0;
        end
    end
end

//---------------------------------------------------------------------------
// 第二屏终端命令: toggle 三级同步, 边沿时取 op/arg (对方在翻转前已稳定并保持到下一条命令)
//---------------------------------------------------------------------------
reg  [2:0] t_s;
reg        t_ev;
reg  [3:0] t_op;
reg  [4:0] t_arg;
always @(posedge clk or posedge rst) begin
    if (rst) begin
        t_s <= 3'd0; t_ev <= 1'b0; t_op <= 4'd0; t_arg <= 5'd0;
    end else begin
        t_s  <= {t_s[1:0], term_tgl};
        t_ev <= (t_s[2] ^ t_s[1]) & ~alarm_on;          // 报警时忽略
        if (t_s[2] ^ t_s[1]) begin
            t_op  <= term_op;
            t_arg <= term_arg;
        end
    end
end
wire t_show  = t_ev && (t_op == 4'd1) && ({t_arg[4], t_arg[3:0]} < img_count);
wire t_next  = t_ev && (t_op == 4'd2);
wire t_prev  = t_ev && (t_op == 4'd3);
wire t_mode  = t_ev && (t_op == 4'd4);
wire t_bri   = t_ev && (t_op == 4'd5);
wire t_vol   = t_ev && (t_op == 4'd6);
wire t_eff   = t_ev && (t_op == 4'd7);
wire t_auto  = t_ev && (t_op == 4'd8);
wire t_alarm = t_ev && (t_op == 4'd9);

//---------------------------------------------------------------------------
// 外接传感器: 2FF 同步, 每 ms 漏桶积分, 到门限置位 (回到 0 才清除); MQ-2 预热期间计数保持 0
//---------------------------------------------------------------------------
reg [1:0]  sm_s, fi_s;
reg [10:0] sm_c, fi_c;
reg [15:0] pre_c;
reg        smoke, fire;     // 1 = 传感器判定有险情
always @(posedge clk or posedge rst) begin
    if (rst) begin
        sm_s <= 2'b00; fi_s <= 2'b00; sm_c <= 11'd0; fi_c <= 11'd0;
        smoke <= 1'b0; fire <= 1'b0; pre_c <= 16'd0; preheat <= 1'b1;
    end else begin
        sm_s <= {sm_s[0], ~smoke_n};
        fi_s <= {fi_s[0], fire_in ~^ FIRE_HI};    // 1 = 检测到火焰
        if (ms_tick) begin
            if (preheat) begin
                pre_c <= pre_c + 16'd1;
                if (pre_c == PREHEAT_MS - 1) preheat <= 1'b0;
            end
            if (sm_s[1] && !preheat) begin
                if (sm_c != SMOKE_MS) sm_c <= sm_c + 11'd1;
            end else if (sm_c != 11'd0) sm_c <= sm_c - 11'd1;
            if (fi_s[1]) begin
                if (fi_c != FIRE_MS) fi_c <= fi_c + 11'd1;
            end else if (fi_c != 11'd0) fi_c <= fi_c - 11'd1;
            if (sm_c == SMOKE_MS) smoke <= 1'b1; else if (sm_c == 11'd0) smoke <= 1'b0;
            if (fi_c == FIRE_MS)  fire  <= 1'b1; else if (fi_c == 11'd0) fire  <= 1'b0;
        end
    end
end

//---------------------------------------------------------------------------
// 应急报警: SW1 布防, 火焰 / 烟雾 / KEY1 触发 (电平), 锁存到 SW1 拨回 0; 终端 alarm 命令同 KEY1
//---------------------------------------------------------------------------
reg [9:0] alm_ms;
always @(posedge clk or posedge rst) begin
    if (rst) begin
        alarm_on <= 1'b0; alm_ms <= 10'd0; alm_bcd <= 16'd0; alm_src <= 2'd0;
    end else if (!arm) begin
        alarm_on <= 1'b0;
    end else if (!alarm_on) begin
        if (fire | smoke | k3 | t_alarm) begin
            alarm_on <= 1'b1;
            alm_ms   <= 10'd0;
            alm_bcd  <= 16'd0;
            alm_src  <= fire ? 2'd2 : smoke ? 2'd1 : k3 ? 2'd0 : 2'd3;
        end
    end else if (ms_tick) begin
        // 持续时间 mm:ss (BCD), 到 99:59 停住
        if (alm_ms == 10'd999) begin
            alm_ms <= 10'd0;
            if (alm_bcd != 16'h9959) begin
                if (alm_bcd[3:0] != 4'd9) alm_bcd[3:0] <= alm_bcd[3:0] + 4'd1;
                else begin
                    alm_bcd[3:0] <= 4'd0;
                    if (alm_bcd[7:4] != 4'd5) alm_bcd[7:4] <= alm_bcd[7:4] + 4'd1;
                    else begin
                        alm_bcd[7:4] <= 4'd0;
                        if (alm_bcd[11:8] != 4'd9) alm_bcd[11:8] <= alm_bcd[11:8] + 4'd1;
                        else begin
                            alm_bcd[11:8]  <= 4'd0;
                            alm_bcd[15:12] <= alm_bcd[15:12] + 4'd1;
                        end
                    end
                end
            end
        end else
            alm_ms <= alm_ms + 10'd1;
    end
end

reg        k1_d, k2_d, sw_d;
reg [9:0]  h1, h2;          // 按住时间 (ms)
reg        l1_done, l2_done;
reg [7:0]  r2;              // KEY2 长按后的连发计时 (ms)
reg        ev_next, ev_prev, ev_auto, ev_eff, ev_aud, ev_rep;
always @(posedge clk or posedge rst) begin
    if (rst) begin
        k1_d <= 1'b0; k2_d <= 1'b0; sw_d <= 1'b0; h1 <= 10'd0; h2 <= 10'd0;
        l1_done <= 1'b0; l2_done <= 1'b0; r2 <= 8'd0;
        {ev_next, ev_prev, ev_auto, ev_eff, ev_aud, ev_rep} <= 6'd0;
    end else begin
        k1_d <= k1; k2_d <= k2; sw_d <= sw;
        {ev_next, ev_prev, ev_auto, ev_eff, ev_aud, ev_rep} <= 6'd0;

        if (k1 && ms_tick && h1 != 10'd1023) h1 <= h1 + 10'd1;
        if (k2 && ms_tick && h2 != 10'd1023) h2 <= h2 + 10'd1;

        // 长按: 到达 0.8s 立即触发
        if (k1 && !l1_done && h1 >= 10'd800) begin l1_done <= 1'b1; ev_prev <= 1'b1; end
        if (k2 && !l2_done && h2 >= 10'd800) begin l2_done <= 1'b1; ev_eff  <= 1'b1; r2 <= 8'd0; end
        // 长按后继续按住: 每 150 ms 连发一次 (只在参数菜单中使用)
        if (k2 && l2_done && ms_tick) begin
            if (r2 == 8'd149) begin r2 <= 8'd0; ev_rep <= 1'b1; end
            else r2 <= r2 + 8'd1;
        end

        // 松开: 短按
        if (k1_d & ~k1) begin
            if (!l1_done) ev_next <= 1'b1;
            h1 <= 10'd0; l1_done <= 1'b0;
        end
        if (k2_d & ~k2) begin
            if (!l2_done) ev_auto <= 1'b1;
            h2 <= 10'd0; l2_done <= 1'b0;
        end
        // SW4 拨动: 音源已随 sw 切换, 此处只用于弹出信息栏
        if (sw_d ^ sw) ev_aud <= 1'b1;
    end
end

//---------------------------------------------------------------------------
// 显示参数调节菜单 (SW3 = 1)
//---------------------------------------------------------------------------
localparam [4:0] LVL_MAX = 5'd16;
localparam [4:0] BRI_DEF = 5'd8, CON_DEF = 5'd8, VOL_DEF = 5'd16, TMP_DEF = 5'd8, GAM_DEF = 5'd8;
localparam [2:0] MI_MODE = 3'd0, MI_BRI = 3'd1, MI_CON = 3'd2, MI_TMP = 3'd3, MI_GAM = 3'd4,
                 MI_VOL = 3'd5, MI_RST = 3'd6;

// 画面模式预设 {亮度, 对比度, 色温, 伽马}
function [19:0] preset;
    input [1:0] m;
    begin
        case (m)
            2'd1:    preset = {5'd11, 5'd10, 5'd9, 5'd7};     // 日间: 亮, 对比强, 略冷, 暗部更沉
            2'd2:    preset = {5'd5,  5'd7,  5'd4, 5'd10};    // 夜间: 暗, 偏暖, 提亮暗部
            2'd3:    preset = {5'd7,  5'd8,  5'd1, 5'd8};     // 护眼: 强暖色, 低蓝光
            default: preset = {5'd8,  5'd8,  5'd8, 5'd8};     // 正常
        endcase
    end
endfunction

function [4:0] lvl_step;
    input [4:0] v;
    input       up;
    begin
        if (up) lvl_step = (v >= LVL_MAX) ? LVL_MAX : v + 5'd1;
        else    lvl_step = (v == 5'd0)    ? 5'd0    : v - 5'd1;
    end
endfunction

wire m_up = ev_auto;                    // KEY2 短按
wire m_dn = ev_eff | ev_rep;            // KEY2 长按 / 连发
wire [1:0]  pm_nx = m_up ? pmode + 2'd1 : pmode - 2'd1;
wire [19:0] pm_v  = preset(pm_nx);
always @(posedge clk or posedge rst) begin
    if (rst) begin
        menu_on <= 1'b0; menu_sel <= MI_MODE; pmode <= 2'd0;
        bri_lvl <= BRI_DEF; con_lvl <= CON_DEF; vol_lvl <= VOL_DEF; temp_lvl <= TMP_DEF; gam_lvl <= GAM_DEF;
    end else begin
        menu_on <= msw & ~alarm_on;                 // 报警时菜单关闭, 不能调节
        if (msw && !menu_on) menu_sel <= MI_MODE;   // 每次打开从 "模式" 开始
        if (menu_on) begin
            if (ev_next) menu_sel <= (menu_sel == MI_RST)  ? MI_MODE : menu_sel + 3'd1;
            if (ev_prev) menu_sel <= (menu_sel == MI_MODE) ? MI_RST  : menu_sel - 3'd1;
            if (m_up | m_dn) begin
                case (menu_sel)
                    MI_MODE: begin
                        pmode <= pm_nx;
                        {bri_lvl, con_lvl, temp_lvl, gam_lvl} <= pm_v;
                    end
                    MI_BRI: bri_lvl  <= lvl_step(bri_lvl, m_up);
                    MI_CON: con_lvl  <= lvl_step(con_lvl, m_up);
                    MI_TMP: temp_lvl <= lvl_step(temp_lvl, m_up);
                    MI_GAM: gam_lvl  <= lvl_step(gam_lvl, m_up);
                    MI_VOL: vol_lvl  <= lvl_step(vol_lvl, m_up);
                    default: begin
                        pmode <= 2'd0;
                        bri_lvl <= BRI_DEF; con_lvl <= CON_DEF; vol_lvl <= VOL_DEF;
                        temp_lvl <= TMP_DEF; gam_lvl <= GAM_DEF;
                    end
                endcase
            end
        end
        // 终端命令 (参数已在终端校验, 此处再限幅)
        if (t_mode) begin
            pmode <= t_arg[1:0];
            {bri_lvl, con_lvl, temp_lvl, gam_lvl} <= preset(t_arg[1:0]);
        end
        if (t_bri) bri_lvl <= (t_arg > LVL_MAX) ? LVL_MAX : t_arg;
        if (t_vol) vol_lvl <= (t_arg > LVL_MAX) ? LVL_MAX : t_arg;
    end
end

//---------------------------------------------------------------------------
// 应答同步
//---------------------------------------------------------------------------
reg [2:0] ack_s;
always @(posedge clk or posedge rst) begin
    if (rst) ack_s <= 3'd0;
    else     ack_s <= {ack_s[1:0], ack_toggle};
end
wire ack_evt = ack_s[2] ^ ack_s[1];

function [20:0] slot_base;
    input [2:0] s;
    case (s)
        3'd0: slot_base = 21'd0;
        3'd1: slot_base = 21'd307200;
        3'd2: slot_base = 21'd614400;
        3'd3: slot_base = 21'd921600;
        3'd4: slot_base = 21'd1228800;
        default: slot_base = 21'd1536000;
    endcase
endfunction


function [3:0] step_img;
    input [3:0] i;
    input       dir;        // 0 下一张, 1 上一张
    input [4:0] n;
    begin
        if (dir) step_img = (i == 4'd0) ? n[3:0] - 4'd1 : i - 4'd1;
        else     step_img = ({1'b0, i} + 5'd1 >= n) ? 4'd0 : i + 4'd1;
    end
endfunction

//---------------------------------------------------------------------------
// 播放状态机
//---------------------------------------------------------------------------
localparam [2:0] P_SPLASH = 3'd0, P_WAIT = 3'd1, P_TRANS0 = 3'd2, P_TRANS = 3'd3,
                 P_SHOW = 3'd4, P_HOLD = 3'd5;

reg [2:0]  ps;
reg [3:0]  tgt;
reg        dir;
reg [4:0]  tries;
reg [2:0]  new_slot;
reg        nav_pend, nav_dir;
reg [13:0] auto_cnt;
reg [7:0]  new_dur;
reg [13:0] auto_lim;        // 当前图片的自动轮播间隔 (帧): 秒数 x 60, 0 秒 = AUTO_FRAMES
reg [8:0]  bar_cnt;
reg [6:0]  bad_cnt;
reg [8:0]  hold_cnt;
reg [2:0]  auto_eff;
reg        have_img;
reg        usr_nav;         // 当前换图由按键发起 (自动轮播为 0)
reg        pend_abs;        // 转场中挂起的是终端 show (绝对目标)
reg  [3:0] pend_img;

wire ready = (ld_status == ST_READY) && (img_count != 5'd0);

assign waiting = (ps == P_WAIT) && !splash_on && usr_nav;
assign msg_bad = (bad_cnt != 7'd0);
assign bar_on  = (bar_cnt != 9'd0) || waiting || msg_bad;

// 用户导航请求 (SHOW 立即执行, 转场中挂起, 等待中改目标); 参数菜单打开时按键归菜单; 报警时全部忽略
//   终端 next / prev / show 同样走这里 (show 为绝对目标 nav_abs)
wire t_nav   = t_next | t_prev | t_show;
wire nav_req = (((ev_next | ev_prev) & ~menu_on) | t_nav) & ~alarm_on;
wire set_auto = ev_auto & ~menu_on & ~alarm_on;
wire set_eff  = ev_eff  & ~menu_on & ~alarm_on;
wire nav_d   = t_nav ? t_prev : ev_prev;
wire nav_abs = t_show;

always @(posedge clk or posedge rst) begin
    if (rst) begin
        ps <= P_SPLASH;
        req_toggle <= 1'b0; req_img <= 4'd0; cur_slot <= 3'd7;
        base_a <= 21'd0; base_b <= 21'd0; b_en <= 1'b0; p <= 9'd0;
        eff_now <= 3'd0; eff_sel <= 4'd8; auto_on <= 1'b1; amode <= 2'd0;
        splash_on <= 1'b1; cur_img <= 4'd0;
        tgt <= 4'd0; dir <= 1'b0; tries <= 5'd0; new_slot <= 3'd0; new_dur <= 8'd0; auto_lim <= {5'd0, AUTO_FRAMES};
        nav_pend <= 1'b0; nav_dir <= 1'b0;
        auto_cnt <= 14'd0; bar_cnt <= 9'd0; bad_cnt <= 7'd0; hold_cnt <= 9'd0;
        auto_eff <= 3'd0; have_img <= 1'b0; usr_nav <= 1'b0; pend_abs <= 1'b0; pend_img <= 4'd0;
    end else begin
        // 设置类按键任何时候都有效
        if (set_auto) begin auto_on <= ~auto_on; auto_cnt <= 14'd0; end
        if (set_eff)  eff_sel <= (eff_sel >= 4'd8) ? 4'd0 : eff_sel + 4'd1;
        if (t_auto)   begin auto_on <= t_arg[0]; auto_cnt <= 14'd0; end
        if (t_eff)    eff_sel <= (t_arg >= 5'd8) ? 4'd8 : t_arg[3:0];
        amode <= alarm_on ? 2'd3 : {1'b0, sw};    // SW4: 0 WAV, 1 测试音; 报警: 3 警笛
        // 信息栏: 只有按键 / SW4 事件才重新计时 5 s
        if (set_auto | set_eff | ev_aud | nav_req | t_auto | t_eff) bar_cnt <= BAR_FRAMES;
        else if (frame_end && bar_cnt != 9'd0) bar_cnt <= bar_cnt - 9'd1;
        if (frame_end && bad_cnt != 7'd0) bad_cnt <= bad_cnt - 7'd1;

        if (!ready && ps != P_SPLASH) begin
            // TF 卡拔出 / 重新扫描: 回到开机画面
            ps <= P_SPLASH;
            splash_on <= 1'b1; b_en <= 1'b0; p <= 9'd0;
            cur_slot <= 3'd7; have_img <= 1'b0; nav_pend <= 1'b0;
        end else begin
            case (ps)
            P_SPLASH: begin
                if (ready) begin
                    tgt <= 4'd0; dir <= 1'b0; tries <= 5'd1; usr_nav <= 1'b0;
                    req_img <= 4'd0; req_toggle <= ~req_toggle;
                    ps <= P_WAIT;
                end
            end
            P_WAIT: begin
                if (nav_req && have_img) begin
                    // 等待中再次按键: 改成新目标
                    tgt   <= nav_abs ? t_arg[3:0] : step_img(tgt, nav_d, img_count);
                    dir   <= nav_d;
                    tries <= 5'd1;
                    usr_nav <= 1'b1;
                    req_img <= nav_abs ? t_arg[3:0] : step_img(tgt, nav_d, img_count);
                    req_toggle <= ~req_toggle;
                end else if (ack_evt && ack_img == tgt) begin
                    if (ack_ok) begin
                        new_slot <= ack_slot;
                        new_dur  <= ack_dur;
                        ps <= P_TRANS0;
                    end else begin
                        bad_cnt <= 7'd120;
                        if (tries < img_count) begin
                            tgt   <= step_img(tgt, dir, img_count);
                            tries <= tries + 5'd1;
                            req_img <= step_img(tgt, dir, img_count);
                            req_toggle <= ~req_toggle;
                        end else if (have_img) begin
                            ps <= P_SHOW;           // 全部损坏: 保持当前图
                            auto_cnt <= 14'd0;
                        end else begin
                            hold_cnt <= 9'd0;
                            ps <= P_HOLD;           // 开机画面等待后重试
                        end
                    end
                end
            end
            P_HOLD: begin
                if (frame_end) begin
                    hold_cnt <= hold_cnt + 9'd1;
                    if (hold_cnt == 9'd300) ps <= P_SPLASH;
                end
            end
            P_TRANS0: begin
                // 帧结束时启动转场, 保证整帧一致
                if (frame_end) begin
                    base_b  <= slot_base(new_slot);
                    b_en    <= 1'b1;
                    p       <= P_STEP;
                    eff_now <= (eff_sel >= 4'd8) ? auto_eff : eff_sel[2:0];
                    if (eff_sel >= 4'd8) auto_eff <= auto_eff + 3'd1;
                    cur_img <= tgt;
                    auto_lim <= (new_dur == 8'd0) ? {5'd0, AUTO_FRAMES} : ({new_dur, 6'd0} - {4'd0, new_dur, 2'd0});
                    // 按键换图 / 插卡后首图: 新图出现时再计时 5 s; 自动轮播不弹出
                    if (usr_nav || !have_img) bar_cnt <= BAR_FRAMES;
                    ps      <= P_TRANS;
                end
            end
            P_TRANS: begin
                if (nav_req) begin nav_pend <= 1'b1; nav_dir <= nav_d; pend_abs <= nav_abs; pend_img <= t_arg[3:0]; end
                if (frame_end) begin
                    if (p >= 9'd256) begin
                        base_a    <= base_b;
                        b_en      <= 1'b0;
                        p         <= 9'd0;
                        splash_on <= 1'b0;
                        cur_slot  <= new_slot;
                        have_img  <= 1'b1;
                        auto_cnt  <= 14'd0;
                        ps        <= P_SHOW;
                    end else
                        p <= p + P_STEP;
                end
            end
            P_SHOW: begin
                if (frame_end && auto_on && !menu_on && !alarm_on && img_count > 5'd1) auto_cnt <= auto_cnt + 14'd1;
                if (nav_req || nav_pend || (auto_on && auto_cnt >= auto_lim && img_count > 5'd1)) begin
                    nav_pend <= 1'b0;
                    auto_cnt <= 14'd0;
                    usr_nav  <= nav_req | nav_pend;
                    if (nav_req) begin
                        dir <= nav_d;
                        tgt     <= nav_abs ? t_arg[3:0] : step_img(cur_img, nav_d, img_count);
                        req_img <= nav_abs ? t_arg[3:0] : step_img(cur_img, nav_d, img_count);
                    end else if (nav_pend) begin
                        dir <= nav_dir;
                        tgt     <= pend_abs ? pend_img : step_img(cur_img, nav_dir, img_count);
                        req_img <= pend_abs ? pend_img : step_img(cur_img, nav_dir, img_count);
                    end else begin
                        dir <= 1'b0;   tgt <= step_img(cur_img, 1'b0, img_count);
                        req_img <= step_img(cur_img, 1'b0, img_count);
                    end
                    tries <= 5'd1;
                    req_toggle <= ~req_toggle;
                    ps <= P_WAIT;
                end
            end
            default: ps <= P_SPLASH;
            endcase
        end
    end
end

endmodule
