# SPDX-License-Identifier: GPL-3.0-or-later OR LicenseRef-Commercial
# Out-of-context Vivado compile of keccak_top (synthesis, placement, routing),
# as used for RESOURCE_ESTIMATES.md.
#
# Run from an empty directory:
#   vivado -mode batch -source <repo>/scripts/vivado_compile.tcl \
#          -tclargs <repo>/rtl <top> [part] [period_ns]
# Reports: <top>_impl_util.rpt and <top>_timing.rpt; the last line printed
# is "RESULT ... wns=<ns> fmax_mhz=<MHz>", with Fmax = 1000 / (period - WNS).
lassign $argv rtl top part period
if {$part eq ""} { set part xc7a35tcsg324-1 }
if {$period eq ""} { set period 5.0 }
read_verilog -sv [glob $rtl/*.sv]
set fh [open clk.xdc w]
puts $fh "create_clock -period $period -name clk \[get_ports clk_i\]"
close $fh
read_xdc -mode out_of_context clk.xdc
synth_design -top $top -part $part -mode out_of_context
opt_design
place_design
route_design
report_utilization -file ${top}_impl_util.rpt
report_timing_summary -max_paths 3 -file ${top}_timing.rpt
set wns [get_property SLACK [get_timing_paths -max_paths 1 -setup]]
puts "RESULT top=$top part=$part period=$period wns=$wns fmax_mhz=[format %.2f [expr {1000.0 / ($period - $wns)}]]"
