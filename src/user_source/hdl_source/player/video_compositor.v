`timescale 1ns/1ps
//============================================================================
// video_compositor (video_clk 域, 640x400; 输出经 video_scale2x 放大成 1280x800)
//
//  图层 (自下而上):
//   A  : 当前图片 (SDRAM 读通道 A), 开机阶段为动态开机画面 (渐变背景+标题+进度条)
//   B  : 转场目标图片 (读通道 B, 仅转场期间有效)
//   转场: out = A + (B - A) * q / 256, q 由特效类型、像素坐标和进度 p 决定
//        0 淡入淡出  1 横向擦除  2 纵向擦除  3 圆形展开
//        4 百叶窗    5 马赛克    6 随机溶解  7 黑场过渡
//   OSD: 顶部信息栏 (轮播图标/序号/文件名/分辨率/特效/音频/标题, 5s 自动隐藏)
//        底部滚动字幕 (SUB.TXT 或内置字幕), 半透明底
//        参数调节菜单 (SW3, 屏幕中央, 模式/亮度/对比度/色温/伽马/音量/复位, 半透明底)
//        音频频谱 (SW2, 字幕上方, audio_spectrum_osd: 1024 点 FFT, 24 段频谱柱 + 峰值帽 + 两端细电平条,
//                  背景透明)
//   应急报警 (最高优先级, alarm_screen): alarm_on 在帧开始锁存, 下一帧整帧硬切到报警画面 (不用转场),
//        盖住图片 / 开机画面 / 信息栏 / 菜单 / 字幕 / 频谱, 也不受亮度对比度影响
//   画面调节 (参考第十四讲并扩展): 只作用于图像 (开机画面 + 图片), OSD 文字与底色不受影响
//        亮度   y = sat(x * bri / 128),                bri = 级别 * 16 (0~256, 128 = 原样)
//        对比度 z = sat((y - 128) * con / 128 + 128),  con = 级别 * 16 (0~256, 128 = 原样)
//        色温   w = sat(z * gain_c / 256)  (每通道增益, 级别 8 原样, 小 = 暖 / 护眼, 大 = 冷)
//        伽马   q = 255 * (w / 255) ^ gamma, gamma = 2 ^ ((8 - 级别) / 8)
//        四步合成一张 256 项 x RGB 的查找表 (color_lut_gen), 每帧 VS 下降沿按本帧参数重算,
//        在第一行有效像素之前写完 -> 整帧一致, 调节时不会出现上下半屏不同的撕裂;
//        像素通路只查表, 不再用乘法器
//
//  流水线: S0 坐标 -> S1 FIFO 数据/字符码 -> S2 字模 -> S3 q -> S4 乘 -> S5 混合
//          -> S6 查表 (BRAM 读) -> S7 查表输出寄存 -> S8 OSD
//============================================================================
module video_compositor(
    input             clk,
    input             rst,
    // 时序 (来自 video_timing_data)
    input             hs_in,
    input             vs_in,
    input             de_in,
    // 帧数据
    output            read_en_a,
    input      [31:0] data_a,
    output            read_en_b,
    input      [31:0] data_b,
    // 播放器状态
    input             splash_on,
    input             bar_on,
    input             auto_on,
    input             waiting,
    input             msg_bad,
    input      [3:0]  cur_img,
    input      [3:0]  eff_sel,        // 0~7 固定特效, 8 轮换
    input      [2:0]  eff_now,
    input      [8:0]  p,              // 转场进度 0~256
    input             b_en,
    input      [1:0]  amode,          // 0 WAV 1 音阶
    // 参数调节菜单
    input             menu_on,
    input      [2:0]  menu_sel,       // 0 模式 1 亮度 2 对比度 3 色温 4 伽马 5 音量 6 复位
    input      [1:0]  pmode,          // 画面模式 (仅显示名称)
    input      [4:0]  bri_lvl,        // 0~16
    input      [4:0]  con_lvl,        // 0~16
    input      [4:0]  temp_lvl,       // 0~16
    input      [4:0]  gam_lvl,        // 0~16
    input      [4:0]  vol_lvl,        // 0~16 (仅显示)
    // 音频波形 (SW2)
    input             wave_on,
    input             aud_tgl,        // pix_clk 域, 每个 48k 样本翻转
    input      [15:0] aud_l,
    input      [15:0] aud_r,
    // 应急报警
    input             alarm_on,
    input      [15:0] alm_bcd,        // 持续时间 mm:ss (BCD)
    input      [1:0]  alm_src,        // 报警触发来源 (报警画面说明行)
    // 加载器状态 (已同步)
    input      [2:0]  ld_status,
    input      [4:0]  img_count,
    input      [3:0]  load_img,
    input      [7:0]  load_prog,
    input             wav_ok,
    input      [2:0]  rate_code,
    input             txt_ok,
    input      [9:0]  txt_len,
    // 文本 / 用户字库 RAM 写口 (sd 时钟域)
    input             wclk,
    input             txt_we,
    input      [9:0]  txt_waddr,
    input      [7:0]  txt_wdata,
    input             fnt_we,
    input      [10:0] fnt_waddr,
    input      [7:0]  fnt_wdata,
    input             fnt_ok,
    // 输出
    output            frame_end,
    output reg        hs_out,
    output reg        vs_out,
    output reg        de_out,
    output reg [23:0] rgb_out
);

`include "osd_str_ids.vh"

localparam [2:0] ST_INIT = 3'd0, ST_SCAN = 3'd1, ST_READY = 3'd2,
                 ST_NOCARD = 3'd3, ST_FSERR = 3'd4, ST_NOIMG = 3'd5;

//---------------------------------------------------------------------------
// 坐标
//---------------------------------------------------------------------------
reg [9:0]  xc;
reg [8:0]  yc;
reg        de_d, vs_d;
reg        ben_f;
reg [7:0]  tick;
reg [12:0] scroll;
reg        alm_f;           // 本帧是否显示报警画面

wire [12:0] mlen8 = txt_ok ? {txt_len, 3'b000} : {2'b00, S_MARQUEE_LEN, 3'b000};

assign frame_end = de_d & ~de_in & (yc == 9'd399);
assign read_en_a = de_in;
assign read_en_b = de_in & ben_f;

always @(posedge clk or posedge rst) begin
    if (rst) begin
        xc <= 10'd0; yc <= 9'd0; de_d <= 1'b0; vs_d <= 1'b1;
        ben_f <= 1'b0; tick <= 8'd0; scroll <= 13'd0;
        alm_f <= 1'b0;
    end else begin
        de_d <= de_in;
        vs_d <= vs_in;
        if (de_in) xc <= xc + 10'd1;
        else       xc <= 10'd0;
        if (!vs_in)             yc <= 9'd0;
        else if (de_d & ~de_in) yc <= yc + 9'd1;
        // 每帧开始 (VS 下降沿) 锁存本帧 B 通道是否有效, 与 SDRAM 读侧一致
        if (vs_d & ~vs_in) begin
            ben_f <= b_en;
            alm_f <= alarm_on;
        end
        if (frame_end) begin
            tick   <= tick + 8'd1;
            scroll <= (scroll >= mlen8 + 13'd639) ? 13'd0 : scroll + 13'd1;
        end
    end
end

//---------------------------------------------------------------------------
// S0: 文本行描述
//---------------------------------------------------------------------------
localparam [1:0] SRC_ROM = 2'd0, SRC_RAM = 2'd1, SRC_DIR = 2'd2;

reg        t_act;
reg [1:0]  t_src;
reg [4:0]  t_sid;
reg [6:0]  t_col;
reg [9:0]  t_raddr;
reg [8:0]  t_code;
reg [3:0]  t_row;
reg [2:0]  t_px;
reg [23:0] t_color;
reg        t_layA;

// 状态行
reg [4:0]  st_sid;
reg [7:0]  st_len;
always @(*) begin
    case (ld_status)
        ST_INIT:   begin st_sid = S_ST_INIT;   st_len = L_ST_INIT;   end
        ST_SCAN:   begin st_sid = S_ST_SCAN;   st_len = L_ST_SCAN;   end
        ST_NOCARD: begin st_sid = S_ST_NOCARD; st_len = L_ST_NOCARD; end
        ST_FSERR:  begin st_sid = S_ST_FSERR;  st_len = L_ST_FSERR;  end
        ST_NOIMG:  begin st_sid = S_ST_NOIMG;  st_len = L_ST_NOIMG;  end
        default:   begin st_sid = S_ST_LOAD;   st_len = L_ST_LOAD + 8'd8; end
    endcase
end
wire [9:0]  st_x0 = 10'd320 - {st_len, 2'b00};
wire [9:0]  st_lx = xc - st_x0;

// 开机画面各行水平居中: 起点 = 320 - 列数 * 字宽 / 2 (标题 2 倍字宽 16 px)
localparam [9:0] TI_X0 = 10'd320 - {L_TITLE, 3'b000};
localparam [9:0] IN_X0 = 10'd320 - {L_INFO, 2'b00};
localparam [9:0] H1_X0 = 10'd320 - {L_HINT1, 2'b00};
localparam [9:0] H2_X0 = 10'd320 - {L_HINT2, 2'b00};
localparam [6:0] TB_TI = 7'd80 - L_TITLE[6:0];     // 顶部信息栏标题起始列 (右对齐)
wire [9:0]  ti_lx = xc - TI_X0;
wire [9:0]  in_lx = xc - IN_X0;
wire [9:0]  h1_lx = xc - H1_X0;
wire [9:0]  h2_lx = xc - H2_X0;
wire [8:0]  ti_ly = yc - 9'd110;
wire [13:0] mv    = {4'd0, xc} + {1'b0, scroll} - 14'd640;   // 滚动字幕坐标 (有符号)
wire [6:0]  tb_col = xc[9:3];

// 参数调节菜单: 底框 x 128~511 (48 列), y 40~327
//   标题 y 48, 分隔线 y 72, 7 个菜单项 y 80 + 32 * i (每项 16 行), 按键说明 y 304
//   菜单项列 (相对框左): 3 光标, 5~12 名称, 15~30 数值条 (16 格), 32~33 级别数字;
//   模式行在第 15~22 列显示模式名, 复位行在第 15~26 列显示说明
//   S_MENU_IT: 第 0~55 列为 7 个项名 (每个 8 列), 56~67 复位说明, 72 + 8 * 模式 起为模式名
localparam [9:0] MT_X0 = 10'd320 - {L_MENU_T, 2'b00};
localparam [9:0] MH_X0 = 10'd320 - {L_MENU_H, 2'b00};
wire [9:0]  mt_lx = xc - MT_X0;
wire [9:0]  mh_lx = xc - MH_X0;
wire [9:0]  mb_lx = xc - 10'd128;
wire [5:0]  m_cx  = mb_lx[8:3];
wire        m_inx = (xc >= 10'd128) && (xc < 10'd512);
wire [8:0]  m_iy  = yc - 9'd80;
wire [2:0]  m_it  = m_iy[7:5];
wire        m_cur = (m_it == menu_sel);
reg  [4:0]  m_lvl;
always @(*) begin
    case (m_it)
        3'd1:    m_lvl = bri_lvl;
        3'd2:    m_lvl = con_lvl;
        3'd3:    m_lvl = temp_lvl;
        3'd4:    m_lvl = gam_lvl;
        default: m_lvl = vol_lvl;
    endcase
end
wire [4:0]  m_one = (m_lvl >= 5'd10) ? m_lvl - 5'd10 : m_lvl;
wire [5:0]  m_bar = m_cx - 6'd15;

// 音频频谱 (开机画面与报警时不显示, 也不做 FFT)
wire        wave_en = wave_on & ~splash_on & ~alm_f;

// 十进制
wire [4:0]  idx1   = {1'b0, cur_img} + 5'd1;
wire [8:0]  idx_t  = (idx1 >= 5'd10) ? 9'h031 : 9'h030;
wire [8:0]  idx_o  = 9'h030 + ((idx1 >= 5'd10) ? idx1 - 5'd10 : idx1);
wire [8:0]  tot_t  = (img_count >= 5'd10) ? 9'h031 : 9'h030;
wire [8:0]  tot_o  = 9'h030 + ((img_count >= 5'd10) ? img_count - 5'd10 : img_count);
wire [6:0]  rate_c = {rate_code, 2'b00} + {1'b0, rate_code, 1'b0};

always @(*) begin
    t_act = 1'b0; t_src = SRC_ROM; t_sid = 5'd0; t_col = 7'd0; t_raddr = 10'd0;
    t_code = 9'h020; t_row = 4'd0; t_px = 3'd0; t_color = 24'hFFFFFF; t_layA = 1'b0;

    if (yc >= 9'd376 && yc < 9'd392) begin
        // 底部滚动字幕
        t_row = yc[3:0] - 4'd8;
        t_px  = mv[2:0];
        t_color = 24'hFFE060;
        if (!mv[13] && mv[12:0] < mlen8) begin
            t_act = 1'b1;
            if (txt_ok) begin
                t_src = SRC_RAM; t_raddr = {1'b0, mv[11:3]};
            end else begin
                t_src = SRC_ROM; t_sid = S_MARQUEE; t_col = mv[9:3];
            end
        end
    end else if (menu_on && yc >= 9'd40 && yc < 9'd328) begin
        // 参数调节菜单 (盖住开机画面中部的文字)
        t_row = yc[3:0];
        t_px  = xc[2:0];
        if (yc >= 9'd48 && yc < 9'd64) begin
            t_px = mt_lx[2:0]; t_col = mt_lx[9:3];
            t_sid = S_MENU_T; t_color = 24'hFFD040;
            t_act = (xc >= MT_X0 && mt_lx < {L_MENU_T, 3'b000});
        end else if (yc >= 9'd80 && yc < 9'd304 && !m_iy[4] && m_inx) begin
            t_act = 1'b1;
            t_src = SRC_DIR;
            if (m_cx == 6'd3) begin
                t_code = m_cur ? 9'h001 : 9'h020; t_color = 24'hFFE060;
            end else if (m_cx >= 6'd5 && m_cx < 6'd13) begin
                t_src = SRC_ROM; t_sid = S_MENU_IT; t_col = {1'b0, m_it, 3'b000} + (m_cx - 6'd5);
                t_color = m_cur ? 24'hFFE060 : 24'hE0E0E0;
            end else if (m_it == 3'd0) begin
                // 模式项: 模式名
                if (m_cx >= 6'd15 && m_cx < 6'd23) begin
                    t_src = SRC_ROM; t_sid = S_MENU_IT; t_col = {2'b10, pmode, 3'b000} + 7'd8 + (m_cx - 6'd15);   // 72 + 8 * 模式
                    t_color = m_cur ? 24'h60E0FF : 24'h80C0D0;
                end else
                    t_act = 1'b0;
            end else if (m_it == 3'd6) begin
                // 复位项: 说明文字
                if (m_cx >= 6'd15 && m_cx < 6'd27) begin
                    t_src = SRC_ROM; t_sid = S_MENU_IT; t_col = 7'd56 + (m_cx - 6'd15);
                    t_color = m_cur ? 24'hFFE060 : 24'hA0A0A0;
                end else
                    t_act = 1'b0;
            end else if (m_cx >= 6'd15 && m_cx < 6'd31) begin
                // 数值条: 前 m_lvl 格为实格
                if (m_bar < {1'b0, m_lvl}) begin t_code = 9'h007; t_color = m_cur ? 24'h60E0FF : 24'h4090B0; end
                else                        begin t_code = 9'h008; t_color = 24'h607080; end
            end else if (m_cx == 6'd32) begin
                t_code = (m_lvl >= 5'd10) ? 9'h031 : 9'h020; t_color = 24'hFFFFFF;
            end else if (m_cx == 6'd33) begin
                t_code = 9'h030 + {4'd0, m_one}; t_color = 24'hFFFFFF;
            end else
                t_act = 1'b0;
        end else if (yc >= 9'd304 && yc < 9'd320) begin
            t_px = mh_lx[2:0]; t_col = mh_lx[9:3];
            t_sid = S_MENU_H; t_color = 24'h80E0FF;
            t_act = (xc >= MH_X0 && mh_lx < {L_MENU_H, 3'b000});
        end
    end else if (splash_on) begin
        t_layA = 1'b1;
        // 开机画面 (400 行): 标题 110~141, 装饰线 150, 信息 168, 状态 216, 进度条 256, 提示 320 / 344
        if (yc >= 9'd110 && yc < 9'd142) begin
            t_row = ti_ly[4:1]; t_px = ti_lx[3:1]; t_col = ti_lx[8:4];
            t_sid = S_TITLE; t_color = 24'hFFD040;
            t_act = (xc >= TI_X0 && ti_lx < {L_TITLE, 4'b0000});
        end else if (yc >= 9'd168 && yc < 9'd184) begin
            t_row = yc[3:0] - 4'd8; t_px = in_lx[2:0]; t_col = in_lx[9:3];
            t_sid = S_INFO; t_color = 24'hC8D0FF;
            t_act = (xc >= IN_X0 && in_lx < {L_INFO, 3'b000});
        end else if (yc >= 9'd216 && yc < 9'd232) begin
            t_row = yc[3:0] - 4'd8; t_px = st_lx[2:0]; t_col = st_lx[9:3];
            t_sid = st_sid; t_color = 24'hFFFFFF;
            t_act = (xc >= st_x0 && st_lx < {st_len, 3'b000});
            if (ld_status == ST_READY && st_lx[9:3] >= L_ST_LOAD) begin
                t_src   = SRC_RAM;
                t_raddr = {3'b100, load_img, st_lx[5:3] - L_ST_LOAD[2:0]};
                t_color = 24'h80FF80;
            end
        end else if (yc >= 9'd320 && yc < 9'd336) begin
            t_row = yc[3:0]; t_px = h1_lx[2:0]; t_col = h1_lx[9:3];
            t_sid = S_HINT1; t_color = 24'h80E0FF;
            t_act = (xc >= H1_X0 && h1_lx < {L_HINT1, 3'b000});
        end else if (yc >= 9'd344 && yc < 9'd360) begin
            t_row = yc[3:0] - 4'd8; t_px = h2_lx[2:0]; t_col = h2_lx[9:3];
            t_sid = S_HINT2; t_color = 24'h80E0FF;
            t_act = (xc >= H2_X0 && h2_lx < {L_HINT2, 3'b000});
        end
    end else if (bar_on && yc >= 9'd6 && yc < 9'd22) begin
        // 顶部信息栏, 80 列
        t_row = yc[3:0] - 4'd6;
        t_px  = xc[2:0];
        t_act = 1'b1;
        t_src = SRC_DIR;
        if (tb_col == 7'd1) begin
            t_code = auto_on ? 9'h001 : 9'h002; t_color = 24'h60FF60;
        end else if (tb_col == 7'd3) t_code = idx_t;
        else if (tb_col == 7'd4) t_code = idx_o;
        else if (tb_col == 7'd5) t_code = 9'h02F;
        else if (tb_col == 7'd6) t_code = tot_t;
        else if (tb_col == 7'd7) t_code = tot_o;
        else if (tb_col >= 7'd10 && tb_col < 7'd22) begin
            if (msg_bad) begin
                t_src = SRC_ROM; t_sid = S_BADIMG; t_col = tb_col - 7'd10; t_color = 24'hFF6060;
            end else if (waiting) begin
                t_src = SRC_ROM; t_sid = S_LOADING; t_col = tb_col - 7'd10; t_color = 24'hFFC040;
            end else if (tb_col < 7'd18) begin
                t_src = SRC_RAM; t_raddr = {3'b100, cur_img, tb_col[2:0] - 3'd2}; t_color = 24'h80FF80;
            end else if (tb_col >= 7'd19) begin
                t_src = SRC_RAM; t_raddr = {2'b11, cur_img, tb_col[3:0] - 4'd3}; t_color = 24'hD0D8E8;
            end
        end else if (tb_col >= 7'd22 && tb_col < 7'd28) begin
            // 图片分辨率 "宽x高" 第 19~27 列 (加载器写入文本 RAM 768 + 图片号 * 16), 提示信息时不显示
            t_src = SRC_RAM; t_raddr = {2'b11, cur_img, tb_col[3:0] - 4'd3}; t_color = 24'hD0D8E8;
            t_act = ~msg_bad & ~waiting;
        end else if (tb_col >= 7'd29 && tb_col < 7'd37) begin
            t_src = SRC_ROM; t_sid = S_EFF0 + {1'b0, eff_sel}; t_col = tb_col - 7'd29; t_color = 24'h60E0FF;
        // 轮播状态已由第 1 列图标表示, 不再单独显示模式文字, 给标题让出位置
        end else if (tb_col == 7'd38) begin
            t_code = 9'h003; t_color = 24'hFF90E0;
        end else if (tb_col >= 7'd39 && tb_col < 7'd47) begin
            t_src = SRC_ROM; t_col = tb_col - 7'd39; t_color = 24'hFF90E0;
            t_sid = (amode == 2'd0) ? S_AUD_WAV : S_AUD_TONE;
        end else if (tb_col >= 7'd47 && tb_col < 7'd53 && amode == 2'd0) begin
            t_src = SRC_ROM; t_color = 24'hFF90E0;
            if (wav_ok) begin
                t_sid = S_RATES; t_col = rate_c + (tb_col - 7'd47);
            end else begin
                t_sid = S_NOWAV; t_col = tb_col - 7'd47;
            end
        end else if (tb_col == 7'd47 && amode == 2'd1) begin
            t_code = 9'h004; t_color = 24'hFF90E0;
        end else if (tb_col >= TB_TI && tb_col < 7'd80) begin
            // 标题右对齐到第 79 列 (一行共 80 列)
            t_src = SRC_ROM; t_sid = S_TITLE; t_col = tb_col - TB_TI; t_color = 24'hFFD040;
        end else
            t_act = 1'b0;
    end
end

//---------------------------------------------------------------------------
// 文本 RAM (0~511 字幕, 512~639 文件名, 768~1023 分辨率文字) / 用户字库 RAM
//---------------------------------------------------------------------------
reg [7:0] tram [0:1023];
reg [7:0] fram [0:2047];
reg [7:0] tram_q;
reg [7:0] fram_q;
always @(posedge wclk) begin
    if (txt_we) tram[txt_waddr] <= txt_wdata;
    if (fnt_we) fram[fnt_waddr] <= fnt_wdata;
end

wire [8:0] srom_q;
osd_str_rom u_str_rom(
    .clk  (clk),
    .addr ({t_sid, t_col}),
    .q    (srom_q)
);

// S0 -> S1
reg        t_act1, t_layA1;
reg [1:0]  t_src1;
reg [8:0]  t_code1;
reg [3:0]  t_row1;
reg [2:0]  t_px1;
reg [23:0] t_color1;
always @(posedge clk) begin
    tram_q   <= tram[t_raddr];
    t_act1   <= t_act & de_in;
    t_layA1  <= t_layA;
    t_src1   <= t_src;
    t_code1  <= t_code;
    t_row1   <= t_row;
    t_px1    <= t_px;
    t_color1 <= t_color;
end

// S1: 字符码
reg [8:0] code1;
always @(*) begin
    case (t_src1)
        SRC_ROM: code1 = srom_q;
        SRC_RAM: code1 = (tram_q < 8'h20) ? 9'h020 : {1'b0, tram_q};
        default: code1 = t_code1;
    endcase
end

wire [7:0] from_q;
osd_font_rom u_font_rom(
    .clk  (clk),
    .addr ({code1, t_row1}),
    .q    (from_q)
);

reg        t_act2, t_layA2, t_user2;
reg [2:0]  t_px2;
reg [23:0] t_color2;
always @(posedge clk) begin
    fram_q   <= fram[{code1[6:0], t_row1}];
    t_act2   <= t_act1;
    t_layA2  <= t_layA1;
    t_user2  <= (code1[8:7] == 2'b01) && fnt_ok;
    t_px2    <= t_px1;
    t_color2 <= t_color1;
end

// S2: 取点
wire [7:0] glyph2 = t_user2 ? fram_q : from_q;
wire       tbit2  = t_act2 & glyph2[3'd7 - t_px2];

//---------------------------------------------------------------------------
// 坐标 / 标志延迟
//---------------------------------------------------------------------------
reg [9:0] x1, x2;
reg [8:0] y1, y2;
reg       de1, de2, de3, de4, de5, de6, de7;
reg       hs1, hs2, hs3, hs4, hs5, hs6, hs7;
reg       vs1, vs2, vs3, vs4, vs5, vs6, vs7;
always @(posedge clk or posedge rst) begin
    if (rst) begin
        x1 <= 0; x2 <= 0; y1 <= 0; y2 <= 0;
        {de1, de2, de3, de4, de5, de6, de7} <= 7'd0;
        {hs1, hs2, hs3, hs4, hs5, hs6, hs7} <= 7'h7F;
        {vs1, vs2, vs3, vs4, vs5, vs6, vs7} <= 7'h7F;
    end else begin
        x1 <= xc; x2 <= x1;
        y1 <= yc; y2 <= y1;
        de1 <= de_in; de2 <= de1; de3 <= de2; de4 <= de3; de5 <= de4; de6 <= de5; de7 <= de6;
        hs1 <= hs_in; hs2 <= hs1; hs3 <= hs2; hs4 <= hs3; hs5 <= hs4; hs6 <= hs5; hs7 <= hs6;
        vs1 <= vs_in; vs2 <= vs1; vs3 <= vs2; vs4 <= vs3; vs5 <= vs4; vs6 <= vs5; vs7 <= vs6;
    end
end

// OSD 区域标志 (S0 计算, 延迟到 S5)
wire o_top  = ~splash_on & bar_on & (yc < 9'd28);
wire o_topl = o_top & (yc == 9'd27);
wire [9:0] lp_w = {1'b0, load_prog, 1'b0} + {3'b000, load_prog[7:1]};   // prog*2.5
wire o_prog = ~splash_on & waiting & (yc >= 9'd24) & (yc < 9'd27) & (xc < lp_w);
wire o_bot  = (yc >= 9'd368);
wire o_botl = (yc == 9'd368);
wire o_mbox = menu_on & m_inx & (yc >= 9'd40) & (yc < 9'd328);
wire o_mln  = o_mbox & ((yc == 9'd40) || (yc == 9'd327) || (xc == 10'd128) || (xc == 10'd511) ||
                        ((yc == 9'd72) && (xc >= 10'd136) && (xc < 10'd504)));
// of = {上栏, 上栏线, 进度, 下栏, 下栏线, 菜单底, 菜单线}
reg [6:0] of1, of2, of3, of4, of5, of6, of7;
always @(posedge clk) begin
    of1 <= {o_top, o_topl, o_prog, o_bot, o_botl, o_mbox, o_mln};
    of2 <= of1; of3 <= of2; of4 <= of3; of5 <= of4; of6 <= of5; of7 <= of6;
end

// 音频频谱: 输出延迟 2 拍 (与 of2 同拍), 再延迟到 S7
// wf = 0 无 / 1 绿 / 2 黄 / 3 红 / 4 白 (峰值帽)
wire [2:0] wf2;
audio_spectrum_osd u_spec(
    .clk     (clk),
    .rst     (rst),
    .enable  (wave_en),
    .vs_in   (vs_in),
    .xc      (xc),
    .yc      (yc),
    .aud_tgl (aud_tgl),
    .aud_l   (aud_l),
    .aud_r   (aud_r),
    .w2      (wf2)
);
reg [2:0] wf3, wf4, wf5, wf6, wf7;
always @(posedge clk) begin
    wf3 <= wf2; wf4 <= wf3; wf5 <= wf4; wf6 <= wf5; wf7 <= wf6;
end
wire [23:0] wcol7 = (wf7 == 3'd4) ? 24'hFFFFFF :              // 峰值帽
                    (wf7 == 3'd1) ? 24'h40E060 :              // 频谱柱 / 电平条 绿 / 黄 / 红
                    (wf7 == 3'd2) ? 24'hFFD040 : 24'hFF4040;

// 应急报警画面: 输出延迟 2 拍, 再延迟到 S7
wire [23:0] am2;
alarm_screen u_alarm(
    .clk   (clk),
    .rst   (rst),
    .vs_in (vs_in),
    .active(alm_f),
    .xc    (xc),
    .yc    (yc),
    .t_bcd (alm_bcd),
    .src   (alm_src),
    .rgb2  (am2)
);
reg [23:0] am3, am4, am5, am6, am7;
always @(posedge clk) begin
    am3 <= am2; am4 <= am3; am5 <= am4; am6 <= am5; am7 <= am6;
end

//---------------------------------------------------------------------------
// S1: 开机画面背景 + 帧数据
//---------------------------------------------------------------------------
wire [8:0] ph1 = {1'b0, x1[9:2]} + {1'b0, tick};
wire [8:0] ph2 = {y1} + {tick, 1'b0};
wire [7:0] tw1 = ph1[8] ? ~ph1[7:0] : ph1[7:0];
wire [7:0] tw2 = ph2[8] ? ~ph2[7:0] : ph2[7:0];
wire [9:0] fill_w = {2'b00, load_prog} + {3'b000, load_prog[7:1]} + {6'd0, load_prog[7:4]};
wire [9:0] bar_lx = x1 - 10'd121;
wire in_bar   = (ld_status == ST_READY) && (y1 >= 9'd256) && (y1 < 9'd272) && (x1 >= 10'd120) && (x1 < 10'd520);
wire bar_edge = (y1 == 9'd256) || (y1 == 9'd271) || (x1 == 10'd120) || (x1 == 10'd519);
wire deco     = ~menu_on && (y1 == 9'd150) && (x1 >= 10'd160) && (x1 < 10'd480);   // 菜单打开时不画 (会透过菜单底)

reg [23:0] sp2, a2, b2;
always @(posedge clk) begin
    if (in_bar) begin
        if (bar_edge)              sp2 <= 24'hC0C0D0;
        else if (bar_lx < fill_w)  sp2 <= {8'h30, 8'hA0 + {1'b0, x1[8:2]}, 8'h60};
        else                       sp2 <= 24'h101828;
    end else if (deco)
        sp2 <= 24'hFFD040;
    else
        sp2 <= {{3'b000, tw1[7:3]} + 8'd8,
                {2'b00, tw2[7:2]} + 8'd16,
                8'd80 + {2'b00, tw1[7:2]} + {3'b000, tw2[7:3]}};
    a2 <= data_a[31:8];
    b2 <= ben_f ? data_b[31:8] : 24'd0;
end

//---------------------------------------------------------------------------
// S2: 转场系数 q
//---------------------------------------------------------------------------
wire signed [10:0] dx = {1'b0, x2} - 11'sd320;
wire signed [10:0] dy = {2'b00, y2} - 11'sd200;
wire [19:0] d2 = dx * dx + dy * dy;
// 半径 p*1.5: p = 256 时 385 > 中心到角的距离 377 (640x400)
wire [9:0]  rr = {1'b0, p} + {2'b00, p[8:1]} + 10'd1;
wire [19:0] r2 = rr * rr;

wire [8:0]  bk  = {y2[8:5], x2[9:5]};
wire [7:0]  hmb = (bk[7:0] * 8'd157) ^ {bk[8], bk[2:0], bk[7:4]} ^ 8'h5A;
wire [3:0]  bay = {x2[0] ^ y2[0], y2[0], x2[1] ^ y2[1], y2[1]};
wire [7:0]  hd  = ({y2[5:2], x2[5:2]} * 8'd109) ^ {x2[9:6], y2[8:5]};
wire [7:0]  thr = {bay, hd[7:4]};

wire [9:0]  wh = {p, 1'b0} + {1'b0, p[8:1]};          // p*2.5
wire [9:0]  wv = {1'b0, p} + {2'b00, p[8:1]} + {5'd0, p[8:4]};   // p*1.5625 (256 -> 400 行)

reg [8:0]  qn;
reg        blk_a, blk_b;
always @(*) begin
    blk_a = 1'b0; blk_b = 1'b0;
    case (eff_now)
        3'd0: qn = p;
        3'd1: qn = (x2 < wh) ? 9'd256 : 9'd0;
        3'd2: qn = ({1'b0, y2} < wv) ? 9'd256 : 9'd0;
        3'd3: qn = (d2 < r2) ? 9'd256 : 9'd0;
        3'd4: qn = ({1'b0, y2[4:0]} < p[8:3]) ? 9'd256 : 9'd0;
        3'd5: qn = ({1'b0, hmb} < p) ? 9'd256 : 9'd0;
        3'd6: qn = ({1'b0, thr} < p) ? 9'd256 : 9'd0;
        default: begin
            // 前半程 A 淡出到黑, 后半程由黑淡入 B, 两段 q 均为 0~254
            if (p < 9'd128) begin qn = {1'b0, p[6:0], 1'b0}; blk_b = 1'b1; end
            else            begin qn = {1'b0, p[6:0], 1'b0}; blk_a = 1'b1; end
        end
    endcase
    if (p >= 9'd256) begin qn = 9'd256; blk_a = 1'b0; blk_b = 1'b0; end
end

reg [23:0] a3, b3;
reg [8:0]  q3;
reg        tbit3;
reg [23:0] tcol3;
always @(posedge clk) begin
    // 开机画面文字画在 A 层上, 随转场一起淡出
    if (splash_on)
        a3 <= (tbit2 & t_layA2) ? t_color2 : sp2;
    else
        a3 <= a2;
    if (blk_a) a3 <= 24'd0;
    b3    <= blk_b ? 24'd0 : b2;
    q3    <= ben_f ? qn : 9'd0;
    tbit3 <= tbit2 & ~t_layA2;
    tcol3 <= t_color2;
end

//---------------------------------------------------------------------------
// S3/S4: 混合 out = a + (b-a)*q/256
//---------------------------------------------------------------------------
wire signed [8:0]  dr = {1'b0, b3[23:16]} - {1'b0, a3[23:16]};
wire signed [8:0]  dg = {1'b0, b3[15:8]}  - {1'b0, a3[15:8]};
wire signed [8:0]  db = {1'b0, b3[7:0]}   - {1'b0, a3[7:0]};
wire signed [9:0]  qs = {1'b0, q3};
reg  signed [18:0] mr, mg, mb;
reg  [23:0] a4;
reg         tbit4, tbit5, tbit6, tbit7;
reg  [23:0] tcol4, tcol5, tcol6, tcol7;
always @(posedge clk) begin
    mr <= dr * qs;
    mg <= dg * qs;
    mb <= db * qs;
    a4 <= a3;
    tbit4 <= tbit3; tcol4 <= tcol3;
    tbit5 <= tbit4; tcol5 <= tcol4;
    tbit6 <= tbit5; tcol6 <= tcol5;
    tbit7 <= tbit6; tcol7 <= tcol6;
end

wire [8:0] or5 = {1'b0, a4[23:16]} + mr[16:8];
wire [8:0] og5 = {1'b0, a4[15:8]}  + mg[16:8];
wire [8:0] ob5 = {1'b0, a4[7:0]}   + mb[16:8];
reg  [23:0] mix5;
always @(posedge clk) mix5 <= {or5[7:0], og5[7:0], ob5[7:0]};

//---------------------------------------------------------------------------
// S6/S7: 画面调节查找表 (亮度 -> 对比度 -> 色温 -> 伽马)
//   每帧 VS 下降沿由 color_lut_gen 按本帧参数重写 (第一行有效像素之前写完);
//   S6 读 BRAM, S7 输出寄存, 与原来 "S6 亮度 + S7 对比度" 的延迟相同
//---------------------------------------------------------------------------
wire        lut_we;
wire [7:0]  lut_wa;
wire [23:0] lut_wd;
color_lut_gen u_lut_gen(
    .clk      (clk),
    .rst      (rst),
    .start    (vs_d & ~vs_in),
    .bri      ({bri_lvl, 4'b0000}),
    .con      ({con_lvl, 4'b0000}),
    .temp_lvl (temp_lvl),
    .gam_lvl  (gam_lvl),
    .we       (lut_we),
    .waddr    (lut_wa),
    .wdata    (lut_wd),
    .busy     ()
);

(* ram_style = "bram" *) reg [7:0] lut_r [0:255];
(* ram_style = "bram" *) reg [7:0] lut_g [0:255];
(* ram_style = "bram" *) reg [7:0] lut_b [0:255];
integer li;
initial for (li = 0; li < 256; li = li + 1) begin lut_r[li] = li; lut_g[li] = li; lut_b[li] = li; end
reg [23:0] lq6, adj7;
always @(posedge clk) begin
    if (lut_we) begin
        lut_r[lut_wa] <= lut_wd[23:16];
        lut_g[lut_wa] <= lut_wd[15:8];
        lut_b[lut_wa] <= lut_wd[7:0];
    end
    lq6  <= {lut_r[mix5[23:16]], lut_g[mix5[15:8]], lut_b[mix5[7:0]]};
    adj7 <= lq6;
end

//---------------------------------------------------------------------------
// S8: OSD 叠加 (OSD 不受亮度/对比度影响)
//---------------------------------------------------------------------------
wire [7:0] dim_b = {2'b00, adj7[7:2]} + 8'd40;
wire [7:0] dim_m = {3'b000, adj7[7:3]} + 8'd32;
always @(posedge clk or posedge rst) begin
    if (rst) begin
        hs_out <= 1'b1; vs_out <= 1'b1; de_out <= 1'b0; rgb_out <= 24'd0;
    end else begin
        hs_out <= hs7;
        vs_out <= vs7;
        de_out <= de7;
        if (!de7)
            rgb_out <= 24'd0;
        else if (alm_f)                                     // 应急报警: 整屏报警画面
            rgb_out <= am7;
        else if (tbit7)
            rgb_out <= tcol7;
        else if (of7[4])                                    // 加载进度
            rgb_out <= 24'hFF9020;
        else if (of7[5] || of7[2] || of7[0])                // 分隔线 / 菜单边框
            rgb_out <= 24'h00B0FF;
        else if (wf7 != 3'd0)                               // 音频频谱
            rgb_out <= wcol7;
        else if (of7[1])                                    // 菜单底: 比信息栏更暗, 文字更清楚
            rgb_out <= {3'b000, adj7[23:19], 3'b000, adj7[15:11], dim_m};
        else if (of7[6] || of7[3])                          // 半透明底
            rgb_out <= {2'b00, adj7[23:18], 2'b00, adj7[15:10], dim_b};
        else
            rgb_out <= adj7;
    end
end

endmodule
