# 命令行烧写 SPI Flash, 固化后上电自启 (在 src/td_project 目录下运行):
#   td_commands_prompt.exe flash_program.tcl                     烧写 cli_out/player.bit (最近一次编译结果) 并校验
#   TD_BIT=release/player.bit td_commands_prompt.exe flash_program.tcl   烧写指定位流
#   TD_DL_MODE=verify_spi td_commands_prompt.exe flash_program.tcl       只校验 Flash 内容
#   TD_DL_MODE=erase_spi  td_commands_prompt.exe flash_program.tcl       擦除 Flash (恢复为不自启)
#   TD_DL_MODE=jtag       td_commands_prompt.exe flash_program.tcl       只下载到 SRAM, 掉电丢失
# 可选: TD_SPD=n 下载速率档位 (默认 7, 连接不稳时调小), TD_CABLE=n 下载器编号 (默认 0)
# 烧写完成后需断电再上电 (或按板上 PROGRAM/重配置键), FPGA 才会从 Flash 加载新位流
import_device eagle_s20.db -package EG4S20BG256

proc env_or {name def} { if {[info exists ::env($name)]} { return $::env($name) } else { return $def } }
set bit   [env_or TD_BIT     cli_out/player.bit]
set mode  [env_or TD_DL_MODE program_spi]
set spd   [env_or TD_SPD     7]
set cable [env_or TD_CABLE   0]

if {![file exists $bit]} {
  puts "FLASH_FAIL: bit file not found: $bit"
  exit
}
puts "bit=$bit mode=$mode spd=$spd cable=$cable"
if {[catch {
  if {$mode eq "program_spi"} {
    # -v: 写完回读校验
    download -bit $bit -mode program_spi -v -spd $spd -sec 64 -cable $cable
  } else {
    download -bit $bit -mode $mode -spd $spd -sec 64 -cable $cable
  }
  puts "FLASH_OK"
} e]} { puts "FLASH_FAIL: $e" }
exit
