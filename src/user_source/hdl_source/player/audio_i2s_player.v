`timescale 1ns/1ps
//============================================================================
// audio_i2s_player (audio_mclk = 12.288MHz 域)
//
//  I2S 输出时序与原 hdmi_audio_tone_i2s_64fs 完全一致 (BCLK = mclk/2,
//  每声道 64 bit, 48kHz), 直接送给 I2S_receiver -> HDMI 音频包.
//
//  amode 0 : WAV 播放. 从异步 FIFO 读取 {L16,R16} 样本,
//            按 WAV 采样率做线性插值重采样到 48kHz (支持 8k~48k, 48k 时逐样本直通);
//            没有 WAV 文件时自动退回音阶模式.
//            预缓冲/欠载 (参考第十一讲 wav_stream_player): FIFO 数据量达到 RESUME
//            才开始 (或恢复) 播放; 播放中 FIFO 读空时暂停, 输出保持最后一个样本,
//            重采样相位与已读样本都不动, 恢复后从断点无缝继续.
//            这样供数不足时只会听到少数几次完整的停顿, 不会把旧样本反复插值成
//            "卡卡顿顿" 的杂音, 也不会因时间轴被拉长而听起来变调.
//  amode 1 : 内置旋律 (小星星), 三角波 + 包络衰减 (SW4 = 1)
//  amode 2 : 静音 (顶层已不再使用)
//  amode 3 : 应急报警警笛 (抢占 WAV / 旋律 / 音量): 频率在 600 Hz ~ 1500 Hz 之间线性往返扫频
//            (上升 1 s, 下降 1 s), 波形为削顶三角波 (梯形, 约 -6 dBFS), 不受音量与静音设置影响.
//            WAV 在报警期间暂停 (run 清零, FIFO 与重采样相位保持), 解除后从断点继续.
//            buzz 输出同频方波驱动板载无源蜂鸣器 (声光报警冗余), 非报警时恒为 0
//  音量 vol_lvl 0~16 (SW3 参数菜单): 每级 2 dB, 16 = 0 dB (原音量), 1 = -30 dB, 0 = 静音.
//            增益表见 vol_gain, 在输出选择处与样本相乘 (增益 <= 1, 不会溢出)
//============================================================================
module audio_i2s_player #(
    parameter integer AW = 13                  // WAV FIFO 深度 2^AW
)(
    input             I_mclk,
    input             I_rst,
    input      [1:0]  amode,          // 异步, 此处同步
    input             wav_ok,         // 异步
    input      [16:0] wav_rate,       // 异步, 准静态
    input      [4:0]  vol_lvl,        // 异步 (video_clk 域), 准静态
    // WAV FIFO 读端
    output reg        fifo_rd,
    input      [31:0] fifo_data,      // fifo_rd 后一拍有效
    input             fifo_empty,
    input      [AW:0] fifo_level,     // FIFO 数据量 (读时钟域)
    // 电平指示 (0~15)
    output reg [3:0]  vu,
    // 欠载指示: WAV 播放中 FIFO 读空后保持约 0.5 s
    output reg        xrun,
    // 蜂鸣器 (报警时为警笛同频方波)
    output reg        buzz,
    output reg        O_i2s_BCLK,
    output reg        O_i2s_LRCK,
    output reg        O_i2s_DOUT
);

localparam [16:0] FS = 17'd48000;

//---------------------------------------------------------------------------
// 同步
//---------------------------------------------------------------------------
reg [1:0]  am0, am1;
reg        wo0, wo1;
reg [16:0] rt0, rt1;
reg [4:0]  vl0, vl1, vl2;
always @(posedge I_mclk or posedge I_rst) begin
    if (I_rst) begin
        am0 <= 2'd0; am1 <= 2'd0; wo0 <= 1'b0; wo1 <= 1'b0; rt0 <= FS; rt1 <= FS;
        vl0 <= 5'd16; vl1 <= 5'd16; vl2 <= 5'd16;
    end else begin
        am0 <= amode;    am1 <= am0;
        wo0 <= wav_ok;   wo1 <= wo0;
        rt0 <= wav_rate; rt1 <= rt0;
        // 多位总线跨域: 连续两拍相同才采用, 避免取到变化瞬间的中间值
        vl0 <= vol_lvl;  vl1 <= vl0;
        if (vl1 == vl0) vl2 <= vl1;
    end
end
wire [16:0] rate  = (rt1 < 17'd4000 || rt1 > FS) ? FS : rt1;   // 每帧最多读 1 个样本
wire        use_wav  = (am1 == 2'd0) && wo1;
wire        use_tone = (am1 == 2'd1) || ((am1 == 2'd0) && !wo1);
wire        use_alarm = (am1 == 2'd3);

//---------------------------------------------------------------------------
// I2S 发送
//---------------------------------------------------------------------------
reg  [5:0]  bit_cnt;
reg  [63:0] shift;
reg  [23:0] word_l, word_r;
reg  [23:0] next_l, next_r;
wire        frame_tick = O_i2s_BCLK && (bit_cnt == 6'd63) && O_i2s_LRCK;

always @(posedge I_mclk or posedge I_rst) begin
    if (I_rst) begin
        O_i2s_BCLK <= 1'b0; O_i2s_LRCK <= 1'b0; O_i2s_DOUT <= 1'b0;
        bit_cnt <= 6'd0; shift <= 64'd0; word_l <= 24'd0; word_r <= 24'd0;
    end else begin
        O_i2s_BCLK <= ~O_i2s_BCLK;
        if (O_i2s_BCLK) begin
            O_i2s_DOUT <= shift[63];
            shift      <= {shift[62:0], 1'b0};
            if (bit_cnt == 6'd63) begin
                bit_cnt <= 6'd0;
                if (!O_i2s_LRCK) begin
                    O_i2s_LRCK <= 1'b1;
                    shift      <= {word_r, 40'd0};
                end else begin
                    O_i2s_LRCK <= 1'b0;
                    word_l     <= next_l;
                    word_r     <= next_r;
                    shift      <= {next_l, 40'd0};
                end
            end else
                bit_cnt <= bit_cnt + 6'd1;
        end
    end
end

//---------------------------------------------------------------------------
// WAV 重采样 (每个 48k 帧计算一次, 最多 ~20 个 mclk)
//---------------------------------------------------------------------------
localparam [2:0] R_IDLE = 3'd0, R_CHK = 3'd1, R_POPW = 3'd2, R_POPD = 3'd3,
                 R_FRAC = 3'd4, R_MUL = 3'd5, R_OUT = 3'd6;
// 开始/恢复播放的预缓冲量: FIFO 的一半 (8192 深时 4096 帧, 48k 下 85 ms).
// 第十一讲用 256 (一个扇区); 这里取大一些, 供数持续不足时停顿次数更少.
localparam [AW:0] RESUME = (1 << AW) / 2;
reg [2:0]  rs;
reg [17:0] acc;
reg signed [15:0] s0l, s0r, s1l, s1r;
reg [15:0] frac;
reg signed [16:0] dl, dr;
reg signed [33:0] ml, mr;
reg signed [15:0] wav_l, wav_r;
reg        run;          // 0 = 预缓冲 / 欠载暂停
reg        lvl_ok;

always @(posedge I_mclk or posedge I_rst) begin
    if (I_rst) begin
        rs <= R_IDLE; acc <= 18'd0; fifo_rd <= 1'b0;
        s0l <= 16'sd0; s0r <= 16'sd0; s1l <= 16'sd0; s1r <= 16'sd0;
        frac <= 16'd0; dl <= 17'sd0; dr <= 17'sd0; ml <= 34'sd0; mr <= 34'sd0;
        wav_l <= 16'sd0; wav_r <= 16'sd0; run <= 1'b0; lvl_ok <= 1'b0;
    end else begin
        fifo_rd <= 1'b0;
        lvl_ok  <= (fifo_level >= RESUME);
        if (!use_wav) run <= 1'b0;
        case (rs)
        R_IDLE: if (frame_tick && use_wav) begin
            if (run) begin
                acc <= acc + {1'b0, rate};
                rs  <= R_CHK;
            end else if (lvl_ok) begin
                // 恢复: 本帧沿用暂停那一帧已经累加的相位, 不再累加
                run <= 1'b1;
                rs  <= R_CHK;
            end
            // 否则暂停: wav_l/wav_r 保持, 相位不动
        end
        R_CHK: begin
            if (acc >= {1'b0, FS}) begin
                if (!fifo_empty) begin
                    acc     <= acc - {1'b0, FS};
                    fifo_rd <= 1'b1;
                    rs      <= R_POPW;
                end else begin
                    // 欠载: 暂停. acc 保留本帧的累加, 恢复时从这里继续
                    run <= 1'b0;
                    rs  <= R_IDLE;
                end
            end else
                rs <= R_FRAC;
        end
        R_POPW: rs <= R_POPD;
        R_POPD: begin
            s0l <= s1l; s0r <= s1r;
            s1l <= fifo_data[31:16];
            s1r <= fifo_data[15:0];
            rs  <= R_CHK;
        end
        R_FRAC: begin
            // frac = acc / 48000 * 65536 ~= acc * 22370 >> 14
            frac <= ({15'd0, acc[16:0]} * 32'd22370) >> 14;
            dl   <= {s1l[15], s1l} - {s0l[15], s0l};
            dr   <= {s1r[15], s1r} - {s0r[15], s0r};
            rs   <= R_MUL;
        end
        R_MUL: begin
            ml <= dl * $signed({1'b0, frac});
            mr <= dr * $signed({1'b0, frac});
            rs <= R_OUT;
        end
        R_OUT: begin
            wav_l <= s0l + ml[32:16];
            wav_r <= s0r + mr[32:16];
            rs    <= R_IDLE;
        end
        default: rs <= R_IDLE;
        endcase
    end
end

// 欠载指示 (开始播放前的预缓冲不算, 只有播放中读空才算)
reg [14:0] xrun_cnt;
always @(posedge I_mclk or posedge I_rst) begin
    if (I_rst) begin
        xrun_cnt <= 15'd0; xrun <= 1'b0;
    end else begin
        if (rs == R_CHK && acc >= {1'b0, FS} && fifo_empty)
            xrun_cnt <= 15'd24000;
        else if (frame_tick && xrun_cnt != 15'd0)
            xrun_cnt <= xrun_cnt - 15'd1;
        xrun <= (xrun_cnt != 15'd0);
    end
end

//---------------------------------------------------------------------------
// 内置旋律: 小星星  1 1 5 5 6 6 5 - 4 4 3 3 2 2 1 -
//---------------------------------------------------------------------------
function [31:0] note_inc;
    input [3:0] n;
    case (n)
        4'd1: note_inc = 32'd23409862;   // C4
        4'd2: note_inc = 32'd26276681;   // D4
        4'd3: note_inc = 32'd29494578;   // E4
        4'd4: note_inc = 32'd31248410;   // F4
        4'd5: note_inc = 32'd35075155;   // G4
        4'd6: note_inc = 32'd39370534;   // A4
        4'd7: note_inc = 32'd44191930;   // B4
        4'd8: note_inc = 32'd46819716;   // C5
        default: note_inc = 32'd0;       // 休止
    endcase
endfunction

function [3:0] melody;
    input [4:0] i;
    case (i)
        5'd0:  melody = 4'd1;  5'd1:  melody = 4'd1;  5'd2:  melody = 4'd5;  5'd3:  melody = 4'd5;
        5'd4:  melody = 4'd6;  5'd5:  melody = 4'd6;  5'd6:  melody = 4'd5;  5'd7:  melody = 4'd0;
        5'd8:  melody = 4'd4;  5'd9:  melody = 4'd4;  5'd10: melody = 4'd3;  5'd11: melody = 4'd3;
        5'd12: melody = 4'd2;  5'd13: melody = 4'd2;  5'd14: melody = 4'd1;  5'd15: melody = 4'd0;
        5'd16: melody = 4'd5;  5'd17: melody = 4'd5;  5'd18: melody = 4'd4;  5'd19: melody = 4'd4;
        5'd20: melody = 4'd3;  5'd21: melody = 4'd3;  5'd22: melody = 4'd2;  5'd23: melody = 4'd0;
        5'd24: melody = 4'd5;  5'd25: melody = 4'd5;  5'd26: melody = 4'd4;  5'd27: melody = 4'd4;
        5'd28: melody = 4'd3;  5'd29: melody = 4'd3;  5'd30: melody = 4'd2;  default: melody = 4'd0;
    endcase
endfunction

reg [31:0] ph;
reg [4:0]  mi;
reg [14:0] ncnt;            // 每音 0.32s = 15360 帧
reg [7:0]  env;
reg signed [15:0] tone;
wire [3:0]  cur_note = melody(mi);
wire [15:0] tri_u    = ph[31] ? ~ph[30:15] : ph[30:15];
wire signed [16:0] tri_s = {1'b0, tri_u} - 17'sd32768;
wire signed [25:0] tri_e = tri_s * $signed({1'b0, env, 1'b0});

always @(posedge I_mclk or posedge I_rst) begin
    if (I_rst) begin
        ph <= 32'd0; mi <= 5'd0; ncnt <= 15'd0; env <= 8'd255; tone <= 16'sd0;
    end else if (frame_tick) begin
        ph <= ph + note_inc(cur_note);
        if (ncnt == 15'd15359) begin
            ncnt <= 15'd0;
            mi   <= mi + 5'd1;
            env  <= 8'd255;
            ph   <= 32'd0;
        end else begin
            ncnt <= ncnt + 15'd1;
            if (ncnt[5:0] == 6'd0 && env != 8'd0) env <= env - 8'd1;
        end
        tone <= (cur_note == 4'd0) ? 16'sd0 : tri_e[25:10];   // 约 -6dB
    end
end

//---------------------------------------------------------------------------
// 应急报警警笛: 相位增量 inc = f * 2^32 / 48000, 600 Hz ~ 1500 Hz 每帧 +/- 1678 (1 s 扫一程)
//---------------------------------------------------------------------------
localparam [31:0] SIR_LO   = 32'd53687091;     // 600 Hz
localparam [31:0] SIR_HI   = 32'd134217728;    // 1500 Hz
localparam [31:0] SIR_STEP = 32'd1678;
reg  [31:0] sph, sinc;
reg         sup;
reg  signed [15:0] siren;
wire [15:0] sir_u = sph[31] ? ~sph[30:15] : sph[30:15];
wire signed [16:0] sir_s = {1'b0, sir_u} - 17'sd32768;
always @(posedge I_mclk or posedge I_rst) begin
    if (I_rst) begin
        sph <= 32'd0; sinc <= SIR_LO; sup <= 1'b1; siren <= 16'sd0; buzz <= 1'b0;
    end else if (frame_tick) begin
        if (!use_alarm) begin
            // 每次报警都从 600 Hz 起扫
            sph <= 32'd0; sinc <= SIR_LO; sup <= 1'b1; siren <= 16'sd0; buzz <= 1'b0;
        end else begin
            sph <= sph + sinc;
            if (sup) begin
                sinc <= sinc + SIR_STEP;
                if (sinc >= SIR_HI - SIR_STEP) sup <= 1'b0;
            end else begin
                sinc <= sinc - SIR_STEP;
                if (sinc <= SIR_LO + SIR_STEP) sup <= 1'b1;
            end
            // 三角波削顶到 +/-16383: 梯形波, 谐波比三角波丰富, 听起来更像警报
            siren <= (sir_s > 17'sd16383) ? 16'sd16383 : (sir_s < -17'sd16383) ? -16'sd16383 : sir_s[15:0];
            buzz  <= sph[31];
        end
    end
end

//---------------------------------------------------------------------------
// 音量: 增益 = 256 * 10^(-(16 - lvl) * 2 / 20), 256 = 0 dB
//---------------------------------------------------------------------------
function [8:0] vol_gain;
    input [4:0] l;
    case (l)
        5'd0:  vol_gain = 9'd0;    5'd1:  vol_gain = 9'd8;    5'd2:  vol_gain = 9'd10;
        5'd3:  vol_gain = 9'd13;   5'd4:  vol_gain = 9'd16;   5'd5:  vol_gain = 9'd20;
        5'd6:  vol_gain = 9'd26;   5'd7:  vol_gain = 9'd32;   5'd8:  vol_gain = 9'd41;
        5'd9:  vol_gain = 9'd51;   5'd10: vol_gain = 9'd64;   5'd11: vol_gain = 9'd81;
        5'd12: vol_gain = 9'd102;  5'd13: vol_gain = 9'd128;  5'd14: vol_gain = 9'd162;
        5'd15: vol_gain = 9'd203;  default: vol_gain = 9'd256;
    endcase
endfunction

reg  [8:0]  gain;
always @(posedge I_mclk) gain <= use_alarm ? 9'd256 : vol_gain(vl2);    // 警笛不受音量 / 静音影响

wire signed [15:0] src_l = use_alarm ? siren : use_wav ? wav_l : use_tone ? tone : 16'sd0;
wire signed [15:0] src_r = use_alarm ? siren : use_wav ? wav_r : use_tone ? tone : 16'sd0;
// 16 bit x 9 bit: 增益 256 时结果正好是 {样本, 8'd0}, 与原来的输出一致
wire signed [25:0] vol_l = src_l * $signed({1'b0, gain});
wire signed [25:0] vol_r = src_r * $signed({1'b0, gain});

//---------------------------------------------------------------------------
// 输出选择 + 电平表
//---------------------------------------------------------------------------
reg [15:0] peak;
reg [11:0] vu_cnt;
wire [15:0] abs_l = next_l[23] ? {~next_l[22:8], 1'b1} : {next_l[22:8], 1'b0};
always @(posedge I_mclk or posedge I_rst) begin
    if (I_rst) begin
        next_l <= 24'd0; next_r <= 24'd0; peak <= 16'd0; vu_cnt <= 12'd0; vu <= 4'd0;
    end else begin
        next_l <= vol_l[23:0];
        next_r <= vol_r[23:0];
        if (frame_tick) begin
            vu_cnt <= vu_cnt + 12'd1;
            if (vu_cnt == 12'd0) begin
                // 约 85ms 更新一次, 取对数近似
                casez (peak[15:8])
                    8'b1???????: vu <= 4'd15;
                    8'b01??????: vu <= 4'd13;
                    8'b001?????: vu <= 4'd11;
                    8'b0001????: vu <= 4'd9;
                    8'b00001???: vu <= 4'd7;
                    8'b000001??: vu <= 4'd5;
                    8'b0000001?: vu <= 4'd3;
                    8'b00000001: vu <= 4'd2;
                    default:     vu <= (peak[7:0] != 8'd0) ? 4'd1 : 4'd0;
                endcase
                peak <= 16'd0;
            end else if (abs_l > peak)
                peak <= abs_l;
        end
    end
end

endmodule
