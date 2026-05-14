################################################################################
# synth_haifuraiya_channelizer.tcl
# Vivado 2022.2 out-of-context synthesis for the Haifuraiya channelizer
#
# Target: ZCU102 (xczu9eg-ffvb1156-2-e)
# DUT:    haifuraiya_channelizer_top, N=64 channels, M=16 decimation,
#         100 MHz clock, 10 Msps complex input
#
# Lives at: haifuraiya/syn/zcu102/
#
# Mode: out-of-context (OOC). No I/O buffers are inserted; no pin LOCs are
# required. The output is a synthesized checkpoint plus utilization and
# timing reports. The checkpoint can later be used as a black-box module
# in the parent ZCU102 design (Zynq UltraScale+ PS + AXI-Stream wrapper).
#
# USAGE
#   From the Vivado TCL console:
#     source /path/to/haifuraiya/syn/zcu102/synth_haifuraiya_channelizer.tcl
#
# Outputs (in synth_project/<run>/):
#   utilization.rpt          - resource counts by primitive (DSP, BRAM, etc.)
#   utilization_hier.rpt     - hierarchical breakdown (which module ate the DSPs?)
#   timing_summary.rpt       - WNS, WHS, TNS, etc. at 100 MHz
#   timing_worst_paths.rpt   - the 20 worst critical paths
#   drc.rpt                  - design-rule check warnings
################################################################################

# Close any existing project so this script is idempotent
catch {close_project}

# Resolve all paths relative to this script's directory
cd [file dirname [info script]]

set project_name "haifuraiya_channelizer_synth"
set project_dir  "./synth_project"
set part_name    "xczu9eg-ffvb1156-2-e"

# Clean previous project so we get a deterministic build
if {[file exists $project_dir]} {
    file delete -force $project_dir
}

puts "============================================"
puts "Haifuraiya Channelizer SYNTHESIS"
puts "Project:    $project_name"
puts "Part:       $part_name (ZCU102)"
puts "Working dir: [pwd]"
puts "Mode:       Out-Of-Context (OOC)"
puts "============================================"

create_project $project_name $project_dir -part $part_name
set_property target_language     VHDL [current_project]
set_property simulator_language  VHDL [current_project]
set_property default_lib         xil_defaultlib [current_project]

################################################################################
# Add VHDL sources (compile order: leaves first, top last)
#
# Paths are two levels up because this script lives at
# haifuraiya/syn/zcu102/, and the RTL lives at haifuraiya/rtl/channelizer/.
#
# The haifuraiya subtree is self-contained -- it does NOT depend on the
# mdt_sic/rtl/pkg/channelizer_pkg.vhd that the older serial-MAC design
# uses. Per haifuraiya/rtl/README.md: "no dependency on channelizer_pkg".
################################################################################
proc safe_add_files {fileset file_list {library "xil_defaultlib"}} {
    foreach file $file_list {
        if {[file exists $file]} {
            add_files -fileset $fileset -norecurse $file
            set_property file_type {VHDL 2008} [get_files [file tail $file]]
            set_property library $library      [get_files [file tail $file]]
            puts "  Added: $file"
        } else {
            puts "  WARNING: file not found: $file"
        }
    }
}

puts "\n--- Adding RTL sources ---"
safe_add_files sources_1 {
    ../../rtl/channelizer/fir_branch_parallel.vhd
    ../../rtl/channelizer/polyphase_filterbank_parallel.vhd
    ../../rtl/channelizer/fft_pkg.vhd
    ../../rtl/channelizer/fft_n_pt.vhd
    ../../rtl/channelizer/haifuraiya_channelizer_top.vhd
}

puts "\n--- Adding constraints ---"
safe_add_files constrs_1 {
    ./haifuraiya_channelizer_synth.xdc
}

set_property top haifuraiya_channelizer_top [current_fileset]
update_compile_order -fileset sources_1

################################################################################
# Copy coefficient file into the synth run directory
#
# fir_branch_parallel.vhd opens the coefficient hex file at ELABORATION via
# TEXTIO using a relative path. During synthesis, Vivado's cwd is the run
# directory, so the .hex must live there. (Same pattern as the sim TCL.)
################################################################################
set runs_dir "$project_dir/$project_name.runs/synth_1"
file mkdir $runs_dir

puts "\n--- Copying coefficient file to synth runs dir ---"
set coeff_src "../../rtl/coeffs/haifuraiya_coeffs.hex"
if {[file exists $coeff_src]} {
    file copy -force $coeff_src $runs_dir/haifuraiya_coeffs.hex
    puts "  Copied: $coeff_src -> $runs_dir/"
} else {
    puts "  ERROR: coefficient file not found at $coeff_src"
    puts "  Adjust the path in this script if your repo layout differs."
    return
}

################################################################################
# Configure synthesis for OOC mode and run it
#
# -mode out_of_context tells Vivado not to insert I/O buffers, so we don't
# need pin LOCs. The result is a usable checkpoint for IP-style reuse.
################################################################################
set_property -name {STEPS.SYNTH_DESIGN.ARGS.MORE OPTIONS} \
             -value {-mode out_of_context} \
             -objects [get_runs synth_1]

# Optional: pick a synthesis strategy. The default "Vivado Synthesis Defaults"
# is fine for a first pass. If we're tight on DSPs, try:
#   set_property strategy {Flow_AreaOptimized_high} [get_runs synth_1]
# If we miss timing at 100 MHz, try:
#   set_property strategy {Flow_PerfOptimized_high} [get_runs synth_1]

puts "\n--- Launching synthesis ---"
launch_runs synth_1 -jobs 4
wait_on_run synth_1

set synth_state [get_property STATUS [get_runs synth_1]]
puts "\nSynthesis run state: $synth_state"

if {[get_property PROGRESS [get_runs synth_1]] != "100%"} {
    puts "============================================"
    puts "SYNTHESIS DID NOT COMPLETE"
    puts "Inspect the synth_1 log in $runs_dir for errors."
    puts "============================================"
    return
}

################################################################################
# Open the synthesized checkpoint and generate reports
################################################################################
open_run synth_1

set report_dir $runs_dir
puts "\n--- Writing reports to $report_dir ---"

report_utilization                     -file $report_dir/utilization.rpt
report_utilization -hierarchical       -file $report_dir/utilization_hier.rpt
report_timing_summary -delay_type min_max -report_unconstrained -check_timing_verbose \
                                       -file $report_dir/timing_summary.rpt
report_timing -max_paths 20 -nworst 20 -delay_type max -sort_by group \
                                       -file $report_dir/timing_worst_paths.rpt
report_clock_interaction               -file $report_dir/clock_interaction.rpt
report_drc                             -file $report_dir/drc.rpt

# Also dump key numbers to the console so we see them at a glance
puts "============================================"
puts "SYNTHESIS COMPLETE"
puts "============================================"
puts "Reports in: $report_dir"
puts ""
puts "Key numbers:"

# Utilization summary lifted straight from the design
set dsp_used  [llength [get_cells -hierarchical -filter {PRIMITIVE_TYPE =~ "ARITHMETIC.dsp.dsp48*" || PRIMITIVE_TYPE =~ "ARITHMETIC.dsp.DSP48*"}]]
set bram_used [llength [get_cells -hierarchical -filter {PRIMITIVE_TYPE =~ "BLOCKRAM.bram.RAMB36*" || PRIMITIVE_TYPE =~ "BLOCKRAM.bram.RAMB18*"}]]
set ff_used   [llength [get_cells -hierarchical -filter {PRIMITIVE_TYPE =~ "REGISTER.sdr.FDRE" || PRIMITIVE_TYPE =~ "REGISTER.sdr.FDSE" || PRIMITIVE_TYPE =~ "REGISTER.sdr.FDCE" || PRIMITIVE_TYPE =~ "REGISTER.sdr.FDPE"}]]
set lut_used  [llength [get_cells -hierarchical -filter {PRIMITIVE_TYPE =~ "CLB.LUT.*"}]]

puts "  DSPs used:   $dsp_used   (ZCU102 budget: 2520)"
puts "  BRAMs used:  $bram_used"
puts "  LUTs used:   $lut_used"
puts "  FFs used:    $ff_used"

# Timing slack at the primary clock
set wns [get_property STATS.WNS [get_runs synth_1]]
set tns [get_property STATS.TNS [get_runs synth_1]]
puts ""
puts "  WNS (post-synth): $wns ns"
puts "  TNS (post-synth): $tns ns"
puts ""
puts "Inspect utilization_hier.rpt to see which submodules"
puts "account for the resource usage."
puts "============================================"
