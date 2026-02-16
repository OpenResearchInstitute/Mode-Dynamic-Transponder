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
│   ├── delay_line.vhd      # Sample delay line (shift register)
│   ├── mac.vhd             # Multiply-accumulate unit
│   ├── fir_branch.vhd      # Single polyphase branch (delay_line + mac)
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

**Build Time:** `mdt_coeffs.hex` on your PC goes to the synthesis tool (which reads the file and runs the initialization function), producing a bitstream with the coefficients embedded.

**Run Time:** On the FPGA, address and clock go into the Block RAM (EBR), and the coefficient register contents are read out. The values are already in the silicon - no file access needed.

---

## How the Delay Line Works

The delay line is a shift register that stores sample history for FIR filtering.

### Why We Need It

An FIR filter computes:

```
y[n] = h[0]·x[n] + h[1]·x[n-1] + h[2]·x[n-2] + ... + h[M-1]·x[n-(M-1)]
```

Each coefficient `h[k]` multiplies a different time-delayed sample. The delay line stores `x[n], x[n-1], x[n-2], ...` so all M products can be computed in parallel.

### Polyphase Structure

In the polyphase channelizer, input samples are distributed round-robin across N branches:

```
Sample index:   0  1  2  3  4  5  6  7  8  ...
Goes to branch: 0  1  2  3  0  1  2  3  0  ...  (for N=4)
```

Each branch has its own delay line:
- Branch 0 sees samples: 0, 4, 8, 12, ...
- Branch 1 sees samples: 1, 5, 9, 13, ...
- etc.

### Shift Operation

When a new sample arrives for a branch (`shift_en=1`):

```
Before (holding x[4], x[0], ...):
┌────────┬────────┬────────┬────────┐
│  x[4]  │  x[0]  │ x[-4]  │ x[-8]  │  ...
└────────┴────────┴────────┴────────┘
  tap[0]   tap[1]   tap[2]   tap[3]
  newest                     oldest

After new sample x[8] arrives:
┌────────┬────────┬────────┬────────┐
│  x[8]  │  x[4]  │  x[0]  │ x[-4]  │  ...
└────────┴────────┴────────┴────────┘
  tap[0]   tap[1]   tap[2]   tap[3]
```

All taps shift toward older positions, new sample enters at tap[0].

### Resource Usage

The delay line uses flip-flops (not Block RAM):

| Config | Branches | Taps/Branch | Bits | FFs per Branch | Total FFs |
|--------|----------|-------------|------|----------------|-----------|
| MDT | 4 | 16 | 16 | 256 | 1,024 |
| Haifuraiya | 64 | 24 | 16 | 384 | 24,576 |

This is acceptable for both targets:
- **iCE40 UP** (~5K FFs): 1,024 FFs = ~20% utilization
- **ZCU102** (548K FFs): 24,576 FFs = ~4.5% utilization

---

## How the MAC Works

The MAC (Multiply-Accumulate) unit computes the dot product of coefficients and samples:

```
result = Σ (coeff[k] × sample[k])  for k = 0 to M-1
```

This is the core FIR filter operation.

### Sequential Operation

This implementation processes taps one at a time (resource-efficient for iCE40):

1. Assert `start` for one cycle
2. MAC iterates through all M taps (M clock cycles)
3. `done` asserts when result is valid
4. Read `result`, then start next computation

```
        ____      ____             ____      ____
 clk   |    |____|    |__ ••• __|    |____|    |
       
       ─────┐                            ┌─────
 start      └────────────────────────────┘
       
                                   ┌───────────
 done  ────────────────────────────┘
       
       |<────────── M cycles ──────────>|
```

### Fixed-Point Arithmetic

| Signal | Width | Format |
|--------|-------|--------|
| samples | DATA_WIDTH (16) | Signed Q1.14 |
| coeffs | COEFF_WIDTH (16) | Signed Q1.14 |
| product | 32 bits | Signed (full precision) |
| accum | ACCUM_WIDTH (36-40) | Signed (prevents overflow) |

**Accumulator sizing to prevent overflow:**

```
ACCUM_WIDTH >= DATA_WIDTH + COEFF_WIDTH + ceil(log2(NUM_TAPS))
```

| Config | Calculation | ACCUM_WIDTH |
|--------|-------------|-------------|
| MDT | 16 + 16 + ceil(log2(16)) = 36 | 36 |
| Haifuraiya | 16 + 16 + ceil(log2(24)) = 37 | 40 (with margin) |

### Resource Usage

Sequential mode uses minimal resources:
- 1 multiplier (infers DSP block if available)
- 1 accumulator register
- Small control FSM

---

## How the FIR Branch Works

The FIR branch combines a delay line and MAC into a complete single-branch FIR filter:

```
                    ┌─────────────────────────────────────┐
                    │           fir_branch                │
                    │                                     │
 sample_in ────────►│    ┌────────────┐                  │
                    │    │ delay_line │──taps──┐         │
 sample_valid ─────►│    └────────────┘        │         │
                    │                          ▼         │
 coeffs ───────────►│                   ┌────────────┐   │
                    │                   │    mac     │   │
                    │                   └─────┬──────┘   │
                    │                         │          │
                    │                         ▼          │
                    │    result ◄─────────────┘          │
                    │    result_valid ◄──────────────────│
                    └─────────────────────────────────────┘
```

### Operation

1. New sample arrives (`sample_valid=1`)
2. Sample shifts into delay line
3. MAC automatically starts computing
4. After M cycles, `result_valid` asserts with filter output

### Interface

| Port | Dir | Description |
|------|-----|-------------|
| sample_in | in | New sample (DATA_WIDTH bits) |
| sample_valid | in | Assert one cycle when sample arrives |
| coeffs | in | All M coefficients packed (from ROM) |
| result | out | Filter output (ACCUM_WIDTH bits) |
| result_valid | out | Asserts when result is ready |

### Coefficient Handling

Coefficients are provided as an input port, not stored internally. This allows:
- Sharing one coefficient ROM across all N branches
- Parent module (polyphase_filterbank) handles addressing

Coefficients must remain stable during MAC computation (M cycles).
