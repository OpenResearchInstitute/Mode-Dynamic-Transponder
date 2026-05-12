###############################################################################
# Makefile
# iCE40UP5K Synthesis for SIC Receiver
###############################################################################
# Open Research Institute
# Project: Polyphase Channelizer (MDT SIC Receiver)
# Target: Lattice iCE40UP5K-B-EVN Evaluation Board
#
# Tools required:
#   - Yosys (synthesis)
#   - nextpnr-ice40 (place and route)
#   - icepack (bitstream generation)
#   - iceprog (programming)
#
# Install on Ubuntu/Debian:
#   sudo apt install fpga-icestorm yosys nextpnr-ice40
#
###############################################################################

# Project name
PROJECT = sic_receiver

# Target device
DEVICE = up5k
PACKAGE = sg48

# Constraint file
PCF = sic_top.pcf

# Source directories
RTL_DIR = ../../rtl
PKG_DIR = $(RTL_DIR)/pkg
CHAN_DIR = $(RTL_DIR)/channelizer
COEFF_DIR = $(RTL_DIR)/coeffs
SYN_DIR = .

# VHDL source files (order matters for dependencies)
VHDL_SRCS = \
    $(PKG_DIR)/channelizer_pkg.vhd \
    $(CHAN_DIR)/coeff_rom.vhd \
    $(CHAN_DIR)/delay_line.vhd \
    $(CHAN_DIR)/mac.vhd \
    $(CHAN_DIR)/fir_branch.vhd \
    $(CHAN_DIR)/polyphase_filterbank.vhd \
    $(CHAN_DIR)/fft_4pt.vhd \
    $(CHAN_DIR)/polyphase_channelizer_top.vhd \
    $(SYN_DIR)/sic_top_ice40.vhd

# Top module
TOP = sic_top_ice40

# Coefficient file
COEFF_FILE = $(COEFF_DIR)/mdt_coeffs.hex

# Build directory
BUILD_DIR = build

# Output files
JSON = $(BUILD_DIR)/$(PROJECT).json
ASC = $(BUILD_DIR)/$(PROJECT).asc
BIN = $(BUILD_DIR)/$(PROJECT).bin
RPT = $(BUILD_DIR)/$(PROJECT).rpt

###############################################################################
# Synthesis and P&R
###############################################################################

.PHONY: all clean prog timing resources report

all: $(BIN)

# Create build directory
$(BUILD_DIR):
	mkdir -p $(BUILD_DIR)

# Synthesis with GHDL plugin for VHDL
# Note: Requires yosys with GHDL plugin support
$(JSON): $(VHDL_SRCS) | $(BUILD_DIR)
	@echo "=== Synthesizing VHDL with Yosys+GHDL ==="
	yosys -m ghdl -p "\
		ghdl --std=08 $(VHDL_SRCS) -e $(TOP); \
		synth_ice40 -dsp -top $(TOP) -json $@"

# Place and Route
$(ASC): $(JSON) $(PCF)
	@echo "=== Place and Route with nextpnr ==="
	nextpnr-ice40 \
		--$(DEVICE) \
		--package $(PACKAGE) \
		--json $(JSON) \
		--pcf $(PCF) \
		--asc $@ \
		--report $(RPT) \
		--timing-allow-fail

# Bitstream generation
$(BIN): $(ASC)
	@echo "=== Generating bitstream ==="
	icepack $< $@
	@echo "=== Build complete: $@ ==="
	@ls -lh $@

###############################################################################
# Programming
###############################################################################

prog: $(BIN)
	@echo "=== Programming iCE40UP5K ==="
	iceprog $<

prog-sram: $(BIN)
	@echo "=== Programming SRAM (volatile) ==="
	iceprog -S $<

###############################################################################
# Analysis
###############################################################################

timing: $(ASC)
	@echo "=== Timing Report ==="
	icetime -d $(DEVICE) -p $(PCF) -r $(BUILD_DIR)/timing.rpt $<
	@cat $(BUILD_DIR)/timing.rpt

# Show resource utilization from nextpnr report (JSON format)
resources: $(RPT)
	@echo "=== Resource Utilization ==="
	@python3 $(SYN_DIR)/report.py $(RPT)

# Show full build report (resources + timing + bitstream)
report: $(RPT) $(BIN)
	@echo ""
	@echo "╔════════════════════════════════════════════════════════════╗"
	@echo "║              SIC Receiver Build Report                     ║"
	@echo "╚════════════════════════════════════════════════════════════╝"
	@echo ""
	@python3 $(SYN_DIR)/report.py $(RPT) $(BIN)

###############################################################################
# Simulation (optional, uses existing Vivado testbenches)
###############################################################################

sim:
	@echo "Use 'make -C ../../sim test' for simulation with Vivado"
	@echo "Or use GHDL: ghdl -a --std=08 <files> && ghdl -r <testbench>"

###############################################################################
# Clean
###############################################################################

clean:
	rm -rf $(BUILD_DIR)
	rm -f *.json *.asc *.bin *.rpt

###############################################################################
# Help
###############################################################################

help:
	@echo "SIC Receiver - iCE40UP5K Build System"
	@echo ""
	@echo "Targets:"
	@echo "  all        - Build bitstream (default)"
	@echo "  prog       - Program flash"
	@echo "  prog-sram  - Program SRAM (volatile, for testing)"
	@echo "  report     - Show full build report (resources + timing)"
	@echo "  resources  - Show resource utilization only"
	@echo "  timing     - Run timing analysis with icetime"
	@echo "  clean      - Remove build artifacts"
	@echo ""
	@echo "Requirements:"
	@echo "  - Yosys with GHDL plugin (for VHDL synthesis)"
	@echo "  - nextpnr-ice40"
	@echo "  - icestorm tools (icepack, iceprog, icetime)"
	@echo ""
	@echo "Install on Ubuntu/Debian:"
	@echo "  sudo apt install fpga-icestorm yosys nextpnr-ice40"
	@echo "  # For GHDL plugin, build yosys with GHDL support"
