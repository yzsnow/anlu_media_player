//============================================================================
// HX4S20C HDMI 多媒体播放器 (选题1)
//
//  TF 卡 (FAT32) : *.BMP 640x400 24bit 图片 (最多 16 张; 640x480 自动居中裁成 640x400),
//                  *.WAV 背景音乐,
//                  *.TXT 滚动字幕, *.FNT 字幕用户字库
//  显示          : HDMI 1280x800@59.9Hz (16:10, 1920x1200 显示器等比放大 1.5 倍铺满无黑边),
//                  画面按 640x400 合成, video_scale2x 每个像素 2x2 复制放大
//                  上电即出开机画面 (无需等待 TF 卡), 首图加载完成后转场进入
//                  8 种转场特效, 顶部 OSD 信息栏 + 底部滚动字幕
//  音频          : WAV 线性插值重采样到 48kHz 经 HDMI 输出 / 内置旋律 (测试音)
//  按键          : KEY3 短按下一张, 长按上一张 (KEY1 / KEY3 功能互换, 见 u_player 连接)
//                  KEY2 短按自动轮播开关, 长按切换特效
//  拨码开关      : SW4 = 0 WAV 播放, SW4 = 1 测试音
//                  SW3 = 1 显示参数调节菜单 (画面模式 正常/日间/夜间/护眼, 亮度/对比度/色温/伽马, 音量),
//                  SW2 = 1 音频频谱 + 左右电平条
//  应急报警      : SW1 = 1 布防, KEY1 (模拟传感器) 按下 / 外接 MQ-2 烟雾 (J1-27, K16) / 火焰传感器 (J1-28, M16) 触发,
//                  锁存到 SW1 拨回 0; MQ-2 / 火焰 DO 均低有效 (内部上拉, 不接时无效), 漏桶滤波见 player_ctrl;
//                  抢占一切: 全屏报警画面 (硬切) + 警笛 (HDMI) + 蜂鸣器 (H11, 板上 SW5 使能)
//                  + 底部滚动应急疏散字幕, 数码管 "ALAr mm.ss"
//  数码管        : [序号][序号] [-] [总数][总数.] [状态机] [特效][音频]
//                  状态机 (官方框图): 1 空闲 / 2 搜索 BMP / 3 写入 SDRAM / 4 OSD 叠加 / E 错误
//  第二屏        : HDMI1 (J7) 1024x600@60Hz 运维终端 (term_top): 系统状态面板 + 事件日志 + 命令行
//                  4x4 轻触开关矩阵键盘 (kb_matrix4x4, A0~A3 = H16 H15 J16 K15, B0~B3 = G14 G16 F15 F14):
//                  A/B 选命令, 0~9 参数, * 退格, # 执行, C/D 上一张/下一张; 命令控制播放器 (换图/模式/亮度/音量/特效/轮播/报警)
//
//  时钟: clk 50M | sd_card_clk 100M | ext_mem_clk 125M | audio_mclk 12.288M
//        video_clk 18.75M (640x400 合成) | pix_clk 75M (HDMI 像素) | hdmi_5x_clk 375M
//        video_clk / pix_clk / hdmi_5x_clk 同一 PLL 输出, 同源同相 (1 : 4 : 20)
//        term_clk 50M / term_5x_clk 250M (第 4 个 PLL, 终端屏 HDMI1)
//============================================================================
module top(
    input                       clk,
    input                       rst_n,
    input                       key1,       // KEY1 (B2): 模拟传感器 (报警触发), 低有效
    input                       key2,
    input                       sw4,        // 拨码开关 SW4 (C5)
    input                       sw3,        // 拨码开关 SW3 (C6): 显示参数调节菜单
    input                       sw2,        // 拨码开关 SW2 (C7): 音频波形可视化
    input                       sw1,        // 拨码开关 SW1 (C8): 应急报警布防
    input                       key3,       // KEY3 (B1): 下一张 / 长按上一张; 参数菜单中为选项键
    input  [3:0]                kb_row,     // 4x4 矩阵键盘行 A0~A3 (内部上拉)
    output [3:0]                kb_col,     // 4x4 矩阵键盘列 B0~B3 (开漏扫描)
    input                       smoke_n,    // MQ-2 烟雾传感器 DO (J1-27, K16), 低有效
    input                       fire_in,    // 火焰传感器 DO (J1-28, M16), 低有效
    output                      buzzer,     // 蜂鸣器 (H11)

    output [7:0]                seg_sel,
    output [7:0]                seg_data,

    // HDMI TMDS
    output                      HDMI_CLK_P,
    output                      HDMI_D2_P,
    output                      HDMI_D1_P,
    output                      HDMI_D0_P,

    // HDMI1 (J7): 第二屏运维终端 1024x600, DVI
    output                      HDMI1_CLK_P,
    output                      HDMI1_D2_P,
    output                      HDMI1_D1_P,
    output                      HDMI1_D0_P,

    // HDMI DDC
    output                      HDMI_DDC_SCL,
    inout                       HDMI_DDC_SDA,

    // TF card SPI
    output                      sd_ncs,
    output                      sd_dclk,
    output                      sd_mosi,
    input                       sd_miso
);

localparam ADDR_BITS = 21;

wire sd_card_clk;
wire ext_mem_clk;
wire ext_mem_clk_sft;
wire video_clk;
wire pix_clk;
wire hdmi_5x_clk;
wire sys_pll_lock;
wire video_pll_lock;
wire audio_pll_lock;
wire audio_mclk;

//---------------------------------------------------------------------------
// 时钟 / 复位 (Flash 固化后上电自启的启动顺序):
//   配置完成 -> 三个 PLL 全部锁定 -> 各时钟域同步释放复位
//   -> SDRAM 初始化完成 -> TF 卡加载器开始扫描 (开机画面不依赖 SDRAM, 立即输出)
// PLL reset 接复位键: 按下时 PLL 重新锁定; 任一 PLL 失锁则整个系统保持复位
//---------------------------------------------------------------------------
sys_pll sys_pll_m0(
    .refclk     (clk),
    .reset      (~rst_n),
    .extlock    (sys_pll_lock),
    .clk0_out   (sd_card_clk),
    .clk1_out   (ext_mem_clk),
    .clk2_out   (ext_mem_clk_sft)
);

video_pll video_pll_m0(
    .refclk     (clk),
    .reset      (~rst_n),
    .extlock    (video_pll_lock),
    .clk0_out   (pix_clk),
    .clk1_out   (hdmi_5x_clk),
    .clk2_out   (video_clk)
);

PLL_HDMI_AUDIO u_audio_pll(
    .refclk     (clk),
    .reset      (~rst_n),
    .extlock    (audio_pll_lock),
    .clk0_out   (),
    .clk1_out   (),
    .clk2_out   (audio_mclk)
);

// 第二屏运维终端 (HDMI1 1024x600@60Hz): 50 MHz 像素 / 250 MHz 串行
wire term_clk, term_5x_clk, term_pll_lock;
term_pll u_term_pll(
    .refclk     (clk),
    .reset      (~rst_n),
    .extlock    (term_pll_lock),
    .clk0_out   (term_clk),
    .clk2_out   (term_5x_clk)
);

wire rst_all = ~rst_n | ~sys_pll_lock | ~video_pll_lock | ~audio_pll_lock | ~term_pll_lock;
wire rst_sd, rst_mem, rst_vid, rst_pix, rst_aud, rst_clk, rst_term;
reset_sync u_rst_term(.clk(term_clk), .arst(rst_all), .rst(rst_term));
reset_sync u_rst_sd (.clk(sd_card_clk), .arst(rst_all), .rst(rst_sd));
reset_sync u_rst_mem(.clk(ext_mem_clk), .arst(rst_all), .rst(rst_mem));
reset_sync u_rst_vid(.clk(video_clk),   .arst(rst_all), .rst(rst_vid));
reset_sync u_rst_pix(.clk(pix_clk),     .arst(rst_all), .rst(rst_pix));
reset_sync u_rst_aud(.clk(audio_mclk),  .arst(rst_all), .rst(rst_aud));
reset_sync u_rst_clk(.clk(clk),         .arst(~rst_n),  .rst(rst_clk));   // 数码管扫描, 不依赖 PLL

//---------------------------------------------------------------------------
// 信号
//---------------------------------------------------------------------------
// SDRAM
wire                 Sdr_init_done;
wire                 Sdr_init_ref_vld;
wire                 Sdr_busy;
wire                 App_rd_en;
wire [ADDR_BITS-1:0] App_rd_addr;
wire                 Sdr_rd_en;
wire [31:0]          Sdr_rd_dout;
wire                 App_wr_en;
wire [ADDR_BITS-1:0] App_wr_addr;
wire [31:0]          App_wr_din;
wire [3:0]           App_wr_dm;

// 帧写入 (sd_card_clk)
wire                 fw_req;
wire                 fw_req_ack;
wire [ADDR_BITS-1:0] fw_addr;
wire                 fw_en;
wire [31:0]          fw_data;
wire                 fw_afull;
wire                 fw_vflip;
wire                 fw_finish;
reg                  fw_finish_toggle;

// 播放器 <-> 加载器
wire        req_toggle;
wire [3:0]  req_img;
wire [2:0]  cur_slot;
wire        ack_toggle;
wire [2:0]  ack_slot;
wire        ack_ok;
wire [3:0]  ack_img;
wire [7:0]  ack_dur;

// WAV
localparam  WAV_AW = 13;            // WAV FIFO 8192 样本, 48kHz 下约 170 ms
wire        wav_we;
wire [31:0] wav_wdata;
wire [WAV_AW:0] wav_level;
wire        wav_rd;
wire [31:0] wav_rdata;
wire        wav_empty;
wire [WAV_AW:0] wav_rd_level;     // audio_mclk 域数据量, 播放器预缓冲/欠载判定
wire [3:0]  vu;
wire        aud_xrun;

// 文本 / 字库
wire        txt_we;
wire [9:0]  txt_waddr;
wire [7:0]  txt_wdata;
wire        fnt_we;
wire [10:0] fnt_waddr;
wire [7:0]  fnt_wdata;

// 加载器状态 (sd 域)
wire [2:0]  ld_status;
wire [4:0]  ld_img_count;
wire [3:0]  ld_load_img;
wire [7:0]  ld_load_prog;
wire        ld_loading;
wire        ld_wav_ok;
wire [2:0]  ld_rate_code;
wire [16:0] ld_wav_rate;
wire [9:0]  ld_txt_len;
wire        ld_txt_ok;
wire        ld_fnt_ok;

//---------------------------------------------------------------------------
// TF 卡媒体加载器
// SDRAM 初始化完成 (ext_mem_clk 域) 同步到 sd_card_clk 后才释放加载器复位,
// 避免冷启动时 SDRAM 尚未初始化就写入首图
//---------------------------------------------------------------------------
wire sdr_init_done_sd;
reg  rst_ld;
sync_2ff u_sdr_init_sync(
    .clk      (sd_card_clk),
    .rst_n    (~rst_sd),
    .async_in (Sdr_init_done),
    .sync_out (sdr_init_done_sd)
);
always @(posedge sd_card_clk or posedge rst_sd) begin
    if (rst_sd) rst_ld <= 1'b1;
    else        rst_ld <= ~sdr_init_done_sd;
end

sd_media_loader #(
    .CLK_HZ  (100_000_000),
    .MAX_IMG (16),
    .NSLOT   (6),
    .WAV_AW  (WAV_AW)
) u_loader (
    .clk                 (sd_card_clk),
    .rst                 (rst_ld),
    .SD_nCS              (sd_ncs),
    .SD_DCLK             (sd_dclk),
    .SD_MOSI             (sd_mosi),
    .SD_MISO             (sd_miso),
    .write_req           (fw_req),
    .write_req_ack       (fw_req_ack),
    .write_addr          (fw_addr),
    .write_en            (fw_en),
    .write_data          (fw_data),
    .write_afull         (fw_afull),
    .write_vflip         (fw_vflip),
    .write_finish_toggle (fw_finish_toggle),
    .req_toggle          (req_toggle),
    .req_img             (req_img),
    .cur_slot            (cur_slot),
    .ack_toggle          (ack_toggle),
    .ack_slot            (ack_slot),
    .ack_ok              (ack_ok),
    .ack_img             (ack_img),
    .ack_dur             (ack_dur),
    .wav_we              (wav_we),
    .wav_wdata           (wav_wdata),
    .wav_level           (wav_level),
    .txt_we              (txt_we),
    .txt_waddr           (txt_waddr),
    .txt_wdata           (txt_wdata),
    .fnt_we              (fnt_we),
    .fnt_waddr           (fnt_waddr),
    .fnt_wdata           (fnt_wdata),
    .status              (ld_status),
    .img_count           (ld_img_count),
    .load_img            (ld_load_img),
    .load_prog           (ld_load_prog),
    .loading             (ld_loading),
    .wav_ok              (ld_wav_ok),
    .wav_rate_code       (ld_rate_code),
    .wav_rate            (ld_wav_rate),
    .txt_len             (ld_txt_len),
    .txt_ok              (ld_txt_ok),
    .fnt_ok              (ld_fnt_ok)
);

// mem_clk 域把 write_finish 单拍转成 toggle, 供 sd_card_clk 域同步
always @(posedge ext_mem_clk or posedge rst_mem) begin
    if (rst_mem)
        fw_finish_toggle <= 1'b0;
    else if (fw_finish)
        fw_finish_toggle <= ~fw_finish_toggle;
end

// WAV 样本 FIFO: sd_card_clk -> audio_mclk, 8192 x {L16,R16}, 放在 8 个 BRAM32K (原本空闲)
async_fifo #(
    .DW        (32),
    .AW        (WAV_AW),
    .RAM_STYLE ("bram_32k")
) u_wav_fifo (
    .wr_clk   (sd_card_clk),
    .wr_rst   (rst_sd),
    .wr_en    (wav_we),
    .wr_data  (wav_wdata),
    .wr_level (wav_level),
    .rd_clk   (audio_mclk),
    .rd_rst   (rst_aud),
    .rd_en    (wav_rd),
    .rd_data  (wav_rdata),
    .rd_empty (wav_empty),
    .rd_level (wav_rd_level)
);

//---------------------------------------------------------------------------
// 加载器状态同步到 video_clk (连续两拍相同才更新, 避免多比特跳变)
//---------------------------------------------------------------------------
localparam SW = 3 + 5 + 4 + 8 + 1 + 3 + 1 + 10 + 1 + 1;
wire [SW-1:0] st_sd = {ld_status, ld_img_count, ld_load_img, ld_load_prog, ld_wav_ok,
                       ld_rate_code, ld_txt_ok, ld_txt_len, ld_fnt_ok, ld_loading};
reg  [SW-1:0] st_s0, st_s1, st_v;
always @(posedge video_clk or posedge rst_vid) begin
    if (rst_vid) begin
        st_s0 <= {SW{1'b0}}; st_s1 <= {SW{1'b0}}; st_v <= {SW{1'b0}};
    end else begin
        st_s0 <= st_sd;
        st_s1 <= st_s0;
        if (st_s1 == st_s0) st_v <= st_s1;
    end
end
wire [2:0]  v_status, v_rate_code;
wire [4:0]  v_img_count;
wire [3:0]  v_load_img;
wire [7:0]  v_load_prog;
wire        v_wav_ok, v_txt_ok, v_fnt_ok, v_loading;
wire [9:0]  v_txt_len;
assign {v_status, v_img_count, v_load_img, v_load_prog, v_wav_ok,
        v_rate_code, v_txt_ok, v_txt_len, v_fnt_ok, v_loading} = st_v;

//---------------------------------------------------------------------------
// 视频时序 + 播放控制 + 合成
//---------------------------------------------------------------------------
wire        video_read_req;
wire        video_read_req_ack;
wire        hs_0, vs_0, de_0;
wire        read_en_a, read_en_b;
wire [31:0] read_data_a, read_data_b;
wire        frame_end;

wire [20:0] base_a, base_b;
wire        b_en;
wire [8:0]  tp;
wire [2:0]  eff_now;
wire [3:0]  eff_sel;
wire        auto_on;
wire [1:0]  amode;
wire        menu_on;
wire [2:0]  menu_sel;
wire [1:0]  pmode;
wire [4:0]  bri_lvl, con_lvl, vol_lvl, temp_lvl, gam_lvl;
wire        wave_on;
wire        alarm_on;               // 应急报警 (video_clk)
wire        term_cmd_tgl;           // 第二屏终端命令 (term_clk 域 toggle + 保持的 op/arg, player_ctrl 内同步)
wire [3:0]  term_cmd_op;
wire [4:0]  term_cmd_arg;
wire [15:0] alm_bcd;                // 报警持续时间 mm:ss
wire [1:0]  alm_src;                // 报警来源 0 KEY1 1 烟雾 2 火焰 3 终端命令
wire        preheat;                // MQ-2 预热中
reg         aud_tgl;                // 音频样本 (pix_clk 域锁存) -> 合成器波形显示
reg  [15:0] aud_l_h, aud_r_h;
wire        splash_on;
wire        bar_on;
wire        waiting;
wire        msg_bad;
wire [3:0]  cur_img;

wire        hs, vs, de;             // 合成器输出 640x400 (video_clk)
wire [23:0] vout_data;
wire        hs_p, vs_p, de_p;       // 放大后 1280x800 (pix_clk)
wire [23:0] rgb_p;

video_timing_data video_timing_data_m0(
    .video_clk         (video_clk),
    .rst               (rst_vid),
    .read_req          (video_read_req),
    .read_req_ack      (video_read_req_ack),
    .hs                (hs_0),
    .vs                (vs_0),
    .de                (de_0)
);

player_ctrl #(
    .CLK_HZ     (18_750_000)
) u_player(
    .clk        (video_clk),
    .rst        (rst_vid),
    .key1_n     (key3),     // 翻页 / 菜单选项键 = 板上 KEY3
    .key2_n     (key2),
    .sw4        (sw4),
    .sw3        (sw3),
    .sw2        (sw2),
    .sw1        (sw1),
    .key3_n     (key1),     // 传感器 (报警触发) = 板上 KEY1
    .smoke_n    (smoke_n),
    .fire_in    (fire_in),
    .term_tgl   (term_cmd_tgl),
    .term_op    (term_cmd_op),
    .term_arg   (term_cmd_arg),
    .frame_end  (frame_end),
    .ld_status  (v_status),
    .img_count  (v_img_count),
    .req_toggle (req_toggle),
    .req_img    (req_img),
    .cur_slot   (cur_slot),
    .ack_toggle (ack_toggle),
    .ack_slot   (ack_slot),
    .ack_ok     (ack_ok),
    .ack_img    (ack_img),
    .ack_dur    (ack_dur),
    .base_a     (base_a),
    .base_b     (base_b),
    .b_en       (b_en),
    .p          (tp),
    .eff_now    (eff_now),
    .eff_sel    (eff_sel),
    .auto_on    (auto_on),
    .amode      (amode),
    .splash_on  (splash_on),
    .bar_on     (bar_on),
    .waiting    (waiting),
    .msg_bad    (msg_bad),
    .cur_img    (cur_img),
    .menu_on    (menu_on),
    .menu_sel   (menu_sel),
    .pmode      (pmode),
    .bri_lvl    (bri_lvl),
    .con_lvl    (con_lvl),
    .temp_lvl   (temp_lvl),
    .gam_lvl    (gam_lvl),
    .vol_lvl    (vol_lvl),
    .wave_on    (wave_on),
    .alarm_on   (alarm_on),
    .alm_bcd    (alm_bcd),
    .alm_src    (alm_src),
    .preheat    (preheat)
);

video_compositor u_compositor(
    .clk        (video_clk),
    .rst        (rst_vid),
    .hs_in      (hs_0),
    .vs_in      (vs_0),
    .de_in      (de_0),
    .read_en_a  (read_en_a),
    .data_a     (read_data_a),
    .read_en_b  (read_en_b),
    .data_b     (read_data_b),
    .splash_on  (splash_on),
    .bar_on     (bar_on),
    .auto_on    (auto_on),
    .waiting    (waiting),
    .msg_bad    (msg_bad),
    .cur_img    (cur_img),
    .eff_sel    (eff_sel),
    .eff_now    (eff_now),
    .p          (tp),
    .b_en       (b_en),
    .amode      (amode),
    .menu_on    (menu_on),
    .menu_sel   (menu_sel),
    .pmode      (pmode),
    .bri_lvl    (bri_lvl),
    .con_lvl    (con_lvl),
    .temp_lvl   (temp_lvl),
    .gam_lvl    (gam_lvl),
    .vol_lvl    (vol_lvl),
    .wave_on    (wave_on),
    .aud_tgl    (aud_tgl),
    .aud_l      (aud_l_h),
    .aud_r      (aud_r_h),
    .alarm_on   (alarm_on),
    .alm_bcd    (alm_bcd),
    .alm_src    (alm_src),
    .ld_status  (v_status),
    .img_count  (v_img_count),
    .load_img   (v_load_img),
    .load_prog  (v_load_prog),
    .wav_ok     (v_wav_ok),
    .rate_code  (v_rate_code),
    .txt_ok     (v_txt_ok),
    .txt_len    (v_txt_len),
    .wclk       (sd_card_clk),
    .txt_we     (txt_we),
    .txt_waddr  (txt_waddr),
    .txt_wdata  (txt_wdata),
    .fnt_we     (fnt_we),
    .fnt_waddr  (fnt_waddr),
    .fnt_wdata  (fnt_wdata),
    .fnt_ok     (v_fnt_ok),
    .frame_end  (frame_end),
    .hs_out     (hs),
    .vs_out     (vs),
    .de_out     (de),
    .rgb_out    (vout_data)
);

// 640x400 -> 1280x800 (2x2 像素复制)
video_scale2x u_scale2x(
    .clk_s  (video_clk),
    .rst_s  (rst_vid),
    .vs_s   (vs),
    .de_s   (de),
    .rgb_s  (vout_data),
    .clk_f  (pix_clk),
    .rst_f  (rst_pix),
    .hs_f   (hs_p),
    .vs_f   (vs_p),
    .de_f   (de_p),
    .rgb_f  (rgb_p)
);

//---------------------------------------------------------------------------
// SDRAM 帧缓存: 1 写 (TF) + 2 读 (A/B)
//---------------------------------------------------------------------------
frame_dual_read_write #(
    .ADDR_BITS  (ADDR_BITS),
    .BURST_SIZE (256),
    .FRAME_LEN  (256000),
    .FRAME_H    (400)
) u_frame_rw (
    .rst              (rst_mem),
    .mem_clk          (ext_mem_clk),
    .Sdr_init_done    (Sdr_init_done),
    .Sdr_init_ref_vld (Sdr_init_ref_vld),
    .Sdr_busy         (Sdr_busy),
    .App_rd_en        (App_rd_en),
    .App_rd_addr      (App_rd_addr),
    .Sdr_rd_en        (Sdr_rd_en),
    .Sdr_rd_dout      (Sdr_rd_dout),
    .App_wr_en        (App_wr_en),
    .App_wr_addr      (App_wr_addr),
    .App_wr_din       (App_wr_din),
    .App_wr_dm        (App_wr_dm),
    .read_clk         (video_clk),
    .read_req         (video_read_req),
    .read_req_ack     (video_read_req_ack),
    .base_a           (base_a),
    .base_b           (base_b),
    .b_en             (b_en),
    .read_en_a        (read_en_a),
    .read_data_a      (read_data_a),
    .read_en_b        (read_en_b),
    .read_data_b      (read_data_b),
    .write_clk        (sd_card_clk),
    .write_req        (fw_req),
    .write_req_ack    (fw_req_ack),
    .write_finish     (fw_finish),
    .write_addr       (fw_addr),
    .write_en         (fw_en),
    .write_data       (fw_data),
    .write_afull      (fw_afull),
    .write_vflip      (fw_vflip)
);

sdram U3(
    .Clk               (ext_mem_clk),
    .Clk_sft           (ext_mem_clk_sft),
    .Rst               (rst_mem),
    .Sdr_init_done     (Sdr_init_done),
    .Sdr_init_ref_vld  (Sdr_init_ref_vld),
    .Sdr_busy          (Sdr_busy),
    .App_wr_en         (App_wr_en),
    .App_wr_addr       (App_wr_addr),
    .App_wr_dm         (App_wr_dm),
    .App_wr_din        (App_wr_din),
    .App_rd_en         (App_rd_en),
    .App_rd_addr       (App_rd_addr),
    .Sdr_rd_en         (Sdr_rd_en),
    .Sdr_rd_dout       (Sdr_rd_dout)
);

//---------------------------------------------------------------------------
// 数码管 (8 位, 从左到右按阅读顺序, 各项分开)
//   播放:  [序号十][序号个] [-] [总数十][总数个.轮播] [ ] [特效][音频.欠载]   例 "03-12 5≡"
//   开机:  [-][-] [ ] [总数十][总数个] [ ][ ] [卡状态.]                     例 "-- 05  2."
// 音频电平用横杠条表示 (_ = ≡), 与数字区分开
//   报警:  [A][L][A][r] [分十][分个.] [秒十][秒个]                          例 "ALAr01.25"
//---------------------------------------------------------------------------
function [7:0] seg7;      // {dp, g..a}, 低有效
    input [4:0] v;        // 0~15 十六进制, 16 '-', 17 灭, 18 'A', 19 'P', 20 'n', 21~23 电平条 _ = ≡, 24 'L', 25 'r'
    input       dp;
    reg   [6:0] s;
    begin
        case (v)
            5'd0:  s = 7'b100_0000;  5'd1:  s = 7'b111_1001;
            5'd2:  s = 7'b010_0100;  5'd3:  s = 7'b011_0000;
            5'd4:  s = 7'b001_1001;  5'd5:  s = 7'b001_0010;
            5'd6:  s = 7'b000_0010;  5'd7:  s = 7'b111_1000;
            5'd8:  s = 7'b000_0000;  5'd9:  s = 7'b001_0000;
            5'd10: s = 7'b000_1000;  5'd11: s = 7'b000_0011;
            5'd12: s = 7'b100_0110;  5'd13: s = 7'b010_0001;
            5'd14: s = 7'b000_0110;  5'd15: s = 7'b000_1110;
            5'd16: s = 7'b011_1111;
            5'd18: s = 7'b000_1000;
            5'd19: s = 7'b000_1100;
            5'd20: s = 7'b010_1011;
            5'd21: s = 7'b111_0111;     // d
            5'd22: s = 7'b011_0111;     // d g
            5'd23: s = 7'b011_0110;     // d g a
            5'd24: s = 7'b100_0111;     // L
            5'd25: s = 7'b010_1111;     // r
            default: s = 7'b111_1111;
        endcase
        seg7 = {~dp, s};
    end
endfunction

wire [4:0] idx1  = {1'b0, cur_img} + 5'd1;
wire [4:0] idx_t = (idx1 >= 5'd10) ? 5'd1 : 5'd0;
wire [4:0] idx_o = (idx1 >= 5'd10) ? idx1 - 5'd10 : idx1;
wire [4:0] tot_t = (v_img_count >= 5'd10) ? 5'd1 : 5'd0;
wire [4:0] tot_o = (v_img_count >= 5'd10) ? v_img_count - 5'd10 : v_img_count;
wire [4:0] eff_d = (eff_sel >= 4'd8) ? 5'd18 : {1'b0, eff_sel};
// 官方框图状态机 (赛题解析 slide 18): 1 空闲 / 2 搜索 BMP / 3 写入 SDRAM / 4 OSD 叠加; E = 卡/文件系统/无图错误
//   2: 初始化 TF 卡、扫描 FAT32 目录;  3: 加载器正在把图片写入 SDRAM 帧槽 (含后台预取);
//   4: 菜单 / 顶部信息栏 / 转场叠加中;  优先级 2 > E > 3 > 4 > 1
wire [4:0] fsm_d = (v_status == 3'd0 || v_status == 3'd1) ? 5'd2 :
                   (v_status != 3'd2)                       ? 5'd14 :
                   v_loading                                ? 5'd3 :
                   (menu_on | bar_on | b_en)                ? 5'd4 : 5'd1;
// 音频位: WAV 模式显示电平条 (_ 弱, = 中, ≡ 强), 旋律模式 'P', 静音 'n'; 小数点亮 = WAV 欠载 (TF 卡供数不及)
wire [4:0] vu_bar = (vu >= 4'd13) ? 5'd23 : (vu >= 4'd5) ? 5'd22 : 5'd21;
wire [4:0] aud_d  = (amode == 2'd0) ? vu_bar : (amode == 2'd1) ? 5'd19 : 5'd20;
reg  [1:0] xrun_s;

// seg_d7 = 最左位 ... seg_d0 = 最右位
reg [7:0] seg_d7, seg_d6, seg_d5, seg_d4, seg_d3, seg_d2, seg_d1, seg_d0;
always @(posedge video_clk) begin
    xrun_s <= {xrun_s[0], aud_xrun};
    if (alarm_on) begin
        // 报警: "ALAr01.25" (持续 1 分 25 秒)
        seg_d7 <= seg7(5'd18, 1'b0);
        seg_d6 <= seg7(5'd24, 1'b0);
        seg_d5 <= seg7(5'd18, 1'b0);
        seg_d4 <= seg7(5'd25, 1'b0);
        seg_d3 <= seg7({1'b0, alm_bcd[15:12]}, 1'b0);
        seg_d2 <= seg7({1'b0, alm_bcd[11:8]}, 1'b1);
        seg_d1 <= seg7({1'b0, alm_bcd[7:4]}, 1'b0);
        seg_d0 <= seg7({1'b0, alm_bcd[3:0]}, 1'b0);
    end else if (splash_on) begin
        // 开机: "-- 05 3 2."  (尚无当前图, 总数, 状态机, 卡状态)
        seg_d7 <= seg7(5'd16, 1'b0);
        seg_d6 <= seg7(5'd16, 1'b0);
        seg_d5 <= seg7(5'd17, 1'b0);
        seg_d4 <= seg7(tot_t, 1'b0);
        seg_d3 <= seg7(tot_o, 1'b0);
        seg_d2 <= seg7(fsm_d, 1'b0);
        seg_d1 <= seg7(5'd17, 1'b0);
        seg_d0 <= seg7({2'b00, v_status}, 1'b1);
    end else begin
        // 播放: "03-12 1 5≡"  (第 3 张 / 共 12 张, 状态机, 特效 5, 音频电平)
        seg_d7 <= seg7(idx_t, 1'b0);
        seg_d6 <= seg7(idx_o, 1'b0);
        seg_d5 <= seg7(5'd16, 1'b0);
        seg_d4 <= seg7(tot_t, 1'b0);
        seg_d3 <= seg7(tot_o, auto_on);
        seg_d2 <= seg7(fsm_d, 1'b0);
        seg_d1 <= seg7(eff_d, 1'b0);
        seg_d0 <= seg7(aud_d, xrun_s[1]);
    end
end

seg_scan8 seg_scan_m0(
    .clk               (clk),
    .rst_n             (~rst_clk),
    .seg_sel           (seg_sel),
    .seg_data          (seg_data),
    .seg_data_0        (seg_d0),
    .seg_data_1        (seg_d1),
    .seg_data_2        (seg_d2),
    .seg_data_3        (seg_d3),
    .seg_data_4        (seg_d4),
    .seg_data_5        (seg_d5),
    .seg_data_6        (seg_d6),
    .seg_data_7        (seg_d7)
);

//---------------------------------------------------------------------------
// 音频: WAV / 旋律 -> I2S -> HDMI 音频包
//---------------------------------------------------------------------------
wire        audio_i2s_bclk;
wire        audio_i2s_lrck;
wire        audio_i2s_dout;
wire        audio_valid;
wire [23:0] audio_left_data;
wire [23:0] audio_right_data;
wire        acr_valid;
wire [19:0] acr_cts;
wire [19:0] acr_n;

audio_i2s_player #(.AW(WAV_AW)) u_audio(
    .I_mclk     (audio_mclk),
    .I_rst      (rst_aud),
    .amode      (amode),
    .wav_ok     (ld_wav_ok),
    .wav_rate   (ld_wav_rate),
    .vol_lvl    (vol_lvl),
    .fifo_rd    (wav_rd),
    .fifo_data  (wav_rdata),
    .fifo_empty (wav_empty),
    .fifo_level (wav_rd_level),
    .vu         (vu),
    .xrun       (aud_xrun),
    .buzz       (buzzer),
    .O_i2s_BCLK (audio_i2s_bclk),
    .O_i2s_LRCK (audio_i2s_lrck),
    .O_i2s_DOUT (audio_i2s_dout)
);

// I2S 接收与 ACR (CTS = 每 N/128 个音频样本内的像素时钟数) 必须在 HDMI 像素时钟域
I2S_receiver u_I2S_receiver(
    .I_clk              (pix_clk),
    .I_rst              (rst_pix),
    .I_i2s_BCLK         (audio_i2s_bclk),
    .I_i2s_LRCK         (audio_i2s_lrck),
    .I_i2s_DOUT         (audio_i2s_dout),
    .O_audio_valid      (audio_valid),
    .O_audio_left_data  (audio_left_data),
    .O_audio_right_data (audio_right_data)
);

// 波形显示取 HDMI 实际输出的样本 (含音量): 锁存高 16 位并翻转 aud_tgl,
// 合成器 (video_clk = pix_clk/4, 同源) 检测翻转后取用, 样本保持 1/48k s
always @(posedge pix_clk or posedge rst_pix) begin
    if (rst_pix) begin
        aud_tgl <= 1'b0; aud_l_h <= 16'd0; aud_r_h <= 16'd0;
    end else if (audio_valid) begin
        aud_tgl <= ~aud_tgl;
        aud_l_h <= audio_left_data[23:8];
        aud_r_h <= audio_right_data[23:8];
    end
end

audio_arc_calculate #(
    .ACR_N         (6144)
) u_audio_arc_calculate (
    .I_clk         (pix_clk),
    .I_rst         (rst_pix),
    .I_audio_valid (audio_valid),
    .O_acr_valid   (acr_valid),
    .O_acr_cts     (acr_cts),
    .O_acr_n       (acr_n)
);

//---------------------------------------------------------------------------
// RGB/DE -> AXIS -> HDMI 1.4b (视频 + 音频)
//---------------------------------------------------------------------------
wire        axis_s_user;
wire        axis_s_valid;
wire        axis_s_last;
wire [23:0] axis_s_data;
wire        axis_s_ready;
wire        edid_trig;
wire        edid_valid;
wire [7:0]  edid_data;
wire [9:0]  tmds_ch0_data;
wire [9:0]  tmds_ch1_data;
wire [9:0]  tmds_ch2_data;
wire [9:0]  tmds_clk_data;

video_rgb_to_axis_640x480 #(
    .H_ACTIVE      (11'd1280)
) u_video_rgb_to_axis_640x480(
    .I_clk         (pix_clk),
    .I_rst         (rst_pix),
    .I_vs          (vs_p),
    .I_de          (de_p),
    .I_rgb         (rgb_p),
    .O_video_user  (axis_s_user),
    .O_video_valid (axis_s_valid),
    .O_video_last  (axis_s_last),
    .O_video_data  (axis_s_data)
);

startup_pulse #(
    .CNT_MAX(20'd100000)
) u_startup_pulse (
    .I_clk   (pix_clk),
    .I_rst   (rst_pix),
    .O_pulse (edid_trig)
);

hdmi_1_4b_transmitter_core_wrapper #(
    .DEVICE                 ( "EG"       ),
    // 1280x800 (与 video_scale2x 一致); 非 CEA 格式, AVI InfoFrame 的 VIC 填 0
    .HTOTAL                 ( 1520       ),
    .HSA                    ( 32         ),
    .HFP                    ( 48         ),
    .HBP                    ( 160        ),
    .HACTIVE                ( 1280       ),
    .VTOTAL                 ( 824        ),
    .VSA                    ( 6          ),
    .VFP                    ( 3          ),
    .VBP                    ( 15         ),
    .VACTIVE                ( 800        ),
    .VIDEO_VIC              ( 0          ),
    .VIDEO_TPG              ( "Disable"  ),
    .VIDEO_FORMAT           ( "RGB"      ),
    .AUDIO_SAMPLE_RATE      ( "48K"      ),
    .IIC_SCL_DIV            ( 250        )
) u_hdmi_1_4b_transmitter_core_wrapper(
    .I_pixel_clk        (pix_clk),
    .I_rst              (rst_pix),
    .I_edid_read_trig   (edid_trig),
    .O_edid_read_valid  (edid_valid),
    .O_edid_read_data   (edid_data),

    .I_axis_s_user      (axis_s_user),
    .I_axis_s_valid     (axis_s_valid),
    .I_axis_s_last      (axis_s_last),
    .I_axis_s_data      (axis_s_data),
    .O_axis_s_ready     (axis_s_ready),

    .I_audio_valid      (audio_valid),
    .I_audio_left_data  (audio_left_data),
    .I_audio_right_data (audio_right_data),
    .I_acr_valid        (acr_valid),
    .I_acr_cts          (acr_cts),
    .I_acr_n            (acr_n),

    .O_video_locked     (),
    .O_ddc_scl          (HDMI_DDC_SCL),
    .IO_ddc_sda         (HDMI_DDC_SDA),

    .O_ch0_tmds_data    (tmds_ch0_data),
    .O_ch1_tmds_data    (tmds_ch1_data),
    .O_ch2_tmds_data    (tmds_ch2_data),
    .O_clk_tmds_data    (tmds_clk_data)
);

hdmi_phy_wrapper #(
    .DEVICE ( "EG" )
) u_hdmi2phy_wrapper(
    .I_pixel_clk        (pix_clk),
    .I_serial_clk       (hdmi_5x_clk),
    .I_rst              (rst_pix),
    .I_tmds_channel_0   (tmds_ch0_data),
    .I_tmds_channel_1   (tmds_ch1_data),
    .I_tmds_channel_2   (tmds_ch2_data),
    .I_tmds_channel_clk (tmds_clk_data),
    .O_tmds_ch0_p       (HDMI_D0_P),
    .O_tmds_ch1_p       (HDMI_D1_P),
    .O_tmds_ch2_p       (HDMI_D2_P),
    .O_tmds_clk_p       (HDMI_CLK_P)
);

//---------------------------------------------------------------------------
// 第二屏运维终端: 状态在 video_clk 域整组采样 (toggle 握手), 事件写日志; 键盘接口预留 (接 0)
//   状态机编码 0 空闲 / 1 搜索 BMP / 2 写入 SDRAM / 3 OSD 叠加 / 4 错误 (与数码管 fsm_d 同一判定)
//---------------------------------------------------------------------------
wire [2:0] term_fsm = (fsm_d == 5'd2) ? 3'd1 : (fsm_d == 5'd14) ? 3'd4 : (fsm_d == 5'd3) ? 3'd2 :
                      (fsm_d == 5'd4) ? 3'd3 : 3'd0;
wire [9:0] term_t0, term_t1, term_t2;
wire       kb_vld;
wire [7:0] kb_ascii;
kb_matrix4x4 u_kb(
    .clk        (term_clk),
    .rst        (rst_term),
    .row        (kb_row),
    .col        (kb_col),
    .kb_vld     (kb_vld),
    .kb_ascii   (kb_ascii)
);
term_top u_term(
    .clk        (term_clk),
    .rst        (rst_term),
    .src_clk    (video_clk),
    .src_rst    (rst_vid),
    .st         (v_status),
    .img_cnt    (v_img_count),
    .wav_ok     (v_wav_ok),
    .txt_ok     (v_txt_ok),
    .fnt_ok     (v_fnt_ok),
    .load_prog  (v_load_prog),
    .cur_img    (cur_img),
    .eff_sel    (eff_sel),
    .auto_on    (auto_on),
    .amode      (amode),
    .menu_on    (menu_on),
    .pmode      (pmode),
    .bri        (bri_lvl),
    .con        (con_lvl),
    .temp       (temp_lvl),
    .gam        (gam_lvl),
    .vol        (vol_lvl),
    .wave_on    (wave_on),
    .alarm_on   (alarm_on),
    .alm_src    (alm_src),
    .preheat    (preheat),
    .vu         (vu),
    .msg_bad    (msg_bad),
    .fsm        (term_fsm),
    .rate       (v_rate_code),
    .sw         ({sw4, sw3, sw2, sw1}),
    .kb_vld     (kb_vld),
    .kb_ascii   (kb_ascii),
    .o_de       (),
    .o_hs       (),
    .o_vs       (),
    .o_rgb      (),
    .tmds0      (term_t0),
    .tmds1      (term_t1),
    .tmds2      (term_t2),
    .cmd_tgl    (term_cmd_tgl),
    .cmd_op     (term_cmd_op),
    .cmd_arg    (term_cmd_arg)
);

// 串行输出复用主屏的 hdmi_phy_wrapper (lane_lvds_10_1 x 4, ODDR), 时钟通道 0000011111
hdmi_phy_wrapper #(
    .DEVICE ( "EG" )
) u_term_phy(
    .I_pixel_clk        (term_clk),
    .I_serial_clk       (term_5x_clk),
    .I_rst              (rst_term),
    .I_tmds_channel_0   (term_t0),
    .I_tmds_channel_1   (term_t1),
    .I_tmds_channel_2   (term_t2),
    .I_tmds_channel_clk (10'b0000011111),
    .O_tmds_ch0_p       (HDMI1_D0_P),
    .O_tmds_ch1_p       (HDMI1_D1_P),
    .O_tmds_ch2_p       (HDMI1_D2_P),
    .O_tmds_clk_p       (HDMI1_CLK_P)
);

endmodule
