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

## How Coefficient Loading Works

The filter coefficients are stored in hex files and loaded into the FPGA's Block RAM.
Here's how the process works:

### Step 1: Generic Parameter

The `coeff_rom` module has a generic for the coefficient file path:

```vhdl
generic (
    ...
    COEFF_FILE : string := "coeffs.hex"
);
```

When instantiating, you specify which file to use:

```vhdl
u_rom : entity work.coeff_rom
    generic map (
        ...
        COEFF_FILE => "rtl/coeffs/mdt_coeffs.hex"
    )
    port map (...);
```

### Step 2: ROM Type Definition

The ROM is defined as an array sized by the generics:

```vhdl
constant ROM_DEPTH : positive := N_CHANNELS * TAPS_PER_BRANCH;  -- e.g., 4 × 16 = 64

type rom_type is array (0 to ROM_DEPTH - 1) of 
    std_logic_vector(COEFF_WIDTH - 1 downto 0);
```

### Step 3: Initialization Function

A VHDL function reads the hex file and returns the populated array:

```vhdl
impure function init_rom_from_file(filename : string) return rom_type is
    ...
    file_open(rom_file, filename, read_mode);
    for i in 0 to ROM_DEPTH - 1 loop
        readline(rom_file, rom_line);    -- Read one line
        hread(rom_line, hex_val, good);  -- Parse as hex
        rom_data(i) := hex_val;          -- Store in array
    end loop;
    ...
end function;
```

### Step 4: ROM Signal Initialization

The ROM signal is initialized by calling the function:

```vhdl
signal rom : rom_type := init_rom_from_file(COEFF_FILE);
```

**Key point:** This function runs at *elaboration time*:
- **Simulation:** Function executes before simulation starts
- **Synthesis:** Tool evaluates function at compile time, embeds values in bitstream

### Step 5: ROM Read Logic

The actual hardware is a simple synchronous read:

```vhdl
process(clk)
begin
    if rising_edge(clk) then
        coeff_reg <= rom(to_integer(unsigned(addr)));
    end if;
end process;
```

The synthesis tool infers Block RAM (EBR on iCE40, BRAM on Xilinx).

### When Is the Hex File Needed?

| Stage | What Happens | Hex File Needed? |
|-------|--------------|------------------|
| **Synthesis** | Tool reads hex file, embeds values in bitstream | ✓ Yes |
| **Simulation** | Simulator reads hex file at elaboration | ✓ Yes |
| **Runtime** | FPGA loads bitstream, coefficients already in Block RAM | ✗ No |

The hex file is a **build artifact** - needed to create the bitstream, but not needed to run it on the FPGA.

### Data Flow Summary

Build Time: mdt_coeffs.hx on your PC goes to Synthesis tool (reads file, runs function), goes to Bitstreatm (coeffcients are embedded). 

Run Time: on the FPGA, we have address and clock into the Block RAM (EBR) and then coefficient register contents are read out because they are already in the silicon. 
