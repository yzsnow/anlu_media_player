`timescale 1ns/1ps
//============================================================================
// frame_dual_read_write
//  SDRAM 帧缓存仲裁: 1 路写 (TF 卡图片) + 2 路读 (A: 当前图, B: 转场目标图)
//
//  写通道沿用原工程 frame_fifo_write (带 BMP 垂直翻转, 自上而下存储的 BMP 由 write_vflip=0 关闭翻转)
//  读通道: 每帧 read_req 时锁存 base_a / base_b / b_en, 复位两个读 FIFO,
//          然后按 256 字突发交替填充 A / B (FIFO 余量少的优先).
//          B 路只在转场期间 (b_en=1) 读取, 平时不占 SDRAM 带宽.
//  一次突发的数据全部返回后 (rd_delay==10) 才开始下一突发, 所以用
//  当前突发的 sel 即可把 Sdr_rd_en 分发到对应 FIFO.
//
//  行刷新 (scrub): 所用 SDRAM 控制器的内部自动刷新实际不起作用
//  (global_def.v 中 SELF_REFRESH_INTERVAL 宏因缺括号算得 0), 只有被读写的行
//  能保住数据 -- 正在显示的图每帧都被读所以完好, 缓存中的其他图会逐渐出现花点.
//  这里每 SCRUB_DIV 个周期对下一行 (row+bank 共 8192 行) 做一次整行突发读,
//  读操作的 ACTIVE/PRECHARGE 即刷新该行. 8192 x 900 x 8 ns = 59 ms 扫完全部行,
//  满足 SDRAM 64 ms 刷新要求. 读回数据丢弃, 不进 FIFO.
//  行刷新读与显示读完全相同 (256 字对齐突发, 同一套时序), 只是数据不写 FIFO:
//  曾用单字读做行刷新, 板上每个突发开头 (SDRAM 行首) 出现闪烁的彩色竖条,
//  说明 SDRAM 控制器对单字读之后的下一个突发处理有问题, 故只使用原工程验证过的整行突发.
//  占用约 30% 的 SDRAM 时间, 转场双路读 + 行刷新合计约 60%.
//============================================================================
module frame_dual_read_write #(
    parameter ADDR_BITS   = 21,
    parameter BURST_SIZE  = 256,
    parameter FRAME_LEN   = 256000,     // 640 x FRAME_H
    parameter FRAME_H     = 400,        // 图片行数 (BMP 垂直翻转用)
    parameter SCRUB_DIV   = 900
)(
    input                    rst,
    input                    mem_clk,
    input                    Sdr_init_done,
    input                    Sdr_init_ref_vld,
    input                    Sdr_busy,
    // SDRAM 读
    output                   App_rd_en,
    output [ADDR_BITS-1:0]   App_rd_addr,
    input                    Sdr_rd_en,
    input  [31:0]            Sdr_rd_dout,
    // SDRAM 写
    output                   App_wr_en,
    output [ADDR_BITS-1:0]   App_wr_addr,
    output [31:0]            App_wr_din,
    output [3:0]             App_wr_dm,
    // 视频读端 (read_clk 域)
    input                    read_clk,
    input                    read_req,
    output reg               read_req_ack,
    input  [ADDR_BITS-1:0]   base_a,
    input  [ADDR_BITS-1:0]   base_b,
    input                    b_en,
    input                    read_en_a,
    output [31:0]            read_data_a,
    input                    read_en_b,
    output [31:0]            read_data_b,
    // 写端 (write_clk 域)
    input                    write_clk,
    input                    write_req,
    output                   write_req_ack,
    output                   write_finish,
    input  [ADDR_BITS-1:0]   write_addr,
    input                    write_en,
    input  [31:0]            write_data,
    output                   write_afull,      // 写 FIFO 将满 (write_clk 域)
    input                    write_vflip       // 本帧垂直翻转 (BMP 自下而上)
);

localparam [ADDR_BITS-1:0] LEN = FRAME_LEN;

//---------------------------------------------------------------------------
// 写通道 (与原 frame_read_write 相同)
//---------------------------------------------------------------------------
wire [8:0] w_rdusedw;
// rdusedw 打一拍再送 frame_fifo_write, 切断 FIFO 计数减法 -> into_burst 比较 -> O_wr_busy 的长路径.
// 突发外只有写入, 延迟值只会偏小; 突发结束 (BURST_END) 后才重新比较, 此时寄存值已更新.
reg  [8:0] w_rdusedw_r;
wire       write_fifo_aclr;
wire       O_wr_busy;
wire       O_rd_busy;

assign App_wr_dm = 4'b0000;

// afull 门限放低到 448: 写端每 4 拍最多写一个字, 留足同步延迟余量
wfifo_32_32_512 #(.AL_FULL_NUM(448)) write_buf(
    .clkr       (mem_clk),
    .clkw       (write_clk),
    .rst        (write_fifo_aclr),
    .we         (write_en),
    .re         (App_wr_en),
    .di         (write_data),
    .dout       (App_wr_din),
    .valid      (),
    .full_flag  (),
    .empty_flag (),
    .afull      (write_afull),
    .aempty     (),
    .wrusedw    (),
    .rdusedw    (w_rdusedw)
);

always @(posedge mem_clk or posedge rst) begin
    if (rst) w_rdusedw_r <= 9'd0;
    else     w_rdusedw_r <= w_rdusedw;
end

frame_fifo_write #(
    .MEM_DATA_BITS (32),
    .ADDR_BITS     (ADDR_BITS),
    .BURST_BITS    (9),
    .BURST_SIZE    (BURST_SIZE),
    .WRITE_V_FLIP  (1),
    .FRAME_WIDTH   (640),
    .FRAME_HEIGHT  (FRAME_H)
) frame_fifo_write_m0(
    .rst              (rst),
    .mem_clk          (mem_clk),
    .Sdr_init_done    (Sdr_init_done),
    .Sdr_init_ref_vld (Sdr_init_ref_vld),
    .Sdr_busy         (Sdr_busy),
    .App_rd_busy      (O_rd_busy),
    .O_wr_busy        (O_wr_busy),
    .App_wr_en        (App_wr_en),
    .App_wr_addr      (App_wr_addr),
    .write_req       (write_req),
    .write_req_ack    (write_req_ack),
    .write_finish     (write_finish),
    .write_addr_0     (write_addr),
    .write_addr_1     (write_addr),
    .write_addr_2     (write_addr),
    .write_addr_3     (write_addr),
    .write_addr_index (2'd0),
    .write_len        (LEN),
    .fifo_aclr        (write_fifo_aclr),
    .rdusedw          ({1'b0, w_rdusedw_r}),
    .write_vflip      (write_vflip)
);

//---------------------------------------------------------------------------
// 双读通道
//---------------------------------------------------------------------------
localparam S_IDLE = 3'd0, S_ACK = 3'd1, S_CHECK = 3'd2, S_BURST = 3'd3, S_BEND = 3'd4;

reg  [2:0]           state;
reg                  req_d0, req_d1, req_d2;
reg  [ADDR_BITS-1:0] ba_d0, ba_d1, bb_d0, bb_d1;
reg                  ben_d0, ben_d1;
reg  [ADDR_BITS-1:0] addr_a, addr_b;
reg  [ADDR_BITS-1:0] cnt_a, cnt_b;
reg                  ben_l;
reg                  sel;
reg                  fifo_rst;
reg  [8:0]           burst_cnt;
reg                  rd_en_r, rd_en_d0;
reg  [3:0]           rd_delay;
wire [8:0]           wu_a, wu_b;
// 行刷新
reg  [9:0]           scrub_tmr;
reg  [3:0]           scrub_cred;         // 待做的行刷新次数
reg  [ADDR_BITS-9:0] scrub_row;          // {row, bank}
reg  [7:0]           scrub_col;          // 每次行刷新正好 256 字, 结束时自然回到 0, 不必清零
reg                  scrub_b;            // 当前突发是行刷新
reg                  scrub_done;
reg  [2:0]           scrub_ret;          // 行刷新结束后返回的状态 (S_IDLE / S_CHECK)
wire                 scrub_pend = (scrub_cred != 4'd0) && !scrub_done;   // scrub_done 这拍计数尚未减

wire need_a = (cnt_a < LEN) && (wu_a < 9'd248);
wire need_b = ben_l && (cnt_b < LEN) && (wu_b < 9'd248);

assign O_rd_busy   = (state == S_BURST);
assign App_rd_en   = rd_en_d0;
assign App_rd_addr = scrub_b ? {scrub_row, scrub_col} : (sel ? addr_b : addr_a);

always @(posedge mem_clk or posedge rst) begin
    if (rst) begin
        scrub_tmr <= 10'd0; scrub_cred <= 4'd0; scrub_row <= 0;
    end else begin
        if (scrub_tmr == SCRUB_DIV - 1) scrub_tmr <= 10'd0;
        else                            scrub_tmr <= scrub_tmr + 10'd1;
        // 同一拍既到期又完成一次刷新时计数不变
        if ((scrub_tmr == SCRUB_DIV - 1) && !scrub_done) begin
            if (scrub_cred != 4'hf) scrub_cred <= scrub_cred + 4'd1;
        end else if (scrub_done && (scrub_tmr != SCRUB_DIV - 1))
            scrub_cred <= scrub_cred - 4'd1;
        if (scrub_done) scrub_row <= scrub_row + 1'b1;
    end
end

always @(posedge mem_clk or posedge rst) begin
    if (rst) begin
        req_d0 <= 1'b0; req_d1 <= 1'b0; req_d2 <= 1'b0;
        ba_d0 <= 0; ba_d1 <= 0; bb_d0 <= 0; bb_d1 <= 0;
        ben_d0 <= 1'b0; ben_d1 <= 1'b0;
    end else begin
        req_d0 <= read_req; req_d1 <= req_d0; req_d2 <= req_d1;
        ba_d0 <= base_a; ba_d1 <= ba_d0;
        bb_d0 <= base_b; bb_d1 <= bb_d0;
        ben_d0 <= b_en;  ben_d1 <= ben_d0;
    end
end

always @(posedge mem_clk or posedge rst) begin
    if (rst || App_rd_en) rd_delay <= 4'd0;
    else if (rd_delay < 4'd10) rd_delay <= rd_delay + 4'd1;
end

wire burst_done = (state == S_BURST) && (burst_cnt >= BURST_SIZE) && (rd_delay == 4'd10);

always @(posedge mem_clk or posedge rst) begin
    if (rst) begin
        state <= S_IDLE;
        read_req_ack <= 1'b0;
        fifo_rst <= 1'b0;
        addr_a <= 0; addr_b <= 0; cnt_a <= 0; cnt_b <= 0;
        ben_l <= 1'b0; sel <= 1'b0;
        burst_cnt <= 9'd0; rd_en_r <= 1'b0; rd_en_d0 <= 1'b0;
        scrub_b <= 1'b0; scrub_col <= 8'd0; scrub_done <= 1'b0; scrub_ret <= S_IDLE;
    end else begin
        scrub_done <= 1'b0;
        if (state == S_CHECK || state == S_IDLE) burst_cnt <= 9'd0;
        else if (rd_en_d0)                        burst_cnt <= burst_cnt + 9'd1;

        if (rd_en_d0) begin
            if (scrub_b)  scrub_col <= scrub_col + 8'd1;
            else if (sel) addr_b <= addr_b + 1'b1;
            else          addr_a <= addr_a + 1'b1;
        end

        rd_en_d0 <= rd_en_r && (burst_cnt + rd_en_d0 < BURST_SIZE);

        case (state)
        S_IDLE: begin
            read_req_ack <= 1'b0;
            if (req_d2 && Sdr_init_done)
                state <= S_ACK;
            else if (Sdr_init_done && scrub_pend && !O_wr_busy) begin
                scrub_b   <= 1'b1;
                rd_en_r   <= 1'b1;
                scrub_ret <= S_IDLE;
                state     <= S_BURST;
            end
        end
        S_ACK: begin
            if (!req_d2) begin
                read_req_ack <= 1'b0;
                fifo_rst     <= 1'b0;
                state        <= S_CHECK;
            end else begin
                read_req_ack <= 1'b1;
                fifo_rst     <= 1'b1;
            end
            addr_a <= ba_d1;
            addr_b <= bb_d1;
            ben_l  <= ben_d1;
            cnt_a  <= 0;
            cnt_b  <= 0;
        end
        S_CHECK: begin
            if (req_d2)
                state <= S_ACK;
            else if (!O_wr_busy && (need_a || need_b)) begin
                sel     <= need_a && (!need_b || wu_a <= wu_b) ? 1'b0 : 1'b1;
                rd_en_r <= 1'b1;
                state   <= S_BURST;
            end else if (!O_wr_busy && scrub_pend) begin
                scrub_b   <= 1'b1;
                rd_en_r   <= 1'b1;
                scrub_ret <= S_CHECK;
                state     <= S_BURST;
            end
        end
        S_BURST: begin
            if (burst_done) begin
                rd_en_r <= 1'b0;
                if (scrub_b) begin
                    // 行刷新突发的数据此时已全部返回 (未写入 FIFO)
                    scrub_b    <= 1'b0;
                    scrub_done <= 1'b1;
                    state      <= scrub_ret;
                end else begin
                    if (sel) cnt_b <= cnt_b + BURST_SIZE;
                    else     cnt_a <= cnt_a + BURST_SIZE;
                    state <= S_BEND;
                end
            end
        end
        S_BEND: begin
            if (req_d2)                                    state <= S_ACK;
            else if (cnt_a < LEN || (ben_l && cnt_b < LEN)) state <= S_CHECK;
            else                                           state <= S_IDLE;
        end
        default: state <= S_IDLE;
        endcase
    end
end

rfifo_32_32_512 read_buf_a(
    .clkr       (read_clk),
    .clkw       (mem_clk),
    .rst        (fifo_rst),
    .we         (Sdr_rd_en & ~sel & ~scrub_b),
    .re         (read_en_a),
    .di         (Sdr_rd_dout),
    .dout       (read_data_a),
    .valid      (),
    .full_flag  (),
    .empty_flag (),
    .afull      (),
    .aempty     (),
    .wrusedw    (wu_a),
    .rdusedw    ()
);

rfifo_32_32_512 read_buf_b(
    .clkr       (read_clk),
    .clkw       (mem_clk),
    .rst        (fifo_rst),
    .we         (Sdr_rd_en & sel & ~scrub_b),
    .re         (read_en_b),
    .di         (Sdr_rd_dout),
    .dout       (read_data_b),
    .valid      (),
    .full_flag  (),
    .empty_flag (),
    .afull      (),
    .aempty     (),
    .wrusedw    (wu_b),
    .rdusedw    ()
);

endmodule
