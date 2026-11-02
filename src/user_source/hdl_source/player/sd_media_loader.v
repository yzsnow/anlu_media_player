`timescale 1ns/1ps
//============================================================================
// sd_media_loader
//  TF 卡 FAT32 媒体加载器 (sd_card_clk = 100MHz 域)
//
//  1. 上电初始化 TF 卡 (超时自动复位重试, 支持热插拔后重新扫描);
//     单扇区读超时先复位控制器并重读该扇区 (最多 2 次, 不丢失播放位置), 仍失败才按拔卡处理
//     空闲心跳: 连续 0.5 s 没有读卡 (图片全部命中缓存且 WAV 不消耗, 如测试音模式) 时读一次
//     分区引导扇区并核对卷序列号 -> 拔卡 / 换卡在空闲时也能发现; 控制器重新初始化后也做一次核对,
//     序列号不同 (换了卡) 就重新扫描
//  2. 解析 MBR/DBR -> FAT32 根目录, 按目录顺序收集:
//       *.BMP  (任意分辨率 16~4096, 24/32bit 非压缩, 最多 MAX_IMG 张) -> 图片列表
//              加载时由 bmp_fit_scaler 等比缩放 (最近邻) 到 640x400, 上下或左右补黑边居中
//       第一个 *.WAV                             -> 背景音乐 (循环播放)
//       第一个 *.TXT                             -> OSD 滚动字幕 (前 512 字节)
//       第一个 *.FNT                             -> 字幕用户字库 (2048 字节)
//     分类文件夹 (根目录下, 有则优先, 没有则用根目录中的文件, 旧卡照常使用):
//       IMG\   图片   MUSIC\   背景音乐   SUB\   字幕 / 字库
//     播放列表 PLAY.CFG (根目录, 文本, 可选): 每行 "图片编号 显示秒数", 如 "03 5" 或 "IMG03.BMP 5",
//       编号对应 IMGnn.BMP 文件名中的数字 (1~16); 行内 '#' 之后为注释; 秒数省略或 0 = 默认 (4 s).
//       有播放列表时, 图片按列表顺序排成播放位置 0..N-1 (名字 RAM / 帧槽 / 预取都按位置),
//       播放器与 OSD 不用改; 列表中找不到的图片按损坏处理 (自动跳过); 每张的秒数随应答 ack_dur 送给播放器
//  3. SDRAM 中开 NSLOT 个帧槽做图片缓存 (每张 640x400, 槽间距仍按 307200 字):
//       以播放器当前请求的图片 focus 为中心预取 {f, f+1, f+2, f-1, f+3, f+4},
//       命中则立即应答, 实现按键切换"零等待"
//  4. WAV 流: 解析 RIFF 块, 8/16bit、单/双声道统一转成 {L16,R16} 写入异步 FIFO,
//       FIFO 余量低于 5/8 时优先连续读取 WAV 扇区, 直到接近满 (滞回),
//       其余带宽给图片加载
//
//  逐字节流式解析, 不需要扇区缓存
//============================================================================
module sd_media_loader #(
    parameter integer CLK_HZ  = 100_000_000,
    parameter integer MAX_IMG = 16,
    parameter integer NSLOT   = 6,
    parameter integer WAV_AW  = 13          // WAV FIFO 深度 2^WAV_AW
)(
    input             clk,
    input             rst,
    // TF card SPI
    output            SD_nCS,
    output            SD_DCLK,
    output            SD_MOSI,
    input             SD_MISO,
    // 帧写入 (frame_fifo_write, write_clk = clk)
    output reg        write_req,
    input             write_req_ack,        // mem_clk 域
    output reg [20:0] write_addr,
    output            write_en,
    output     [31:0] write_data,
    input             write_afull,          // 写 FIFO 将满 (本时钟域)
    output            write_vflip,          // 1: 自下而上存储的 BMP, 写地址垂直翻转
    input             write_finish_toggle,  // mem_clk 域
    // 播放器 (video_clk 域) 请求/应答
    input             req_toggle,
    input      [3:0]  req_img,
    input      [2:0]  cur_slot,             // 正在显示的帧槽, 7 = 无
    output reg        ack_toggle,
    output reg [2:0]  ack_slot,
    output reg        ack_ok,
    output reg [3:0]  ack_img,
    output reg [7:0]  ack_dur,              // 该图显示秒数 (播放列表), 0 = 默认; 随 ack_img 保持
    // WAV FIFO 写端
    output reg        wav_we,
    output reg [31:0] wav_wdata,
    input  [WAV_AW:0] wav_level,
    // 文本 RAM (0~511 字幕, 512~639 图片文件名, 768~1023 图片分辨率文字) / 用户字库 RAM
    output            txt_we,
    output     [9:0]  txt_waddr,
    output     [7:0]  txt_wdata,
    output reg        fnt_we,
    output reg [10:0] fnt_waddr,
    output reg [7:0]  fnt_wdata,
    // 状态 (准静态)
    output reg [2:0]  status,
    output reg [4:0]  img_count,
    output reg [3:0]  load_img,
    output reg [7:0]  load_prog,
    output reg        loading,
    output reg        wav_ok,
    output reg [2:0]  wav_rate_code,
    output reg [16:0] wav_rate,
    output reg [9:0]  txt_len,
    output reg        txt_ok,
    output reg        fnt_ok
);

localparam [2:0] ST_INIT = 3'd0, ST_SCAN = 3'd1, ST_READY = 3'd2,
                 ST_NOCARD = 3'd3, ST_FSERR = 3'd4, ST_NOIMG = 3'd5;

localparam [2:0] C_BOOT = 3'd0, C_FAT = 3'd1, C_DIR = 3'd2, C_TXT = 3'd3,
                 C_FNT  = 3'd4, C_IMG = 3'd5, C_WAV = 3'd6, C_NONE = 3'd7;

localparam [5:0]
    M_RST      = 6'd0,  M_INIT     = 6'd1,  M_BOOT0    = 6'd2,  M_BOOT0_D  = 6'd3,
    M_BOOT1_D  = 6'd4,  M_CALC0    = 6'd5,  M_CALC1    = 6'd6,  M_CALC2    = 6'd7,
    M_DIR      = 6'd8,  M_DIR_D    = 6'd9,  M_TXT      = 6'd10, M_TXT_RD   = 6'd11,
    M_TXT_D    = 6'd12, M_FNT      = 6'd13, M_FNT_RD   = 6'd14, M_FNT_D    = 6'd15,
    M_SCANEND  = 6'd16, M_SCHED    = 6'd17, M_WAV_D    = 6'd18, M_IMG_D    = 6'd19,
    M_IMG_FIN  = 6'd20, M_PLAN0    = 6'd21, M_PLAN1    = 6'd22, M_PLAN2    = 6'd23,
    M_VICT     = 6'd24, M_START    = 6'd25, M_OPEN     = 6'd26, M_OPEN_ACK = 6'd27,
    M_OPEN_GAP = 6'd28, X_ISSUE    = 6'd29, X_WAIT     = 6'd30, K_CALC0    = 6'd31,
    K_CALC1    = 6'd32, K_ADV      = 6'd33, K_FATD     = 6'd34, M_HALT     = 6'd35,
    X_RST      = 6'd36, X_INIT     = 6'd37, M_PROBE    = 6'd38, M_PROBE_D  = 6'd39,
    M_NEXT     = 6'd40, M_CFG      = 6'd41, M_CFG_RD   = 6'd42, M_CFG_D    = 6'd43,
    M_CFG_W    = 6'd44, M_CFG_W2   = 6'd45;
localparam [1:0] D_ROOT = 2'd0, D_IMG = 2'd1, D_MUS = 2'd2, D_SUB = 2'd3;   // 正在扫描的目录

localparam [31:0] T_INIT_TO = CLK_HZ / 2 * 3;     // 1.5s 初始化超时
localparam [31:0] T_SEC_TO  = CLK_HZ / 4;         // 250ms 单扇区超时 (SDHC 读访问时间上限 100ms, 留足余量)
localparam [1:0]  X_RETRY_MAX = 2'd2;             // 单扇区超时后 "复位 TF 卡控制器 + 重读" 的次数
localparam [31:0] T_FIN_TO  = CLK_HZ / 50;        // 20ms 等待写 SDRAM 完成
localparam [31:0] T_ACK_TO  = CLK_HZ / 10;
localparam [31:0] T_PROBE   = CLK_HZ / 2;         // 空闲心跳间隔 0.5 s
localparam [31:0] BMP_MIN   = 32'd54;           // 目录项小于 BMP 头长度的直接忽略
// WAV FIFO 滞回门限: 低于 WAV_LO 开始补数, 连续读到 WAV_HI 以上才停.
// 一个扇区最多写入 512 个样本 (8bit 单声道), WAV_HI 离满留 512 + 64.
localparam [WAV_AW:0] WAV_LO = (1 << WAV_AW) / 8 * 5;
localparam [WAV_AW:0] WAV_HI = (1 << WAV_AW) - 576;

//---------------------------------------------------------------------------
// TF 卡底层
//---------------------------------------------------------------------------
reg         sd_rst_r;
reg         sd_sec_read;
reg  [31:0] sd_sec_addr;
wire        sd_init_done;
wire [7:0]  bdat_i;
wire        bval_i;
wire        bend;
// 读数据打一拍再消费, 切断 sd_card_sec_read_write 状态译码 -> 解析逻辑的长路径.
// 最后一个字节到 bend 之间还有 CRC 等 SPI 传输, 延迟一拍不会越过 bend.
reg  [7:0]  bdat;
reg         bval;

sd_card_top #(
    .SPI_LOW_SPEED_DIV  (248),
    .SPI_HIGH_SPEED_DIV (0)
) u_sd_card_top (
    .clk                    (clk),
    .rst                    (rst | sd_rst_r),
    .SD_nCS                 (SD_nCS),
    .SD_DCLK                (SD_DCLK),
    .SD_MOSI                (SD_MOSI),
    .SD_MISO                (SD_MISO),
    .sd_init_done           (sd_init_done),
    .sd_sec_read            (sd_sec_read),
    .sd_sec_read_addr       (sd_sec_addr),
    .sd_sec_read_data       (bdat_i),
    .sd_sec_read_data_valid (bval_i),
    .sd_sec_read_end        (bend),
    .sd_sec_write           (1'b0),
    .sd_sec_write_addr      (32'd0),
    .sd_sec_write_data      (8'd0),
    .sd_sec_write_data_req  (),
    .sd_sec_write_end       ()
);

always @(posedge clk or posedge rst) begin
    if (rst) begin
        bdat <= 8'd0;
        bval <= 1'b0;
    end else begin
        bdat <= bdat_i;
        bval <= bval_i;
    end
end

//---------------------------------------------------------------------------
// 跨时钟域同步
//---------------------------------------------------------------------------
reg [2:0] wack_s;
reg [2:0] fin_s;
reg [3:0] req_s;
reg [3:0] req_img_s0, req_img_s1;
reg [2:0] cur_s0, cur_s1;
reg [WAV_AW:0] wlev_r;
always @(posedge clk or posedge rst) begin
    if (rst) begin
        wack_s <= 3'd0; fin_s <= 3'd0; req_s <= 4'd0;
        req_img_s0 <= 4'd0; req_img_s1 <= 4'd0;
        cur_s0 <= 3'd7; cur_s1 <= 3'd7;
        wlev_r <= {(WAV_AW+1){1'b0}};
    end else begin
        wack_s <= {wack_s[1:0], write_req_ack};
        fin_s  <= {fin_s[1:0], write_finish_toggle};
        req_s  <= {req_s[2:0], req_toggle};
        req_img_s0 <= req_img;  req_img_s1 <= req_img_s0;
        cur_s0 <= cur_slot;     cur_s1 <= cur_s0;
        wlev_r <= wav_level;
    end
end
wire req_evt = req_s[3] ^ req_s[2];
wire wack    = wack_s[2];
wire fin_now = fin_s[2];

//---------------------------------------------------------------------------
// 文件系统参数
//---------------------------------------------------------------------------
reg [7:0]  b_jmp;
reg [15:0] b_bps;
reg [7:0]  b_spc;
reg [15:0] b_rsvd;
reg [7:0]  b_nfats;
reg [31:0] b_fatsz;
reg [31:0] b_root;
reg [31:0] b_plba;
reg [15:0] b_sig;
reg [31:0] b_ser;          // FAT32 卷序列号 (VBR 0x43)
reg [31:0] vol_ser;        // 扫描时记录的卷序列号, 心跳核对用
reg [31:0] part_lba;
reg [31:0] fat_lba;
reg [31:0] data_lba;
reg [2:0]  spc_shift;
// 引导扇区判定寄存一拍: 最后一个字节 (0x1FF) 之后还有 CRC 与 bend, 判定使用时早已稳定
reg boot_is_vbr, boot_is_mbr;
always @(posedge clk or posedge rst) begin
    if (rst) begin
        boot_is_vbr <= 1'b0;
        boot_is_mbr <= 1'b0;
    end else begin
        boot_is_vbr <= ((b_jmp == 8'hEB) || (b_jmp == 8'hE9)) && (b_bps == 16'd512) &&
                       (b_fatsz != 32'd0) && (b_spc != 8'd0) && (b_nfats != 8'd0);
        boot_is_mbr <= (b_sig == 16'hAA55) && (b_plba != 32'd0);
    end
end

//---------------------------------------------------------------------------
// 工作游标 (扇区读取公用) + 两个通道 (P: 目录/字幕/图片, W: WAV)
//---------------------------------------------------------------------------
reg [31:0] k_clus;
reg [7:0]  k_sec;
reg        k_eof;
reg [31:0] k_tmp;
reg [5:0]  k_ret;
reg [5:0]  x_ret;
reg [2:0]  ctx, ctx_save;
reg [8:0]  bidx;
reg [6:0]  fat_off;
reg [31:0] fat_val;

reg [31:0] p_clus;  reg [7:0] p_sec;  reg p_eof;
reg [31:0] w_clus;  reg [7:0] w_sec;  reg w_eof;

reg [5:0]  state;
reg [31:0] tmr;
// tmr 的超时比较提前一拍寄存 (100 MHz 时序): 状态机里 tmr 只有 "+1" 和 "清 0" 两种写法,
// 检查超时的状态都在同一拍 +1, 所以上一拍的 tmr >= K-1 就等于这一拍的 tmr >= K.
// 清 0 后的那一拍寄存结果还是旧值, 用 tclr 屏蔽.
reg        tclr;
reg        tq_2k, tq_64, tq_init, tq_sec, tq_fin, tq_ack, tq_1s;
wire       t_2k   = tq_2k   & ~tclr;
wire       t_64   = tq_64   & ~tclr;
wire       t_init = tq_init & ~tclr;
wire       t_sec  = tq_sec  & ~tclr;
wire       t_fin  = tq_fin  & ~tclr;
wire       t_ack  = tq_ack  & ~tclr;
wire       t_1s   = tq_1s   & ~tclr;
always @(posedge clk) begin
    tq_2k   <= (tmr >= 32'd2000 - 32'd1);
    tq_64   <= (tmr >= 32'd64 - 32'd1);
    tq_init <= (tmr >= T_INIT_TO - 32'd1);
    tq_sec  <= (tmr >= T_SEC_TO - 32'd1);
    tq_fin  <= (tmr >= T_FIN_TO - 32'd1);
    tq_ack  <= (tmr >= T_ACK_TO - 32'd1);
    tq_1s   <= (tmr >= CLK_HZ - 1);
end
// K_ADV "本簇最后一个扇区" 判定提前一拍寄存 (100 MHz 时序): k_sec 只在进入扇区读之前改变,
// 到 K_ADV 时至少已读完一个扇区, 寄存值早已稳定
reg k_last;
always @(posedge clk) k_last <= ({1'b0, k_sec} + 9'd1 >= {1'b0, b_spc});
reg [1:0]  x_retry;
reg        chk_card;       // 控制器重新初始化过: 下次调度先核对卷序列号 (防止快速换卡)

// 空闲心跳计时: 任何扇区读完成都清零; 比较寄存一拍, bend 同拍清除
reg [31:0] idle_cnt;
reg        idle_due;
always @(posedge clk or posedge rst) begin
    if (rst) begin
        idle_cnt <= 32'd0;
        idle_due <= 1'b0;
    end else if (bend) begin
        idle_cnt <= 32'd0;
        idle_due <= 1'b0;
    end else begin
        if (!idle_due) idle_cnt <= idle_cnt + 32'd1;
        idle_due <= (idle_cnt >= T_PROBE - 32'd1);
    end
end

//---------------------------------------------------------------------------
// 目录扫描
//---------------------------------------------------------------------------
reg [7:0]  e_name0;
reg [23:0] e_ext;
reg [7:0]  e_attr;
reg [15:0] e_chi, e_clo;
reg [23:0] e_size;
reg        dir_end;
reg [11:0] dir_secs;
reg [27:0] img_clus [0:MAX_IMG-1];
reg        wav_found, txt_found, fnt_found;
reg [27:0] wav_clus, txt_clus, fnt_clus;
reg [31:0] txt_size, fnt_size;

// 分类文件夹 / 播放列表
reg [1:0]  dmode;                 // D_ROOT / D_IMG / D_MUS / D_SUB
reg [2:0]  sp;                    // 扫描阶段: 0 PLAY.CFG 1 IMG 2 MUSIC 3 SUB 4 收尾
reg        imgd_found, musd_found, subd_found, cfg_found;
reg [27:0] dclus [0:3];           // 簇号 (分布式 RAM): 0 PLAY.CFG 1 IMG 2 MUSIC 3 SUB, 按扫描阶段 sp 读
reg [11:0] cfg_len;               // PLAY.CFG 长度 (封顶 2048)
reg        cfg_rd;                // 正在读 PLAY.CFG (借用 C_TXT 上下文)
reg        cfg_ok;                // 播放列表有效 (至少一行)
reg        cfg_clr, cfg_end;      // 播放列表解析器: 清空 / 文件结束 (提交最后一行)
reg [MAX_IMG-1:0] pos_found;      // 播放位置对应的图片已找到
// 目录项名字逐字节核对 (第 0~7 字节), 名字先缓存, 第 12~19 字节再写入名字 RAM (此时已知位置)
reg        m_img, m_mus, m_sub, m_play, n_ok;
reg [6:0]  e_nn;                  // IMGnn 中的编号
reg [7:0]  e_nm [0:7];           // 分布式 RAM (无复位)
reg [3:0]  e_slot;                // 本项若为图片: 放到的位置
reg        e_slot_ok;
function [7:0] ch8;               // 8 字符常量的第 k 个字符
    input [63:0] str;
    input [2:0]  k;
    begin
        ch8 = str >> {~k, 3'b000};
    end
endfunction
wire       b_dig = (bdat >= "0") && (bdat <= "9");
wire [27:0] dclus_q = dclus[sp[1:0]];
wire [1:0] dclus_wa = e_is_cfg ? 2'd0 : m_img ? 2'd1 : m_mus ? 2'd2 : 2'd3;
// 以下判定的输入在第 12 字节前都已确定, 寄存后在第 31 字节使用
reg        e_img_ok;              // 本项是要收录的图片 (不含大小判定)
reg        e_dir_new;             // 本项是尚未找到的分类文件夹
reg        e_cfg_new;             // 本项是播放列表 (不含大小判定)
always @(posedge clk) begin
    e_img_ok  <= e_is_bmp && e_slot_ok && dm_img;
    e_dir_new <= (dmode == D_ROOT) && e_is_dir &&
                 ((m_img && !imgd_found) || (m_mus && !musd_found) || (m_sub && !subd_found));
    e_cfg_new <= (dmode == D_ROOT) && e_is_cfg && !cfg_found;
end
wire       dm_img = (dmode == D_ROOT) || (dmode == D_IMG);
wire       dm_mus = (dmode == D_ROOT) || (dmode == D_MUS);
wire       dm_sub = (dmode == D_ROOT) || (dmode == D_SUB);

wire [31:0] e_size_full = {bdat, e_size};
wire [27:0] e_clus_full = {e_chi[11:0], e_clo};
wire        e_valid     = (e_name0 != 8'h00) && (e_name0 != 8'hE5) && (e_name0 != 8'h2E) &&
                          (e_attr != 8'h0F) && ((e_attr & 8'h18) == 8'h00);

//---------------------------------------------------------------------------
// 顺序文件 (字幕/字库/图片) 偏移
//---------------------------------------------------------------------------
reg [31:0] f_off;

//---------------------------------------------------------------------------
// 图片加载
//---------------------------------------------------------------------------
reg        img_job;
reg [3:0]  job_img;
reg [2:0]  job_slot;
reg [31:0] h_off;
reg [31:0] h_w;
reg [31:0] h_h;
reg [15:0] h_bpp;
reg [31:0] h_comp;
reg        img_bad;

// 目录项名字缓存与文件夹簇号的写口 (分布式 RAM, 不复位)
always @(posedge clk) begin
    if (bval && ctx == C_DIR && !dir_end && bidx[4:3] == 2'd0)
        e_nm[bidx[2:0]] <= (bidx[2:0] == 3'd0 && bdat == 8'h05) ? 8'hE5 : bdat;
    if (bval && ctx == C_DIR && !dir_end && bidx[4:0] == 5'd31 && (e_dir_new || (e_cfg_new && e_sz_nz)))
        dclus[dclus_wa] <= e_clus_full;
end

//---------------------------------------------------------------------------
// 播放列表 PLAY.CFG 解析: 读文件时每个字节晚一拍送进来, 与主状态机的字节处理分开 (不加长 bdat 路径).
//   数字累加成字段 (超过 255 封顶), 非数字字符结束当前字段 (字母等跳过, 所以 "IMG03.BMP 5" 也可),
//   '#' 到行尾为注释, 换行或文件结束提交一行: 字段 0 = 图片编号 1~16, 字段 1 = 秒数.
//   编号重复的行只取第一次; 最多 MAX_IMG 行
//---------------------------------------------------------------------------
reg        cb_v;
reg [7:0]  cb;
reg [4:0]  plen;                          // 列表行数 = 播放位置数
reg [MAX_IMG-1:0] inv_v;                  // 编号 n 已在列表中
reg [3:0]  inv_p [0:MAX_IMG-1];           // 编号 n -> 播放位置   (分布式 RAM, 有效位在 inv_v)
reg [7:0]  dur   [0:MAX_IMG-1];           // 播放位置 -> 秒数     (分布式 RAM)
reg        cp_cmt, cp_dig, cp_have;
reg [1:0]  cp_f;
reg [7:0]  cp_v0, cp_v1;
always @(posedge clk) begin
    cb_v <= bval && (ctx == C_TXT) && cfg_rd && f_cfg_in;
    cb   <= bdat;
end
wire        cb_digit = (cb >= "0") && (cb <= "9");
wire [11:0] cp_m0 = {1'b0, cp_v0, 3'b000} + {3'b000, cp_v0, 1'b0} + {8'd0, cb[3:0]};   // v * 10 + d
wire [11:0] cp_m1 = {1'b0, cp_v1, 3'b000} + {3'b000, cp_v1, 1'b0} + {8'd0, cb[3:0]};
wire [7:0]  cp_n0 = cp_v0 - 8'd1;
wire        cp_line = cfg_end || (cb_v && cb == 8'h0A);
wire        cp_add  = cp_have && (cp_v0 != 8'd0) && (cp_v0 <= MAX_IMG) && (plen < MAX_IMG) && !inv_v[cp_n0[3:0]];
always @(posedge clk) begin
    if (cp_line && cp_add) begin
        inv_p[cp_n0[3:0]] <= plen[3:0];
        dur[plen[3:0]]    <= cp_v1;
    end
end
always @(posedge clk or posedge rst) begin
    if (rst) begin
        plen <= 5'd0; inv_v <= {MAX_IMG{1'b0}};
        cp_cmt <= 1'b0; cp_dig <= 1'b0; cp_have <= 1'b0; cp_f <= 2'd0; cp_v0 <= 8'd0; cp_v1 <= 8'd0;
    end else if (cfg_clr) begin
        plen <= 5'd0; inv_v <= {MAX_IMG{1'b0}};
        cp_cmt <= 1'b0; cp_dig <= 1'b0; cp_have <= 1'b0; cp_f <= 2'd0; cp_v0 <= 8'd0; cp_v1 <= 8'd0;
    end else if (cp_line) begin
        if (cp_add) begin
            inv_v[cp_n0[3:0]] <= 1'b1;
            plen              <= plen + 5'd1;
        end
        cp_cmt <= 1'b0; cp_dig <= 1'b0; cp_have <= 1'b0; cp_f <= 2'd0; cp_v0 <= 8'd0; cp_v1 <= 8'd0;
    end else if (cb_v && !cp_cmt) begin
        if (cb == "#")
            cp_cmt <= 1'b1;
        else if (cb_digit) begin
            cp_dig <= 1'b1;
            if (cp_f == 2'd0) begin
                cp_v0   <= (cp_m0[11:8] != 4'd0) ? 8'hFF : cp_m0[7:0];
                cp_have <= 1'b1;
            end else if (cp_f == 2'd1)
                cp_v1 <= (cp_m1[11:8] != 4'd0) ? 8'hFF : cp_m1[7:0];
        end else if (cp_dig) begin
            cp_dig <= 1'b0;
            if (cp_f != 2'd2) cp_f <= cp_f + 2'd1;
        end
    end
end
// 应答附带该位置的秒数 (ack_img 改变后一拍更新; 播放器经过多级同步才采样)
always @(posedge clk) ack_dur <= cfg_ok ? dur[ack_img] : 8'd0;

//---------------------------------------------------------------------------
// 图片分辨率文字: 头部读到偏移 34 (宽高已知) 时把 "宽x高" 转成 ASCII, 写入文本 RAM
// 768 + 图片号 * 16 的前 9 字节 (左对齐, 空格补齐, 例 "640x400  "), 顶部信息栏显示当前图片的分辨率.
// 十进制按位权 1000/100/10/1 逐次减 (每拍一次比较减法), 高位 0 不输出; 一张图约 50 拍.
// 只在读图片第一个扇区期间进行 (C_IMG, 相邻字节至少隔 32 拍, 该状态不写文本 RAM), 与文件名 / 字幕写入不冲突
//---------------------------------------------------------------------------
reg        tw_we;
reg [9:0]  tw_waddr;
reg [7:0]  tw_wdata;
reg        rs_go;
localparam [1:0] RS_IDLE = 2'd0, RS_DIG = 2'd1, RS_X = 2'd2, RS_PAD = 2'd3;
reg [1:0]  rs_st;
reg        rs_hgt;          // 0 正在写宽, 1 正在写高
reg [12:0] rs_v, rs_h;
reg [1:0]  rs_k;            // 位权 1000 / 100 / 10 / 1
reg [3:0]  rs_d;
reg        rs_nz;           // 已输出过非 0 位
reg [3:0]  rs_col, rs_img;
reg        rs_we;
reg [7:0]  rs_wdata;
reg [3:0]  rs_wcol;
wire [12:0] rs_p   = (rs_k == 2'd0) ? 13'd1000 : (rs_k == 2'd1) ? 13'd100 : (rs_k == 2'd2) ? 13'd10 : 13'd1;
wire        rs_ge  = (rs_v >= rs_p);
wire [12:0] rs_hn  = 13'd0 - h_h[12:0];        // 高度为负 (自上而下存储) 时取绝对值
always @(posedge clk or posedge rst) begin
    if (rst) begin
        rs_st <= RS_IDLE; rs_we <= 1'b0; rs_wdata <= 8'd0; rs_wcol <= 4'd0;
        rs_hgt <= 1'b0; rs_v <= 13'd0; rs_h <= 13'd0; rs_k <= 2'd0; rs_d <= 4'd0;
        rs_nz <= 1'b0; rs_col <= 4'd0; rs_img <= 4'd0;
    end else begin
        rs_we <= 1'b0;
        case (rs_st)
        RS_IDLE: if (rs_go) begin
            rs_st <= RS_DIG; rs_img <= job_img; rs_col <= 4'd0;
            rs_v <= h_w[12:0]; rs_h <= h_h[31] ? rs_hn : h_h[12:0];
            rs_hgt <= 1'b0; rs_k <= 2'd0; rs_d <= 4'd0; rs_nz <= 1'b0;
        end
        RS_DIG: begin
            if (rs_ge) begin
                rs_v <= rs_v - rs_p; rs_d <= rs_d + 4'd1;
            end else begin
                if (rs_d != 4'd0 || rs_nz || rs_k == 2'd3) begin
                    rs_we <= 1'b1; rs_wcol <= rs_col; rs_wdata <= {4'h3, rs_d};
                    rs_col <= rs_col + 4'd1; rs_nz <= 1'b1;
                end
                rs_k <= rs_k + 2'd1; rs_d <= 4'd0;
                if (rs_k == 2'd3) rs_st <= rs_hgt ? RS_PAD : RS_X;
            end
        end
        RS_X: begin
            rs_we <= 1'b1; rs_wcol <= rs_col; rs_wdata <= "x";
            rs_col <= rs_col + 4'd1;
            rs_v <= rs_h; rs_hgt <= 1'b1; rs_nz <= 1'b0; rs_st <= RS_DIG;
        end
        default: begin              // RS_PAD: 空格补到 9 字节, 盖掉上次更长的文字
            if (rs_col == 4'd9) rs_st <= RS_IDLE;
            else begin
                rs_we <= 1'b1; rs_wcol <= rs_col; rs_wdata <= 8'h20;
                rs_col <= rs_col + 4'd1;
            end
        end
        endcase
    end
end
assign txt_we    = tw_we | rs_we;
assign txt_waddr = rs_we ? {2'b11, rs_img, rs_wcol} : tw_waddr;
assign txt_wdata = rs_we ? rs_wdata : tw_wdata;

// 图片字节处理用的比较结果提前一拍寄存, 缩短 bval -> 状态机的组合路径 (100 MHz 时序).
// TF 卡 SPI 最快 25 MHz, 相邻两个字节至少间隔 32 个时钟, f_off / h_off
// 在上一个字节处更新, 下一个字节到来之前这些寄存结果早已更新完毕.
reg [6:0]  f_hdr;          // f_off < 64 时为 f_off, 否则 7'h7F (不与任何头部偏移匹配)
reg        f_px_ok;        // f_off >= 35 && f_off >= h_off
reg        f_txt_in;       // f_off < 512  && f_off < txt_size (字幕文件内)
reg        f_fnt_in;       // f_off < 2048 && f_off < fnt_size (字库文件内)
reg        f_cfg_in;       // f_off < 2048 && f_off < cfg_len (播放列表文件内)
always @(posedge clk) begin
    f_cfg_in <= (f_off < 32'd2048) && (f_off[11:0] < cfg_len);
    f_hdr    <= (f_off[31:6] == 26'd0) ? {1'b0, f_off[5:0]} : 7'h7F;
    f_px_ok  <= (f_off >= 32'd35) && (f_off >= h_off);
    f_txt_in <= (f_off < 32'd512)  && (f_off < txt_size);
    f_fnt_in <= (f_off < 32'd2048) && (f_off < fnt_size);
end
// 目录项判定同样提前寄存: 扩展名 / 属性在第 8~11 字节、大小低 3 字节在第 28~30 字节就已确定,
// 第 31 字节 (大小最高字节) 到来时只剩与 bdat 的简单组合 (加入第二屏终端后 sd_card_clk 余量不足)
reg        e_is_bmp, e_is_wav, e_is_txt, e_is_fnt, e_is_dir, e_is_cfg;
reg        e_lo_nz, e_lo_bmp;    // 大小低 24 位 != 0 / >= BMP_MIN
always @(posedge clk) begin
    e_is_bmp <= e_valid && (e_ext == "BMP");
    e_is_wav <= e_valid && (e_ext == "WAV");
    e_is_txt <= e_valid && (e_ext == "TXT");
    e_is_fnt <= e_valid && (e_ext == "FNT");
    e_is_cfg <= e_valid && (e_ext == "CFG") && m_play;
    e_is_dir <= (e_name0 != 8'h00) && (e_name0 != 8'hE5) && (e_name0 != 8'h2E) &&
                (e_attr != 8'h0F) && ((e_attr & 8'h18) == 8'h10);
    e_lo_nz  <= (e_size != 24'd0);
    e_lo_bmp <= (e_size >= BMP_MIN);
end
wire e_sz_nz  = (bdat != 8'd0) || e_lo_nz;          // e_size_full != 0
wire e_sz_bmp = (bdat != 8'd0) || e_lo_bmp;         // e_size_full >= BMP_MIN

// 任意分辨率 -> 640x400 缩放, 产生全部 256000 个写像素 (含黑边)
reg        scl_start, scl_cfg, scl_pv;
reg [7:0]  scl_pb;
wire       scl_bad, scl_need, scl_room, scl_done;
wire [18:0] scl_cnt;
bmp_fit_scaler u_fit (
    .clk      (clk),
    .rst      (rst),
    .start    (scl_start),
    .cfg      (scl_cfg),
    .cfg_w    (h_w),
    .cfg_h    (h_h),
    .cfg_bpp  (h_bpp),
    .cfg_comp (h_comp),
    .px_vld   (scl_pv),
    .px_byte  (scl_pb),
    .afull    (write_afull),
    .wr_en    (write_en),
    .wr_data  (write_data),
    .bad      (scl_bad),
    .need     (scl_need),
    .room     (scl_room),
    .done     (scl_done),
    .dst_cnt  (scl_cnt),
    .vflip    (write_vflip)
);
reg        fin_ref;
reg        first_done;
reg [MAX_IMG-1:0] bad_img;

//---------------------------------------------------------------------------
// 缓存
//---------------------------------------------------------------------------
reg [NSLOT-1:0] slot_valid;
reg [3:0]  slot_tag [0:NSLOT-1];
reg        pend, pend_new;
reg [3:0]  pend_img;
reg [3:0]  focus;
reg        plan_dirty;
reg [3:0]  wl [0:5];
reg [3:0]  pn, pv;
reg [2:0]  pi;
reg [3:0]  tgt;

//---------------------------------------------------------------------------
// WAV 解析
//---------------------------------------------------------------------------
reg        wav_active;
reg [2:0]  w_phase;
reg [3:0]  w_cnt;
reg [31:0] w_id;
reg [31:0] w_csize;
reg [31:0] w_rem;
reg        w_rem1;         // w_rem == 1, 提前一拍寄存 (同 f_hdr)
always @(posedge clk) w_rem1 <= (w_rem == 32'd1);
reg [15:0] w_fmt;
reg [7:0]  w_chn;
reg [7:0]  w_bits;
reg [23:0] w_rate_acc;
reg        w_fmt_ok;
reg        wav_bad;
reg        wav_restart;
reg [1:0]  w_sb;
reg [7:0]  w_lo;
reg [15:0] w_left;

localparam [2:0] WP_RIFF = 3'd0, WP_CHDR = 3'd1, WP_FMT = 3'd2, WP_DATA = 3'd3,
                 WP_SKIP = 3'd4, WP_IGN  = 3'd5;

wire [31:0] w_csize_full = {bdat, w_csize[31:8]};
wire [31:0] w_id_full    = {w_id[23:0], bdat};
wire [4:0]  img_count_m1 = img_count - 5'd1;

//---------------------------------------------------------------------------
// 组合辅助
//---------------------------------------------------------------------------
function [3:0] nxt;
    input [3:0] v;
    input [4:0] cnt;
    begin
        nxt = ({1'b0, v} + 5'd1 >= cnt) ? 4'd0 : v + 4'd1;
    end
endfunction

function [20:0] slot_base;
    input [2:0] s;
    begin
        case (s)
            3'd0: slot_base = 21'd0;
            3'd1: slot_base = 21'd307200;
            3'd2: slot_base = 21'd614400;
            3'd3: slot_base = 21'd921600;
            3'd4: slot_base = 21'd1228800;
            3'd5: slot_base = 21'd1536000;
            default: slot_base = 21'd0;
        endcase
    end
endfunction

// 命中查找
reg        hit_pend, hit_tgt;
reg [2:0]  hit_pend_slot;
reg [NSLOT-1:0] ev_mask;
reg [2:0]  inv_slot, ev_slot;
reg        inv_any, ev_any;
reg        cand_cached;
integer    si, sj;
reg        in_wl;
always @(*) begin
    hit_pend = 1'b0; hit_pend_slot = 3'd0;
    cand_cached = 1'b0;
    inv_any = 1'b0; inv_slot = 3'd0;
    ev_any  = 1'b0; ev_slot  = 3'd0;
    ev_mask = {NSLOT{1'b0}};
    for (si = NSLOT - 1; si >= 0; si = si - 1) begin
        if (slot_valid[si] && slot_tag[si] == pend_img) begin
            hit_pend = 1'b1; hit_pend_slot = si;
        end
        if (slot_valid[si] && slot_tag[si] == wl[pi])
            cand_cached = 1'b1;
        in_wl = 1'b0;
        for (sj = 0; sj < 6; sj = sj + 1)
            if (slot_tag[si] == wl[sj]) in_wl = 1'b1;
        ev_mask[si] = slot_valid[si] && (si != cur_s1) && !in_wl;
        if (!slot_valid[si]) begin
            inv_any = 1'b1; inv_slot = si;
        end
        if (ev_mask[si]) begin
            ev_any = 1'b1; ev_slot = si;
        end
    end
end

// 调度判定提前一拍寄存 (缩短主状态机组合深度, 满足 100MHz)
//  - 替换槽: M_PLAN2 -> M_VICT 期间 wl / slot_valid 不变, 延迟一拍结果一致
//  - WAV 补数: FIFO 余量判定晚两拍无影响 (WAV_HI 离满还有 576 样本)
//    滞回: 一旦开始就连续读 WAV 扇区直到 WAV_HI. 同一文件的相邻扇区连续读,
//    比与图片扇区逐个交替 (两处地址来回跳) 在实际 TF 卡上快得多.
reg        vict_inv_any, vict_ev_any;
reg [2:0]  vict_inv_slot, vict_ev_slot;
reg        wav_need, wav_fill;
reg        cand_r, cand_bad_r;
reg        pl_ph;
wire       wav_on = wav_active && !wav_bad && (first_done || img_count == 5'd0) && !w_eof;

// 进度 (0~255): 已写像素 * 65 / 65536, 256000 像素时约 253
wire [24:0] prog_mul = {scl_cnt, 6'b000000} + {6'b000000, scl_cnt};
wire [8:0]  prog_raw = prog_mul[24:16];

always @(posedge clk or posedge rst) begin
    if (rst) begin
        vict_inv_any <= 1'b0; vict_ev_any <= 1'b0;
        vict_inv_slot <= 3'd0; vict_ev_slot <= 3'd0;
        wav_need <= 1'b0; wav_fill <= 1'b0;
    end else begin
        vict_inv_any  <= inv_any;
        vict_inv_slot <= inv_slot;
        vict_ev_any   <= ev_any;
        vict_ev_slot  <= ev_slot;
        if (!wav_on || wlev_r >= WAV_HI) wav_fill <= 1'b0;
        else if (wlev_r < WAV_LO)        wav_fill <= 1'b1;
        wav_need      <= wav_on && wav_fill && wlev_r < WAV_HI;
    end
end

//---------------------------------------------------------------------------
// 主状态机
//---------------------------------------------------------------------------
integer ii;
always @(posedge clk or posedge rst) begin
    if (rst) begin
        state <= M_RST; tmr <= 32'd0; tclr <= 1'b1; x_retry <= 2'd0;
        sd_rst_r <= 1'b1; sd_sec_read <= 1'b0; sd_sec_addr <= 32'd0;
        status <= ST_INIT;
        write_req <= 1'b0; write_addr <= 21'd0;
        scl_start <= 1'b0; scl_cfg <= 1'b0; scl_pv <= 1'b0; scl_pb <= 8'd0;
        ack_toggle <= 1'b0; ack_slot <= 3'd0; ack_ok <= 1'b0; ack_img <= 4'd0;
        wav_we <= 1'b0; wav_wdata <= 32'd0;
        tw_we <= 1'b0; tw_waddr <= 10'd0; tw_wdata <= 8'd0; rs_go <= 1'b0;
        fnt_we <= 1'b0; fnt_waddr <= 11'd0; fnt_wdata <= 8'd0;
        img_count <= 5'd0; load_img <= 4'd0; load_prog <= 8'd0; loading <= 1'b0;
        wav_ok <= 1'b0; wav_rate_code <= 3'd0; wav_rate <= 17'd48000;
        txt_len <= 10'd0; txt_ok <= 1'b0; fnt_ok <= 1'b0;
        b_jmp <= 8'd0; b_bps <= 16'd0; b_spc <= 8'd0; b_rsvd <= 16'd0; b_nfats <= 8'd0;
        b_fatsz <= 32'd0; b_root <= 32'd0; b_plba <= 32'd0; b_sig <= 16'd0;
        b_ser <= 32'd0; vol_ser <= 32'd0; chk_card <= 1'b0;
        part_lba <= 32'd0; fat_lba <= 32'd0; data_lba <= 32'd0; spc_shift <= 3'd0;
        k_clus <= 32'd0; k_sec <= 8'd0; k_eof <= 1'b0; k_tmp <= 32'd0; k_ret <= M_RST; x_ret <= M_RST;
        ctx <= C_NONE; ctx_save <= C_NONE; bidx <= 9'd0; fat_off <= 7'd0; fat_val <= 32'd0;
        p_clus <= 32'd0; p_sec <= 8'd0; p_eof <= 1'b0;
        w_clus <= 32'd0; w_sec <= 8'd0; w_eof <= 1'b0;
        e_name0 <= 8'd0; e_ext <= 24'd0; e_attr <= 8'd0; e_chi <= 16'd0; e_clo <= 16'd0; e_size <= 24'd0;
        dir_end <= 1'b0; dir_secs <= 12'd0;
        dmode <= D_ROOT; sp <= 3'd0; cfg_rd <= 1'b0; cfg_ok <= 1'b0; cfg_clr <= 1'b0; cfg_end <= 1'b0;
        imgd_found <= 1'b0; musd_found <= 1'b0; subd_found <= 1'b0; cfg_found <= 1'b0;
        cfg_len <= 12'd0;
        pos_found <= {MAX_IMG{1'b0}};
        m_img <= 1'b0; m_mus <= 1'b0; m_sub <= 1'b0; m_play <= 1'b0; n_ok <= 1'b0; e_nn <= 7'd0;
        e_slot <= 4'd0; e_slot_ok <= 1'b0;
        wav_found <= 1'b0; txt_found <= 1'b0; fnt_found <= 1'b0;
        wav_clus <= 28'd0; txt_clus <= 28'd0; fnt_clus <= 28'd0; txt_size <= 32'd0; fnt_size <= 32'd0;
        f_off <= 32'd0;
        img_job <= 1'b0; job_img <= 4'd0; job_slot <= 3'd0;
        h_off <= 32'd0; h_w <= 32'd0; h_h <= 32'd0; h_bpp <= 16'd0; h_comp <= 32'd0;
        img_bad <= 1'b0; fin_ref <= 1'b0; first_done <= 1'b0; bad_img <= {MAX_IMG{1'b0}};
        slot_valid <= {NSLOT{1'b0}};
        pend <= 1'b0; pend_new <= 1'b0; pend_img <= 4'd0; focus <= 4'd0; plan_dirty <= 1'b0;
        pn <= 4'd0; pv <= 4'd0; pi <= 3'd0; tgt <= 4'd0;
        cand_r <= 1'b0; cand_bad_r <= 1'b0; pl_ph <= 1'b0;
        wav_active <= 1'b0; w_phase <= WP_RIFF; w_cnt <= 4'd0; w_id <= 32'd0; w_csize <= 32'd0;
        w_rem <= 32'd0; w_fmt <= 16'd0; w_chn <= 8'd0; w_bits <= 8'd0; w_rate_acc <= 24'd0;
        w_fmt_ok <= 1'b0; wav_bad <= 1'b0; wav_restart <= 1'b0; w_sb <= 2'd0; w_lo <= 8'd0; w_left <= 16'd0;
        for (ii = 0; ii < NSLOT; ii = ii + 1) slot_tag[ii] <= 4'd0;
        for (ii = 0; ii < 6; ii = ii + 1) wl[ii] <= 4'd0;
    end else begin
        scl_start <= 1'b0;
        scl_cfg   <= 1'b0;
        scl_pv    <= 1'b0;
        tclr     <= 1'b0;
        wav_we   <= 1'b0;
        tw_we   <= 1'b0;
        rs_go   <= 1'b0;
        cfg_clr <= 1'b0;
        cfg_end <= 1'b0;
        fnt_we   <= 1'b0;
        load_prog <= (prog_raw > 9'd255) ? 8'd255 : prog_raw[7:0];
        wav_ok   <= wav_active & w_fmt_ok & ~wav_bad;

        //=================== 字节消费 (按当前上下文) ===================
        if (bval) begin
            bidx <= bidx + 9'd1;
            case (ctx)
            C_BOOT: begin
                case (bidx)
                    9'd0:   b_jmp <= bdat;
                    9'd11:  b_bps[7:0]  <= bdat;
                    9'd12:  b_bps[15:8] <= bdat;
                    9'd13:  b_spc <= bdat;
                    9'd14:  b_rsvd[7:0]  <= bdat;
                    9'd15:  b_rsvd[15:8] <= bdat;
                    9'd16:  b_nfats <= bdat;
                    9'd36:  b_fatsz[7:0]   <= bdat;
                    9'd37:  b_fatsz[15:8]  <= bdat;
                    9'd38:  b_fatsz[23:16] <= bdat;
                    9'd39:  b_fatsz[31:24] <= bdat;
                    9'd44:  b_root[7:0]   <= bdat;
                    9'd45:  b_root[15:8]  <= bdat;
                    9'd46:  b_root[23:16] <= bdat;
                    9'd47:  b_root[31:24] <= bdat;
                    9'h43:  b_ser[7:0]    <= bdat;
                    9'h44:  b_ser[15:8]   <= bdat;
                    9'h45:  b_ser[23:16]  <= bdat;
                    9'h46:  b_ser[31:24]  <= bdat;
                    9'h1C6: b_plba[7:0]   <= bdat;
                    9'h1C7: b_plba[15:8]  <= bdat;
                    9'h1C8: b_plba[23:16] <= bdat;
                    9'h1C9: b_plba[31:24] <= bdat;
                    9'h1FE: b_sig[7:0]  <= bdat;
                    9'h1FF: b_sig[15:8] <= bdat;
                    default: ;
                endcase
            end
            C_FAT: begin
                if (bidx[8:2] == fat_off) begin
                    case (bidx[1:0])
                        2'd0: fat_val[7:0]   <= bdat;
                        2'd1: fat_val[15:8]  <= bdat;
                        2'd2: fat_val[23:16] <= bdat;
                        default: fat_val[31:24] <= bdat;
                    endcase
                end
            end
            C_DIR: begin
                if (!dir_end) begin
                    case (bidx[4:0])
                        5'd0:  e_name0 <= bdat;
                        5'd8:  e_ext[23:16] <= bdat;
                        5'd9:  e_ext[15:8]  <= bdat;
                        5'd10: e_ext[7:0]   <= bdat;
                        5'd11: e_attr <= bdat;
                        5'd20: e_chi[7:0]  <= bdat;
                        5'd21: e_chi[15:8] <= bdat;
                        5'd26: e_clo[7:0]  <= bdat;
                        5'd27: e_clo[15:8] <= bdat;
                        5'd28: e_size[7:0]   <= bdat;
                        5'd29: e_size[15:8]  <= bdat;
                        5'd30: e_size[23:16] <= bdat;
                        default: ;
                    endcase
                    // 名字: 缓存并逐字节核对 IMG / MUSIC / SUB / PLAY 与 IMGnn 编号
                    if (bidx[4:3] == 2'd0) begin
                        m_img  <= ((bidx[2:0] == 3'd0) || m_img)  && (bdat == ch8("IMG     ", bidx[2:0]));
                        m_mus  <= ((bidx[2:0] == 3'd0) || m_mus)  && (bdat == ch8("MUSIC   ", bidx[2:0]));
                        m_sub  <= ((bidx[2:0] == 3'd0) || m_sub)  && (bdat == ch8("SUB     ", bidx[2:0]));
                        m_play <= ((bidx[2:0] == 3'd0) || m_play) && (bdat == ch8("PLAY    ", bidx[2:0]));
                        case (bidx[2:0])
                            3'd0: n_ok <= (bdat == "I");
                            3'd1: n_ok <= n_ok && (bdat == "M");
                            3'd2: n_ok <= n_ok && (bdat == "G");
                            3'd3: begin n_ok <= n_ok && b_dig; e_nn <= {3'd0, bdat[3:0]}; end
                            3'd4: if (b_dig) e_nn <= {e_nn[3:0], 3'b000} + {e_nn[5:0], 1'b0} + {3'd0, bdat[3:0]};
                                  else if (bdat != " ") n_ok <= 1'b0;
                            default: ;
                        endcase
                    end
                    // 第 8 字节: 确定图片位置 (播放列表: 编号查表; 否则按目录顺序)
                    if (bidx[4:0] == 5'd8) begin
                        e_slot    <= cfg_ok ? inv_p[e_nn[3:0] - 4'd1] : img_count[3:0];
                        e_slot_ok <= cfg_ok ? (n_ok && (e_nn != 7'd0) && (e_nn <= MAX_IMG) && inv_v[e_nn[3:0] - 4'd1])
                                            : (img_count < MAX_IMG);
                    end
                    // 第 12~19 字节: 图片名字写入名字 RAM 的对应位置
                    if ((bidx[4:2] == 3'b011 || bidx[4:2] == 3'b100) && e_is_bmp && e_slot_ok && dm_img) begin
                        tw_we    <= 1'b1;
                        tw_waddr <= {3'b100, e_slot, bidx[2:0] - 3'd4};
                        tw_wdata <= e_nm[bidx[2:0] - 3'd4];
                    end
                    if (bidx[4:0] == 5'd0 && bdat == 8'h00)
                        dir_end <= 1'b1;
                    if (bidx[4:0] == 5'd31) begin
                        if (e_img_ok && e_sz_bmp) begin
                            img_clus[e_slot] <= e_clus_full;
                            if (cfg_ok) pos_found[e_slot] <= 1'b1;
                            else        img_count <= img_count + 5'd1;
                        end
                        if (e_is_wav && !wav_found && dm_mus) begin
                            wav_found <= 1'b1; wav_clus <= e_clus_full;
                        end
                        if (e_is_txt && !txt_found && e_sz_nz && dm_sub) begin
                            txt_found <= 1'b1; txt_clus <= e_clus_full; txt_size <= e_size_full;
                        end
                        if (e_is_fnt && !fnt_found && e_sz_nz && dm_sub) begin
                            fnt_found <= 1'b1; fnt_clus <= e_clus_full; fnt_size <= e_size_full;
                        end
                        if (e_dir_new) begin
                            if (m_img) imgd_found <= 1'b1;
                            if (m_mus) musd_found <= 1'b1;
                            if (m_sub) subd_found <= 1'b1;
                        end
                        if (e_cfg_new && e_sz_nz) begin
                            cfg_found <= 1'b1;
                            cfg_len   <= (e_size_full[31:11] != 21'd0) ? 12'd2048 : {1'b0, e_size_full[10:0]};
                        end
                    end
                end
            end
            C_TXT: begin
                f_off <= f_off + 32'd1;
                if (f_txt_in && !cfg_rd) begin
                    tw_we    <= 1'b1;
                    tw_waddr <= {1'b0, f_off[8:0]};
                    tw_wdata <= bdat;
                end
            end
            C_FNT: begin
                f_off <= f_off + 32'd1;
                if (f_fnt_in) begin
                    fnt_we    <= 1'b1;
                    fnt_waddr <= f_off[10:0];
                    fnt_wdata <= bdat;
                end
            end
            C_IMG: begin
                f_off <= f_off + 32'd1;
                case (f_hdr)
                    7'd0:  if (bdat != 8'h42) img_bad <= 1'b1;
                    7'd1:  if (bdat != 8'h4D) img_bad <= 1'b1;
                    7'd10: h_off[7:0]   <= bdat;
                    7'd11: h_off[15:8]  <= bdat;
                    7'd12: h_off[23:16] <= bdat;
                    7'd13: h_off[31:24] <= bdat;
                    7'd18: h_w[7:0]   <= bdat;
                    7'd19: h_w[15:8]  <= bdat;
                    7'd20: h_w[23:16] <= bdat;
                    7'd21: h_w[31:24] <= bdat;
                    7'd22: h_h[7:0]   <= bdat;
                    7'd23: h_h[15:8]  <= bdat;
                    7'd24: h_h[23:16] <= bdat;
                    7'd25: h_h[31:24] <= bdat;
                    7'd28: h_bpp[7:0]  <= bdat;
                    7'd29: h_bpp[15:8] <= bdat;
                    7'd30: h_comp[7:0]   <= bdat;
                    7'd31: h_comp[15:8]  <= bdat;
                    7'd32: h_comp[23:16] <= bdat;
                    7'd33: h_comp[31:24] <= bdat;
                    7'd34: begin
                        // 尺寸 / 位深 / 压缩方式由 bmp_fit_scaler 检查 (scl_bad)
                        if (h_off < 32'd54) img_bad <= 1'b1;
                        scl_cfg <= 1'b1;
                        rs_go   <= 1'b1;
                    end
                    default: ;
                endcase
                if (f_px_ok && !img_bad) begin
                    scl_pv <= 1'b1;
                    scl_pb <= bdat;
                end
            end
            C_WAV: begin
                case (w_phase)
                WP_RIFF: begin
                    w_id  <= w_id_full;
                    w_cnt <= w_cnt + 4'd1;
                    if (w_cnt == 4'd11) begin
                        w_cnt <= 4'd0;
                        if (w_id_full == "WAVE") w_phase <= WP_CHDR;
                        else begin wav_bad <= 1'b1; w_phase <= WP_IGN; end
                    end
                end
                WP_CHDR: begin
                    w_cnt <= w_cnt + 4'd1;
                    if (w_cnt < 4'd4) w_id <= w_id_full;
                    else              w_csize <= w_csize_full;
                    if (w_cnt == 4'd7) begin
                        w_cnt <= 4'd0;
                        if (w_id == "fmt ") begin
                            w_rem   <= w_csize_full;
                            w_phase <= (w_csize_full == 32'd0) ? WP_CHDR : WP_FMT;
                        end else if (w_id == "data") begin
                            w_rem <= w_csize_full;
                            if (!w_fmt_ok) begin
                                wav_bad <= 1'b1; w_phase <= WP_IGN;
                            end else if (w_csize_full == 32'd0) begin
                                wav_restart <= 1'b1; w_phase <= WP_IGN;
                            end else begin
                                w_phase <= WP_DATA; w_sb <= 2'd0;
                            end
                        end else begin
                            w_rem   <= w_csize_full + {31'd0, w_csize_full[0]};
                            w_phase <= (w_csize_full == 32'd0) ? WP_CHDR : WP_SKIP;
                        end
                    end
                end
                WP_FMT: begin
                    w_rem <= w_rem - 32'd1;
                    if (w_cnt != 4'd15) w_cnt <= w_cnt + 4'd1;
                    case (w_cnt)
                        4'd0: w_fmt[7:0]  <= bdat;
                        4'd1: w_fmt[15:8] <= bdat;
                        4'd2: w_chn <= bdat;
                        4'd4: w_rate_acc[7:0]   <= bdat;
                        4'd5: w_rate_acc[15:8]  <= bdat;
                        4'd6: w_rate_acc[23:16] <= bdat;
                        4'd14: w_bits <= bdat;
                        default: ;
                    endcase
                    if (w_rem1) begin
                        w_cnt   <= 4'd0;
                        w_phase <= WP_CHDR;
                        w_fmt_ok <= (w_fmt == 16'd1) && (w_chn == 8'd1 || w_chn == 8'd2) &&
                                    (w_bits == 8'd8 || w_bits == 8'd16 || (w_cnt == 4'd14 && (bdat == 8'd8 || bdat == 8'd16))) &&
                                    (w_rate_acc >= 24'd8000) && (w_rate_acc <= 24'd48000);
                        wav_rate <= w_rate_acc[16:0];
                        case (w_rate_acc)
                            24'd8000:  wav_rate_code <= 3'd1;
                            24'd11025: wav_rate_code <= 3'd2;
                            24'd16000: wav_rate_code <= 3'd3;
                            24'd22050: wav_rate_code <= 3'd4;
                            24'd32000: wav_rate_code <= 3'd5;
                            24'd44100: wav_rate_code <= 3'd6;
                            24'd48000: wav_rate_code <= 3'd7;
                            default:   wav_rate_code <= 3'd0;
                        endcase
                    end
                end
                WP_DATA: begin
                    w_rem <= w_rem - 32'd1;
                    if (w_rem1) begin
                        wav_restart <= 1'b1;
                        w_phase     <= WP_IGN;
                    end
                    if (w_bits == 8'd16) begin
                        w_sb <= w_sb + 2'd1;
                        if (w_sb[0] == 1'b0)
                            w_lo <= bdat;
                        else if (w_chn == 8'd1) begin
                            wav_we <= 1'b1; wav_wdata <= {bdat, w_lo, bdat, w_lo}; w_sb <= 2'd0;
                        end else if (w_sb == 2'd1)
                            w_left <= {bdat, w_lo};
                        else begin
                            wav_we <= 1'b1; wav_wdata <= {w_left, bdat, w_lo};
                        end
                    end else begin
                        if (w_chn == 8'd1) begin
                            wav_we <= 1'b1; wav_wdata <= {bdat ^ 8'h80, 8'h00, bdat ^ 8'h80, 8'h00};
                        end else if (w_sb[0] == 1'b0) begin
                            w_left <= {bdat ^ 8'h80, 8'h00}; w_sb <= 2'd1;
                        end else begin
                            wav_we <= 1'b1; wav_wdata <= {w_left, bdat ^ 8'h80, 8'h00}; w_sb <= 2'd0;
                        end
                    end
                end
                WP_SKIP: begin
                    w_rem <= w_rem - 32'd1;
                    if (w_rem1) begin
                        w_phase <= WP_CHDR; w_cnt <= 4'd0;
                    end
                end
                default: ;
                endcase
            end
            default: ;
            endcase
        end

        //=================== 状态机 ===================
        case (state)
        M_RST: begin
            // 软复位: 复位 TF 卡控制器并清空所有扫描结果
            sd_rst_r    <= 1'b1;
            sd_sec_read <= 1'b0;
            write_req   <= 1'b0;
            ctx         <= C_NONE;
            img_count   <= 5'd0;
            slot_valid  <= {NSLOT{1'b0}};
            img_job     <= 1'b0;
            loading     <= 1'b0;
            wav_active  <= 1'b0;
            txt_ok      <= 1'b0;
            fnt_ok      <= 1'b0;
            bad_img     <= {MAX_IMG{1'b0}};
            x_retry     <= 2'd0;
            chk_card    <= 1'b0;
            tmr <= tmr + 32'd1;
            if (t_2k) begin
                tmr      <= 32'd0; tclr <= 1'b1;
                sd_rst_r <= 1'b0;
                state    <= M_INIT;
            end
        end
        M_INIT: begin
            tmr <= tmr + 32'd1;
            if (sd_init_done) begin
                tmr    <= 32'd0; tclr <= 1'b1;
                status <= ST_SCAN;
                state  <= M_BOOT0;
            end else if (t_init) begin
                tmr    <= 32'd0; tclr <= 1'b1;
                status <= ST_NOCARD;
                state  <= M_RST;
            end
        end
        M_BOOT0: begin
            sd_sec_addr <= 32'd0;
            ctx   <= C_BOOT;
            x_ret <= M_BOOT0_D;
            state <= X_ISSUE;
        end
        M_BOOT0_D: begin
            if (boot_is_vbr) begin
                part_lba <= 32'd0;
                state    <= M_CALC0;
            end else if (boot_is_mbr) begin
                part_lba    <= b_plba;
                sd_sec_addr <= b_plba;
                ctx   <= C_BOOT;
                x_ret <= M_BOOT1_D;
                state <= X_ISSUE;
            end else begin
                status <= ST_FSERR;
                state  <= M_HALT;
            end
        end
        M_BOOT1_D: begin
            if (boot_is_vbr) state <= M_CALC0;
            else begin
                status <= ST_FSERR;
                state  <= M_HALT;
            end
        end
        M_CALC0: begin
            fat_lba <= part_lba + {16'd0, b_rsvd};
            vol_ser <= b_ser;
            case (b_spc)
                8'd1:   spc_shift <= 3'd0;
                8'd2:   spc_shift <= 3'd1;
                8'd4:   spc_shift <= 3'd2;
                8'd8:   spc_shift <= 3'd3;
                8'd16:  spc_shift <= 3'd4;
                8'd32:  spc_shift <= 3'd5;
                8'd64:  spc_shift <= 3'd6;
                default: spc_shift <= 3'd7;
            endcase
            state <= M_CALC1;
        end
        M_CALC1: begin
            data_lba <= fat_lba + ((b_nfats == 8'd2) ? {b_fatsz[30:0], 1'b0} : b_fatsz);
            state    <= M_CALC2;
        end
        M_CALC2: begin
            k_clus    <= b_root;
            k_sec     <= 8'd0;
            k_eof     <= (b_root < 32'd2);
            dir_end   <= 1'b0;
            dir_secs  <= 12'd0;
            img_count <= 5'd0;
            wav_found <= 1'b0; txt_found <= 1'b0; fnt_found <= 1'b0;
            dmode     <= D_ROOT; sp <= 3'd0;
            imgd_found <= 1'b0; musd_found <= 1'b0; subd_found <= 1'b0; cfg_found <= 1'b0;
            cfg_ok    <= 1'b0; cfg_rd <= 1'b0; cfg_clr <= 1'b1;
            state     <= M_DIR;
        end
        //------------------- 根目录扫描 -------------------
        M_DIR: begin
            if (k_eof) state <= M_NEXT;
            else begin
                ctx   <= C_DIR;
                k_ret <= M_DIR_D;
                state <= K_CALC0;
            end
        end
        M_DIR_D: begin
            dir_secs <= dir_secs + 12'd1;
            if (dir_end || k_eof || dir_secs == 12'hFFF) state <= M_NEXT;
            else                                           state <= M_DIR;
        end
        //------------------- 播放列表 / 分类文件夹 -------------------
        M_NEXT: begin
            dir_end  <= 1'b0;
            dir_secs <= 12'd0;
            k_sec    <= 8'd0;
            // 下一个要读的目录 / 文件的首簇: 无条件装入 (不加长 k_clus 写使能的组合路径), 用不到时也无妨
            k_clus   <= (sp == 3'd1 && !imgd_found) ? b_root : {4'd0, dclus_q};
            k_eof    <= (sp == 3'd1 && !imgd_found) ? (b_root < 32'd2) : (dclus_q < 28'd2);
            case (sp)
            3'd0: begin                              // 根目录扫描完: 先读播放列表 (读完在 M_CFG_W2 进入阶段 1)
                if (cfg_found) state <= M_CFG;
                else           sp    <= 3'd1;
            end
            3'd1: begin                              // 图片: IMG 文件夹 (有播放列表而没有 IMG 时重扫根目录)
                sp <= 3'd2;
                if (imgd_found || cfg_ok) begin
                    dmode     <= D_IMG;
                    img_count <= 5'd0;
                    pos_found <= {MAX_IMG{1'b0}};
                    state     <= M_DIR;
                end
            end
            3'd2: begin
                sp <= 3'd3;
                if (musd_found) begin
                    dmode <= D_MUS; wav_found <= 1'b0;
                    state <= M_DIR;
                end
            end
            3'd3: begin
                sp <= 3'd4;
                if (subd_found) begin
                    dmode <= D_SUB; txt_found <= 1'b0; fnt_found <= 1'b0;
                    state <= M_DIR;
                end
            end
            default: begin
                dmode <= D_ROOT;
                if (cfg_ok) begin
                    // 播放位置数 = 列表行数; 列表中找不到的图片按损坏处理
                    img_count <= (pos_found == {MAX_IMG{1'b0}}) ? 5'd0 : plen;
                    bad_img   <= ~pos_found;
                end
                state <= M_TXT;
            end
            endcase
        end
        M_CFG: begin                                 // k_clus / k_eof 已在 M_NEXT 装入
            f_off  <= 32'd0;
            cfg_rd <= 1'b1;
            state  <= M_CFG_RD;
        end
        M_CFG_RD: begin
            if (k_eof) state <= M_CFG_D;
            else begin
                ctx   <= C_TXT;
                k_ret <= M_CFG_D;
                state <= K_CALC0;
            end
        end
        M_CFG_D: begin
            if (k_eof || !f_cfg_in) begin
                cfg_rd  <= 1'b0;
                cfg_end <= 1'b1;                     // 提交最后一行 (文件末尾可以没有换行)
                state   <= M_CFG_W;
            end else
                state <= M_CFG_RD;
        end
        M_CFG_W:  state <= M_CFG_W2;
        M_CFG_W2: begin
            cfg_ok <= (plen != 5'd0);
            sp     <= 3'd1;
            state  <= M_NEXT;
        end
        //------------------- 字幕文本 -------------------
        M_TXT: begin
            if (txt_found) begin
                k_clus <= {4'd0, txt_clus}; k_sec <= 8'd0; k_eof <= (txt_clus < 28'd2);
                f_off  <= 32'd0;
                state  <= M_TXT_RD;
            end else
                state <= M_FNT;
        end
        M_TXT_RD: begin
            if (k_eof) state <= M_TXT_D;
            else begin
                ctx   <= C_TXT;
                k_ret <= M_TXT_D;
                state <= K_CALC0;
            end
        end
        M_TXT_D: begin
            if (k_eof || !f_txt_in) begin
                txt_ok  <= 1'b1;
                txt_len <= (txt_size >= 32'd512) ? 10'd512 : txt_size[9:0];
                state   <= M_FNT;
            end else
                state <= M_TXT_RD;
        end
        //------------------- 用户字库 -------------------
        M_FNT: begin
            if (fnt_found) begin
                k_clus <= {4'd0, fnt_clus}; k_sec <= 8'd0; k_eof <= (fnt_clus < 28'd2);
                f_off  <= 32'd0;
                state  <= M_FNT_RD;
            end else
                state <= M_SCANEND;
        end
        M_FNT_RD: begin
            if (k_eof) state <= M_FNT_D;
            else begin
                ctx   <= C_FNT;
                k_ret <= M_FNT_D;
                state <= K_CALC0;
            end
        end
        M_FNT_D: begin
            if (k_eof || !f_fnt_in) begin
                fnt_ok <= 1'b1;
                state  <= M_SCANEND;
            end else
                state <= M_FNT_RD;
        end
        M_SCANEND: begin
            ctx        <= C_NONE;
            status     <= (img_count == 5'd0) ? ST_NOIMG : ST_READY;
            w_clus     <= {4'd0, wav_clus};
            w_sec      <= 8'd0;
            w_eof      <= (wav_clus < 28'd2);
            w_phase    <= WP_RIFF;
            w_cnt      <= 4'd0;
            w_fmt_ok   <= 1'b0;
            wav_bad    <= 1'b0;
            wav_restart<= 1'b0;
            wav_active <= wav_found;
            plan_dirty <= 1'b1;
            if (pend) pend_new <= 1'b1;   // 扫描期间收到的请求重新处理
            state      <= M_SCHED;
        end
        //------------------- 调度 -------------------
        M_SCHED: begin
            ctx <= C_NONE;
            if (pend_new) begin
                pend_new   <= 1'b0;
                focus      <= pend_img;
                plan_dirty <= 1'b1;
                if ({1'b0, pend_img} >= img_count || bad_img[pend_img]) begin
                    ack_slot <= 3'd0; ack_ok <= 1'b0; ack_toggle <= ~ack_toggle; ack_img <= pend_img;
                    pend <= 1'b0;
                end else if (hit_pend) begin
                    ack_slot <= hit_pend_slot; ack_ok <= 1'b1; ack_toggle <= ~ack_toggle; ack_img <= pend_img;
                    pend <= 1'b0;
                end else if (img_job && job_img != pend_img) begin
                    // 正在预取别的图片: 放弃, 优先加载用户要看的
                    img_job <= 1'b0;
                    loading <= 1'b0;
                end
            end else if (chk_card) begin
                state <= M_PROBE;
            end else if (wav_need) begin
                k_clus <= w_clus; k_sec <= w_sec; k_eof <= w_eof;
                ctx    <= C_WAV;
                k_ret  <= M_WAV_D;
                state  <= K_CALC0;
            end else if (img_job) begin
                // 缩放器行缓存剩余不足一个扇区时先等它输出 (小图大倍数放大)
                if (scl_room) begin
                    k_clus <= p_clus; k_sec <= p_sec; k_eof <= p_eof;
                    ctx    <= C_IMG;
                    k_ret  <= M_IMG_D;
                    state  <= K_CALC0;
                end
            end else if (plan_dirty && status == ST_READY) begin
                plan_dirty <= 1'b0;
                state      <= M_PLAN0;
            end else if (idle_due) begin
                state <= M_PROBE;
            end
        end
        //------------------- 心跳 / 换卡核对 -------------------
        // 读分区引导扇区: 卡已拔出 -> X_WAIT 超时 -> 重新初始化失败 -> NOCARD, 等插卡后重新扫描;
        // 换了新卡 -> 新卡未初始化, 读超时 -> 重新初始化成功 -> 重读 -> 序列号不同 -> 重新扫描
        M_PROBE: begin
            sd_sec_addr <= part_lba;
            ctx   <= C_BOOT;
            x_ret <= M_PROBE_D;
            state <= X_ISSUE;
        end
        M_PROBE_D: begin
            ctx      <= C_NONE;
            chk_card <= 1'b0;
            if (boot_is_vbr && b_ser == vol_ser)
                state <= M_SCHED;
            else begin
                status <= ST_NOCARD;
                if (pend) pend_new <= 1'b1;
                state  <= M_RST;
            end
        end
        M_WAV_D: begin
            if (wav_restart || k_eof) begin
                // 播放到结尾: 回到文件头循环
                w_clus  <= {4'd0, wav_clus};
                w_sec   <= 8'd0;
                w_eof   <= 1'b0;
                w_phase <= WP_RIFF;
                w_cnt   <= 4'd0;
                wav_restart <= 1'b0;
            end else begin
                w_clus <= k_clus; w_sec <= k_sec; w_eof <= k_eof;
            end
            state <= M_SCHED;
        end
        M_IMG_D: begin
            p_clus <= k_clus; p_sec <= k_sec; p_eof <= k_eof;
            if (img_bad || scl_bad || (k_eof && scl_need)) begin
                bad_img[job_img] <= 1'b1;
                img_job    <= 1'b0;
                loading    <= 1'b0;
                plan_dirty <= 1'b1;
                if (pend && pend_img == job_img) begin
                    ack_slot <= job_slot; ack_ok <= 1'b0; ack_toggle <= ~ack_toggle; ack_img <= pend_img;
                    pend <= 1'b0;
                end
                state <= M_SCHED;
            end else if (!scl_need) begin
                // 源数据已够, 后面的扇区不必再读; 等缩放器送完剩余行和黑边
                tmr   <= 32'd0; tclr <= 1'b1;
                state <= M_IMG_FIN;
            end else
                state <= M_SCHED;
        end
        M_IMG_FIN: begin
            tmr <= tmr + 32'd1;
            if (!scl_done) begin
                tmr <= 32'd0; tclr <= 1'b1;      // 20 ms 超时从最后一个像素送出后开始计
            end else if (fin_now != fin_ref || t_fin) begin
                slot_valid[job_slot] <= 1'b1;
                slot_tag[job_slot]   <= job_img;
                img_job    <= 1'b0;
                loading    <= 1'b0;
                first_done <= 1'b1;
                plan_dirty <= 1'b1;
                if (pend && pend_img == job_img) begin
                    ack_slot <= job_slot; ack_ok <= 1'b1; ack_toggle <= ~ack_toggle; ack_img <= pend_img;
                    pend <= 1'b0;
                end
                state <= M_SCHED;
            end
        end
        //------------------- 预取规划 -------------------
        M_PLAN0: begin
            wl[0] <= focus;
            pn    <= nxt(focus, img_count);
            pv    <= (focus == 4'd0) ? img_count_m1[3:0] : focus - 4'd1;
            pi    <= 3'd1;
            state <= M_PLAN1;
        end
        M_PLAN1: begin
            pi <= pi + 3'd1;
            case (pi)
                3'd1: begin wl[1] <= pn; pn <= nxt(pn, img_count); end
                3'd2: begin wl[2] <= pn; pn <= nxt(pn, img_count); end
                3'd3: begin wl[3] <= pv; end
                3'd4: begin wl[4] <= pn; pn <= nxt(pn, img_count); end
                default: begin wl[5] <= pn; pi <= 3'd0; pl_ph <= 1'b0; state <= M_PLAN2; end
            endcase
        end
        M_PLAN2: begin
            // 两拍一个候选: 先寄存命中判定, 再决定
            pl_ph <= ~pl_ph;
            if (!pl_ph) begin
                cand_r     <= cand_cached;
                cand_bad_r <= bad_img[wl[pi]];
            end else if (!cand_r && !cand_bad_r) begin
                tgt   <= wl[pi];
                state <= M_VICT;
            end else if (pi == 3'd5)
                state <= M_SCHED;
            else
                pi <= pi + 3'd1;
        end
        M_VICT: begin
            if (vict_inv_any) begin
                job_slot <= vict_inv_slot;
                state    <= M_START;
            end else if (vict_ev_any) begin
                job_slot <= vict_ev_slot;
                state    <= M_START;
            end else
                state <= M_SCHED;
        end
        M_START: begin
            slot_valid[job_slot] <= 1'b0;
            scl_start <= 1'b1;                   // 先停住缩放器输出, 再复位写 FIFO
            job_img  <= tgt;
            load_img <= tgt;
            p_clus   <= {4'd0, img_clus[tgt]};
            p_sec    <= 8'd0;
            p_eof    <= (img_clus[tgt] < 28'd2);
            state    <= M_OPEN;
        end
        M_OPEN: begin
            write_addr <= slot_base(job_slot);
            write_req  <= 1'b1;
            tmr        <= 32'd0; tclr <= 1'b1;
            state      <= M_OPEN_ACK;
        end
        M_OPEN_ACK: begin
            tmr <= tmr + 32'd1;
            if (wack) begin
                write_req <= 1'b0;
                tmr       <= 32'd0; tclr <= 1'b1;
                state     <= M_OPEN_GAP;
            end else if (t_ack) begin
                write_req <= 1'b0;
                state     <= M_SCHED;
                plan_dirty<= 1'b1;
            end
        end
        M_OPEN_GAP: begin
            // 等待写 FIFO 复位释放
            tmr <= tmr + 32'd1;
            if (!wack && t_64) begin
                img_job <= 1'b1;
                loading <= 1'b1;
                f_off   <= 32'd0;
                h_off   <= 32'hFFFF_FFFF;
                img_bad <= 1'b0;
                fin_ref <= fin_now;
                state   <= M_SCHED;
            end
        end
        //------------------- 簇内扇区读取公共流程 -------------------
        K_CALC0: begin
            k_tmp <= (k_clus - 32'd2) << spc_shift;
            state <= K_CALC1;
        end
        K_CALC1: begin
            sd_sec_addr <= data_lba + k_tmp + {24'd0, k_sec};
            x_ret <= K_ADV;
            state <= X_ISSUE;
        end
        K_ADV: begin
            if (k_last) begin
                // 本簇读完: 查 FAT 表得到下一簇
                sd_sec_addr <= fat_lba + {7'd0, k_clus[31:7]};
                fat_off  <= k_clus[6:0];
                ctx_save <= ctx;
                ctx      <= C_FAT;
                x_ret    <= K_FATD;
                state    <= X_ISSUE;
            end else begin
                k_sec <= k_sec + 8'd1;
                state <= k_ret;
            end
        end
        K_FATD: begin
            k_clus <= {4'd0, fat_val[27:0]};
            k_sec  <= 8'd0;
            k_eof  <= (fat_val[27:0] >= 28'hFFFFFF8) || (fat_val[27:0] < 28'd2);
            ctx    <= ctx_save;
            state  <= k_ret;
        end
        X_ISSUE: begin
            sd_sec_read <= 1'b1;
            bidx  <= 9'd0;
            tmr   <= 32'd0; tclr <= 1'b1;
            state <= X_WAIT;
        end
        X_WAIT: begin
            tmr <= tmr + 32'd1;
            if (bend) begin
                sd_sec_read <= 1'b0;
                x_retry     <= 2'd0;
                state       <= x_ret;
            end else if (t_sec) begin
                sd_sec_read <= 1'b0;
                tmr         <= 32'd0; tclr <= 1'b1;
                if (x_retry != X_RETRY_MAX) begin
                    // 读超时 (卡内部整理、接触瞬断等): 只复位 TF 卡控制器, 重新初始化后重读同一扇区.
                    // 扫描结果、图片缓存和 WAV 播放位置全部保留, 音乐不会从头开始.
                    // SPI 读在收到数据令牌 FE 之前才会卡住, 此时本扇区还没有任何字节送出, 重读是安全的.
                    x_retry <= x_retry + 2'd1;
                    state   <= X_RST;
                end else begin
                    // 连续多次失败 (卡被拔出): 软复位后重新初始化和扫描
                    status  <= ST_NOCARD;
                    if (pend) pend_new <= 1'b1;
                    state   <= M_RST;
                end
            end
        end
        X_RST: begin
            sd_rst_r <= 1'b1;
            tmr <= tmr + 32'd1;
            if (t_2k) begin
                tmr      <= 32'd0; tclr <= 1'b1;
                sd_rst_r <= 1'b0;
                state    <= X_INIT;
            end
        end
        X_INIT: begin
            tmr <= tmr + 32'd1;
            if (sd_init_done) begin
                tmr   <= 32'd0; tclr <= 1'b1;
                chk_card <= 1'b1;          // 可能已换卡: 本次读完后先核对卷序列号
                state <= X_ISSUE;          // sd_sec_addr / ctx / x_ret 未变, 重发同一扇区
            end else if (t_init) begin
                tmr     <= 32'd0; tclr <= 1'b1;
                status  <= ST_NOCARD;
                if (pend) pend_new <= 1'b1;
                state   <= M_RST;
            end
        end
        M_HALT: begin
            // 文件系统错误: 1 秒后重试
            tmr <= tmr + 32'd1;
            if (t_1s) begin
                tmr   <= 32'd0; tclr <= 1'b1;
                state <= M_RST;
            end
        end
        default: state <= M_RST;
        endcase

        // 显示帧槽变化后, 原先被占用的帧槽可以回收, 重新规划预取
        if (cur_s1 != cur_s0)
            plan_dirty <= 1'b1;

        //=================== 播放器请求 (优先级最高, 放在最后) ===================
        if (req_evt) begin
            pend     <= 1'b1;
            pend_new <= 1'b1;
            pend_img <= req_img_s1;
        end
    end
end

endmodule
