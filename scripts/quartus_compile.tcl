# SPDX-License-Identifier: GPL-3.0-or-later OR LicenseRef-Commercial
# Out-of-context Quartus Prime compile of keccak_top, as used for
# RESOURCE_ESTIMATES.md. Every port except clk_i becomes a virtual pin.
#
# Run from an empty directory:
#   quartus_sh -t <repo>/scripts/quartus_compile.tcl <repo>/rtl <top> [device] [period_ns]
# Reports: <top>.fit.summary (area) and <top>.sta.rpt ("Fmax Summary").
load_package flow
lassign $quartus(args) rtl top device period
if {$device eq ""} { set device 5CSEMA5F31C6 }
if {$period eq ""} { set period 5.0 }
project_new $top -overwrite
set_global_assignment -name FAMILY "Cyclone V"
set_global_assignment -name DEVICE $device
set_global_assignment -name TOP_LEVEL_ENTITY $top
foreach f [glob $rtl/*.sv] { set_global_assignment -name SYSTEMVERILOG_FILE $f }
set fh [open clk.sdc w]
puts $fh "create_clock -period $period -name clk \[get_ports clk_i\]"
close $fh
set_global_assignment -name SDC_FILE clk.sdc
foreach p {rst_ni mode_i[*] start_i data_i[*] valid_i last_i last_bytes_i[*] ready_o digest_o[*] digest_bits_o[*] digest_valid_o busy_o} {
  set_instance_assignment -name VIRTUAL_PIN ON -to $p
}
export_assignments
execute_module -tool map
execute_module -tool fit
execute_module -tool sta
project_close
