///////////////////////////////////////////////////////////////////////////////
//  终端屏 (HDMI1, 1024x600@60Hz) 时钟, 第 4 个 PLL
//	Input frequency:               50.000000MHz
//	Clock information:
//		Clock name	| Frequency 	| Phase shift
//		C0        	| 50.000000 MHZ	| 0.0000  DEG     像素时钟 (1344 x 620 x 60.0 Hz)
//		C2        	| 250.000000MHZ	| 0.0000  DEG     5 倍串行时钟 (lane_lvds_10_1 DDR 输出 10:1)
//	分频与环路参数取自 TD IP 生成的官方例程 lab_ex_4 al_ip/pll_50.v (VCO = 1000MHz),
//	结构同 IP/video_pll.v (C0 经 BUFG 外部反馈)
///////////////////////////////////////////////////////////////////////////////
`timescale 1 ns / 100 fs
module term_pll (
  refclk,
  reset,
  extlock,
  clk0_out,
  clk2_out
);
  input refclk;
  input reset;
  output extlock;
  output clk0_out;
  output clk2_out;

  wire clk0_buf;

  EG_LOGIC_BUFG bufg_feedback (
    .i(clk0_buf),
    .o(clk0_out)
  );

  EG_PHY_PLL #(
    .DPHASE_SOURCE("DISABLE"),
    .DYNCFG("DISABLE"),
    .FIN("50.000000"),
    .FEEDBK_MODE("NORMAL"),
    .FEEDBK_PATH("CLKC0_EXT"),
    .STDBY_ENABLE("DISABLE"),
    .PLLRST_ENA("ENABLE"),
    .SYNC_ENABLE("DISABLE"),
    .GMC_GAIN(4),
    .ICP_CURRENT(13),
    .KVCO(4),
    .LPF_CAPACITOR(1),
    .LPF_RESISTOR(4),
    .REFCLK_DIV(1),
    .FBCLK_DIV(1),
    .CLKC0_ENABLE("ENABLE"),
    .CLKC0_DIV(20),
    .CLKC0_CPHASE(19),
    .CLKC0_FPHASE(0),
    .CLKC2_ENABLE("ENABLE"),
    .CLKC2_DIV(4),
    .CLKC2_CPHASE(3),
    .CLKC2_FPHASE(0)
  ) pll_inst (
    .refclk(refclk),
    .reset(reset),
    .stdby(1'b0),
    .extlock(extlock),
    .load_reg(1'b0),
    .psclk(1'b0),
    .psdown(1'b0),
    .psstep(1'b0),
    .psclksel(3'b000),
    .psdone(open),
    .dclk(1'b0),
    .dcs(1'b0),
    .dwe(1'b0),
    .di(8'b00000000),
    .daddr(6'b000000),
    .do({open, open, open, open, open, open, open, open}),
    .fbclk(clk0_out),
    .clkc({open, open, clk2_out, open, clk0_buf})
  );

endmodule
