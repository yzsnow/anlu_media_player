`timescale 1ns/1ps
//============================================================================
// sd_card_top 行为模型 (仅仿真)
//  端口/参数与 SD/sd_card_top.v 相同, 扇区内容来自 disk.img.
//  读时序模仿 sd_card_sec_read_write:
//    空闲时采样 sd_sec_read -> 命令延迟 -> 512 个 valid 字节 (间隔 BYTE_GAP)
//    -> CRC 间隔 -> sd_sec_read_end 一拍 -> 回到空闲再采样 sd_sec_read
//============================================================================
module sd_card_top #(
    parameter SPI_LOW_SPEED_DIV  = 248,
    parameter SPI_HIGH_SPEED_DIV = 0
)(
    input            clk,
    input            rst,
    output           SD_nCS,
    output           SD_DCLK,
    output           SD_MOSI,
    input            SD_MISO,
    output reg       sd_init_done,
    input            sd_sec_read,
    input  [31:0]    sd_sec_read_addr,
    output reg [7:0] sd_sec_read_data,
    output reg       sd_sec_read_data_valid,
    output           sd_sec_read_end,
    input            sd_sec_write,
    input  [31:0]    sd_sec_write_addr,
    input  [7:0]     sd_sec_write_data,
    output           sd_sec_write_data_req,
    output           sd_sec_write_end
);

`include "expect.vh"

parameter integer INIT_CYC = 3000;
`ifdef REAL_SD
// 接近实际的 TF 卡时序 (压力测试用, 见 README): 25MHz SPI 每字节 36 周期;
// 命令到数据令牌的访问延迟: 紧接上一扇区 0.1 ms, 跳址 1 ms; 每 1000 次读插入一次 40 ms 长延迟
parameter integer CMD_LAT  = 10_000;
parameter integer SEEK_LAT = 100_000;
parameter integer SPIKE_N  = 1000;
parameter integer SPIKE    = 4_000_000;
parameter integer BYTE_GAP = 36;
parameter integer CRC_GAP  = 80;
`else
parameter integer CMD_LAT  = 40;
parameter integer SEEK_LAT = 40;
parameter integer SPIKE_N  = 0;
parameter integer SPIKE    = 0;
parameter integer BYTE_GAP = 4;
parameter integer CRC_GAP  = 40;
`endif

assign SD_nCS  = 1'b1;
assign SD_DCLK = 1'b0;
assign SD_MOSI = 1'b1;
assign sd_sec_write_data_req = 1'b0;
assign sd_sec_write_end      = 1'b0;

reg [7:0] disk [0:DISK_BYTES-1];
integer fd, n;
initial begin
    fd = $fopen("disk.img", "rb");
    if (fd == 0) begin
        $display("STUB: cannot open disk.img");
        $finish;
    end
    n = $fread(disk, fd);
    $fclose(fd);
    $display("STUB: disk.img %0d bytes", n);
end

// 仿真控制: tb 可以置 card_present = 0 模拟拔卡
//   power_lost = 1: 卡掉过电 (拔出 / 换卡), 回到 SD 模式, 控制器复位重新初始化之前不响应读命令
reg card_present = 1'b1;
reg power_lost   = 1'b0;

localparam S_INIT = 0, S_IDLE = 1, S_CMD = 2, S_DATA = 3, S_CRC = 4, S_END = 5;
reg [2:0]  st;
assign sd_sec_read_end = (st == S_END);   // 与原模块一样是状态译码
integer    cnt, bi;
reg [31:0] base;
integer    nread = 0;
integer    lat = 0;
reg [31:0] last_addr = 32'hFFFF_FFF0;

always @(posedge clk or posedge rst) begin
    if (rst) begin
        st <= S_INIT; cnt <= 0; bi <= 0; base <= 0;
        sd_init_done <= 1'b0;
        power_lost   <= 1'b0;
        sd_sec_read_data <= 8'd0; sd_sec_read_data_valid <= 1'b0;
    end else begin
        sd_sec_read_data_valid <= 1'b0;
        case (st)
        S_INIT: begin
            cnt <= cnt + 1;
            if (cnt >= INIT_CYC && card_present) begin
                sd_init_done <= 1'b1;
                st <= S_IDLE;
            end
        end
        S_IDLE: if (sd_sec_read) begin
            base  <= sd_sec_read_addr * 512;
            cnt   <= 0;
            bi    <= 0;
            nread = nread + 1;
            lat   = (sd_sec_read_addr == last_addr + 1) ? CMD_LAT : SEEK_LAT;
            if (SPIKE_N > 0 && nread % SPIKE_N == 0) lat = lat + SPIKE;
            last_addr <= sd_sec_read_addr;
            st    <= S_CMD;
        end
        S_CMD: begin
            cnt <= cnt + 1;
            if (cnt >= lat && card_present && !power_lost) begin cnt <= 0; st <= S_DATA; end
        end
        S_DATA: begin
            cnt <= cnt + 1;
            if (cnt == BYTE_GAP - 1) begin
                cnt <= 0;
                sd_sec_read_data_valid <= 1'b1;
                sd_sec_read_data <= (base + bi < DISK_BYTES) ? disk[base + bi] : 8'h00;
                bi <= bi + 1;
                if (bi == 511) st <= S_CRC;
            end
        end
        S_CRC: begin
            cnt <= cnt + 1;
            if (cnt >= CRC_GAP) begin cnt <= 0; st <= S_END; end
        end
        S_END: begin
            st <= S_IDLE;
        end
        default: st <= S_IDLE;
        endcase
    end
end

endmodule
