#-----------------------------------------------------------------------------
# run_r2sdf_sim.tcl -- Vivado project + behavioral sim for the R2SDF FFT unit TB
#-----------------------------------------------------------------------------
# Open Research Institute -- Haifuraiya / Mode-Dynamic-Transponder
#
# Builds a throwaway Vivado project, adds the VHDL-93 R2SDF RTL + testbench,
# hands the golden vectors to xsim, and runs the bit-exact check twice:
# once packed (GAPS=false) and once bursty (GAPS=true).
#
# Usage (from the repo root):
#   vivado -mode batch -source sim/run_r2sdf_sim.tcl
# Optional args:
#   vivado -mode batch -source sim/run_r2sdf_sim.tcl -tclargs <repo_root> <part> <vec_dir>
#
# Look for "RESULT: PASS  all 8 frames bit-exact" in the log for each run.
#
# Vectors: produced by  python3 docs/r2sdf_export_vectors.py  (run it from the
# directory you want the .txt in; vec_dir below must point there). xsim copies
# non-HDL sim-fileset files into its run dir, so the TB's bare file_open works
# -- same mechanism the channelizer coeff .hex already relies on.
#-----------------------------------------------------------------------------

set repo_root [pwd]
set part      xczu9eg-ffvb1156-2-e      ;# ZCU102; behavioral sim is part-agnostic

if {$argc >= 1} { set repo_root [lindex $argv 0] }
if {$argc >= 2} { set part      [lindex $argv 1] }

set rtl_dir [file join $repo_root rtl channelizer]
set sim_dir [file join $repo_root sim]
set vec_dir [file join $repo_root docs]            ;# where the .txt vectors live
if {$argc >= 3} { set vec_dir [lindex $argv 2] }

set in_vec  [file join $vec_dir fft_input.txt]
set exp_vec [file join $vec_dir fft_expected.txt]
foreach f [list $in_vec $exp_vec] {
    if {![file exists $f]} {
        puts "ERROR: vector file not found: $f"
        puts "       run:  python3 docs/r2sdf_export_vectors.py   (from $vec_dir)"
        return -code error "missing vectors"
    }
}

set proj_dir [file join $repo_root sim r2sdf_sim_proj]
file delete -force $proj_dir
create_project r2sdf_sim $proj_dir -part $part -force

# --- RTL (synthesizable) ---
add_files -norecurse [list \
    [file join $rtl_dir r2sdf_stage.vhd]   \
    [file join $rtl_dir r2sdf_reorder.vhd] \
    [file join $rtl_dir r2sdf_fft.vhd]     ]

# --- testbench + vectors (sim only) ---
add_files -fileset sim_1 -norecurse [file join $sim_dir tb_r2sdf_fft.vhd]
add_files -fileset sim_1 -norecurse [list $in_vec $exp_vec]

# Force plain VHDL-93 on every HDL source (Vivado "VHDL" == 93; "VHDL 2008" is
# a separate type). This is what keeps us off any 2008-only elaboration.
set_property file_type VHDL [get_files -filter {FILE_TYPE =~ VHDL*}]

set_property top tb_r2sdf_fft [get_filesets sim_1]
update_compile_order -fileset sources_1
update_compile_order -fileset sim_1

proc run_one {gaps} {
    set_property generic "GAPS=$gaps" [get_filesets sim_1]
    puts "============================================================"
    puts "  R2SDF sim run: GAPS=$gaps"
    puts "============================================================"
    launch_simulation
    run all
    close_sim
}

run_one false      ;# packed feed
run_one true       ;# bursty feed (idle cycles between samples)

puts "Done. Scroll up for the two RESULT lines."
