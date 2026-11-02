
# ============================================================
# merged_top_tf_hdmi_audio.sdc
# 用于：TF 图片轮播 + HDMI(视频+音频) 整合工程
#
# 合并原则：
# 1) 保留 top.sdc 里的系统主时钟与 derive_clocks
# 2) 把 timing(2).sdc 里的 pixel/serial 时钟改成整合工程实际名字
# 3) 增加 hdmi_5x_clk / audio_mclk 的命名
# 4) 不再对内部 net 直接 create_clock，避免和 derive_clocks 重复
# ============================================================

# ------------------------------------------------------------
# 1. 板级输入主时钟
#    你的原 top.sdc 里 clk=50MHz，所以这里仍然用 20ns
# ------------------------------------------------------------
create_clock -name clk -period 20 -waveform {0 10} [get_ports {clk}]

# ------------------------------------------------------------
# 2. 自动推导 PLL 输出时钟
# ------------------------------------------------------------
derive_clocks

# ------------------------------------------------------------
# 3. 给关键 PLL 输出命名
#    下面这些路径是按你当前工程实例名写的：
#      sys_pll      -> sys_pll_m0
#      video_pll    -> video_pll_m0
#      音频 PLL     -> u_audio_pll
#
#    如果综合后实例路径略有不同，就按 Timing Analyzer 里的实际 pin 路径改。
# ------------------------------------------------------------
rename_clock -name {sd_card_clk} -source [get_ports {clk}] -master_clock {clk} [get_pins {sys_pll_m0/pll_inst.clkc[0]}]
rename_clock -name {ext_mem_clk} -source [get_ports {clk}] -master_clock {clk} [get_pins {sys_pll_m0/pll_inst.clkc[1]}]
# 1280x800 输出: pix_clk 75M (HDMI 像素) / hdmi_5x_clk 375M (串行) / video_clk 18.75M (640x400 合成)
rename_clock -name {pix_clk}     -source [get_ports {clk}] -master_clock {clk} [get_pins {video_pll_m0/pll_inst.clkc[0]}]
rename_clock -name {hdmi_5x_clk} -source [get_ports {clk}] -master_clock {clk} [get_pins {video_pll_m0/pll_inst.clkc[1]}]
rename_clock -name {video_clk}   -source [get_ports {clk}] -master_clock {clk} [get_pins {video_pll_m0/pll_inst.clkc[2]}]
rename_clock -name {audio_mclk}  -source [get_ports {clk}] -master_clock {clk} [get_pins {u_audio_pll/pll_inst.clkc[2]}]
# 第二屏运维终端 (HDMI1 1024x600): term_clk 50M 像素 / term_5x_clk 250M 串行
rename_clock -name {term_clk}    -source [get_ports {clk}] -master_clock {clk} [get_pins {u_term_pll/pll_inst.clkc[0]}]
rename_clock -name {term_5x_clk} -source [get_ports {clk}] -master_clock {clk} [get_pins {u_term_pll/pll_inst.clkc[2]}]

# ------------------------------------------------------------
# 4. 从原 timing(2).sdc 迁移过来的 HDMI 像素/串行时钟约束
#
#    原文件是：
#      create_clock -name pixel_clk  ... [get_nets {S_pixel_clk}]
#      create_clock -name serial_clk ... [get_nets {S_serial_clk}]
#      set_clock_groups -exclusive ...
#
#    在整合工程里，这两个时钟已经由 video_pll 产生，并通过 derive_clocks 建出来了，
#    所以这里只保留“组关系”，不再重复 create_clock。
#
#    这里沿用原作者的写法，把 video_clk 和 hdmi_5x_clk 设成 exclusive。
#    如果后面 Timing Analyzer 明确显示两者之间需要做同步时序分析，再把这一条去掉。
# ------------------------------------------------------------
#    video_clk (合成, 1/4 像素时钟) 与 pix_clk 同源同相, 放在同一组按同步路径分析
#    (video_scale2x 中 video_clk -> pix_clk 的寄存器路径需要检查).
set_clock_groups -exclusive \
    -group [get_clocks {video_clk pix_clk}] \
    -group [get_clocks {hdmi_5x_clk}]
#    终端屏同样: 像素时钟与 5 倍串行时钟之间的装载由 lane_lvds_10_1 按相位保证
set_clock_groups -exclusive \
    -group [get_clocks {term_clk}] \
    -group [get_clocks {term_5x_clk}]

# ------------------------------------------------------------
# 5. 音频 I2S 发生器/接收器跨域
#
#    audio_mclk 域里生成 I2S，video_clk 域里做三拍同步采样。
#    这类路径不是普通同步时序路径，直接切掉更合理。
# ------------------------------------------------------------
set_clock_groups -asynchronous \
    -group [get_clocks {audio_mclk}] \
    -group [get_clocks {clk video_clk pix_clk hdmi_5x_clk sd_card_clk ext_mem_clk term_clk term_5x_clk}]

# ------------------------------------------------------------
# 6. 播放器工程: 所有跨时钟域信号都经过异步 FIFO (格雷码指针) /
#    toggle 握手 / 两级同步器 / 准静态寄存器, 因此各时钟之间按异步处理.
#      clk         : 仅数码管扫描 (数据来自 video_clk 域, 准静态)
#      sd_card_clk : TF 卡加载器, 帧写 FIFO 写端, WAV FIFO 写端
#      ext_mem_clk : SDRAM 控制, 帧 FIFO 另一端
#      video_clk   : 视频时序/合成/播放控制 (640x400)
#      pix_clk     : 2x 放大输出 / HDMI 发送核 / I2S 接收 / ACR (与 video_clk、hdmi_5x_clk 同源)
# ------------------------------------------------------------
set_clock_groups -asynchronous -group [get_clocks {clk}] -group [get_clocks {sd_card_clk}] -group [get_clocks {ext_mem_clk}] -group [get_clocks {video_clk pix_clk hdmi_5x_clk}] -group [get_clocks {term_clk term_5x_clk}]

# ------------------------------------------------------------
# 7. 复位按键 (第六讲: 异步复位同步释放)
#    rst_n 只进 reset_sync 的异步置位端与 PLL reset, 释放沿已由同步器对齐,
#    端口到寄存器的路径不做时序分析
# ------------------------------------------------------------
set_false_path -from [get_ports {rst_n}]

# ------------------------------------------------------------
# 8. 其余 Input/Output delay 先保持空白
#    你当前两个原始 sdc 也都没有写这部分。
# ------------------------------------------------------------
