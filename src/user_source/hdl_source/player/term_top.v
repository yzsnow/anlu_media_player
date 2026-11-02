//---------------------------------------------------------------------------
// 第二屏运维终端: HDMI1 输出 1024x600@60Hz (50 MHz 像素时钟, DVI)
//
//   屏幕为 128 列 x 37 行字符 (8x16), 显存每格 {字符码[8:0], 前景色[2:0]}, 上电初值即界面模板
//   (边框 / 面板标题 / 标签由 python/gen_term_rom.py 预置到 BRAM 初值, 不占逻辑).
//   动态内容由一个微程序引擎写入显存 (指令定义见 gen_term_rom.py, 该文件同时是逐位一致的参考模型):
//     P_STATUS  循环刷新三个状态面板 / 运行时间 / 日志计数 / 键盘状态
//     P_LOG     有事件时写一条日志 "[hh:mm:ss] 级别 消息 [后缀] [数值]" 到 15 行日志环
//               (渲染时按环头偏移映射行号, 滚动不搬数据)
//     P_CMDCLR  命令行回车后清行
//   状态来源 (src_clk = video_clk 域) 每 SNAP_DIV 拍用 toggle 握手整组采样一次 (保持寄存器稳定后再取, 多位一致);
//   相邻两次采样比较得到日志事件.
//   命令行 (4x4 矩阵键盘 kb_matrix4x4, 键码见该文件): A/B 循环选择命令 (写入命令名), 0~9 输入参数 (最多 2 位),
//   * 退格 (无参数时清除命令), # 校验后执行, C/D 直接执行 上一张/下一张.
//   命令号: 1 show <1~图片数>  2 next  3 prev  4 mode <0~3>  5 bright <0~16>  6 vol <0~16>  7 eff <0~8>
//           8 auto <0|1>  9 alarm (需 SW1 布防)
//   执行 = cmd_tgl 翻转, cmd_op / cmd_arg 保持到下一条命令 (player_ctrl 同步后执行, show 的参数已减 1);
//   成功写日志 "CMD 执行 <命令> <参数>", 失败写 WARN (未选命令 / 参数错误 / 未布防 / 报警中 / TF 卡未就绪) 且不执行.
//
//   渲染流水线: c0 计数器 -> 显存地址 | c1 显存数据 -> 字库地址 | c2 字库数据 | c3 RGB | +2 TMDS
//   1024x600 时序: H 1024 + 40 + 128 + 152 = 1344, V 600 + 3 + 6 + 11 = 620, 同步负极性
//---------------------------------------------------------------------------
module term_top #(
    parameter SEC_DIV  = 50_000_000,      // 运行时间 1 s
    parameter SNAP_DIV = 50_000,          // 状态同步周期 1 ms
    parameter BLINK    = 5                // 光标闪烁: 帧计数第 BLINK 位 (2^5 帧 = 0.53 s)
)(
    input             clk,                // term_clk 50 MHz
    input             rst,
    // ---- 状态 (src_clk 域, 准静态) ----
    input             src_clk,
    input             src_rst,
    input      [2:0]  st,                 // 加载器状态 0 初始化 1 扫描 2 就绪 3 无卡 4 文件系统错误 5 无图片
    input      [4:0]  img_cnt,
    input             wav_ok,
    input             txt_ok,
    input             fnt_ok,
    input      [7:0]  load_prog,
    input      [3:0]  cur_img,
    input      [3:0]  eff_sel,
    input             auto_on,
    input      [1:0]  amode,
    input             menu_on,
    input      [1:0]  pmode,
    input      [4:0]  bri,
    input      [4:0]  con,
    input      [4:0]  temp,
    input      [4:0]  gam,
    input      [4:0]  vol,
    input             wave_on,
    input             alarm_on,
    input      [1:0]  alm_src,            // 报警来源 0 KEY1 1 烟雾 2 火焰 3 终端命令
    input             preheat,            // MQ-2 预热中
    input      [3:0]  vu,
    input             msg_bad,
    input      [2:0]  fsm,                // 状态机 0 空闲 1 搜索BMP 2 写入SDRAM 3 OSD叠加 4 错误
    input      [2:0]  rate,
    input      [3:0]  sw,                 // 拨码开关 SW4..SW1 (异步, 内部同步)
    // ---- 键盘 (预留, clk 域) ----
    input             kb_vld,
    input      [7:0]  kb_ascii,
    // ---- 输出 ----
    output reg        o_de,
    output reg        o_hs,
    output reg        o_vs,
    output reg [23:0] o_rgb,
    output     [9:0]  tmds0,
    output     [9:0]  tmds1,
    output     [9:0]  tmds2,
    // ---- 命令输出 (clk 域, 电平保持; 接 player_ctrl, 对方同步) ----
    output reg        cmd_tgl,
    output reg [3:0]  cmd_op,
    output reg [4:0]  cmd_arg
);
`include "term_prog.vh"

//===========================================================================
// 状态采样: src_clk 域保持寄存器 + toggle 握手
//===========================================================================
localparam SNW = 3+5+1+1+1+8+4+4+1+2+1+2+25+1+1+2+1+4+1+3+3+4;   // 79
reg  [3:0] sw_m, sw_s;
always @(posedge src_clk) begin
    sw_m <= sw;
    sw_s <= sw_m;
end
wire [SNW-1:0] snap_in = {st, img_cnt, wav_ok, txt_ok, fnt_ok, load_prog, cur_img, eff_sel, auto_on, amode,
                          menu_on, pmode, bri, con, temp, gam, vol, wave_on, alarm_on, alm_src, preheat, vu, msg_bad, fsm, rate, sw_s};
reg            req_t, ack_t;
reg  [2:0]     req_s;
reg  [SNW-1:0] hold;
always @(posedge src_clk) begin
    if (src_rst) begin
        req_s <= 3'd0;
        ack_t <= 1'b0;
    end else begin
        req_s <= {req_s[1:0], req_t};
        if (req_s[2] ^ req_s[1]) begin
            hold  <= snap_in;
            ack_t <= ~ack_t;
        end
    end
end

reg  [2:0]     ack_s;
reg  [16:0]    snap_cnt;
reg            snap_busy, snap_new;
reg  [SNW-1:0] snap;
always @(posedge clk) begin
    if (rst) begin
        ack_s <= 3'd0; req_t <= 1'b0; snap_cnt <= 17'd0; snap_busy <= 1'b0; snap_new <= 1'b0;
        snap <= {SNW{1'b0}};
    end else begin
        ack_s    <= {ack_s[1:0], ack_t};
        snap_new <= 1'b0;
        if (ack_s[2] ^ ack_s[1]) begin
            snap      <= hold;
            snap_new  <= 1'b1;
            snap_busy <= 1'b0;
        end
        if (snap_cnt == SNAP_DIV - 1) begin
            snap_cnt <= 17'd0;
            if (!snap_busy) begin
                req_t     <= ~req_t;
                snap_busy <= 1'b1;
            end
        end else
            snap_cnt <= snap_cnt + 17'd1;
    end
end

wire [2:0] s_st;   wire [4:0] s_cnt;  wire s_wav, s_txt, s_fnt; wire [7:0] s_prog; wire [3:0] s_cur, s_eff;
wire s_auto;       wire [1:0] s_amode; wire s_menu; wire [1:0] s_pmode; wire [4:0] s_bri, s_con, s_temp, s_gam, s_vol;
wire s_wave, s_alarm; wire [1:0] s_asrc; wire s_pre; wire [3:0] s_vu; wire s_bad; wire [2:0] s_fsm, s_rate; wire [3:0] s_sw;
assign {s_st, s_cnt, s_wav, s_txt, s_fnt, s_prog, s_cur, s_eff, s_auto, s_amode, s_menu, s_pmode,
        s_bri, s_con, s_temp, s_gam, s_vol, s_wave, s_alarm, s_asrc, s_pre, s_vu, s_bad, s_fsm, s_rate, s_sw} = snap;

//===========================================================================
// 运行时间 hh:mm:ss (BCD)
//===========================================================================
reg [25:0] sec_cnt;
reg [3:0]  t_s0, t_m0, t_h0, t_h1;
reg [2:0]  t_s1, t_m1;
always @(posedge clk) begin
    if (rst) begin
        sec_cnt <= 26'd0;
        {t_h1, t_h0, t_m1, t_m0, t_s1, t_s0} <= 22'd0;
    end else if (sec_cnt == SEC_DIV - 1) begin
        sec_cnt <= 26'd0;
        if (t_s0 != 4'd9) t_s0 <= t_s0 + 4'd1;
        else begin
            t_s0 <= 4'd0;
            if (t_s1 != 3'd5) t_s1 <= t_s1 + 3'd1;
            else begin
                t_s1 <= 3'd0;
                if (t_m0 != 4'd9) t_m0 <= t_m0 + 4'd1;
                else begin
                    t_m0 <= 4'd0;
                    if (t_m1 != 3'd5) t_m1 <= t_m1 + 3'd1;
                    else begin
                        t_m1 <= 3'd0;
                        if (t_h0 != 4'd9) t_h0 <= t_h0 + 4'd1;
                        else begin
                            t_h0 <= 4'd0;
                            t_h1 <= (t_h1 == 4'd9) ? 4'd0 : t_h1 + 4'd1;
                        end
                    end
                end
            end
        end
    end else
        sec_cnt <= sec_cnt + 26'd1;
end

//===========================================================================
// 日志事件: 相邻两次采样比较, 置待处理位 (同一类事件未处理前再次变化只记最新值)
//===========================================================================
reg            snap_first;
reg  [SNW-1:0] prev;
reg  [NEV-1:0] pend;
reg            lg_ok, lg_bad;             // 引擎: 命令执行 / 命令错误 -> 日志事件
wire [2:0] p_st;   wire [4:0] p_cnt;  wire p_wav, p_txt, p_fnt; wire [7:0] p_prog; wire [3:0] p_cur, p_eff;
wire p_auto;       wire [1:0] p_amode; wire p_menu; wire [1:0] p_pmode; wire [4:0] p_bri, p_con, p_temp, p_gam, p_vol;
wire p_wave, p_alarm; wire [1:0] p_asrc; wire p_pre; wire [3:0] p_vu; wire p_bad; wire [2:0] p_fsm, p_rate; wire [3:0] p_sw;
assign {p_st, p_cnt, p_wav, p_txt, p_fnt, p_prog, p_cur, p_eff, p_auto, p_amode, p_menu, p_pmode,
        p_bri, p_con, p_temp, p_gam, p_vol, p_wave, p_alarm, p_asrc, p_pre, p_vu, p_bad, p_fsm, p_rate, p_sw} = prev;

wire [NEV-1:0] ev_set;
assign ev_set[E_BOOT]  = 1'b0;
assign ev_set[E_ST]    = s_st    != p_st;
assign ev_set[E_IMG]   = s_cur   != p_cur;
assign ev_set[E_MENU]  = s_menu  != p_menu;
assign ev_set[E_PMODE] = s_pmode != p_pmode;
assign ev_set[E_ARM]   = s_sw[0] != p_sw[0];
assign ev_set[E_ALM]   = s_alarm != p_alarm;
assign ev_set[E_WAVE]  = s_wave  != p_wave;
assign ev_set[E_AUTO]  = s_auto  != p_auto;
assign ev_set[E_EFF]   = s_eff   != p_eff;
assign ev_set[E_AMODE] = s_amode != p_amode;
assign ev_set[E_WAV]   = s_wav   & ~p_wav;
assign ev_set[E_BAD]   = s_bad   & ~p_bad;
assign ev_set[E_CMD]   = 1'b0;
assign ev_set[E_CMDERR] = 1'b0;

// 引擎取走的事件 (清待处理位)
reg  [3:0]     ev_k;
reg            ev_take;
always @(posedge clk) begin
    if (rst) begin
        snap_first <= 1'b1;
        prev       <= {SNW{1'b0}};
        pend       <= {{(NEV-1){1'b0}}, 1'b1};     // 上电日志
    end else begin
        if (snap_new) begin
            prev       <= snap;
            snap_first <= 1'b0;
        end
        // 先清已取走的, 再置新事件 (同一拍再次发生不丢)
        pend <= (pend & ~(ev_take ? ({{(NEV-1){1'b0}}, 1'b1} << ev_k) : {NEV{1'b0}}))
              | ((snap_new && !snap_first) ? ev_set : {NEV{1'b0}})
              | (lg_ok  ? ({{(NEV-1){1'b0}}, 1'b1} << E_CMD)    : {NEV{1'b0}})
              | (lg_bad ? ({{(NEV-1){1'b0}}, 1'b1} << E_CMDERR) : {NEV{1'b0}});
    end
end

// 最低位优先
reg  [3:0] ev_pick;
integer    ei;
always @(*) begin
    ev_pick = 4'd0;
    for (ei = NEV - 1; ei >= 0; ei = ei - 1)
        if (pend[ei]) ev_pick = ei;
end

// 最近一条命令 (日志用)
reg  [3:0] lg_op;
reg  [6:0] lg_val;
reg        lg_has;
reg  [2:0] lg_err;

// 事件值 (选消息 / 后缀) 与数值
function [7:0] ev_value;
    input [3:0] e;
    begin
        case (e)
            E_ST:    ev_value = {5'd0, s_st};
            E_MENU:  ev_value = {7'd0, s_menu};
            E_PMODE: ev_value = {6'd0, s_pmode};
            E_ARM:   ev_value = {7'd0, s_sw[0]};
            E_ALM:   ev_value = !s_alarm ? 8'd0 : (s_asrc == 2'd1) ? 8'd2 : (s_asrc == 2'd2) ? 8'd3 : 8'd1;   // 0 解除 1 KEY1/终端 2 烟雾 3 火焰
            E_WAVE:  ev_value = {7'd0, s_wave};
            E_AUTO:  ev_value = {7'd0, s_auto};
            E_EFF:   ev_value = {4'd0, s_eff};
            E_AMODE: ev_value = {6'd0, s_amode};
            E_CMD:   ev_value = {4'd0, lg_op};
            E_CMDERR: ev_value = {5'd0, lg_err};
            default: ev_value = 8'd0;
        endcase
    end
endfunction

//===========================================================================
// 微程序引擎
//===========================================================================
localparam OPS_STR = 2'd0, OPS_DEC = 2'd1, OPS_POS = 2'd2, OPS_PAD = 2'd3;
localparam [3:0] S_IDLE = 4'd0, S_FETCH = 4'd1, S_EXEC = 4'd2, S_DATA = 4'd3, S_DATA2 = 4'd4,
                 S_DEC = 4'd5, S_BAR = 4'd6, S_TIME = 4'd7, S_PAD = 4'd8, S_KB = 4'd9;
localparam [4:0] SRC_ESUF = 5'd29, SRC_EMSG = 5'd30, SRC_EARG = 5'd31;

reg  [3:0]  es;
reg  [10:0] pc, ret;
reg         in_str, task_log, task_cw;
reg  [1:0]  op;
reg  [4:0]  op_src;
reg  [5:0]  row;
reg  [6:0]  col, tgt;
reg  [2:0]  colr;
reg  [7:0]  v;
reg  [3:0]  k;
reg         lead, dtrim, dzero;
reg  [3:0]  log_wr, log_cnt;
reg  [7:0]  log_total;
reg  [21:0] ev_t;
reg  [7:0]  ev_val, ev_arg;
reg         ev_has;
reg         kb_pend;
reg  [7:0]  kb_char;
reg  [6:0]  cur;
reg  [3:0]  cmd_sel;                      // 0 = 未选, 1~9
reg  [1:0]  ndig;
reg  [3:0]  d_hi, d_lo;

wire [8:0]  q;
term_prog_rom u_prog(.clk(clk), .addr(pc), .q(q));

reg         we;
reg  [12:0] waddr;
reg  [8:0]  wcode;
reg  [2:0]  wcol;

wire [14:0] p100   = {s_prog, 6'd0} + {1'b0, s_prog, 5'd0} + {4'd0, s_prog, 2'd0} + 15'd128;
wire [7:0]  s_pct  = p100[14:8];                    // (prog * 100 + 128) >> 8
wire [8:0]  p16    = {1'b0, s_prog} + 9'd8;

function [7:0] src_val;
    input [4:0] s;
    begin
        case (s)
            5'd0:  src_val = {5'd0, s_st};
            5'd1:  src_val = {3'd0, s_cnt};
            5'd2:  src_val = {7'd0, s_wav};
            5'd3:  src_val = {7'd0, s_txt};
            5'd4:  src_val = {7'd0, s_fnt};
            5'd5:  src_val = s_alarm ? 8'd2 : !s_sw[0] ? 8'd0 : s_pre ? 8'd3 : 8'd1;
            5'd6:  src_val = {7'd0, s_sw[0]};
            5'd7:  src_val = {7'd0, s_sw[1]};
            5'd8:  src_val = {7'd0, s_sw[2]};
            5'd9:  src_val = {7'd0, s_sw[3]};
            5'd10: src_val = {4'd0, s_cur} + 8'd1;
            5'd11: src_val = {5'd0, s_fsm};
            5'd12: src_val = {3'd0, p16[8:4]};
            5'd13: src_val = s_pct;
            5'd14: src_val = {4'd0, s_eff};
            5'd15: src_val = {7'd0, s_auto};
            5'd16: src_val = {7'd0, s_wave};
            5'd17: src_val = {7'd0, s_menu};
            5'd18: src_val = {6'd0, s_amode};
            5'd19: src_val = {6'd0, s_pmode};
            5'd20: src_val = {3'd0, s_bri};
            5'd21: src_val = {3'd0, s_con};
            5'd22: src_val = {3'd0, s_temp};
            5'd23: src_val = {3'd0, s_gam};
            5'd24: src_val = {3'd0, s_vol};
            5'd25: src_val = {4'd0, s_vu};
            5'd26: src_val = {5'd0, s_rate};
            5'd28: src_val = log_total;
            5'd27: src_val = {4'd0, cmd_sel};
            5'd31: src_val = ev_arg;
            default: src_val = 8'd0;
        endcase
    end
endfunction

// 8 位二进制 -> 3 位 BCD (组合)
wire [3:0] bcd_h = (v >= 8'd200) ? 4'd2 : (v >= 8'd100) ? 4'd1 : 4'd0;
wire [7:0] v_lo  = v - {bcd_h, 6'd0} - {bcd_h, 5'd0} - {bcd_h, 2'd0};    // v - 100 * h
wire [3:0] bcd_t = (v_lo >= 8'd90) ? 4'd9 : (v_lo >= 8'd80) ? 4'd8 : (v_lo >= 8'd70) ? 4'd7 :
                   (v_lo >= 8'd60) ? 4'd6 : (v_lo >= 8'd50) ? 4'd5 : (v_lo >= 8'd40) ? 4'd4 :
                   (v_lo >= 8'd30) ? 4'd3 : (v_lo >= 8'd20) ? 4'd2 : (v_lo >= 8'd10) ? 4'd1 : 4'd0;
wire [3:0] bcd_o = v_lo - {bcd_t, 3'd0} - {bcd_t, 1'b0};                   // v_lo - 10 * t
wire [3:0] dg    = (k == 4'd0) ? bcd_h : (k == 4'd1) ? bcd_t : bcd_o;

// TIME 第 k 个字符: ev_t = {h1[3:0], h0[3:0], m1[2:0], m0[3:0], s1[2:0], s0[3:0]}
reg  [8:0] tchar;
always @(*) begin
    case (k[2:0])
        3'd0: tchar = {5'h03, ev_t[21:18]};
        3'd1: tchar = {5'h03, ev_t[17:14]};
        3'd3: tchar = {5'h03, 1'b0, ev_t[13:11]};
        3'd4: tchar = {5'h03, ev_t[10:7]};
        3'd6: tchar = {5'h03, 1'b0, ev_t[6:4]};
        3'd7: tchar = {5'h03, ev_t[3:0]};
        default: tchar = 9'h03A;            // ':'
    endcase
end

wire [19:0] evt   = ev_tab(ev_k);         // {按值选, 有后缀, 后缀数据字, 消息数据字}
wire [8:0]  str_d = (op_src == SRC_EMSG) ? evt[8:0] : (op_src == SRC_ESUF) ? evt[17:9] : q;
wire [7:0]  str_i = {1'b0, str_d[6:0]} + v;
wire [12:0] str_a = (str_d[8:7] == 2'd0) ? {1'b0, str_i, 4'd0} :
                    (str_d[8:7] == 2'd1) ? {str_i, 5'd0} : {str_i[6:0], 6'd0};

// 命令校验 (S_KB 中按下 # / C / D 时使用)
wire       x_hot  = (kb_char == 8'h13) || (kb_char == 8'h14);
wire [3:0] x_op   = (kb_char == 8'h13) ? 4'd3 : (kb_char == 8'h14) ? 4'd2 : cmd_sel;
wire [1:0] x_nd   = x_hot ? 2'd0 : ndig;
wire [6:0] x_val  = (ndig == 2'd2) ? ({d_hi, 3'd0} + {2'd0, d_hi, 1'b0} + {3'd0, d_lo}) : {3'd0, d_hi};
wire       x_need = (x_op == 4'd1) || (x_op >= 4'd4 && x_op <= 4'd8);
reg  [6:0] x_max;
always @(*) begin
    case (x_op)
        4'd1:       x_max = {2'd0, s_cnt};
        4'd4:       x_max = 7'd3;
        4'd5, 4'd6: x_max = 7'd16;
        4'd7:       x_max = 7'd8;
        4'd8:       x_max = 7'd1;
        default:    x_max = 7'd0;
    endcase
end
wire       x_e0   = (x_op == 4'd0);
wire       x_e3   = s_alarm;
wire       x_e2   = (x_op == 4'd9) && !s_sw[0];
wire       x_e4   = (x_op >= 4'd1 && x_op <= 4'd3) && !(s_st == 3'd2 && s_cnt != 5'd0);
wire       x_e1   = x_need && (x_nd == 2'd0 || x_val > x_max || (x_op == 4'd1 && x_val == 7'd0));
wire       x_ok   = !(x_e0 | x_e1 | x_e2 | x_e3 | x_e4);
wire [2:0] x_err  = x_e0 ? 3'd0 : x_e3 ? 3'd3 : x_e2 ? 3'd2 : x_e4 ? 3'd4 : 3'd1;

always @(posedge clk) begin
    if (rst) begin
        es <= S_IDLE; pc <= 11'd0; ret <= 11'd0; in_str <= 1'b0; task_log <= 1'b0; task_cw <= 1'b0;
        op <= OPS_STR; op_src <= 5'd0; row <= 6'd0; col <= 7'd0; tgt <= 7'd0; colr <= 3'd1;
        v <= 8'd0; k <= 4'd0; lead <= 1'b0; dtrim <= 1'b0; dzero <= 1'b0;
        log_wr <= 4'd0; log_cnt <= 4'd0; log_total <= 8'd0;
        ev_k <= 4'd0; ev_take <= 1'b0; ev_val <= 8'd0; ev_arg <= 8'd0; ev_has <= 1'b0; ev_t <= 22'd0;
        kb_pend <= 1'b0; kb_char <= 8'd0; lg_ok <= 1'b0; lg_bad <= 1'b0; cur <= CMD_C0;
        cmd_sel <= 4'd0; ndig <= 2'd0; d_hi <= 4'd0; d_lo <= 4'd0;
        lg_op <= 4'd0; lg_val <= 7'd0; lg_has <= 1'b0; lg_err <= 3'd0;
        cmd_tgl <= 1'b0; cmd_op <= 4'd0; cmd_arg <= 5'd0;
        we <= 1'b0; waddr <= 13'd0; wcode <= 9'd0; wcol <= 3'd0;
    end else begin
        we       <= 1'b0;
        ev_take  <= 1'b0;
        lg_ok    <= 1'b0;
        lg_bad   <= 1'b0;
        if (kb_vld && !kb_pend) begin
            kb_pend <= 1'b1;
            kb_char <= kb_ascii;
        end
        case (es)
        S_IDLE: begin
            colr   <= 3'd1;
            in_str <= 1'b0;
            ev_t   <= {t_h1, t_h0, t_m1, t_m0, t_s1, t_s0};
            if (|pend && !ev_take) begin
                ev_k     <= ev_pick;
                ev_take  <= 1'b1;
                ev_val   <= ev_value(ev_pick);
                ev_arg   <= (ev_pick == E_ST) ? {3'd0, s_cnt} : (ev_pick == E_CMD) ? {1'b0, lg_val} :
                            {4'd0, s_cur} + 8'd1;
                ev_has   <= (ev_pick == E_ST) ? (s_st == 3'd2) : (ev_pick == E_CMD) ? lg_has : (ev_pick == E_IMG);
                pc       <= P_LOG;
                task_log <= 1'b1;
                task_cw  <= 1'b0;
                es       <= S_FETCH;
            end else if (kb_pend) begin
                es <= S_KB;
            end else begin
                pc       <= P_STATUS;
                task_log <= 1'b0;
                task_cw  <= 1'b0;
                es       <= S_FETCH;
            end
        end
        S_FETCH: begin
            pc <= pc + 11'd1;
            es <= S_EXEC;
        end
        S_EXEC: begin
            op_src <= q[4:0];
            k      <= 4'd0;
            if (q < 9'h180) begin                              // 字符
                we <= 1'b1; waddr <= {row, col}; wcode <= q; wcol <= colr;
                col <= col + 7'd1;
                es  <= S_FETCH;
            end else if (q < 9'h1A0) begin                     // STR
                op <= OPS_STR;
                v  <= (q[4:0] == SRC_EMSG) ? (evt[19] ? ev_val : 8'd0) :
                      (q[4:0] == SRC_ESUF) ? ev_val : src_val(q[4:0]);
                pc <= pc + 11'd1;
                es <= S_DATA;
            end else if (q < 9'h1C0) begin                     // DEC
                op <= OPS_DEC;
                v  <= src_val(q[4:0]);
                pc <= pc + 11'd1;
                es <= S_DATA;
            end else if (q < 9'h1E0) begin                     // BAR
                v  <= src_val(q[4:0]);
                es <= S_BAR;
            end else if (q == 9'h1E0) begin                    // END
                pc     <= ret;
                in_str <= 1'b0;
                es     <= S_FETCH;
            end else if (q == 9'h1E1) begin                    // HALT
                if (task_log) begin
                    log_wr    <= (log_wr == LOG_N - 1) ? 4'd0 : log_wr + 4'd1;
                    log_cnt   <= (log_cnt == LOG_N) ? log_cnt : log_cnt + 4'd1;
                    log_total <= (log_total == 8'd255) ? log_total : log_total + 8'd1;
                end
                if (task_cw) cur <= col;                       // 命令名写完: 光标放在其后
                es <= S_IDLE;
            end else if (q == 9'h1E2) begin                    // TIME
                es <= S_TIME;
            end else if (q == 9'h1E3) begin                    // PAD
                op <= OPS_PAD;
                pc <= pc + 11'd1;
                es <= S_DATA;
            end else if (q == 9'h1E4) begin                    // SETPOS r, c
                op <= OPS_POS;
                pc <= pc + 11'd1;
                es <= S_DATA;
            end else if (q == 9'h1E5) begin                    // SETPOS_LOG c
                row <= LOG_TOP + {2'd0, log_wr};
                op  <= OPS_POS;
                pc  <= pc + 11'd1;
                es  <= S_DATA2;
            end else begin                                     // SETCOL
                colr <= q[2:0];
                es   <= S_FETCH;
            end
        end
        S_DATA: begin
            case (op)
            OPS_STR: begin
                if (op_src == SRC_ESUF && !evt[18])
                    es <= S_FETCH;
                else begin
                    ret    <= pc;
                    pc     <= str_a[10:0];
                    in_str <= 1'b1;
                    es     <= S_FETCH;
                end
            end
            OPS_DEC: begin
                dzero <= q[2];
                dtrim <= q[3];
                lead  <= 1'b1;
                k     <= 4'd3 - {2'd0, q[1:0]};
                es    <= (op_src == SRC_EARG && !ev_has) ? S_FETCH : S_DEC;
            end
            OPS_POS: begin
                row <= q[5:0];
                pc  <= pc + 11'd1;
                es  <= S_DATA2;
            end
            default: begin                                     // PAD
                tgt <= q[6:0];
                es  <= S_PAD;
            end
            endcase
        end
        S_DATA2: begin                                         // 位置的列
            col <= q[6:0];
            es  <= S_FETCH;
        end
        S_DEC: begin
            k <= k + 4'd1;
            if (lead && dg == 4'd0 && k != 4'd2) begin
                if (!dtrim) begin
                    we <= 1'b1; waddr <= {row, col}; wcode <= dzero ? 9'h030 : 9'h020; wcol <= colr;
                    col <= col + 7'd1;
                end
            end else begin
                lead <= 1'b0;
                we <= 1'b1; waddr <= {row, col}; wcode <= {5'h03, dg}; wcol <= colr;
                col <= col + 7'd1;
            end
            if (k == 4'd2) es <= S_FETCH;
        end
        S_BAR: begin
            we    <= 1'b1;
            waddr <= {row, col};
            wcode <= ({4'd0, k} < v) ? 9'h00B : 9'h00C;
            wcol  <= ({4'd0, k} < v) ? colr : 3'd0;
            col   <= col + 7'd1;
            k     <= k + 4'd1;
            if (k == 4'd15) es <= S_FETCH;
        end
        S_TIME: begin
            we <= 1'b1; waddr <= {row, col}; wcode <= tchar; wcol <= colr;
            col <= col + 7'd1;
            k   <= k + 4'd1;
            if (k == 4'd7) es <= S_FETCH;
        end
        S_PAD: begin
            if (col < tgt) begin
                we <= 1'b1; waddr <= {row, col}; wcode <= 9'h020; wcol <= colr;
                col <= col + 7'd1;
            end else
                es <= S_FETCH;
        end
        S_KB: begin
            kb_pend <= 1'b0;
            es      <= S_IDLE;
            if (kb_char >= 8'h30 && kb_char <= 8'h39) begin        // 数字: 选了命令才接受, 最多 2 位
                if (cmd_sel != 4'd0 && ndig != 2'd2) begin
                    we <= 1'b1; waddr <= {CMD_ROW, cur}; wcode <= {1'b0, kb_char}; wcol <= 3'd1;
                    cur  <= cur + 7'd1;
                    ndig <= ndig + 2'd1;
                    if (ndig == 2'd0) d_hi <= kb_char[3:0]; else d_lo <= kb_char[3:0];
                end
            end else if (kb_char == 8'h08) begin                   // * 退格
                if (ndig != 2'd0) begin
                    we <= 1'b1; waddr <= {CMD_ROW, cur - 7'd1}; wcode <= 9'h020; wcol <= 3'd1;
                    cur  <= cur - 7'd1;
                    ndig <= ndig - 2'd1;
                end else if (cmd_sel != 4'd0) begin
                    cmd_sel  <= 4'd0;
                    cur      <= CMD_C0;
                    pc       <= P_CMDCLR;
                    task_log <= 1'b0;
                    task_cw  <= 1'b0;
                    es       <= S_FETCH;
                end
            end else if (kb_char == 8'h11 || kb_char == 8'h12) begin  // A / B 选命令
                cmd_sel  <= (kb_char == 8'h11) ? ((cmd_sel >= 4'd9) ? 4'd1 : cmd_sel + 4'd1)
                                               : ((cmd_sel <= 4'd1) ? 4'd9 : cmd_sel - 4'd1);
                ndig     <= 2'd0;
                pc       <= P_CMDW;
                task_log <= 1'b0;
                task_cw  <= 1'b1;
                es       <= S_FETCH;
            end else if (kb_char == 8'h0D || x_hot) begin          // # 执行 / C D 快捷
                if (x_ok) begin
                    cmd_tgl <= ~cmd_tgl;
                    cmd_op  <= x_op;
                    cmd_arg <= !x_need ? 5'd0 : (x_op == 4'd1) ? x_val[4:0] - 5'd1 : x_val[4:0];
                    lg_op   <= x_op;
                    lg_val  <= x_val;
                    lg_has  <= x_need;
                    lg_ok   <= 1'b1;
                end else begin
                    lg_err  <= x_err;
                    lg_bad  <= 1'b1;
                end
                if (!x_hot) begin
                    cmd_sel  <= 4'd0;
                    ndig     <= 2'd0;
                    cur      <= CMD_C0;
                    pc       <= P_CMDCLR;
                    task_log <= 1'b0;
                    task_cw  <= 1'b0;
                    es       <= S_FETCH;
                end
            end
        end
        default: es <= S_IDLE;
        endcase
    end
end

//===========================================================================
// 显存 + 字库
//===========================================================================
reg  [10:0] hc;
reg  [9:0]  vc;
reg  [5:0]  fc;                           // 帧计数 (光标闪烁)
wire [5:0]  r0   = vc[9:4];
wire [6:0]  cl0  = hc[9:3];
wire [3:0]  head = (log_cnt == LOG_N) ? log_wr : 4'd0;
wire        inlg = (r0 >= LOG_TOP) && (r0 < LOG_TOP + LOG_N);
wire [5:0]  pk   = r0 - LOG_TOP + {2'd0, head};
wire [5:0]  prow = inlg ? ((pk >= LOG_N) ? pk - LOG_N + LOG_TOP : pk + LOG_TOP) :
                   (r0 > 6'd36) ? 6'd36 : r0;
wire [12:0] raddr = {prow, cl0};
wire [8:0]  vq_code;
wire [2:0]  vq_col;
term_vram_c u_vram_c(.clk(clk), .we(we), .waddr(waddr), .wdata(wcode), .raddr(raddr), .q(vq_code));
term_vram_a u_vram_a(.clk(clk), .we(we), .waddr(waddr), .wdata(wcol),  .raddr(raddr), .q(vq_col));

wire        de0  = (hc < 11'd1024) && (vc < 10'd600);
wire        hs0  = ~((hc >= 11'd1064) && (hc < 11'd1192));
wire        vs0  = ~((vc >= 10'd603) && (vc < 10'd609));
wire        cur0 = (r0 == CMD_ROW) && (cl0 == cur) && fc[BLINK];

reg  [2:0]  bx1, bx2;
reg  [3:0]  vr1;
reg  [5:0]  r1, r2;
reg         de1, hs1, vs1, cu1, de2, hs2, vs2, cu2;
reg  [2:0]  col2;
wire [7:0]  fq;
term_font_rom u_font(.clk(clk), .addr({vq_code, vr1}), .q(fq));

always @(posedge clk) begin
    if (rst) begin
        hc <= 11'd0; vc <= 10'd0; fc <= 6'd0;
    end else if (hc == 11'd1343) begin
        hc <= 11'd0;
        if (vc == 10'd619) begin
            vc <= 10'd0;
            fc <= fc + 6'd1;
        end else
            vc <= vc + 10'd1;
    end else
        hc <= hc + 11'd1;
    // c1
    bx1 <= hc[2:0]; vr1 <= vc[3:0]; r1 <= r0; de1 <= de0; hs1 <= hs0; vs1 <= vs0; cu1 <= cur0;
    // c2
    bx2 <= bx1; r2 <= r1; de2 <= de1; hs2 <= hs1; vs2 <= vs1; cu2 <= cu1; col2 <= vq_col;
end

// c3: RGB
wire        bit2 = (r2 <= 6'd36) && fq[3'd7 - bx2];
wire [23:0] bg2  = (r2 == 6'd0) ? BG_TITLE : (r2 >= 6'd36) ? BG_SBAR : BG_MAIN;
always @(posedge clk) begin
    o_de  <= de2;
    o_hs  <= hs2;
    o_vs  <= vs2;
    o_rgb <= !de2 ? 24'd0 : cu2 ? (bit2 ? bg2 : CURSOR) : (bit2 ? pal(col2) : bg2);
end

//===========================================================================
// TMDS: 通道 0 = B + {VS, HS}, 通道 1 = G, 通道 2 = R
//===========================================================================
tmds_encoder u_enc0(.clk(clk), .rst(rst), .de(o_de), .c0(o_hs), .c1(o_vs), .d(o_rgb[7:0]),   .q(tmds0));
tmds_encoder u_enc1(.clk(clk), .rst(rst), .de(o_de), .c0(1'b0), .c1(1'b0), .d(o_rgb[15:8]),  .q(tmds1));
tmds_encoder u_enc2(.clk(clk), .rst(rst), .de(o_de), .c0(1'b0), .c1(1'b0), .d(o_rgb[23:16]), .q(tmds2));

endmodule
