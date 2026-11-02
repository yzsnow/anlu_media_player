`timescale 1ns/1ps
//---------------------------------------------------------------------------
// 8 位数码管动态扫描 (HX4S20C 板载 8 位共阳数码管)
// 参照第三讲 seg7_panel.v 的扫描驱动与官方 5_seg_SCAN / seg_scan:
//   位选 seg_sel 低有效独热码, seg_sel[0] = 最右位 (D11) ... seg_sel[7] = 最左位 (F16)
//   段码 {dp, g, f, e, d, c, b, a} 低有效, 由调用者给出 (8'hff = 全灭)
//   每位 8192 个时钟 (50 MHz 下 164 us, 8 位一圈 1.31 ms, 与例程相同)
//---------------------------------------------------------------------------
module seg_scan8 #(
    parameter integer SCAN_STEP_CYCLES = 8192
) (
    input            clk,
    input            rst_n,
    input      [7:0] seg_data_0,     // 最右位
    input      [7:0] seg_data_1,
    input      [7:0] seg_data_2,
    input      [7:0] seg_data_3,
    input      [7:0] seg_data_4,
    input      [7:0] seg_data_5,
    input      [7:0] seg_data_6,
    input      [7:0] seg_data_7,     // 最左位
    output reg [7:0] seg_sel,
    output reg [7:0] seg_data
);

reg [12:0] scan_cnt;
reg [2:0]  scan_idx;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        scan_cnt <= 13'd0;
        scan_idx <= 3'd0;
        seg_sel  <= 8'hff;
        seg_data <= 8'hff;
    end else begin
        if (scan_cnt == SCAN_STEP_CYCLES - 1) begin
            scan_cnt <= 13'd0;
            scan_idx <= scan_idx + 3'd1;
        end else begin
            scan_cnt <= scan_cnt + 13'd1;
        end
        seg_sel <= ~(8'b0000_0001 << scan_idx);
        case (scan_idx)
            3'd0: seg_data <= seg_data_0;
            3'd1: seg_data <= seg_data_1;
            3'd2: seg_data <= seg_data_2;
            3'd3: seg_data <= seg_data_3;
            3'd4: seg_data <= seg_data_4;
            3'd5: seg_data <= seg_data_5;
            3'd6: seg_data <= seg_data_6;
            default: seg_data <= seg_data_7;
        endcase
    end
end

endmodule
