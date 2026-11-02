import_device eagle_s20.db -package EG4S20BG256
source files.tcl
if {[catch {
  foreach f $SRC { read_verilog -file $f -include_dir $H/player -include_dir $H/SD -include_dir $H/include }
  elaborate -top top
} e]} { puts "BUILD_FAIL: $e" }
exit
