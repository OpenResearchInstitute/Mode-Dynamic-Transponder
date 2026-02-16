# RTL - Synthesizable VHDL

This directory contains the synthesizable VHDL for the polyphase channelizer.

## Directory Structure

```
rtl/
├── pkg/                    # Packages (compile first)
│   └── channelizer_pkg.vhd # Shared types, constants, configs
│
├── channelizer/            # Channelizer modules
│   ├── coeff_rom.vhd       # Coefficient ROM
│   ├── delay_line.vhd      # Sample delay line (TODO)
│   ├── mac.vhd             # Multiply-accumulate (TODO)
│   ├── fir_branch.vhd      # Single polyphase branch (TODO)
│   ├── polyphase_filterbank.vhd  # All branches (TODO)
│   ├── fft_4pt.vhd         # 4-point FFT for MDT (TODO)
│   ├── fft_64pt.vhd        # 64-point FFT for Haifuraiya (TODO)
│   └── polyphase_channelizer_top.vhd  # Top level (TODO)
│
└── coeffs/                 # Coefficient files
    ├── mdt_coeffs.hex      # MDT: 64 coefficients (4 ch × 16 taps)
    └── haifuraiya_coeffs.hex  # Haifuraiya: 1536 coefficients (64 ch × 24 taps)
```

## Compilation Order

1. `pkg/channelizer_pkg.vhd` - Must be compiled first
2. `channelizer/*.vhd` - Any order after package

## Configurations

The design supports two configurations defined in `channelizer_pkg.vhd`:

| Config | Channels | Taps | Target | Application |
|--------|----------|------|--------|-------------|
| MDT_CONFIG | 4 | 64 | iCE40 UP | FunCube+ spectrum monitoring |
| HAIFURAIYA_CONFIG | 64 | 1536 | ZCU102 | Opulent Voice FDMA |

## Usage

```vhdl
library work;
use work.channelizer_pkg.all;

-- Use pre-defined configuration
constant CFG : channelizer_config_t := MDT_CONFIG;

-- Or define custom
constant MY_CFG : channelizer_config_t := (
    n_channels      => 8,
    taps_per_branch => 20,
    data_width      => 16,
    coeff_width     => 16,
    accum_width     => 38
);
```
