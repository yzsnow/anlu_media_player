`timescale 1ns/1ps
//============================================================================
// frame_dual_read_write 仿真: 双路显示读 + 帧写入 + 行刷新 (scrub)
//  SDRAM 用行为模型代替 (读延迟默认 7 拍), 记录每一行 (row+bank, 共 8192 行)
//  最近一次被激活的时间. 检查:
//   1. 转场状态下 A/B 两路显示数据逐像素正确 (FIFO 不欠载, scrub 数据不进 FIFO)
//   2. 同时写入的第三帧 (带垂直翻转) 内容正确
//   3. 读写从不同时发起
//   4. 从 62 ms 起, 任意时刻每一行在过去 62 ms 内都被访问过 (刷新要求 64 ms)
//============================================================================
`ifndef RD_LAT
`define RD_LAT 7            // SDRAM 模型读延迟 (拍), 可用 -DRD_LAT=n 覆盖
`endif
module tb_sdram_arb;

reg mem_clk = 0, video_clk = 0, sd_clk = 0;
always #4  mem_clk   = ~mem_clk;    // 125M
always #26.667 video_clk = ~video_clk;  // 18.75M (640x400 内容时钟)
always #5  sd_clk    = ~sd_clk;     // 100M
reg rst = 1;

localparam LEN = 256000;             // 640x400
localparam [20:0] BASE_A = 0, BASE_B = LEN, BASE_W = 2 * LEN;

//---------------------------------------------------------------------------
// SDRAM 行为模型
//---------------------------------------------------------------------------
reg  [31:0] mem [0:2097151];
wire        App_rd_en, App_wr_en;
wire [20:0] App_rd_addr, App_wr_addr;
wire [31:0] App_wr_din;
wire [3:0]  App_wr_dm;
localparam  L = `RD_LAT;
reg  [L-1:0] rd_pipe_en = 0;
reg  [20:0] rd_pipe_addr [0:L-1];
wire        Sdr_rd_en   = rd_pipe_en[L-1];
wire [31:0] Sdr_rd_dout = mem[rd_pipe_addr[L-1]];
real        last_act [0:8191];
integer     i, both = 0;

always @(posedge mem_clk) begin
    rd_pipe_en <= {rd_pipe_en[L-2:0], App_rd_en};
    rd_pipe_addr[0] <= App_rd_addr;
    for (i = 1; i < L; i = i + 1) rd_pipe_addr[i] <= rd_pipe_addr[i - 1];
    if (App_wr_en) begin
        mem[App_wr_addr] <= App_wr_din;
        last_act[App_wr_addr[20:8]] = $realtime;
    end
    if (App_rd_en) last_act[App_rd_addr[20:8]] = $realtime;
    if (App_rd_en && App_wr_en) both = both + 1;
end

//---------------------------------------------------------------------------
// DUT
//---------------------------------------------------------------------------
wire read_req, read_req_ack, hs, vs, de;
wire [31:0] rd_a, rd_b;
reg  write_req = 0, write_en = 0;
reg  [31:0] write_data = 0;
wire write_req_ack, write_finish;

video_timing_data u_tim(
    .video_clk(video_clk), .rst(rst),
    .read_req(read_req), .read_req_ack(read_req_ack),
    .hs(hs), .vs(vs), .de(de)
);

frame_dual_read_write dut(
    .rst(rst), .mem_clk(mem_clk),
    .Sdr_init_done(1'b1), .Sdr_init_ref_vld(1'b0), .Sdr_busy(1'b0),
    .App_rd_en(App_rd_en), .App_rd_addr(App_rd_addr),
    .Sdr_rd_en(Sdr_rd_en), .Sdr_rd_dout(Sdr_rd_dout),
    .App_wr_en(App_wr_en), .App_wr_addr(App_wr_addr), .App_wr_din(App_wr_din), .App_wr_dm(App_wr_dm),
    .read_clk(video_clk), .read_req(read_req), .read_req_ack(read_req_ack),
    .base_a(BASE_A), .base_b(BASE_B), .b_en(1'b1),
    .read_en_a(de), .read_data_a(rd_a), .read_en_b(de), .read_data_b(rd_b),
    .write_clk(sd_clk), .write_req(write_req), .write_req_ack(write_req_ack),
    .write_finish(write_finish), .write_addr(BASE_W),
    .write_en(write_en), .write_data(write_data),
    .write_afull(), .write_vflip(1'b1)
);

//---------------------------------------------------------------------------
// 显示数据核对: FIFO 为非预读模式, read_en 后一拍数据有效
//---------------------------------------------------------------------------
// 复位后的第一帧之前还没有 read_req, 从第一次应答之后开始核对
reg     de_d = 0, vs_d = 1, started = 0;
integer pix = 0, bad_a = 0, bad_b = 0, frames = 0, checked = 0;
always @(posedge video_clk) begin
    de_d <= de & started;
    vs_d <= vs;
    if (read_req_ack) started <= 1'b1;
    if (vs_d & ~vs) begin
        if (pix != 0) frames = frames + 1;
        pix = 0;
    end
    if (de_d) begin
        if (rd_a !== {8'hA0, pix[23:0]}) begin
            if (bad_a < 5) $display("[%0t] A mismatch pix %0d: %h", $time, pix, rd_a);
            bad_a = bad_a + 1;
        end
        if (rd_b !== {8'hB0, pix[23:0]}) begin
            if (bad_b < 5) $display("[%0t] B mismatch pix %0d: %h", $time, pix, rd_b);
            bad_b = bad_b + 1;
        end
        pix = pix + 1;
        checked = checked + 1;
    end
end

//---------------------------------------------------------------------------
// 帧写入: 与加载器相同的 toggle 握手之后连续推入 256000 个字 (每 3 拍一个)
//---------------------------------------------------------------------------
reg     wdone = 0;
integer k, wbad = 0;
always @(posedge mem_clk) if (write_finish) wdone <= 1'b1;

initial begin : writer
    integer n;
    @(negedge rst);
    #2_000_000;                         // 2 ms 后开始, 与显示读重叠
    @(posedge sd_clk) write_req <= 1'b1;
    wait (write_req_ack);
    @(posedge sd_clk) write_req <= 1'b0;
    wait (!write_req_ack);
    repeat (20) @(posedge sd_clk);
    for (n = 0; n < LEN; n = n + 1) begin
        @(posedge sd_clk) begin write_en <= 1'b1; write_data <= {8'hC0, n[23:0]}; end
        @(posedge sd_clk) write_en <= 1'b0;
        @(posedge sd_clk);
    end
end

//---------------------------------------------------------------------------
// 行刷新覆盖检查
//---------------------------------------------------------------------------
real    t, worst = 0;
integer stale = 0, stale_max = 0, nscrub = 0, scrub_misalign = 0;
always @(posedge mem_clk) if (dut.scrub_done) begin
    nscrub = nscrub + 1;
    if (dut.scrub_col !== 8'd0) scrub_misalign = scrub_misalign + 1;   // 每次行刷新必须是完整的 256 字
end

initial begin
    for (i = 0; i < LEN; i = i + 1) begin
        mem[BASE_A + i] = {8'hA0, i[23:0]};
        mem[BASE_B + i] = {8'hB0, i[23:0]};
    end
    for (i = 0; i < 8192; i = i + 1) last_act[i] = 0.0;
    #1000 rst = 0;

    #62_000_000;
    repeat (8) begin            // 62 ~ 70 ms (行刷新一轮约 59 ms), 期间显示读已核对多帧
        t = $realtime;
        stale = 0;
        for (i = 0; i < 8192; i = i + 1) begin
            if (t - last_act[i] > worst) worst = t - last_act[i];
            if (t - last_act[i] > 62_000_000.0) stale = stale + 1;
        end
        if (stale > stale_max) stale_max = stale;
        #1_000_000;
    end

    // 写入帧核对 (垂直翻转: 第 r 行写到第 399-r 行)
    if (!wdone) $display("write not finished");
    for (k = 0; k < LEN; k = k + 1)
        if (mem[BASE_W + (399 - k / 640) * 640 + k % 640] !== {8'hC0, k[23:0]}) wbad = wbad + 1;

    $display("frames checked: %0d (%0d pixels), A errors %0d, B errors %0d", frames, checked, bad_a, bad_b);
    $display("write frame: finished=%0d, errors %0d", wdone, wbad);
    $display("rd/wr collisions: %0d", both);
    $display("scrub bursts: %0d (misaligned %0d), worst row idle time %.2f ms, rows idle > 62 ms: %0d",
             nscrub, scrub_misalign, worst / 1e6, stale_max);
    if (bad_a == 0 && bad_b == 0 && checked >= LEN && wdone && wbad == 0 && both == 0 && stale_max == 0 && scrub_misalign == 0)
        $display("==== tb_sdram_arb PASS ====");
    else
        $display("==== tb_sdram_arb FAIL ====");
    $finish;
end

endmodule
