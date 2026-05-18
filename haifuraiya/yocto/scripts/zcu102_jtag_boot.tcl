# zcu102_jtag_boot.tcl
#
# Boot Yocto-built bootloader stack on ZCU102 via JTAG, leaving the board
# at the U-Boot prompt. From there, U-Boot can TFTP-fetch kernel/dtb/
# initramfs from /tftpboot/abraxas3d-yocto/ and boot Linux.
#
# Targets the ZCU102's PSU (ZynqMP), filters past the LibreSDR (xc7z020)
# that shares the JTAG chain on keroppi.
#
# Usage from keroppi:
#   source /tools/Xilinx/Vivado/2022.2/settings64.sh
#   # Start hw_server if not running:
#   hw_server -d
#   # Run boot:
#   xsdb /tmp/abraxas3d-yocto-boot/zcu102_jtag_boot.tcl
#
# Or pass paths via environment if running from elsewhere:
#   BOOT_DIR=/tmp/abraxas3d-yocto-boot xsdb zcu102_jtag_boot.tcl

# --- Resolve boot artifacts directory ---
if {[info exists ::env(BOOT_DIR)]} {
    set boot_dir $::env(BOOT_DIR)
} else {
    set boot_dir "/tmp/abraxas3d-yocto-boot"
}

set pmu_fw    "$boot_dir/pmu-firmware-zcu102-zynqmp.elf"
set fsbl      "$boot_dir/fsbl-zcu102-zynqmp.elf"
set atf_bin   "$boot_dir/arm-trusted-firmware.bin"
set uboot_elf "$boot_dir/u-boot.elf"

# --- Sanity check files exist ---
foreach f [list $pmu_fw $fsbl $atf_bin $uboot_elf] {
    if {![file exists $f]} {
        puts "ERROR: file not found: $f"
        puts "       Run copy_to_keroppi.sh first."
        exit 1
    }
}

puts "=== Connecting to hw_server ==="
connect -url tcp:127.0.0.1:3121

puts ""
puts "=== Available JTAG targets ==="
targets

# --- Step 1: System reset via PSU ---
puts ""
puts "=== Resetting ZCU102 via JTAG ==="
targets -set -filter {name =~ "PSU"}

# Enable JTAG access to the PMU MicroBlaze (MULTIBOOT register).
# After this write, "MicroBlaze PMU" will appear as a target under PSU.
mwr 0xffca0038 0x1ff

rst -system
after 2000

# --- Step 2: Load PMU firmware ---
puts ""
puts "=== Loading PMU firmware ==="
targets -set -filter {name =~ "PMU"}
dow $pmu_fw
con
after 500

# --- Step 3: Load and run FSBL on A53 #0 ---
puts ""
puts "=== Loading and running FSBL on Cortex-A53 #0 ==="
targets -set -filter {name =~ "Cortex-A53 #0"}
rst -processor

dow $fsbl
con

# FSBL initializes PSU registers and DDR. It exits into a wait loop
# after completing its work. Give it a generous window.
puts "Waiting 6 seconds for FSBL to complete DDR init..."
after 6000
stop

# --- Step 4: Load ATF (BL31) at its standard load address ---
puts ""
puts "=== Loading ATF binary at 0xfffea000 ==="
dow -data $atf_bin 0xfffea000

# --- Step 5: Load U-Boot ELF ---
puts ""
puts "=== Loading U-Boot ELF ==="
dow $uboot_elf

# --- Step 6: Start execution ---
puts ""
puts "=== Starting execution (FSBL -> ATF -> U-Boot) ==="
con

puts ""
puts "================================================================"
puts "JTAG boot sequence complete."
puts ""
puts "Watch the serial console on /dev/zcu102_uart1 (or ttyUSB0)."
puts "Expect to see U-Boot banner and the ZynqMP> prompt."
puts ""
puts "At the U-Boot prompt, run:"
puts "  setenv serverip 10.73.1.94    # keroppi"
puts "  setenv ipaddr   10.73.1.16    # ZCU102 static IP"
puts "  tftpboot 0x80000     abraxas3d-yocto/Image"
puts "  tftpboot 0x4000000   abraxas3d-yocto/system.dtb"
puts "  tftpboot 0x4100000   abraxas3d-yocto/initramfs.cpio.gz.u-boot"
puts "  booti 0x80000 0x4100000 0x4000000"
puts ""
puts "Or use 'pxe get; pxe boot' if pxelinux.cfg is configured."
puts "================================================================"
