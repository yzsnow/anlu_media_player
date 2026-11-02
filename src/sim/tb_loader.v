`timescale 1ns/1ps
//============================================================================
// sd_media_loader 自检仿真
//  配合 sd_card_top_stub.v 与 mkdisk.py 生成的 disk.img
//  检查: 目录解析 (图片数 / 文件名), 字幕与字库, 帧数据哈希, 损坏图片应答,
//        缓存命中 (零等待切换), WAV 样本序列与循环, 瞬时读超时后原位重读 (不丢播放位置),
//        拔卡/插卡后重新扫描
//
//  -DREAL_SD (sh run_sim.sh stress): 桩模型改用接近实际 TF 卡的时序, WAV 按
//        48kHz 实时消费, 在加载图片的同时统计 FIFO 欠载次数与最低水位.
//        -DOLD_FIFO 时按旧版 (2048 深 FIFO, 无 WAV_AW 参数) 连接, 用于对比.
//  -DHOTPLUG (sh run_sim.sh hotplug): 空闲心跳 / 换卡检测. 加载器按 CLK_HZ = 10 MHz 例化,
//        所有超时和心跳间隔按周期数缩短 10 倍 (逻辑不变), 下文 "ms" 均指加载器眼中的时间.
//        模拟测试音模式: WAV FIFO 不再消耗, 图片全部命中缓存, 加载器没有任何读卡需求.
//  -DFIT (sh run_sim.sh fit): 任意分辨率图片 (mkdisk.py --fit): 逐张请求, 核对等比缩放 + 黑边后
//        256000 字的哈希与参考模型一致、垂直翻转标志正确、不支持的格式被拒绝;
//        写 FIFO afull 随机拉高 (约 3/8 的周期) 检查反压, 并监视缩放器行缓存不溢出.
//============================================================================
module tb_loader;

`include "expect.vh"

`ifdef OLD_FIFO
localparam integer WAV_CAP = 2048;
`else
localparam integer WAV_CAP = 8192;
`endif
`ifdef REAL_SD
localparam integer WAV_PERIOD = 2083;        // 100MHz / 48kHz
localparam integer REQ_TO     = 200_000_000;
`elsif FIT
localparam integer WAV_PERIOD = 300;
localparam integer REQ_TO     = 100_000_000;
`else
localparam integer WAV_PERIOD = 300;
localparam integer REQ_TO     = 20_000_000;
`endif
`ifdef HOTPLUG
localparam integer LD_HZ = 10_000_000;
`else
localparam integer LD_HZ = 100_000_000;
`endif

reg clk = 0;            // sd_card_clk 100M
reg mclk = 0;           // ext_mem_clk 125M
always #5 clk  = ~clk;
always #4 mclk = ~mclk;
reg rst = 1;

integer errors = 0;
task fail(input [8*64-1:0] msg);
    begin
        errors = errors + 1;
        $display("[%0t] ERROR: %0s", $time, msg);
    end
endtask

//---------------------------------------------------------------------------
// DUT
//---------------------------------------------------------------------------
wire        write_req, write_en;
wire [20:0] write_addr;
wire [31:0] write_data;
reg         write_req_ack = 0;
reg         write_finish_toggle = 0;
reg         req_toggle = 0;
reg  [3:0]  req_img = 0;
reg  [2:0]  cur_slot = 3'd7;
wire        ack_toggle, ack_ok;
wire [2:0]  ack_slot;
wire [3:0]  ack_img;
wire [7:0]  ack_dur;
wire        wav_we;
wire [31:0] wav_wdata;
reg  [13:0] wav_level = 0;
wire        txt_we, fnt_we;
wire [9:0]  txt_waddr;
wire [7:0]  txt_wdata, fnt_wdata;
wire [10:0] fnt_waddr;
wire [2:0]  status, wav_rate_code;
wire [4:0]  img_count;
wire [3:0]  load_img;
wire [7:0]  load_prog;
wire        loading, wav_ok, txt_ok, fnt_ok;
wire [16:0] wav_rate;
wire [9:0]  txt_len;
wire        write_vflip;
reg         write_afull = 1'b0;
`ifdef FIT
always @(posedge clk) write_afull <= (($random & 7) < 3);
`endif

`ifdef OLD_FIFO
sd_media_loader #(.CLK_HZ(100_000_000)) dut (
`else
sd_media_loader #(.CLK_HZ(LD_HZ), .WAV_AW(13)) dut (
`endif
    .clk(clk), .rst(rst),
    .SD_nCS(), .SD_DCLK(), .SD_MOSI(), .SD_MISO(1'b1),
    .write_req(write_req), .write_req_ack(write_req_ack), .write_addr(write_addr),
    .write_en(write_en), .write_data(write_data), .write_finish_toggle(write_finish_toggle),
    .write_afull(write_afull), .write_vflip(write_vflip),
    .req_toggle(req_toggle), .req_img(req_img), .cur_slot(cur_slot),
    .ack_toggle(ack_toggle), .ack_slot(ack_slot), .ack_ok(ack_ok), .ack_img(ack_img), .ack_dur(ack_dur),
    .wav_we(wav_we), .wav_wdata(wav_wdata), .wav_level(wav_level),
    .txt_we(txt_we), .txt_waddr(txt_waddr), .txt_wdata(txt_wdata),
    .fnt_we(fnt_we), .fnt_waddr(fnt_waddr), .fnt_wdata(fnt_wdata),
    .status(status), .img_count(img_count), .load_img(load_img), .load_prog(load_prog),
    .loading(loading), .wav_ok(wav_ok), .wav_rate_code(wav_rate_code), .wav_rate(wav_rate),
    .txt_len(txt_len), .txt_ok(txt_ok), .fnt_ok(fnt_ok)
);

//---------------------------------------------------------------------------
// frame_fifo_write 行为模型 (mem_clk 域): 请求握手 + 写满一帧后翻转 finish
//---------------------------------------------------------------------------
reg [2:0]  wreq_s = 0;
integer    wcnt = 0;
reg [31:0] whash = 0;
reg [20:0] wbase = 0;
reg [31:0] slot_hash [0:7];
reg [31:0] slot_cnt  [0:7];
reg        slot_vf   [0:7];
integer    k;
initial for (k = 0; k < 8; k = k + 1) begin slot_hash[k] = 0; slot_cnt[k] = 0; slot_vf[k] = 0; end

always @(posedge mclk) begin
    wreq_s <= {wreq_s[1:0], write_req};
    write_req_ack <= wreq_s[2];
end
always @(posedge write_req) begin
    wbase = write_addr;
    wcnt  = 0;
    whash = 32'h811C9DC5;
end
always @(posedge clk) if (write_en) begin
    whash = (whash ^ write_data) * 32'h01000193;
    wcnt  = wcnt + 1;
    if (wcnt == 256000) begin          // 一帧 640x400 (槽间距仍为 307200)
        slot_hash[wbase / 307200] = whash;
        slot_cnt[wbase / 307200]  = wcnt;
        slot_vf[wbase / 307200]   = write_vflip;
        #200 write_finish_toggle = ~write_finish_toggle;
    end
end

//---------------------------------------------------------------------------
// WAV FIFO 模型: 每 WAV_PERIOD 周期消费一个样本, 检查样本序列
//---------------------------------------------------------------------------
reg [31:0] wav_exp [0:WAV_N-1];
integer    wav_idx = 0, wav_total = 0, wav_loops = 0, wav_err = 0;
integer    wdiv = 0;
reg        wav_chk = 1'b1;   // 热插拔测试时关闭 (重新扫描后 WAV 从头播放)
reg        wav_hold = 1'b0;  // 1 = 停止消费 (测试音模式)
// 欠载统计 (与 audio_i2s_player 的 xrun 口径相同: 开始消费后读到空才算)
reg        primed = 1'b0, starving = 1'b0;
integer    xrun_ev = 0, xrun_smp = 0, consumed = 0;
integer    min_lvl = 1 << 30;
initial $readmemh("wav_exp.hex", wav_exp);
always @(posedge clk) begin
    if (wav_we && wav_chk) begin
        if (wav_wdata !== wav_exp[wav_idx]) begin
            wav_err = wav_err + 1;
            if (wav_err <= 5)
                $display("[%0t] ERROR: wav sample %0d = %08h, expect %08h", $time, wav_idx, wav_wdata, wav_exp[wav_idx]);
        end
        wav_total = wav_total + 1;
        if (wav_idx == WAV_N - 1) begin wav_idx = 0; wav_loops = wav_loops + 1; end
        else wav_idx = wav_idx + 1;
    end
    wdiv = wav_hold ? 1 : (wdiv == WAV_PERIOD - 1) ? 0 : wdiv + 1;
    wav_level <= wav_level + (wav_we ? 14'd1 : 14'd0) - ((wdiv == 0 && wav_level != 0) ? 14'd1 : 14'd0);
    if (wdiv == 0) begin
        if (wav_level != 0) begin
            primed = 1'b1; starving = 1'b0; consumed = consumed + 1;
        end else if (primed) begin
            if (!starving) xrun_ev = xrun_ev + 1;
            starving = 1'b1; xrun_smp = xrun_smp + 1;
        end
        if (primed && wav_level < min_lvl) min_lvl = wav_level;
    end
    if (wav_level > WAV_CAP - 8) begin
        $display("[%0t] ERROR: wav fifo overflow", $time);
        errors = errors + 1;
    end
end

//---------------------------------------------------------------------------
// 文本 / 字库 RAM
//---------------------------------------------------------------------------
reg [7:0] txt_ram [0:1023];
reg [7:0] fnt_ram [0:2047];
reg [7:0] txt_exp [0:TXT_N-1];
reg [7:0] fnt_exp [0:2047];
initial begin
    $readmemh("txt_exp.hex", txt_exp);
    $readmemh("fnt_exp.hex", fnt_exp);
end
always @(posedge clk) begin
    if (txt_we) txt_ram[txt_waddr] <= txt_wdata;
    if (fnt_we) fnt_ram[fnt_waddr] <= fnt_wdata;
end

//---------------------------------------------------------------------------
// 播放器侧请求
//---------------------------------------------------------------------------
task request(input [3:0] img, output ok, output [2:0] slot, output integer lat);
    integer t;
    reg     a0;
    begin
        @(posedge clk);
        a0         = ack_toggle;
        req_img    = img;
        req_toggle = ~req_toggle;
        t = 0;
        while (ack_toggle == a0 && t < REQ_TO) begin
            @(posedge clk);
            t = t + 1;
        end
        ok   = ack_ok;
        slot = ack_slot;
        lat  = t;
        if (t >= REQ_TO) fail("request timeout");
        if (ack_img !== img) fail("ack_img mismatch");
        $display("[%0t] request img %0d -> ok=%0d slot=%0d latency=%0d cycles (%0.1f us)",
                 $time, img, ok, slot, t, t / 100.0);
    end
endtask

function [8*8-1:0] name_at(input integer idx);
    integer j;
    begin
        name_at = 0;
        for (j = 0; j < 8; j = j + 1)
            name_at = {name_at[8*7-1:0], txt_ram[512 + idx * 8 + j]};
    end
endfunction

// 分辨率文字 (文本 RAM 768 + 图片号 * 16, 9 字节)
function [9*8-1:0] res_at(input integer idx);
    integer j;
    begin
        res_at = 0;
        for (j = 0; j < 9; j = j + 1)
            res_at = {res_at[8*8-1:0], txt_ram[768 + idx * 16 + j]};
    end
endfunction

task check_res(input integer idx, input [9*8-1:0] exp);
    begin
        if (res_at(idx) !== exp) begin
            $display("  img %0d res '%s', expect '%s'", idx, res_at(idx), exp);
            fail("res text");
        end else
            $display("  img %0d res '%s' OK", idx, res_at(idx));
    end
endtask

//---------------------------------------------------------------------------
// 主流程
//---------------------------------------------------------------------------
reg        ok;
reg [2:0]  slot;
integer    lat, i;
integer    t0;
reg [31:0] h;
// 瞬时超时测试用: 统计控制器复位次数和状态离开 READY 的周期数
integer    nstatus_bad = 0, nxrst = 0;
reg        watch_st = 1'b0;
reg [5:0]  st_d = 6'd0;
always @(posedge clk) begin
    st_d <= dut.state;
    if (watch_st && dut.state == 6'd36 && st_d != 6'd36) nxrst = nxrst + 1;   // X_RST
    if (watch_st && status != 3'd2) nstatus_bad = nstatus_bad + 1;
end
// 心跳计数 (进入 M_PROBE) / 重新扫描计数 (进入 M_CALC2)
integer    nprobe = 0, nscan = 0;
always @(posedge clk) begin
    if (dut.state == 6'd38 && st_d != 6'd38) nprobe = nprobe + 1;
    if (dut.state == 6'd7  && st_d != 6'd7)  nscan  = nscan + 1;
end
task wait_status(input [2:0] s, input integer lim, output integer t);
    begin
        t = 0;
        while (status != s && t < lim) begin @(posedge clk); t = t + 1; end
    end
endtask
task wait_idle;   // WAV 补数结束 (水位到 WAV_HI) 且没有图片任务 -> 之后不会再读卡
    integer t;
    begin
        t = 0;
        while ((wav_level < 14'd7000 || dut.wav_fill || loading || dut.img_job || dut.state != 6'd17) && t < 20_000_000) begin
            @(posedge clk); t = t + 1;
        end
        if (t >= 20_000_000) fail("loader never idle");
    end
endtask
`ifdef HOTPLUG
localparam integer MS = LD_HZ / 1000;        // 加载器的 1 ms (周期数)
integer n0, s0;
initial begin
    $display("==== tb_loader hotplug start (loader CLK_HZ %0d) ====", LD_HZ);
    #100 rst = 0;
    wait_status(3'd2, 5_000_000, t0);
    if (status != 3'd2 || img_count != 5'd3) fail("scan");
    $display("[%0t] scan done: img_count=%0d vol_ser=%08h", $time, img_count, dut.vol_ser);
    if (dut.vol_ser !== VOL_SER) fail("vol_ser");
    request(4'd0, ok, slot, lat); cur_slot = slot;
    if (!ok || slot_hash[slot] !== HASH_IMG0) fail("img0");
    request(4'd2, ok, slot, lat); cur_slot = slot;
    if (!ok || slot_hash[slot] !== HASH_IMG2) fail("img2");

    // 1. 测试音模式空闲: 不读卡时每 0.5 s 心跳一次, 状态与缓存不受影响
    wav_hold = 1'b1;
    wav_chk  = 1'b0;
    wait_idle;
    n0 = nprobe; s0 = nscan; nstatus_bad = 0; watch_st = 1'b1;
    repeat (1600 * MS) @(posedge clk);
    watch_st = 1'b0;
    $display("[%0t] idle 1.6 s: %0d probes, %0d rescans, status left READY %0d cycles",
             $time, nprobe - n0, nscan - s0, nstatus_bad);
    if (nprobe - n0 < 2 || nprobe - n0 > 4) fail("idle probe count");
    if (nscan != s0 || nstatus_bad != 0) fail("probe disturbed READY");
    request(4'd0, ok, slot, lat);
    if (!ok || lat > 2000) fail("cache lost after probes");
    cur_slot = slot;

    // 2. 空闲时拔卡 (原问题): 心跳读超时 -> 重新初始化失败 -> NOCARD
    wait_idle;
    dut.u_sd_card_top.card_present = 1'b0;
    dut.u_sd_card_top.power_lost   = 1'b1;
    wait_status(3'd3, 4000 * MS, t0);
    $display("[%0t] idle removal -> status=%0d after %0.1f ms", $time, status, t0 * 1.0 / MS);
    if (status != 3'd3) fail("idle removal not detected");
    repeat (300 * MS) @(posedge clk);
    dut.u_sd_card_top.card_present = 1'b1;
    wait_status(3'd2, 3000 * MS, t0);
    $display("[%0t] reinsert -> status=%0d img_count=%0d after %0.1f ms", $time, status, img_count, t0 * 1.0 / MS);
    if (status != 3'd2 || img_count != 5'd3) fail("rescan after idle reinsert");
    request(4'd2, ok, slot, lat); cur_slot = slot;
    if (!ok || slot_hash[slot] !== HASH_IMG2) fail("img2 after reinsert");
    request(4'd0, ok, slot, lat); cur_slot = slot;
    if (!ok || slot_hash[slot] !== HASH_IMG0) fail("img0 after reinsert");

    // 3. 空闲时快速换卡 (0.1 s 内换上另一张卡: 序列号不同, 且没有 IMG_C.BMP)
    //    心跳读不到 (新卡未初始化) -> 重新初始化成功 -> 序列号不符 -> 重新扫描 -> 2 张图
    wait_idle;
    s0 = nscan;
    dut.u_sd_card_top.card_present = 1'b0;
    dut.u_sd_card_top.power_lost   = 1'b1;
    for (i = 0; i < 4; i = i + 1)
        dut.u_sd_card_top.disk[VBR_OFF + 8'h43 + i] = dut.u_sd_card_top.disk[VBR_OFF + 8'h43 + i] ^ 8'h5A;
    dut.u_sd_card_top.disk[DIRC_OFF] = 8'hE5;
    repeat (100 * MS) @(posedge clk);
    dut.u_sd_card_top.card_present = 1'b1;
    t0 = 0;
    while (!(nscan > s0 && status == 3'd2) && t0 < 4000 * MS) begin @(posedge clk); t0 = t0 + 1; end
    $display("[%0t] quick swap -> status=%0d img_count=%0d vol_ser=%08h after %0.1f ms",
             $time, status, img_count, dut.vol_ser, t0 * 1.0 / MS);
    if (nscan == s0 || status != 3'd2 || img_count != 5'd2) fail("quick swap not rescanned");
    if (dut.vol_ser !== (VOL_SER ^ 32'h5A5A5A5A)) fail("new vol_ser");
    request(4'd0, ok, slot, lat); cur_slot = slot;
    if (!ok || slot_hash[slot] !== HASH_IMG0) fail("img0 on new card");
    request(4'd2, ok, slot, lat);
    if (ok) fail("img2 should not exist on new card");

    // 4. 同一张卡瞬时无响应 (空闲时 0.4 s, 不掉电): 心跳重读成功, 序列号相同 -> 不重新扫描
    //    卡在心跳读发出的同时停止响应, 保证走 "超时 -> 复位控制器 -> 重新初始化 -> 核对序列号" 路径
    wait_idle;
    s0 = nscan; nstatus_bad = 0; nxrst = 0; watch_st = 1'b1;
    wait (dut.state == 6'd38);
    dut.u_sd_card_top.card_present = 1'b0;
    repeat (400 * MS) @(posedge clk);
    dut.u_sd_card_top.card_present = 1'b1;
    repeat (1000 * MS) @(posedge clk);
    watch_st = 1'b0;
    $display("[%0t] transient stall while idle: %0d controller resets, %0d rescans, status left READY %0d cycles, chk_card %0d",
             $time, nxrst, nscan - s0, nstatus_bad, dut.chk_card);
    if (nxrst < 1) fail("probe did not retry");
    if (nscan != s0 || nstatus_bad != 0 || dut.chk_card) fail("transient stall caused rescan");
    request(4'd0, ok, slot, lat);
    if (!ok || lat > 2000) fail("cache lost after transient stall");

    $display("sd sector reads: %0d", dut.u_sd_card_top.nread);
    if (errors == 0) $display("==== tb_loader HOTPLUG PASS ====");
    else             $display("==== tb_loader HOTPLUG FAIL (%0d errors) ====", errors);
    $finish;
end
`elsif FIT
reg [39:0] fit_exp [0:FIT_N-1];
integer    novf = 0;
always @(posedge clk) if (dut.u_fit.used > 12'd2048) novf = novf + 1;
initial begin
    $readmemh("fit_exp.hex", fit_exp);
    $display("==== tb_loader FIT start ====");
    #100 rst = 0;
    t0 = 0;
    while (status != 3'd2 && status != 3'd4 && status != 3'd5 && t0 < 5_000_000) begin
        @(posedge clk); t0 = t0 + 1;
    end
    $display("[%0t] scan done: status=%0d img_count=%0d", $time, status, img_count);
    if (status != 3'd2 || img_count != FIT_N) fail("scan");
    for (i = 0; i < FIT_N; i = i + 1) begin
        request(i, ok, slot, lat);
        case (i)
            0: check_res(i, "800x500  ");   1: check_res(i, "1000x333 ");
            2: check_res(i, "301x500  ");   3: check_res(i, "160x100  ");
            4: check_res(i, "202x150  ");   5: check_res(i, "123x77   ");
            6: check_res(i, "17x900   ");   7: check_res(i, "4096x16  ");
            10: check_res(i, "15x15    "); 11: check_res(i, "4097x16  ");
            default: ;                      // 8 RLE / 9 截断: 同样写入, 不显示 (图片错误提示)
        endcase
        if (ok !== fit_exp[i][36]) begin
            $display("  img %0d: ok=%0d expect %0d", i, ok, fit_exp[i][36]);
            fail("fit ok");
        end else if (ok) begin
            cur_slot = slot;
            if (slot_hash[slot] !== fit_exp[i][31:0] || slot_vf[slot] !== fit_exp[i][32]) begin
                $display("  img %0d: hash %08h vflip %0d, expect %08h vflip %0d", i,
                         slot_hash[slot], slot_vf[slot], fit_exp[i][31:0], fit_exp[i][32]);
                fail("fit frame");
            end else
                $display("  img %0d frame hash / vflip OK (%0.1f ms)", i, lat / 100000.0);
        end
    end
    if (novf != 0) fail("scaler ring overflow");
    $display("sd sector reads: %0d", dut.u_sd_card_top.nread);
    if (errors == 0) $display("==== tb_loader FIT PASS ====");
    else             $display("==== tb_loader FIT FAIL (%0d errors) ====", errors);
    $finish;
end
`elsif FOLDER
// 分类文件夹 + 播放列表: 位置顺序 / 名字 / 分辨率文字 / 秒数 (ack_dur) / 缺失图片应答失败 / MUSIC 与 SUB 文件夹
reg [43:0] fold_exp [0:FOLD_N-1];
function [9*8-1:0] res_exp(input integer idx);
    res_exp = FOLD_RES >> (8 * 9 * (FOLD_N - 1 - idx));
endfunction
function [8*8-1:0] name_exp(input integer idx);
    name_exp = FOLD_NAMES >> (8 * 8 * (FOLD_N - 1 - idx));
endfunction
initial begin
    $readmemh("fold_exp.hex", fold_exp);
    $display("==== tb_loader FOLDER start ====");
    #100 rst = 0;
    t0 = 0;
    while (status != 3'd2 && status != 3'd4 && status != 3'd5 && t0 < 5_000_000) begin
        @(posedge clk); t0 = t0 + 1;
    end
    $display("[%0t] scan done: status=%0d img_count=%0d txt_ok=%0d fnt_ok=%0d", $time, status, img_count, txt_ok, fnt_ok);
    if (status != 3'd2 || img_count != FOLD_N) fail("scan / img_count");
    if (!txt_ok || txt_len != TXT_N) fail("txt from SUB");
    for (i = 0; i < TXT_N; i = i + 1)
        if (txt_ram[i] !== txt_exp[i]) begin fail("txt byte"); i = TXT_N; end
    for (i = 0; i < 2048; i = i + 1)
        if (fnt_ram[i] !== fnt_exp[i]) begin fail("fnt byte"); i = 2048; end
    for (i = 0; i < FOLD_N; i = i + 1) begin
        request(i, ok, slot, lat);
        repeat (2) @(posedge clk);          // ack_dur 比 ack_img 晚一拍 (播放器同步后才采样)
        if (ok !== fold_exp[i][40]) begin
            $display("  pos %0d: ok=%0d expect %0d", i, ok, fold_exp[i][40]); fail("fold ok");
        end
        if (ack_dur !== fold_exp[i][39:32]) begin
            $display("  pos %0d: ack_dur=%0d expect %0d", i, ack_dur, fold_exp[i][39:32]); fail("ack_dur");
        end
        if (ok) begin
            cur_slot = slot;
            if (slot_hash[slot] !== fold_exp[i][31:0]) begin
                $display("  pos %0d: hash %08h expect %08h", i, slot_hash[slot], fold_exp[i][31:0]); fail("fold frame");
            end
            if (name_at(i) !== name_exp(i)) begin
                $display("  pos %0d: name '%s' expect '%s'", i, name_at(i), name_exp(i)); fail("fold name");
            end
            check_res(i, res_exp(i));
            $display("  pos %0d '%s' %0d s, frame hash OK", i, name_at(i), ack_dur);
        end else
            $display("  pos %0d missing -> ack fail (%0d s)", i, ack_dur);
    end
    t0 = 0;
    while (!wav_ok && t0 < 5_000_000) begin @(posedge clk); t0 = t0 + 1; end
    $display("  wav_ok=%0d rate=%0d (MUSIC\\MUSIC.WAV), %0d samples", wav_ok, wav_rate, wav_total);
    if (!wav_ok || wav_rate != WAV_RATE || wav_total < 600) fail("wav from MUSIC");
    if (wav_err) begin $display("  wav sample errors %0d", wav_err); fail("wav samples"); end
    if (errors == 0) $display("==== tb_loader FOLDER PASS ====");
    else             $display("==== tb_loader FOLDER FAIL (%0d errors) ====", errors);
    $finish;
end
`elsif REAL_SD
// 压力测试: 首图 -> 第二张 -> 来回切换 (缓存命中), 共运行 T_RUN 个周期
localparam integer T_RUN = 200_000_000;      // 2 s
initial begin
    $display("==== tb_loader stress start (WAV_CAP %0d, 48kHz consumer) ====", WAV_CAP);
    #100 rst = 0;
    t0 = 0;
    while (status != 3'd2 && t0 < 50_000_000) begin @(posedge clk); t0 = t0 + 1; end
    $display("[%0t] scan done: status=%0d img_count=%0d wav_ok=%0d (%0.1f ms)",
             $time, status, img_count, wav_ok, t0 / 100000.0);
    if (status != 3'd2) fail("status != READY");
    request(4'd0, ok, slot, lat);
    if (!ok || slot_hash[slot] !== HASH_IMG0) fail("img0");
    cur_slot = slot;
    request(4'd2, ok, slot, lat);
    if (!ok || slot_hash[slot] !== HASH_IMG2) fail("img2");
    cur_slot = slot;
    request(4'd0, ok, slot, lat); cur_slot = slot;
    request(4'd2, ok, slot, lat); cur_slot = slot;
    while ($time < T_RUN * 64'd10) @(posedge clk);
    $display("[%0t] wav: %0d samples written, %0d consumed, %0d errors, rate %0d",
             $time, wav_total, consumed, wav_err, wav_rate);
    $display("  underrun events %0d, starved samples %0d (%0.1f ms), min level after start %0d",
             xrun_ev, xrun_smp, xrun_smp / 48.0, min_lvl);
    $display("  sd sector reads: %0d", dut.u_sd_card_top.nread);
    if (wav_err) errors = errors + 1;
    if (xrun_ev) errors = errors + 1;
    if (errors == 0) $display("==== tb_loader STRESS PASS ====");
    else             $display("==== tb_loader STRESS FAIL (%0d errors) ====", errors);
    $finish;
end
`else
initial begin
    $display("==== tb_loader start ====");
    #100 rst = 0;

    // 1. 扫描
    t0 = 0;
    while (status != 3'd2 && status != 3'd4 && status != 3'd5 && t0 < 5_000_000) begin
        @(posedge clk); t0 = t0 + 1;
    end
    $display("[%0t] scan done: status=%0d img_count=%0d wav_ok=%0d txt_ok=%0d fnt_ok=%0d (%0.1f us)",
             $time, status, img_count, wav_ok, txt_ok, fnt_ok, t0 / 100.0);
    if (status != 3'd2) fail("status != READY");
    if (img_count != 5'd3) fail("img_count != 3");
    if (!txt_ok || txt_len != TXT_N) fail("txt");
    if (!fnt_ok) fail("fnt_ok");
    if (name_at(0) != "IMG_A   ") fail("name 0");
    if (name_at(1) != "BAD     ") fail("name 1");
    if (name_at(2) != "IMG_C   ") fail("name 2");
    $display("  names: '%s' '%s' '%s'", name_at(0), name_at(1), name_at(2));
    for (i = 0; i < TXT_N; i = i + 1)
        if (txt_ram[i] !== txt_exp[i]) begin fail("txt byte"); i = TXT_N; end
    for (i = 0; i < 2048; i = i + 1)
        if (fnt_ram[i] !== fnt_exp[i]) begin fail("fnt byte"); i = 2048; end

    // 2. 首图
    request(4'd0, ok, slot, lat);
    if (!ok) fail("img0 not ok");
    cur_slot = slot;
    if (slot_hash[slot] !== HASH_IMG0) begin
        $display("  hash slot%0d = %08h, expect %08h", slot, slot_hash[slot], HASH_IMG0);
        fail("img0 hash");
    end else $display("  img0 frame hash OK");
    check_res(0, "640x400  ");

    // 3. 损坏图片
    request(4'd1, ok, slot, lat);
    if (ok) fail("bad img acked ok");

    // 4. IMG_C (后台预取中或已完成)
    request(4'd2, ok, slot, lat);
    if (!ok) fail("img2 not ok");
    cur_slot = slot;
    if (slot_hash[slot] !== HASH_IMG2) begin
        $display("  hash slot%0d = %08h, expect %08h", slot, slot_hash[slot], HASH_IMG2);
        fail("img2 hash");
    end else $display("  img2 frame hash OK (fragmented cluster chain)");
    check_res(2, "640x480  ");

    // 5. 回到 img0: 应缓存命中
    request(4'd0, ok, slot, lat);
    if (!ok) fail("img0 again");
    if (lat > 2000) fail("img0 not served from cache");
    cur_slot = slot;
    request(4'd2, ok, slot, lat);
    if (lat > 2000) fail("img2 not served from cache");

    // 6. 等待 WAV 至少循环一次
    t0 = 0;
    while (wav_loops < 1 && t0 < 20_000_000) begin @(posedge clk); t0 = t0 + 1; end
    $display("[%0t] wav: %0d samples written, %0d loops, %0d errors, rate code %0d",
             $time, wav_total, wav_loops, wav_err, wav_rate_code);
    if (wav_loops < 1) fail("wav did not loop");
    if (!wav_ok || wav_rate != WAV_RATE || wav_rate_code != 3'd4) fail("wav format");
    if (wav_err) errors = errors + 1;

    // 7. 瞬时读超时: 卡停止响应 400 ms (超过 250 ms 单扇区超时) 后恢复.
    //    应只复位 TF 卡控制器并重读该扇区: 状态保持 READY, WAV 接着原位置继续 (样本序列不能从头开始),
    //    图片缓存仍然有效
    nstatus_bad = 0; nxrst = 0;
    t0 = wav_total;
    dut.u_sd_card_top.card_present = 1'b0;
    watch_st = 1'b1;
    #400_000_000;
    dut.u_sd_card_top.card_present = 1'b1;
    i = 0;
    while (wav_total < t0 + 20000 && i < 50_000_000) begin @(posedge clk); i = i + 1; end
    watch_st = 1'b0;
    $display("[%0t] transient stall 400 ms: %0d controller resets, status left READY %0d cycles, wav +%0d samples, %0d errors",
             $time, nxrst, nstatus_bad, wav_total - t0, wav_err);
    if (nxrst < 1) fail("no sector retry after timeout");
    if (nstatus_bad != 0) fail("status left READY during retry");
    if (wav_total < t0 + 20000) fail("wav did not resume");
    if (wav_err) errors = errors + 1;
    request(4'd0, ok, slot, lat);
    if (!ok || lat > 2000) fail("cache lost after retry");
    cur_slot = slot;

    // 8. 热插拔: 拔卡 -> 重读仍失败 -> NOCARD -> 插回 -> 重新扫描 -> 重新加载
    wav_chk = 1'b0;
    dut.u_sd_card_top.card_present = 1'b0;
    t0 = 0;
    while (status != 3'd3 && t0 < 300_000_000) begin @(posedge clk); t0 = t0 + 1; end
    $display("[%0t] card removed -> status=%0d after %0.1f ms", $time, status, t0 / 100000.0);
    if (status != 3'd3) fail("no NOCARD after removal");
    dut.u_sd_card_top.card_present = 1'b1;
    t0 = 0;
    while (status != 3'd2 && t0 < 30_000_000) begin @(posedge clk); t0 = t0 + 1; end
    $display("[%0t] card inserted -> status=%0d img_count=%0d after %0.1f ms", $time, status, img_count, t0 / 100000.0);
    if (status != 3'd2 || img_count != 5'd3) fail("rescan after insert");
    request(4'd2, ok, slot, lat);
    if (!ok || slot_hash[slot] !== HASH_IMG2) fail("reload img2 after insert");
    check_res(2, "640x480  ");

    $display("sd sector reads: %0d", dut.u_sd_card_top.nread);
    if (errors == 0) $display("==== tb_loader PASS ====");
    else             $display("==== tb_loader FAIL (%0d errors) ====", errors);
    $finish;
end
`endif

initial begin
    repeat (8) #1_000_000_000;
    $display("==== tb_loader TIMEOUT ====");
    $finish;
end

endmodule
