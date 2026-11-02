import_device eagle_s20.db -package EG4S20BG256
if {[catch {
  open_project cli_build.al
  elaborate -top top
} e]} { puts "BUILD_FAIL: $e" }
exit
