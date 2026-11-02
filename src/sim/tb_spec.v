`timescale 1ns/1ps
//============================================================================
// tb_spec : SW2 音频频谱 (video_compositor + audio_spectrum_osd) 画面仿真
//
//  video_clk 18.75 MHz, 音频 48 kHz, 左右声道相同 = 0.5*sin(200 Hz) + 0.25*sin(3 kHz)
//  导出画面 frames/sNN.hex, 由 check_spec_img.py 核对:
//    s00 SW2=0      : 频谱区域全部是原图 (0x606060), 不叠加任何东西
//    s01 两个音调   : 背景透明 (区域内只有原图 / 柱 / 峰值帽 / 电平条);
//                     最高的两根柱在 200 Hz 与 3 kHz 所在频段; 有白色峰值帽
//    s02 静音 3 帧后: 柱子回落 (比 s01 矮), 峰值帽仍保持
//============================================================================
module tb_spec;


reg clk = 0;
always #26.667 clk = ~clk;     // 18.75 MHz
reg rst = 1;

wire hs0, vs0, de0, rreq;
video_timing_data u_tim(
    .video_clk(clk), .rst(rst), .read_req(rreq), .read_req_ack(rreq),
    .hs(hs0), .vs(vs0), .de(de0)
);

// A 通道: 固定灰色图案
wire        ren_a, ren_b;
reg  [31:0] data_a = 32'h60606000;

// 音频源
real    amp  = 0.0;
real    freq = 1000.0;
real    tph  = 0.0;
reg        aud_tgl = 0;
reg [15:0] aud_l = 0, aud_r = 0;
integer    vl;
always begin
    #20833.33;                     // 48 kHz
    tph = tph + freq / 48000.0;
    if (tph >= 1.0) tph = tph - 1.0;
    vl  = $rtoi(amp * 32767.0 * (0.5 * $sin(6.283185307 * tph) + 0.25 * $sin(6.283185307 * tph * 15.0)));
    @(posedge clk);                // 与 video_clk 对齐 (硬件上 pix_clk 与 video_clk 同源)
    aud_l   <= vl[15:0];
    aud_r   <= vl[15:0];
    aud_tgl <= ~aud_tgl;
end

reg wave_on = 0;
wire frame_end, hs, vs, de;
wire [23:0] rgb;
video_compositor dut(
    .clk(clk), .rst(rst),
    .hs_in(hs0), .vs_in(vs0), .de_in(de0),
    .read_en_a(ren_a), .data_a(data_a), .read_en_b(ren_b), .data_b(32'd0),
    .splash_on(1'b0), .bar_on(1'b0), .auto_on(1'b1), .waiting(1'b0), .msg_bad(1'b0),
    .cur_img(4'd0), .eff_sel(4'd8), .eff_now(3'd0), .p(9'd0), .b_en(1'b0), .amode(2'd1),
    .menu_on(1'b0), .menu_sel(3'd0), .pmode(2'd0), .bri_lvl(5'd8), .con_lvl(5'd8),
    .temp_lvl(5'd8), .gam_lvl(5'd8), .vol_lvl(5'd16),
    .wave_on(wave_on), .aud_tgl(aud_tgl), .aud_l(aud_l), .aud_r(aud_r), .alarm_on(1'b0), .alm_bcd(16'd0), .alm_src(2'd0),
    .ld_status(3'd2), .img_count(5'd5), .load_img(4'd0), .load_prog(8'd0),
    .wav_ok(1'b0), .rate_code(3'd6), .txt_ok(1'b0), .txt_len(10'd0),
    .wclk(clk), .txt_we(1'b0), .txt_waddr(10'd0), .txt_wdata(8'd0),
    .fnt_we(1'b0), .fnt_waddr(11'd0), .fnt_wdata(8'd0), .fnt_ok(1'b0),
    .frame_end(frame_end), .hs_out(hs), .vs_out(vs), .de_out(de), .rgb_out(rgb)
);

integer fd, npix, nfr = 0, list;
task grab(input [8*24-1:0] tag);
    reg [8*64-1:0] fn;
    begin
        $sformat(fn, "frames/s%02d.hex", nfr);
        fd = $fopen(fn, "w");
        $fdisplay(list, "s%02d %0s wave=%0d amp=%0d freq=%0d", nfr, tag, wave_on, $rtoi(amp * 100), $rtoi(freq));
        @(negedge vs);
        npix = 0;
        while (npix < 640 * 400) begin
            @(posedge clk);
            if (de) begin $fdisplay(fd, "%06h", rgb); npix = npix + 1; end
        end
        $fclose(fd);
        $display("[%0t] frame s%02d %0s", $time, nfr, tag);
        nfr = nfr + 1;
        @(posedge frame_end);
    end
endtask

initial begin
    list = $fopen("frames/slist.txt", "w");
    #500 rst = 0;
    amp = 1.0; freq = 200.0;                // 200 Hz 基波 + 3 kHz (15 倍频)
    repeat (2) @(posedge frame_end);
    grab("off");                            // s00 SW2 = 0
    wave_on = 1;
    repeat (3) @(posedge frame_end);        // 环形缓冲装满 (21 ms), 柱子升起
    grab("two_tones");                      // s01
    amp = 0.0;
    repeat (3) @(posedge frame_end);
    grab("silence_3f");                     // s02 柱子回落, 峰值帽保持
    $fclose(list);
    $display("==== tb_spec done, %0d frames ====", nfr);
    $finish;
end

endmodule
