# 命令行完整编译 (在 src/td_project 目录下运行):
#   td_commands_prompt.exe cli_build.tcl
#   TD_SEED=n td_commands_prompt.exe cli_build.tcl    (指定布局种子)
# 输出在 cli_out/ 下, 位流 cli_out/player.bit
import_device eagle_s20.db -package EG4S20BG256
if {[catch {
  # 命令行编译使用独立的工程文件 cli_build.al (文件列表与 ../build/files.tcl 一致);
  # TD 图形界面开着时会把它内存中的旧文件列表存回 HDMI1.4b_Transmitter_v1.0.al, 不影响这里
  open_project cli_build.al
  elaborate -top top
  read_adc ../user_source/constraints_source/pin.adc
  read_sdc ../user_source/constraints_source/timing.sdc
  read_sdc -ip rfifo_32_32_512 ../user_source/hdl_source/ip/afifo_32_16_256.tcl
  read_sdc -ip wfifo_32_32_512 ../user_source/hdl_source/ip/afifo_16_32_256.tcl
  export_db cli_out/player_elaborate.db
  optimize_rtl
  report_area -file cli_out/player_rtl.area
  optimize_gate -packarea cli_out/player_gate.area
  legalize_phy_inst
  update_timing
  report_timing_summary -file cli_out/player_gate.timing
  export_db cli_out/player_gate.db
  # 可选布局种子: TD_SEED=n td_commands_prompt.exe cli_build.tcl
  # (某些布局下 TD 6.2.1 的 route 保持时间修复阶段会崩溃, 换种子即可)
  if {[info exists ::env(TD_SEED)]} { set_param place seed $::env(TD_SEED) }
  place
  update_timing -mode manhattan
  report_timing_summary -file cli_out/player_place.timing
  export_db cli_out/player_place.db
  route
  update_timing -mode final
  report_timing_status -file cli_out/player_phy.ts
  report_timing_summary -file cli_out/player_pr.timing
  export_db cli_out/player_pr.db
  # .bit 供 JTAG 下载 / SPI Flash 烧写, .bin 为纯 Flash 镜像 (第三方烧录器用)
  # 默认 boot_mode 为 mspix1, 与板载 SPI Flash 连接方式一致
  bitgen -bit cli_out/player.bit -bin cli_out/player.bin -g mclk_freq_div:29MHz
  report_area -io_info -file cli_out/player_phy.area
  puts "BUILD_OK"
} e]} { puts "BUILD_FAIL: $e" }
exit
