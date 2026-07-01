# WP1 Companion: Per-Channel State Inventory (16:1 Interleaved Demod Core)

**Purpose:** the concrete list of registers in `msk_demodulator` that must become
channel-indexed RAM when the single-channel demod is interleaved to 16 channels per
core. This turns WP1 from "convert per-channel state to RAM" into a checklist.

**Scope:** one core, 16 channels. Multiply RAM totals by 4 for the full receiver.

---

## How to read this

State splits into two kinds. Only the first kind becomes RAM.

- **Persistent per-channel state (Table A):** registers that carry a channel's value
  from one of its samples to the next (NCO phases, loop accumulators, lock counters,
  FIR history). These MUST be stored per channel. Read at the channel's pipeline
  entry, written back at its exit. Because a channel's samples are 160 clocks apart
  and the pipeline is ~25 deep, a channel is never in the pipeline twice, so a single
  dual-port RAM (1 read + 1 write/clock) per state group is hazard-free.

- **In-flight pipeline state (Table B):** the sample currently traversing the
  square -> mix -> FIR -> CORDIC chain. There is one sample per channel in flight and
  it flows with the channel tag. These stay as ordinary pipeline registers; they do
  NOT become RAM. They only need the channel index carried alongside.

---

## Table A - Persistent per-channel state -> channel-indexed RAM

Widths marked (m) are read directly from the RTL generics/signals; (e) are estimates
to confirm against the final loop structure.

### A.1 de Buda common carrier path

| Signal | Width (bits) | Depth | Notes |
|---|---|---|---|
| `dbu_phase` (2fc NCO phase) | 32 (m, NCO_W) | 16 | de Buda carrier NCO accumulator |
| `common_adjust` (carrier freq correction) | 32 (m, NCO_W) | 16 | accumulated common-loop steer |
| common PI integrator (`u_carrier_filter`) | ~40 (e) | 16 | pi_controller accumulator |
| `dl_i` (de Buda FIR delay line, I) | 25 x 20 = 500 (m) | 16 | see FIR note below |
| `dl_q` (de Buda FIR delay line, Q) | 25 x 20 = 500 (m) | 16 | see FIR note below |

Subtotal per channel: ~1,104 bits (of which 1,000 is the FIR history).

### A.2 Costas loop f1 (`U_f1`)

| Signal | Width (bits) | Depth | Notes |
|---|---|---|---|
| `car_phase` (NCO phase) | 32 (m, NCO_W) | 16 | tone-1 carrier NCO |
| `rx_sin_filt_acc` | 32 (m, ACC_W) | 16 | loop filter EMA (I) |
| `rx_cos_filt_acc` | 32 (m, ACC_W) | 16 | loop filter EMA (Q) |
| `rx_sin_acc` | 32 (m, ACC_W) | 16 | integrate-and-dump (I) |
| `rx_cos_acc` | 32 (m, ACC_W) | 16 | integrate-and-dump (Q) |
| internal PI integrator | ~32 (e) | 16 | if separate from EMA path |
| symbol timing (`tclk` + counter) | ~16 (e) | 16 | per-channel symbol clock |

Subtotal loop f1: ~208 bits per channel.

### A.3 Lock detector f1 (`costas_lock_detect` inside `U_f1`)

| Signal | Width (bits) | Depth | Notes |
|---|---|---|---|
| `acc_i` | 16 (m, ACC_W) | 16 | |
| `acc_q` | 16 (m, ACC_W) | 16 | |
| `acc_iq_delta` | 16 (m, ACC_W) | 16 | |
| `icntr` (integration counter) | 10 (m, ICNT_W) | 16 | |
| `tcntr` (lock-time counter) | 16 (m, TCNT_W) | 16 | |
| `lock`, `lock_d`, `lock_once` | 3 x 1 (m) | 16 | lock flags |

Subtotal lock f1: ~77 bits per channel.

### A.4 Costas loop f2 + lock detector f2 (`U_f2`)

Identical structure to A.2 + A.3. Subtotal: ~285 bits per channel.

### A.5 Demod top glue

| Signal | Width (bits) | Depth | Notes |
|---|---|---|---|
| top-level flags / small counters | ~48 (e) | 16 | init, valid bookkeeping per channel |

---

## Table B - In-flight pipeline state (carry the channel tag, NOT RAM)

These hold the one sample per channel currently traversing the pipeline. Keep them as
pipeline registers; add a channel-index field that flows with them.

| Signal | Width (bits) | Notes |
|---|---|---|
| `dbu_sq_re`, `dbu_sq_im` | 25 (m) each | complex square output |
| `dbu_mix_re`, `dbu_mix_im` | 38 (m) each | after 2fc mix |
| `dbu_fir_i`, `dbu_fir_q` | 35 (m) each | FIR output to CORDIC |
| CORDIC stages `xp/yp/ap` | 16 stages (m) | pipelined; tag rides in `vp`-style vector |
| `dbu_angle` | 32 (m) | CORDIC output angle |
| valid chain (`*_valid`) | 1 each | extend with channel-tag field |

**Action for Table B:** widen the existing valid pipeline into a `{valid, channel}`
pipeline so the tag arrives at the write-back stage aligned with each result.

---

## The de Buda FIR delay line - the one item needing structural care

`dl_i` / `dl_q` are 25-deep shift registers today. A 25-tap FIR reads all 25 taps
every output, so you cannot store the history as a plain sample buffer and read it
back one tap per clock: at 16:1 you have only ~10 clocks per channel, and a
sequential 25-tap read would need ~25. Two workable structures:

1. **Wide-word window RAM (recommended):** store each channel's full 25-tap window as
   one wide entry (25 x 20 = 500 bits per rail), 16 entries deep. Each visit: read the
   channel's window in one cycle, feed the existing parallel 46-DSP FIR, shift the
   window (drop oldest, insert newest), write it back. Keeps the FIR parallel and the
   throughput at one channel per visit. Best mapped to distributed LUTRAM
   (wide-and-shallow), which is cheap here since LUT is not the binding resource.

2. **Transposed FIR with per-channel partial-sum RAM:** heavier rework; avoid unless
   the window RAM causes routing trouble.

Do NOT go to a sequential single-multiplier FIR to save DSP here - it breaks the
per-channel clock budget. Keep the 46 taps parallel; only the delay line is per
channel. (Symmetry folding of those 46 taps to ~24 is WP3, a separate reserve lever,
and is compatible with the window RAM.)

---

## RAM sizing summary (feeds the WP5 BRAM tally)

| Scope | Persistent bits | Notes |
|---|---|---|
| Per channel | ~1,722 | ~1,000 of it the FIR window |
| Per core (16 ch) | ~27,600 (~3.4 KB) | |
| Full receiver (4 cores) | ~110,000 (~13.5 KB) | |

Mapping guidance:
- **FIR windows** (~64 Kbit of the total): distributed LUTRAM, wide-and-shallow, keeps
  the 25-tap read parallel. Modest LUT cost, no BRAM.
- **Accumulators / phases / counters** (~46 Kbit): pack per core into one small BRAM
  each, or distributed RAM. As BRAM that is ~1-2 RAMB18 per core, ~3-4 RAMB36
  equivalent across all four cores.

Net: the interleave adds only a few BRAM tiles (or mostly LUTRAM) on a device with 912
tiles. This is expected to be a rounding error in the WP5 BRAM budget, but record the
actual figure there.

---

## Width provenance

- **Measured (m)** from RTL: NCO_W = 32 (all four carrier NCOs and `common_adjust`);
  Costas ACC_W = 32 (loop-filter and integrate-dump accumulators); lock detector
  ACC_W = 16, ICNT_W = 10, TCNT_W = 16; FIR NTAPS = 25, IN_W = 20; and the Table B
  in-flight widths (25/38/35-bit).
- **Estimated (e), confirm before sizing RAM to the bit:** the common PI integrator
  width (~40), the Costas internal PI integrator count/width (~32), the per-channel
  symbol-timing counter width (~16), and top-level glue (~48). These are small
  relative to the FIR windows and do not change the sizing conclusion, but pin them
  from the final loop structure before freezing RAM widths.

---

## WP1 implementation checklist

1. Add a `{valid, channel[5:0]}` tag pipeline spanning all ~25 stages (Table B).
2. Replace each Table A signal with a dual-port RAM, addressed by incoming channel at
   read and by the emerged tag at write-back.
3. Build the FIR window RAM per the recommended wide-word structure; keep taps parallel.
4. Instantiate one core; regress bit-exact against 16 independent golden single-channel
   demods on 16 stimulus streams.
5. Instantiate 4 cores; assign channels to cores in the pattern that simplifies
   channelizer-output-to-RAM-address mapping.
6. Confirm loop lock/hold behavior is unchanged versus golden (a change here signals a
   state-addressing bug, not a tuning need).
7. Record the actual BRAM/LUTRAM used and feed it into the WP5 tally.
