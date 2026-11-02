// 自动生成, 请勿手改: python/gen_gamma_rom.py
// 色温增益 (256 = 1.0): {R[8:0], G[8:0], B[8:0]}, 级别 8 为原样
function [26:0] temp_gain;
    input [4:0] t;
    begin
        case (t)
            5'd0: temp_gain = {9'd256, 9'd224, 9'd160};
            5'd1: temp_gain = {9'd256, 9'd228, 9'd172};
            5'd2: temp_gain = {9'd256, 9'd232, 9'd184};
            5'd3: temp_gain = {9'd256, 9'd236, 9'd196};
            5'd4: temp_gain = {9'd256, 9'd240, 9'd208};
            5'd5: temp_gain = {9'd256, 9'd244, 9'd220};
            5'd6: temp_gain = {9'd256, 9'd248, 9'd232};
            5'd7: temp_gain = {9'd256, 9'd252, 9'd244};
            5'd8: temp_gain = {9'd256, 9'd256, 9'd256};
            5'd9: temp_gain = {9'd246, 9'd253, 9'd256};
            5'd10: temp_gain = {9'd236, 9'd250, 9'd256};
            5'd11: temp_gain = {9'd226, 9'd247, 9'd256};
            5'd12: temp_gain = {9'd216, 9'd244, 9'd256};
            5'd13: temp_gain = {9'd206, 9'd241, 9'd256};
            5'd14: temp_gain = {9'd196, 9'd238, 9'd256};
            5'd15: temp_gain = {9'd186, 9'd235, 9'd256};
            5'd16: temp_gain = {9'd176, 9'd232, 9'd256};
            default: temp_gain = {9'd256, 9'd256, 9'd256};
        endcase
    end
endfunction
