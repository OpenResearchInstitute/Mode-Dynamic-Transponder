################################################################################
# run_channel_normalizer_mux.tcl
#
# Vivado 2022.2 xsim runner for the per-channel normalizer.
#
# The block is one line of arithmetic:
#     gain = GAIN_TARGET / sqrt( max(power, SQUELCH_THR) )
#     out  = saturate( round( in * gain ) )
#
# so the bench needs NO golden vectors and NO python. The analytic oracle is
# real-arithmetic, computed inside the testbench, checked against the RTL's
# fixed point. Nothing to regenerate, nothing to drift.
#
# ORACLES
#   A1   latency is exactly 5; out_valid/out_chan/out_last travel with the data
#   A1b  8 back-to-back beats with distinct tags emerge in order
#   A2   BYPASS: gain_mode='0', gain_manual=0x0400 -> bit-exact identity
#   A3   saturation clamps to +/- full scale and raises gain_sat; never wraps
#   A4   the gain law holds over a 60 dB power sweep (worst error 0.017 dB)
#   A5   every input amplitude emerges at GAIN_TARGET  <- the point of the block
#   A6   below SQUELCH_THR the gain stops growing; a dead channel is not
#        amplified to full scale
#   A7   power=0 with squelch_thr=0 produces no X
#   A8   the block is STATELESS: same beat, 200 unrelated beats apart, same answer
#
# MUTATION-TESTED (all caught):
#   octave-only gain            -> A4  (2.77 dB error)
#   3-bit mantissa ROM          -> A4  (0.051 dB error)
#   no squelch floor            -> A6
#   gain averaged with previous -> A4  (stateful)
#   out_chan skewed one stage   -> A1b
#   out_last skewed one stage   -> A1b
#   wrapping multiply           -> A3
#
# USAGE, from sim/ in the Vivado TCL console:
#     source run_channel_normalizer_mux.tcl
#
# GHDL equivalent (headless, no licence):
#     ghdl -a --std=08 ../rtl/channelizer/channel_normalizer_mux.vhd \
#                      tb_channel_normalizer_mux.vhd
#     ghdl -e --std=08 tb_channel_normalizer_mux
#     ghdl -r --std=08 tb_channel_normalizer_mux
# The DUT is also confirmed clean under --std=93, which is what Vivado 2022.2
# assumes for a .vhd file unless the file_type is set to VHDL 2008.
################################################################################

catch {close_sim -force}
cd [file dirname [info script]]

# A missing DUT must be a HARD ERROR. If it is merely skipped, Vivado reports
# "'channel_normalizer_mux' is not compiled in library" two steps later, which
# points at the testbench instead of at the wrong path.
proc add_required {fileset file_list} {
    foreach f $file_list {
        if {![file exists $f]} {
            puts "ERROR: required source not found: $f"
            puts "       (cwd is [pwd] -- is the RTL path right for your tree?)"
            return -code error "missing source $f"
        }
        add_files -fileset $fileset -norecurse $f
        puts "  OK   $f"
    }
}

set project_name "channel_normalizer_mux_sim"
set project_dir  "./channel_normalizer_mux_sim_project"
set part_name    "xczu9eg-ffvb1156-2-e"
if {[file exists $project_dir]} { file delete -force $project_dir }
create_project $project_name $project_dir -part $part_name

puts "\nAdding RTL..."
add_required sources_1 { ../rtl/channelizer/channel_normalizer_mux.vhd }
puts "\nAdding testbench..."
add_required sim_1 { ./tb_channel_normalizer_mux.vhd }

foreach fs {sources_1 sim_1} {
    foreach f [get_files -of_objects [get_filesets $fs] -filter {FILE_TYPE == VHDL}] {
        set_property file_type {VHDL 2008} $f
    }
}

set_property top tb_channel_normalizer_mux [get_filesets sim_1]
set_property -name {xsim.simulate.runtime} -value {50 us} -objects [get_filesets sim_1]

puts "\nLaunching simulation..."
launch_simulation

puts "\n========================================"
puts "Look for: 'CHANNEL NORMALIZER TB PASSED'"
puts "Expect:   failures = 0"
puts "          latency=5  GAIN_TARGET=16000  SQUELCH_THR=65536"
puts "          A4 worst gain-law error ~0.017 dB"
puts "          A5 every input amplitude emerges at 16000"
puts "========================================"
