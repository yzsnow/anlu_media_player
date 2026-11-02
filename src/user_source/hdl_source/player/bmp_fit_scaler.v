// 任意分辨率 BMP -> 640x400 等比缩放 (最近邻), 上下或左右补黑边居中.
//
//  输入: sd_media_loader 送来的 BMP 像素区字节 (B,G,R[,A], 每行补齐到 4 字节).
//  输出: 恰好 256000 个像素 {R,G,B,8'h00}, 按 BMP 行到达顺序, 交给 frame_fifo_write.
//        自下而上存储 (高度为正) 的图 vflip=1, 写地址垂直翻转; 自上而下 (高度为负) vflip=0.
//
//  几何: W*400 >= H*640 (比屏幕宽): dw = 640, dh = H*640/W; 否则 dh = 400, dw = W*400/H.
//        目标像素 k 取源像素 floor(k*W/dw), 目标行 j 取源行 floor(j*H/dh) (都按到达顺序计).
//  结构:
//   - 填充端: 源图比目标大的方向先抽取 (DDA 判定该源像素/行是否被某个目标像素选中),
//     被选中的像素写入 2048 像素环形行缓存. 每个存储行 Ls = min(W, dw) <= 640 像素,
//     共 Hs = min(H, dh) 行; 全部存完后 need=0, 加载器不必再读后面的扇区.
//   - 输出端: 逐行生成 640x400: 黑边行 / [左黑边][dw 像素][右黑边]. 源图比目标小的方向
//     用 DDA 重复像素 / 重复整行; 一行最后一次使用后释放其缓存空间.
//   - 流控: room = 缓存剩余 >= 256 像素. 一个扇区最多 171 个像素, 加载器每读一个图片扇区前
//     等待 room, 小图大倍数放大时自动降速, 缓存不会溢出.
//  DDA 只用加法和符号位, 唯一的除法在每张图开始时用 10 拍移位相减完成, 不占 DSP.
//  每个输出像素 4 拍 (25 M 像素/s, 写满一帧约 10 ms), 写 FIFO afull 时暂停.
module bmp_fit_scaler (
    input             clk,
    input             rst,
    input             start,        // 新图片任务开始: 清空全部状态
    input             cfg,          // 头部 (偏移 0~33) 解析完毕, 单拍
    input      [31:0] cfg_w,
    input      [31:0] cfg_h,        // 有符号, 负值表示自上而下存储
    input      [15:0] cfg_bpp,
    input      [31:0] cfg_comp,
    input             px_vld,       // 像素区字节
    input      [7:0]  px_byte,
    input             afull,        // 写 FIFO 将满
    output reg        wr_en,
    output reg [31:0] wr_data,
    output reg        bad,          // 尺寸 / 格式不支持
    output reg        need,         // 还需要源数据
    output reg        room,         // 行缓存可再接收一个扇区
    output reg        done,         // 256000 像素全部送出
    output reg [18:0] dst_cnt,
    output reg        vflip
);

localparam [9:0] OW = 10'd640;
localparam [8:0] OH = 9'd400;

//---------------------------------------------------------------------------
// 每张图的几何参数
//---------------------------------------------------------------------------
localparam [2:0] G_IDLE = 3'd0, G_CHK = 3'd1, G_MUL = 3'd2, G_DIV = 3'd3, G_SET = 3'd4,
                 G_RUN = 3'd5, G_BAD = 3'd6, G_ABS = 3'd7;
reg [2:0]  gs;
reg [31:0] r_w, r_h, r_ha;
reg [15:0] r_bpp;
reg [31:0] r_comp;
reg [12:0] w13, h13;        // 宽 / 高 (16 ~ 4096)
reg        bpp32;
reg        wide;            // W*400 >= H*640
reg [22:0] rem;
reg [21:0] dsh;             // 除数左移
reg [9:0]  q;
reg [3:0]  dcnt;
reg [9:0]  dw;              // 目标图像宽 (1 ~ 640)
reg [8:0]  dh;              // 目标图像高 (1 ~ 400)
reg [9:0]  ls;              // 存储行长度 min(W, dw)
reg [8:0]  hs;              // 存储行数 min(H, dh)
reg        hdec, vdec;      // 水平 / 垂直方向需要抽取
reg [8:0]  pad_l;           // 左黑边
reg [8:0]  pad_f;           // 先输出的黑边行数
reg [9:0]  x_end;           // pad_l + dw
reg [8:0]  y_end;           // pad_f + dh
reg [12:0] wm1;             // W - 1
reg [1:0]  padn;            // 每行补齐字节数
reg        run;

wire [31:0] habs   = r_h[31] ? (32'd0 - r_h) : r_h;
wire [22:0] mul_w  = {w13, 8'd0} + {1'b0, w13, 7'd0} + {4'd0, w13, 4'd0};   // W*400
wire [22:0] mul_h  = {h13, 9'd0} + {2'd0, h13, 7'd0};                         // H*640
reg  [22:0] a_w, a_h;

always @(posedge clk or posedge rst) begin
    if (rst) begin
        gs <= G_IDLE; bad <= 1'b0; run <= 1'b0; vflip <= 1'b1;
        r_w <= 32'd0; r_h <= 32'd0; r_ha <= 32'd0; r_bpp <= 16'd0; r_comp <= 32'd0;
        w13 <= 13'd0; h13 <= 13'd0; bpp32 <= 1'b0; wide <= 1'b0;
        rem <= 23'd0; dsh <= 22'd0; q <= 10'd0; dcnt <= 4'd0; a_w <= 23'd0; a_h <= 23'd0;
        dw <= 10'd0; dh <= 9'd0; ls <= 10'd0; hs <= 9'd0; hdec <= 1'b0; vdec <= 1'b0;
        pad_l <= 9'd0; pad_f <= 9'd0; x_end <= 10'd0; y_end <= 9'd0; wm1 <= 13'd0; padn <= 2'd0;
    end else if (start) begin
        gs <= G_IDLE; bad <= 1'b0; run <= 1'b0;
    end else begin
        case (gs)
        G_IDLE: if (cfg) begin
            r_w <= cfg_w; r_h <= cfg_h; r_bpp <= cfg_bpp; r_comp <= cfg_comp;
            gs  <= G_ABS;
        end
        G_ABS: begin
            r_ha <= habs;               // 取绝对值单独一拍, 不与下面的范围比较串在一起
            gs   <= G_CHK;
        end
        G_CHK: begin
            w13   <= r_w[12:0];
            h13   <= r_ha[12:0];
            bpp32 <= (r_bpp == 16'd32);
            vflip <= ~r_h[31];
            if (r_w < 32'd16 || r_w > 32'd4096 || r_ha < 32'd16 || r_ha > 32'd4096 ||
                !((r_bpp == 16'd24 && r_comp == 32'd0) ||
                  (r_bpp == 16'd32 && (r_comp == 32'd0 || r_comp == 32'd3)))) begin
                bad <= 1'b1;
                gs  <= G_BAD;
            end else
                gs  <= G_MUL;
        end
        G_MUL: begin
            a_w  <= mul_w;
            a_h  <= mul_h;
            wm1  <= w13 - 13'd1;
            padn <= bpp32 ? 2'd0 : w13[1:0];        // 24 bit: (4 - W*3 % 4) % 4 = W % 4
            dcnt <= 4'd0;
            gs   <= G_DIV;
        end
        G_DIV: begin
            // dcnt 0: 装载被除数 / 除数; 1~10: 每拍求一位商 (商 <= 640)
            dcnt <= dcnt + 4'd1;
            if (dcnt == 4'd0) begin
                wide <= (a_w >= a_h);
                rem  <= (a_w >= a_h) ? a_h : a_w;
                dsh  <= (a_w >= a_h) ? {w13, 9'd0} : {h13, 9'd0};
                q    <= 10'd0;
            end else begin
                if ({1'b0, dsh} <= rem) begin
                    rem <= rem - {1'b0, dsh};
                    q   <= {q[8:0], 1'b1};
                end else
                    q   <= {q[8:0], 1'b0};
                dsh <= {1'b0, dsh[21:1]};
                if (dcnt == 4'd10) gs <= G_SET;
            end
        end
        G_SET: begin
            if (wide) begin
                dw <= OW;
                dh <= (q[8:0] == 9'd0) ? 9'd1 : q[8:0];
            end else begin
                dw <= (q == 10'd0) ? 10'd1 : q;
                dh <= OH;
            end
            gs <= G_RUN;
        end
        G_RUN: begin
            // dw / dh 在 G_SET 写入, 这里再算一拍派生量, 之后保持不变
            if (!run) begin
                ls    <= ({3'd0, dw} < w13) ? dw : w13[9:0];
                hs    <= ({4'd0, dh} < h13) ? dh : h13[8:0];
                hdec  <= ({3'd0, dw} < w13);
                vdec  <= ({4'd0, dh} < h13);
                pad_l <= (OW - dw) >> 1;
                pad_f <= (OH - dh) >> 1;
                x_end <= ((OW - dw) >> 1) + dw;
                y_end <= ((OH - dh) >> 1) + dh;
                run   <= 1'b1;
            end
        end
        default: ;
        endcase
    end
end

//---------------------------------------------------------------------------
// 行缓存 2048 x 24 bit {R,G,B}
//---------------------------------------------------------------------------
(* ram_style = "bram" *) reg [23:0] ring [0:2047];
reg        rwe;
reg [10:0] rwa, rra;
reg [23:0] rwd, rq;
always @(posedge clk) begin
    if (rwe) ring[rwa] <= rwd;
    rq <= ring[rra];
end

//---------------------------------------------------------------------------
// 填充端
//---------------------------------------------------------------------------
reg [1:0]  bi;              // 像素内字节序号
reg [12:0] xs;              // 源像素列
reg        xl;              // xs == W-1 (提前一拍寄存)
reg        in_pad;
reg [1:0]  padc;
reg [7:0]  sb, sg;
reg signed [14:0] f;        // 水平抽取 DDA: k*W - (x+1)*dw, <0 时选中
reg signed [14:0] g;        // 垂直抽取 DDA: j*H - (y+1)*dh
reg        row_end;
reg [11:0] wp;              // 写指针 (比缓存多一位)
reg [9:0]  rows_w;          // 已存完的行数

wire       px_keep  = !hdec || f[14];
wire       row_keep = !vdec || g[14];
wire [1:0] bi_last  = bpp32 ? 2'd3 : 2'd2;

always @(posedge clk) xl <= (xs == wm1);

//---------------------------------------------------------------------------
// 输出端
//---------------------------------------------------------------------------
localparam [1:0] E_IDLE = 2'd0, E_ROW = 2'd1, E_WAIT = 2'd2, E_PIX = 2'd3;
reg [1:0]  es;
reg [1:0]  ph;
reg [8:0]  oy;
reg [9:0]  xo;
reg        rimg;            // 当前行为图像行
reg        pimg;            // 当前像素为图像像素
reg [9:0]  r;               // 当前使用的存储行
reg [11:0] rs;              // 当前存储行起始指针
reg [9:0]  s;               // 当前行内源像素
reg signed [11:0] d;        // 水平放大 DDA: k*Ls - (s+1)*dw, >=0 时前进
reg signed [10:0] dv;       // 垂直放大 DDA: j*Hs - (r+1)*dh
reg        afull_r;
reg [11:0] used;

wire       adv_h = !d[11];
wire       adv_v = !dv[10];
wire [9:0] s_use = s + {9'd0, adv_h};

always @(posedge clk or posedge rst) begin
    if (rst) begin
        need <= 1'b0; room <= 1'b1; done <= 1'b0; dst_cnt <= 19'd0;
        wr_en <= 1'b0; wr_data <= 32'd0;
        rwe <= 1'b0; rwa <= 11'd0; rwd <= 24'd0; rra <= 11'd0;
        bi <= 2'd0; xs <= 13'd0; in_pad <= 1'b0; padc <= 2'd0; sb <= 8'd0; sg <= 8'd0;
        f <= 15'sd0; g <= 15'sd0; row_end <= 1'b0; wp <= 12'd0; rows_w <= 10'd0;
        es <= E_IDLE; ph <= 2'd0; oy <= 9'd0; xo <= 10'd0; rimg <= 1'b0; pimg <= 1'b0;
        r <= 10'd0; rs <= 12'd0; s <= 10'd0; d <= 12'sd0; dv <= 11'sd0;
        afull_r <= 1'b0; used <= 12'd0;
    end else if (start) begin
        need <= 1'b1; room <= 1'b1; done <= 1'b0; dst_cnt <= 19'd0;
        wr_en <= 1'b0; rwe <= 1'b0;
        bi <= 2'd0; xs <= 13'd0; in_pad <= 1'b0; row_end <= 1'b0; wp <= 12'd0; rows_w <= 10'd0;
        es <= E_IDLE; ph <= 2'd0; oy <= 9'd0; xo <= 10'd0; r <= 10'd0; rs <= 12'd0;
    end else begin
        rwe     <= 1'b0;
        wr_en   <= 1'b0;
        afull_r <= afull;
        used    <= wp - rs;
        room    <= (used < 12'd1792);

        //------------------- 填充端 (字节间隔 >= 32 拍) -------------------
        if (es == E_IDLE && run) begin
            f <= -$signed({5'd0, dw});
            g <= -$signed({6'd0, dh});
        end
        if (px_vld && run && need && !row_end) begin
            if (in_pad) begin
                padc <= padc - 2'd1;
                if (padc == 2'd1) begin
                    in_pad  <= 1'b0;
                    row_end <= 1'b1;
                end
            end else begin
                bi <= (bi == bi_last) ? 2'd0 : bi + 2'd1;
                case (bi)
                    2'd0: sb <= px_byte;
                    2'd1: sg <= px_byte;
                    2'd2: if (px_keep && row_keep) begin
                        rwe <= 1'b1;
                        rwa <= wp[10:0];
                        rwd <= {px_byte, sg, sb};
                        wp  <= wp + 12'd1;
                    end
                    default: ;
                endcase
                if (bi == bi_last) begin
                    f  <= f + (px_keep ? $signed({2'd0, w13}) : 15'sd0) - $signed({5'd0, dw});
                    xs <= xs + 13'd1;
                    if (xl) begin
                        if (padn != 2'd0) begin
                            in_pad <= 1'b1;
                            padc   <= padn;
                        end else
                            row_end <= 1'b1;
                    end
                end
            end
        end
        if (row_end) begin
            row_end <= 1'b0;
            xs <= 13'd0;
            f  <= -$signed({5'd0, dw});
            g  <= g + (row_keep ? $signed({2'd0, h13}) : 15'sd0) - $signed({6'd0, dh});
            if (row_keep) begin
                rows_w <= rows_w + 10'd1;
                if (rows_w + 10'd1 == {1'b0, hs}) need <= 1'b0;
            end
        end

        //------------------- 输出端 -------------------
        case (es)
        E_IDLE: if (run) begin
            oy <= 9'd0;
            r  <= 10'd0;
            rs <= 12'd0;
            dv <= -$signed({2'd0, dh});
            es <= E_ROW;
        end
        E_ROW: begin
            xo <= 10'd0;
            s  <= 10'd0;
            d  <= -$signed({2'd0, dw});
            ph <= 2'd0;
            if (oy == OH) begin
                done <= 1'b1;
                es   <= E_WAIT;
            end else if (oy >= pad_f && oy < y_end) begin
                rimg <= 1'b1;
                if (adv_v) begin
                    r  <= r + 10'd1;
                    rs <= rs + {2'd0, ls};            // 释放上一存储行
                end
                dv <= dv + $signed({2'd0, hs}) - (adv_v ? $signed({2'd0, dh}) : 11'sd0);
                es <= E_WAIT;
            end else begin
                rimg <= 1'b0;
                es   <= E_PIX;
            end
        end
        E_WAIT: begin
            // 等待当前存储行写完整 (done 后停在这里)
            if (!done && rows_w > r) es <= E_PIX;
        end
        default: begin   // E_PIX
            ph <= ph + 2'd1;
            case (ph)
            2'd0: begin
                if (afull_r) ph <= 2'd0;
                pimg <= rimg && xo >= {1'b0, pad_l} && xo < x_end;
            end
            2'd1: begin
                if (pimg) begin
                    rra <= rs[10:0] + {1'b0, s_use};
                    s   <= s_use;
                    d   <= d + $signed({2'd0, ls}) - (adv_h ? $signed({2'd0, dw}) : 12'sd0);
                end
            end
            2'd2: ;     // 读行缓存
            default: begin
                wr_en   <= 1'b1;
                wr_data <= pimg ? {rq, 8'h00} : 32'd0;
                dst_cnt <= dst_cnt + 19'd1;
                xo      <= xo + 10'd1;
                if (xo == OW - 10'd1) begin
                    oy <= oy + 9'd1;
                    es <= E_ROW;
                end
            end
            endcase
        end
        endcase
    end
end

endmodule
