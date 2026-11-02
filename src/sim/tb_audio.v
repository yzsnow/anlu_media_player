`timescale 1ns/1ps
//============================================================================
// 音频通路仿真: async_fifo (WAV FIFO) -> audio_i2s_player -> I2S_receiver
//  与顶层连接方式相同. 写侧按 audio_in.hex 顺序写入 {L16,R16} 样本
//  (FIFO 低于 5/8 时连续写入, 模拟加载器滞回补数).
//  SUP != 0 时限制供数速度为播放所需的 SUP%, 按 128 样本 (一个 16 bit 立体声扇区)
//  成块写入, 模拟 TF 卡读得比播放慢 (欠载).
//  I2S_receiver 输出的每个 48k 帧写入 audio_out.txt, 由 check_audio.py 分析.
//  -DOLD_PLAYER: 按改进前的播放器端口连接 (没有 fifo_level), 用于对比.
//============================================================================
module tb_audio;

parameter integer RATE    = 32000;       // WAV 采样率 (audio_in.hex 的采样率)
parameter integer N_IN    = 16000;       // audio_in.hex 样本数
parameter integer N_OUT   = 24000;       // 记录的输出帧数
parameter integer AW      = 13;          // FIFO 深度 2^AW (顶层为 13)
parameter integer SUP     = 0;           // 供数速度 (% of RATE), 0 = 不限

reg clk = 0;     // 写侧 (实际为 sd_card_clk 100M, 这里用 50M 加快仿真)
reg mclk = 0;    // audio_mclk 12.295M
reg vclk = 0;    // video_clk 25M
always #10     clk  = ~clk;
always #40.665 mclk = ~mclk;
always #20     vclk = ~vclk;
reg rst = 1;

reg  [31:0] src [0:N_IN-1];
initial $readmemh("audio_in.hex", src);

wire [AW:0] wr_level, rd_level;
reg         we = 0;
reg  [31:0] wd = 0;
wire        rd, empty;
wire [31:0] rdata;

async_fifo #(.DW(32), .AW(AW), .RAM_STYLE("bram_32k")) u_fifo (
    .wr_clk(clk), .wr_rst(rst), .wr_en(we), .wr_data(wd), .wr_level(wr_level),
    .rd_clk(mclk), .rd_rst(rst), .rd_en(rd), .rd_data(rdata), .rd_empty(empty), .rd_level(rd_level)
);

wire bclk, lrck, dout, xrun;
wire [3:0] vu;
`ifdef OLD_PLAYER
audio_i2s_player u_p (
    .I_mclk(mclk), .I_rst(rst), .amode(2'd0), .wav_ok(1'b1), .wav_rate(RATE[16:0]),
    .fifo_rd(rd), .fifo_data(rdata), .fifo_empty(empty),
    .vu(vu), .xrun(xrun), .buzz(), .O_i2s_BCLK(bclk), .O_i2s_LRCK(lrck), .O_i2s_DOUT(dout)
);
`else
audio_i2s_player #(.AW(AW)) u_p (
    .I_mclk(mclk), .I_rst(rst), .amode(2'd0), .wav_ok(1'b1), .wav_rate(RATE[16:0]),
    .fifo_rd(rd), .fifo_data(rdata), .fifo_empty(empty), .fifo_level(rd_level), .vol_lvl(5'd16),
    .vu(vu), .xrun(xrun), .buzz(), .O_i2s_BCLK(bclk), .O_i2s_LRCK(lrck), .O_i2s_DOUT(dout)
);
`endif

wire        av;
wire [23:0] al, ar;
I2S_receiver u_rx (
    .I_clk(vclk), .I_rst(rst), .I_i2s_BCLK(bclk), .I_i2s_LRCK(lrck), .I_i2s_DOUT(dout),
    .O_audio_valid(av), .O_audio_left_data(al), .O_audio_right_data(ar)
);

// 写侧: 低于 WR_LO 开始连续写 (每 4 周期一个样本), 写到 WR_HI 停.
// 按 128 样本成块写 (一块开始后写完为止), WR_HI 离满留 128 + 64.
// 限速时每攒够 128 个样本的额度才写一块.
localparam integer WR_LO = (1 << AW) / 8 * 5;
localparam integer WR_HI = (1 << AW) - 192;
integer wi = 0;
integer burst = 0;
reg     fill = 0;
integer div = 0;
real    credit = 0.0;
always @(posedge clk) begin
    we  <= 1'b0;
    div <= div + 1;
    if (!rst) begin
        if (wr_level >= WR_HI) fill <= 1'b0;
        else if (wr_level < WR_LO) fill <= 1'b1;
        if (burst == 0 && fill && wi < N_IN && (SUP == 0 || credit >= 128.0)) begin
            burst = 128;
            if (SUP != 0) credit = credit - 128.0;
        end
        if (burst != 0 && div[1:0] == 2'd0 && wi < N_IN) begin
            we    <= 1'b1;
            wd    <= src[wi];
            wi    <= wi + 1;
            burst = burst - 1;
        end
    end
end

// 读出的样本必须与写入顺序逐个一致 (检查 FIFO 丢数/错位)
integer npop = 0, pop_err = 0;
reg     rd_q = 0;
always @(posedge mclk) begin
    rd_q <= rd;
    if (rd_q) begin
        if (rdata !== src[npop]) begin
            if (pop_err < 5) $display("fifo data error: sample %0d got %08x expect %08x", npop, rdata, src[npop]);
            pop_err = pop_err + 1;
        end
        npop = npop + 1;
    end
end

integer fo;
integer nout = 0;
integer nxrun = 0;
reg     xrun_d = 0;
initial begin
    fo = $fopen("audio_out.txt", "w");
    #1000 rst = 0;
end
always @(posedge vclk) if (av) begin
    $fwrite(fo, "%0d %0d %0d\n", $signed(al), $signed(ar), empty);
    nout = nout + 1;
    if (SUP != 0) credit = credit + RATE * SUP / 100.0 / 48000.0;
    if (nout == N_OUT) begin
        $fclose(fo);
        $display("tb_audio: %0d frames written, %0d input samples used, xrun events %0d", nout, wi, nxrun);
        $display("tb_audio: %0d samples read from FIFO, %0d data errors", npop, pop_err);
        $finish;
    end
end
`ifdef DUMP_POP
integer fp;
reg     rd_d = 0;
initial fp = $fopen("audio_pop.txt", "w");
always @(posedge mclk) begin
    rd_d <= rd;
    if (rd_d) $fwrite(fp, "%08x %0d %0d\n", rdata, nout, rd_level);
end
always @(posedge clk) if (we) $fwrite(fp, "W %08x %0d %0d\n", wd, nout, wr_level);
`endif
always @(posedge mclk) begin
    xrun_d <= xrun;
    if (xrun && !xrun_d) nxrun = nxrun + 1;
end

endmodule
