`timescale 1ns/1ps
//============================================================================
// tb_spec_unit : audio_spectrum_osd 的 FFT / 频段计算单元测试 (不接视频, 运行快)
//
//  "帧" 缩短为 60000 拍 (FFT 约 4.3 万拍即可完成), 音频 48 kHz (每 390~391 拍一个样本).
//  每个用例先放 8 帧 (> 1024 个样本) 让环形缓冲装满, 然后导出最后一次计算的
//    spec/cN_in.txt   : 进入 FFT 的 1024 个样本 (旧 -> 新)
//    spec/cN_fft.txt  : FFT 后数据 RAM 全部 1024 点 (re im)
//    spec/cN_band.txt : 24 个频段高度 nh
//  check_spec.py 用同样的定点算法逐位核对, 并与浮点 FFT 比较精度.
//  用例: c0 1 kHz (L 0.8 / R 0.4)   c1 200 Hz 0.5 + 3 kHz 0.25   c2 60 Hz 0.9
//        c3 伪随机噪声 (约 -20 dB)   c4 静音
//============================================================================
module tb_spec_unit;

reg clk = 0;
always #26.667 clk = ~clk;
reg rst = 1;

// 缩短的帧: VS 低 20 拍
integer fc = 0;
reg vs = 1;
always @(posedge clk) begin
    fc <= (fc == 59999) ? 0 : fc + 1;
    vs <= !(fc < 20);
end

// 音频
integer    tcase = 0;
real       tt = 0.0;
reg        aud_tgl = 0;
reg [15:0] aud_l = 0, aud_r = 0;
reg [31:0] lfsr = 32'h1234_5678;
integer    vl, vr;
function integer clip; input real x;
    clip = (x > 32767.0) ? 32767 : (x < -32768.0) ? -32768 : $rtoi(x);
endfunction
always begin
    #20833.33;
    tt = tt + 1.0 / 48000.0;
    lfsr = {lfsr[30:0], lfsr[31] ^ lfsr[21] ^ lfsr[1] ^ lfsr[0]};
    case (tcase)
        0: begin vl = clip(0.8 * 32767.0 * $sin(6.283185307 * 1000.0 * tt)); vr = vl / 2; end
        1: begin vl = clip(32767.0 * (0.5 * $sin(6.283185307 * 200.0 * tt) + 0.25 * $sin(6.283185307 * 3000.0 * tt + 1.0))); vr = vl; end
        2: begin vl = clip(0.9 * 32767.0 * $sin(6.283185307 * 60.0 * tt)); vr = vl; end
        3: begin vl = $signed(lfsr[15:0]) / 10; vr = $signed(lfsr[31:16]) / 10; end
        default: begin vl = 0; vr = 0; end
    endcase
    @(posedge clk);
    aud_l   <= vl[15:0];
    aud_r   <= vr[15:0];
    aud_tgl <= ~aud_tgl;
end

wire [2:0] w2;
audio_spectrum_osd dut(
    .clk(clk), .rst(rst), .enable(1'b1), .vs_in(vs), .xc(10'd0), .yc(9'd0),
    .aud_tgl(aud_tgl), .aud_l(aud_l), .aud_r(aud_r), .w2(w2)
);

// 导出
integer fin = 0, ff, i, dump = 0;
reg [8*48-1:0] fn;
always @(posedge clk) begin
    if (dump && dut.lv3 && dut.st == 4'd2) $fdisplay(fin, "%0d", $signed(dut.iq3));
end

task run_case(input integer c);
    begin
        tcase = c;
        repeat (8) @(negedge vs);
        // 下一帧: 记录输入
        $sformat(fn, "spec/c%0d_in.txt", c);
        fin = $fopen(fn, "w");
        @(negedge vs); dump = 1;
        wait (dut.st == 4'd11);            // S_B0: FFT 完成
        @(posedge clk); #1;                // 最后一个蝶形的 b 点在 S_B0 这一拍写入
        dump = 0; $fclose(fin);
        $sformat(fn, "spec/c%0d_fft.txt", c);
        ff = $fopen(fn, "w");
        for (i = 0; i < 1024; i = i + 1)
            $fdisplay(ff, "%0d %0d", $signed(dut.dram[i][35:18]), $signed(dut.dram[i][17:0]));
        $fclose(ff);
        wait (dut.st == 4'd0);             // 频段计算完成
        $sformat(fn, "spec/c%0d_band.txt", c);
        ff = $fopen(fn, "w");
        for (i = 0; i < 24; i = i + 1) $fdisplay(ff, "%0d", dut.nh[i]);
        $fclose(ff);
        $display("[%0t] case %0d dumped", $time, c);
    end
endtask

integer tfft;
initial begin
    #500 rst = 0;
    run_case(0);
    // 计算时间
    @(negedge vs); tfft = 0;
    while (dut.st != 4'd11) begin @(posedge clk); tfft = tfft + 1; end
    $display("UPD + LOAD + FFT = %0d cycles (%.2f ms @ 18.75 MHz)", tfft, tfft / 18750.0);
    run_case(1);
    run_case(2);
    run_case(3);
    run_case(4);
    $display("==== tb_spec_unit done ====");
    $finish;
end

endmodule
