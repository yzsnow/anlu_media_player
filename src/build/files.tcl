# 播放器工程源文件列表 (相对 src/build)
# 注意: read_verilog 每读一个文件就会立即 elaborate, 所以必须自底向上排列
set H ../user_source/hdl_source
set SRC [list \
  $H/ip/sys_pll.v \
  $H/ip/video_pll.v \
  ../td_project/al_ip/PLL_HDMI_AUDIO.v \
  $H/ip/afifo_16_32_256.v \
  $H/ip/afifo_32_16_256.v \
  $H/include/sdr_init_ref.enc.v \
  $H/include/sdr_wrrd.enc.v \
  $H/include/sdr_as_ram.enc.v \
  $H/SD/sdram.v \
  $H/SD/spi_master.v \
  $H/SD/sd_card_sec_read_write.v \
  $H/SD/sd_card_cmd.v \
  $H/SD/sd_card_top.v \
  $H/SD/frame_fifo_write.v \
  $H/SD/color_bar.v \
  $H/SD/video_timing_data.v \
  $H/SD/seg_scan.v \
  $H/player/reset_sync.v \
  $H/player/async_fifo.v \
  $H/player/frame_dual_read_write.v \
  $H/player/osd_font_rom.v \
  $H/player/osd_str_rom.v \
  $H/player/audio_spectrum_osd.v   $H/player/alarm_rom.v   $H/player/alarm_screen.v \
  $H/player/gamma_rom.v \
  $H/player/color_lut_gen.v \
  $H/player/video_compositor.v \
  $H/player/video_scale2x.v \
  $H/player/sd_media_loader.v \
  $H/player/bmp_fit_scaler.v \
  $H/player/tmds_encoder.v \
  $H/player/term_pll.v \
  $H/player/term_prog_rom.v \
  $H/player/term_font_rom.v \
  $H/player/term_vram_c.v \
  $H/player/term_vram_a.v \
  $H/player/term_top.v \
  $H/player/kb_matrix4x4.v \
  $H/player/player_ctrl.v \
  $H/player/audio_i2s_player.v \
  $H/I2S_receiver.v \
  $H/audio_arc_calculate.v \
  $H/startup_pulse.v \
  $H/video_rgb_to_axis_640x480.v \
  $H/lane_lvds_10_1.v \
  $H/hdmi_phy_warpper.v \
  $H/hdmi1.4b_transmitter_core/hdmi_1_4b_transmitter_core_wrapper.enc.v \
  $H/top_tf_hdmi_audio.v ]
