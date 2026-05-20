# zcu102_jtag_boot.tcl  (v4 — adds PL bitstream load after PMU wake)
#
# Boot Yocto-built bootloader stack on ZCU102 via JTAG.
#
# Key fixes from v2:
#   - Use exact-name filter {name == "MicroBlaze PMU"} (avoids matching the
#     "PMU" TAP at parent level)
#   - rst -processor on MicroBlaze PMU to wake it from "Sleeping. No clock"
#   - Load ATF BEFORE running FSBL (so FSBL's chain-to-ATF finds it)
#   - U-Boot loaded after FSBL/ATF run (DDR is now initialized)
#   - v4: load PL bitstream (system_top.bit) after PMU is running,
#     before A53 work — provides ADRV9002 AXI peripherals for kernel

if {[info exists ::env(BOOT_DIR)]} {
    set boot_dir $::env(BOOT_DIR)
} else {
    set boot_dir "/tmp/abraxas3d-yocto-boot"
}

set pmu_fw    "$boot_dir/pmu-firmware-zcu102-zynqmp.elf"
set fsbl      "$boot_dir/fsbl-zcu102-zynqmp.elf"
set atf_bin   "$boot_dir/arm-trusted-firmware.bin"
set uboot_elf "$boot_dir/u-boot.elf"
set boot_scr  "$boot_dir/boot.scr"
set system_bit "$boot_dir/system_top.bit"

foreach f [list $pmu_fw $fsbl $atf_bin $uboot_elf $boot_scr $system_bit] {
    if {![file exists $f]} {
        puts "ERROR: file not found: $f"
        exit 1
    }
}

# --- Connect ---
puts "=== Connecting to hw_server ==="
if {[catch {connect -url tcp:127.0.0.1:3121} err]} {
    puts "ERROR: connect failed: $err"
    exit 1
}
puts "    Connected."

# --- System reset ---
puts ""
puts "=== System reset via JTAG ==="
if {[catch {targets -set -filter {name =~ "PSU"}} err]} {
    puts "ERROR: could not select PSU target: $err"
    exit 1
}
stop
rst -system
after 2000
# MULTIBOOT register (harmless redundancy)
catch {mwr 0xffca0038 0x1ff}
after 500
puts "    Reset complete."

# --- Wake and load PMU MicroBlaze ---
puts ""
puts "=== Waking and loading MicroBlaze PMU ==="
if {[catch {targets -set -filter {name == "MicroBlaze PMU"}} err]} {
    puts "ERROR: could not select MicroBlaze PMU target: $err"
    exit 1
}
puts "    MicroBlaze PMU selected. Resetting processor to wake it..."
rst -processor
after 500

puts "    Downloading PMU firmware..."
if {[catch {dow $pmu_fw} err]} {
    puts "ERROR: PMU firmware download failed: $err"
    exit 1
}
puts "    Running PMU..."
con
after 1000



# --- Switch to A53 #0 ---
puts ""
puts "=== Selecting Cortex-A53 #0 ==="
if {[catch {targets -set -filter {name == "Cortex-A53 #0"}} err]} {
    puts "ERROR: could not select Cortex-A53 #0: $err"
    exit 1
}
rst -processor
puts "    A53 #0 in reset catch."

# --- Load ATF FIRST (before FSBL runs, since FSBL chains to ATF) ---
puts ""
puts "=== Loading ATF binary at 0xfffea000 (OCM) ==="
if {[catch {dow -data $atf_bin 0xfffea000} err]} {
    puts "ERROR: ATF load failed: $err"
    exit 1
}
puts "    ATF loaded."

# --- Load FSBL ELF (sets PC to FSBL entry) ---
puts ""
puts "=== Loading FSBL ELF ==="
if {[catch {dow $fsbl} err]} {
    puts "ERROR: FSBL load failed: $err"
    exit 1
}
puts "    FSBL loaded."

# --- Run FSBL — it inits DDR, chains to ATF, ATF tries to jump to U-Boot ---
# After this, A53 is somewhere; might be hung trying to execute uninit DDR,
# might be in ATF's wait loop, might be in early Linux if residual memory.
# Either way, DDR will now be initialized.
puts ""
puts "=== Running FSBL (will chain to ATF, then attempt U-Boot) ==="
con
puts "    Waiting 8 seconds for FSBL + ATF to complete..."
after 8000

# --- Stop A53 — DDR is now up ---
puts ""
puts "=== Stopping A53 to load U-Boot into DDR ==="
stop
puts "    A53 stopped."



# --- Load PL bitstream (M2.5 ADI HDL adrv9001_zcu102 reference design) ---
# Must load AFTER PMU is running (PMU FW owns the PCAP interface on
# ZynqMP, which is the bitstream-load path) and BEFORE kernel boot
# (ADRV9002 driver probes against AXI peripherals — axi_adrv9001 at
# 0x84A30000 etc — that only exist once the bitstream is on the PL).
#
# Trophy case: at this point in JTAG boot, PMU FW is alive, A53 is
# still in reset, so the PL load is the safest and quietest window.
puts ""
puts "=== Loading PL bitstream ($system_bit) ==="

# IMPORTANT: ZCU102 has TWO FPGA devices on JTAG — the system controller
# (Zynq-7020, first in chain) and the ZynqMP (xczu9eg, second). When `fpga`
# finds multiple devices, it lists their target IDs in the error message and
# expects us to pick one via `targets -set` first.
#
# For our current ZCU102 + Digilent cable setup:
#   target 17  = system controller (Zynq-7020) — NOT what we want
#   target 1   = ZynqMP PL (xczu9eg)           — YES, this one
#
# Other setups may differ. If load fails with "Multiple FPGA devices found:
# X, Y", try `targets -set X` then re-run. Update this script with the
# correct ID once verified.
if {[catch {targets -set 1} err]} {
    puts "ERROR: could not select target 17 (ZynqMP PL): $err"
    exit 1
}

if {[catch {fpga -no-revision-check -file $system_bit} err]} {
    puts "ERROR: bitstream load failed: $err"
    puts "       If target 17 was wrong, try target 1 (swap above)."
    exit 1
}
puts "    Bitstream loaded."
after 500



puts "    Bitstream loaded."
after 500

# Switch back to A53 #0 — fpga -file switched our context to the PL target,
# and the subsequent dow $uboot_elf needs to target the A53's memory space.
if {[catch {targets -set -filter {name == "Cortex-A53 #0"}} err]} {
    puts "ERROR: could not re-select Cortex-A53 #0 after bitstream load: $err"
    exit 1
}
puts "    Re-selected Cortex-A53 #0."





# --- Load U-Boot (DDR is initialized now, so 0x8000000 is accessible) ---
puts ""
puts "=== Loading U-Boot ELF ==="
if {[catch {dow $uboot_elf} err]} {
    puts "ERROR: U-Boot load failed: $err"
    puts "       If 'MMU fault at VA 0x8000000' — A53 already past this point"
    puts "       and MMU is enabled. Reset and try again."
    exit 1
}
puts "    U-Boot loaded."

# --- Load boot.scr to 0x20000000 (U-Boot autoboot finds it FIRST) ---
# U-Boot's autoboot sequence checks 0x20000000 for a script BEFORE trying
# MMC, QSPI, network, etc. Our script there sets static IPs and TFTPs
# the kernel automatically — no DHCP needed, no manual typing.
puts ""
puts "=== Loading boot.scr at 0x20000000 (U-Boot autoboot will run it) ==="
if {[catch {dow -data $boot_scr 0x20000000} err]} {
    puts "ERROR: boot.scr load failed: $err"
    exit 1
}
puts "    boot.scr loaded."

# --- Set PC to ATF entry (so ATF runs first, transitions EL3 → EL2) ---
# dow $uboot_elf set PC to U-Boot's entry; we override that so ATF runs
# first. ATF then sets up EL2 and jumps to U-Boot. Without this, U-Boot
# runs at EL3 and Linux's PSCI SMCs panic the kernel.
puts ""
puts "=== Setting PC to ATF entry (0xfffea000) ==="
catch {stop}
rwr pc 0xfffea000
puts "    PC set. [rrd pc]"

# --- Continue execution: ATF → U-Boot → boot.scr → Linux ---
puts ""
puts "=== Starting execution ==="
con

puts ""
puts "================================================================"
puts "JTAG boot sequence complete."
puts ""
puts "WATCH THE SERIAL CONSOLE — U-Boot autoboot should now:"
puts "  1. Find boot.scr at 0x20000000"
puts "  2. Run setenv commands (static IPs)"
puts "  3. TFTP kernel, dtb, initramfs"
puts "  4. Boot Linux"
puts ""
puts "Login: root (no password, debug-tweaks enabled)"
puts "================================================================"
