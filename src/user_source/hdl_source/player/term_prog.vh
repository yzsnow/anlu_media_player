// 自动生成, 请勿手改: python/gen_term_rom.py
localparam [10:0] P_STATUS = 1792, P_LOG = 1995, P_CMDCLR = 2012, P_CMDW = 2018;
localparam FONT_DEPTH = 7872;
localparam [5:0] LOG_TOP = 12, LOG_N = 15, CMD_ROW = 29;
localparam [6:0] CMD_C0 = 18, CMD_MAX = 126;
localparam NEV = 15;
localparam [3:0] E_BOOT = 0;
localparam [3:0] E_ST = 1;
localparam [3:0] E_IMG = 2;
localparam [3:0] E_MENU = 3;
localparam [3:0] E_PMODE = 4;
localparam [3:0] E_ARM = 5;
localparam [3:0] E_ALM = 6;
localparam [3:0] E_WAVE = 7;
localparam [3:0] E_AUTO = 8;
localparam [3:0] E_EFF = 9;
localparam [3:0] E_AMODE = 10;
localparam [3:0] E_WAV = 11;
localparam [3:0] E_BAD = 12;
localparam [3:0] E_CMD = 13;
localparam [3:0] E_CMDERR = 14;
// 事件表: {按值选消息, 有后缀, 后缀 STR 数据字[8:0], 消息 STR 数据字[8:0]}  (数据字 = {sz[1:0], 槽号[6:0]})
function [19:0] ev_tab;
    input [3:0] e;
    begin
        case (e)
            4'd0: ev_tab = {1'b0, 1'b0, 9'h000, 9'h0b7};  // BOOT
            4'd1: ev_tab = {1'b1, 1'b0, 9'h000, 9'h0ac};  // ST
            4'd2: ev_tab = {1'b0, 1'b0, 9'h000, 9'h09e};  // IMG
            4'd3: ev_tab = {1'b0, 1'b1, 9'h002, 9'h0a3};  // MENU
            4'd4: ev_tab = {1'b0, 1'b1, 9'h004, 9'h09f};  // PMODE
            4'd5: ev_tab = {1'b1, 1'b0, 9'h000, 9'h0a4};  // ARM
            4'd6: ev_tab = {1'b1, 1'b0, 9'h000, 9'h0b2};  // ALM
            4'd7: ev_tab = {1'b0, 1'b1, 9'h002, 9'h0a6};  // WAVE
            4'd8: ev_tab = {1'b0, 1'b1, 9'h002, 9'h0a0};  // AUTO
            4'd9: ev_tab = {1'b0, 1'b1, 9'h014, 9'h0a1};  // EFF
            4'd10: ev_tab = {1'b0, 1'b1, 9'h01d, 9'h03b};  // AMODE
            4'd11: ev_tab = {1'b0, 1'b0, 9'h000, 9'h0a2};  // WAV
            4'd12: ev_tab = {1'b0, 1'b0, 9'h000, 9'h0b6};  // BAD
            4'd13: ev_tab = {1'b0, 1'b1, 9'h030, 9'h03a};  // CMD
            4'd14: ev_tab = {1'b1, 1'b0, 9'h000, 9'h0a7};  // CMDERR
            default: ev_tab = 20'h0;
        endcase
    end
endfunction
// 调色板
function [23:0] pal;
    input [2:0] k;
    begin
        case (k)
            3'd0: pal = 24'h4A5868;
            3'd1: pal = 24'hE6EDF3;
            3'd2: pal = 24'h4DD0E1;
            3'd3: pal = 24'h69F0AE;
            3'd4: pal = 24'hFFD740;
            3'd5: pal = 24'hFF5252;
            3'd6: pal = 24'h9AA8B6;
            3'd7: pal = 24'h82B1FF;
        endcase
    end
endfunction
localparam [23:0] BG_MAIN = 24'h0B1622, BG_TITLE = 24'h0D47A1, BG_SBAR = 24'h1C2833, CURSOR = 24'hE6EDF3;
