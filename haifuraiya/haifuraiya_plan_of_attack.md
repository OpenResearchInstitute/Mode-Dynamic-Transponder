# Haifuraiya: The Dungeon Map

*Plan of attack for getting Phase 4 Ground from "channelizer closes timing"
to "64-channel OPV transponder running on the lab bench."*

---

## ⚔️ You Are Here

Quick orientation when you come back to this doc weeks later:

| Status | Item | Notes |
|:-:|---|---|
| ✅ | Haifuraiya channelizer RTL | Closes 100 MHz on ZCU102, route clean, bit-true tests pass |
| ✅ | **Phase 1 AXI-Stream + AXI-Lite wrapper** | **9/9 testbench PASS. DC → ch0 (639M power) and tone bin 32 → ch32 (266M power) with clean inter-test reset and bounded EMA arithmetic. 7 bugs found and fixed during bring-up (see Bug Hunt section).** |
| ✅ | DVB-S2 encoder | ORI's `dvb_fpga` repo, tested vs GNU Radio, runs on zcu106 |
| ✅ | OPV demodulator RTL | `pluto_msk`, working on LibreSDR; would need 64× or time-shared |
| ✅ | OPV demodulator software | `opv-cxx-demod`, real-time on Pluto's A9 |
| ⏳ | lowpass_ema upstream PRs | **TWO open PRs** to `OpenResearchInstitute/lowpass_ema`: `fix/data-ena-gate` (multiplexed-stream gating) and `fix/sum-saturation` (PROD_W-range clamping). Local builds use `ori/integration` branch until both merge. |
| 🎯 | **Next session focus** | **IP-XACT packaging, block-design smoke test, sustained-amplitude regression test, Friedrichshafen demo prep** |
| ⏳ | ADRV9002 + ZCU102 board | Hardware exists; state of bring-up unknown |
| ⏳ | Yocto Linux on ZCU102 PS | Migration from Petalinux underway; Takadono observability lives here too |
| ❓ | HD.CLK_SRC OOC clock prop | Unresolved; cosmetic for now |

If you only have 5 minutes when returning to this doc, read this section,
then jump to **Phase 1** (next session focus) and **Open Quests** (decisions
you owe yourself).

---

## 🗺️ The Big Picture

```
   ▲ uplink (10 MHz of OPV, 64 narrowband signals)
   │
ADRV9002 RX
   │
   ▼ AXIS @ 10 MSps complex
┌────────────────┐
│  Haifuraiya    │  PL — closes 100 MHz, 53% DSPs
│  channelizer   │  64 channels @ 625 kSps each (10 MSps / M=16)
│  ✅ DONE       │
└────────────────┘
   │
   ▼ AXIS w/ TDEST = channel index, 0..63
┌────────────────┐
│  AXI-DMA       │  PL → PS DDR
└────────────────┘
   │
   ▼
┌──────────────────────────────────────────┐
│  PS (4× A53 Cortex, Linux)               │
│                                          │
│  64× opv-cxx-demod  (recover OPV frames) │
│         │                                │
│         ▼                                │
│  Kabura-ya MUX (PS-side)                 │
│    - GSE encapsulation (per callsign)    │
│    - Periodic manifest PDU               │
│    - BBHEADER + BBFRAME scheduling       │
└──────────────────────────────────────────┘
   │
   ▼ AXIS BBFRAMEs to PL
┌────────────────┐
│  dvb_fpga      │  PL — ~6.5K LUT, tiny next to channelizer
│  DVB-S2 enc    │
│  ✅ HAVE IT    │
└────────────────┘
   │
   ▼ I/Q to DAC
ADRV9002 TX
   │
   ▼ downlink (DVB-S2 broadcast carrying all 64 OPV streams)
```

**Roles:**
- **Haifuraiya** = the channelizer (RF wideband in → 64 channels out)
- **Kabura-ya** = the PS-side MUX (64 streams in → broadcast bitstream out)
- **dvb_fpga** = the DVB-S2 encoder (bitstream in → modulated signal out)

The two heavy DSP pieces (channelizer + DVB-S2 encoder) are *done*. What
remains is integration glue, drivers, and software.

---

## 🎒 Component Inventory

### What we have (party roster)

| Component | Type | Source | Resource cost | License |
|---|---|---|---|---|
| Haifuraiya channelizer | PL IP | this session | 1346 DSP / 116K LUT / 0 BRAM @ 100 MHz | ORI internal (CERN-OHL-S-2.0 standard) |
| `dvb_fpga` DVB-S2 encoder | PL IP | `github.com/OpenResearchInstitute/dvb_fpga` | ~6.5K LUT / 64 DSP / 20 BRAM @ 300 MHz | CERN-OHL-W-2 |
| `pluto_msk` OPV TX+RX modem | PL IP | ORI / LibreSDR build | ~48K LUT total (TX+RX+infra), ~10K LUT for RX only (estimate) | CERN-OHL-S-2.0 |
| `opv-cxx-demod` | PS software | C++, working stack | per-stream small on A53 | (verify license) |

### What we need

| Item | Type | Estimated effort | Phase |
|---|---|---|---|
| Channelizer AXI-Stream wrapper | PL RTL + packaging | 1-2 sessions | 1 |
| Output serializer (parallel 64-ch → AXIS with TDEST) | PL RTL | included in P1 | 1 |
| ADRV9002 reference design integration | Vivado + Linux driver | hours-weeks (depends on starting state) | 2 |
| Yocto Linux on ZCU102 PS | Build system + recipes | unknown | 2 |
| First-light block design | Vivado | hours | 3 |
| opv-cxx-demod ↔ AXIS DMA glue | C++ + Linux DMA driver | 1-2 sessions | 4 |
| Kabura-ya GSE MUX | C++ on PS | 1-3 sessions | 5 |
| Manifest PDU generator | C++ on PS | 1 session | 5 |
| dvb_fpga ZCU102 port | Vivado board files | hours | 5 |

---

## 🧭 Strategic Architecture (the decisions and the why)

### Path B: PL channelize + PS demod (with PL fallback in pocket)

**Decision:** Channelization in PL fabric, OPV demodulation in software on
the A53s, broadcast format generation in PS software, DVB-S2 encoding in PL
fabric.

**Why:**
- DSPs aren't the constraint — channelizer uses 53% of ZCU102 DSPs, leaving plenty
- LUTs are the binding constraint — 64× pluto_msk-style PL demods would need ~5× more LUTs than available
- `opv-cxx-demod` already works as software demod; reusing it is faster than time-sharing PL demods
- A53 throughput estimate: 64 streams at 625 kSps is well within four cores' capability
- Software demod gives flexibility — modulation parameter changes, debugging, future protocol additions don't need re-synth

**Fallback plan:** If the A53s saturate, 8 PL demod instances each time-sharing 8 channels (8:1 round-robin) fits comfortably (~80K LUT). The math is in this session's resource analysis.

### GSE not MPEG-TS for the downlink

**Decision:** Encapsulate the 64 streams in GSE (Generic Stream
Encapsulation, ETSI TS 102 606) rather than MPEG Transport Stream. Set
BBHEADER `TS/GS = 01` (Generic Continuous Stream) when emitting baseband
frames to dvb_fpga.

**Why:**
- **Overhead.** TS is ~5-15% overhead (188-byte alignment + PSI tables + stuffing). GSE is ~2-5%. For our ~1.74 Mbps payload, the savings are ~120 kbps — not enormous, but real.
- **Flexibility for amateur radio semantics.** GSE's Label field can encode a 6-byte callsign directly. Protocol Type is a 16-bit value that can distinguish voice / data / telemetry / chat / image traffic. There's no fixed PID table to maintain.
- **Receiver UX.** TS+PIDs feels like broadcast television. GSE-with-callsign-labels feels like amateur radio — and the receiver application can build a real-time directory of who's on, where they are (grid square), what mode they're in, and at what signal strength. **"Fun and rewarding"** is the design goal; GSE makes it achievable.
- **No commercial-STB compatibility loss.** Our audience uses SDR-based or purpose-built receivers; we're not constrained by what set-top boxes can decode.
- **dvb_fpga doesn't care.** The encoder ingests BBHEADER + BBFRAME; whether the BBFRAME contains TS or GSE is just a bit in the header.

**Cost:** Thinner receiver-side library ecosystem than TS. Mitigated by
`libgse` (OpenSAND, ETSI reference implementation) and by ORI publishing
reference receiver software.

---

## 🏰 Phase 1: AXI Wrap the Channelizer
**✅ RTL complete — IP-XACT packaging and block-design smoke test remain**

### Goal
Package `haifuraiya_channelizer_top` as a drop-in Vivado IP with AXI-Stream
data interfaces and an AXI-Lite control plane, suitable for instantiation
in any ZCU102 block design.

### Tasks (in order)

1. **Interface design (settled).** Decisions made at start of Phase 1:
   - **Input AXIS:** TDATA[31:0] = `{Q[15:0], I[15:0]}` (ADI/Xilinx convention, Q in high half). TVALID drives `sample_valid`. TREADY = '1' always (channelizer accepts every clock).
   - **Output AXIS:** TDATA[31:0] = `{Q[15:0], I[15:0]}` per channel, **requantized from the channelizer's native 40-bit each to 16-bit each** via a runtime-configurable bit-shift. TDEST[7:0] = channel index (0..63 of the 8-bit field). TLAST tied to `channel_last`. TREADY *not* honored in Phase 1 — downstream must keep up; sticky overflow if it doesn't.
   - **AXI-Lite control plane:** Register map below, including `OUTPUT_SHIFT` field that defaults to extracting bits [31:16] of the 40-bit channelizer output.
   - **Reset:** Single domain — AXI `aresetn` (inverted) drives channelizer `reset`. Soft reset register also asserts internal reset.

2. **(skipped — already done inside the channelizer).** The channelizer's existing `haifuraiya_channelizer_top` entity already exposes one-channel-per-clock outputs via `channel_re / channel_im / channel_idx / channel_valid / channel_last`. The internal dual-FFT arbitration takes care of serialization. The AXI wrapper just renames these to AXIS pins — no separate serializer block needed.

3. **Per-channel power detector (existing component reused).** Two ORI submodules under `haifuraiya/third_party/`:
   - `power_detector` from https://github.com/OpenResearchInstitute/power_detector (the per-channel power calculator)
   - `lowpass_ema` from https://github.com/OpenResearchInstitute/lowpass_ema (transitive — `power_detector` instantiates `entity work.lowpass_ema(rtl)` for its filtering stages)

   Both CERN-OHL-W-2. URLs are captured in `.gitmodules` and documented in `haifuraiya/third_party/README.md` to satisfy CERN-OHL-W §4 Source Location requirements.

   Instantiate **64 copies of `power_detector` in parallel**, one per channel, all reading the streaming `channel_re/im` (requantized to 16-bit). Each instance's `data_ena` fires when `channel_idx == k AND channel_valid='1'` — selector logic decoded from the channel index. Generics: `DATA_W=16, IQ_MOD=True, I_USED=True, Q_USED=True, EMA_CASCADE=True`. *Why this matters operationally:* channels see substantial power variation from orbit — edge-of-coverage channels and band-edge channels where the satellite transponder gain rolls off are significantly weaker than channels in the satellite's sweet spot. Power detection per channel becomes a real operational signal for AGC, squelch, and dynamic compute allocation. The dual-stage EMA handles fast scintillation/fading and slower geometry-driven variation simultaneously. Cost: ~4 DSPs per channel × 64 = ~256 DSPs (about 10% of the ZCU102 budget).

4. **AXI-Stream + AXI-Lite shell.** Write `haifuraiya_channelizer_axi.vhd` that instantiates `haifuraiya_channelizer_top`, adds the AXIS pin-renaming, the requantization stage, the 64 power detectors, and the AXI-Lite register block.

5. **AXI-Lite control plane.** Register map:

   | Offset | Name | Type | Description |
   |---|---|---|---|
   | 0x00 | VERSION | RO | major.minor.patch |
   | 0x04 | CONTROL | RW | bit 0: soft reset (sticky); bit 1: enable |
   | 0x08 | STATUS | RO | bit 0: ready; bit 1: overflow sticky; bit 2: backpressure sticky |
   | 0x0C | FRAME_COUNT | RO | output frames since reset (32-bit) |
   | 0x10 | DROPPED_FRAMES | RO | count of frames lost to FIFO overflow |
   | 0x14 | OUTPUT_SHIFT | RW | right-shift applied to the 40-bit channelizer output before AXIS (default 16; valid 0..24) |
   | 0x18 | POWER_ALPHA1 | RW | first-stage EMA α (default: fast tracker, e.g. α=2^-6) |
   | 0x1C | POWER_ALPHA2 | RW | second-stage EMA α (default: slower smoother, e.g. α=2^-12) |
   | 0x100-0x1FC | CHANNEL_POWER[0..63] | RO | per-channel latest integrated power, 32-bit each |

   Stable offsets — treated as a versioned interface for Takadono telemetry.

6. **Testbench.** Write `tb_haifuraiya_channelizer_axi.vhd` that drives AXIS in, reads AXIS out, and exercises AXI-Lite reads/writes. Verify bit-true output against the existing standalone channelizer testbench (all 6 tests should pass with bit-identical channel data when accounting for the requantization shift). Add a smoke test that reads back channel power values via AXI-Lite.

7. **Vivado IP-XACT packaging.** Use the "Create IP" flow; set up the XGui for AXI ports; configure register map.

8. **Smoke test in a tiny block design** — channelizer IP between AXIS BFMs and an AXI-Lite master BFM. Just confirms it instantiates cleanly. Doesn't require hardware.

### Deliverable
A versioned Vivado IP that downstream phases can instantiate. Bit-true vs
current channelizer behavior. Self-contained.

### Status after all bring-up + overflow-debug sessions

| Task | Status | Notes |
|---|:-:|---|
| 1. Interface design | ✅ | All decisions held up under load |
| 2. (skipped, internal to channelizer) | ✅ | Channelizer's existing outputs renamed cleanly |
| 3. 64× power_detector instantiation | ✅ | Works correctly with both upstream lowpass_ema fixes in place |
| 4. AXIS + AXI-Lite shell (`haifuraiya_channelizer_axi.vhd`) | ✅ | Committed; passes 9/9 |
| 5. AXI-Lite register block (`axi_lite_regs.vhd`) | ✅ | Committed; passes 9/9 |
| 6. Testbench (`tb_haifuraiya_channelizer_axi.vhd`) | ✅ | 9 tests, all PASS, with inter-test reset between Test 5 and Test 6 |
| 7. Vivado IP-XACT packaging | 🎯 | Remaining |
| 8. Block-design smoke test | 🎯 | Remaining |
| Bonus: DROPPED_FRAMES=0 in Test 9 | ✅ | Resolved in dispatch-alignment session |
| Bonus: EMA arithmetic bounded (no overflow) | ✅ | `fix/sum-saturation` PR open to upstream lowpass_ema |
| Bonus: Sustained-amplitude regression test | 🎯 | Test 10 to add — assert sum MSB never flips under max-DC stress |

**Measured results after the full bring-up + overflow-debug arc:**
- DC at amplitude 20000 → peak at channel 0 (**639M power**, real value, no wraparound), 1ms test runtime
- Tone at FFT bin 32 → peak at channel 32 (**266M power**), with inter-test reset clearing prior DC state
- u_ema_2 `sum` MSB stays 0 throughout the entire 1ms simulation — no signed-range wraps
- DROPPED_FRAMES = 0, all 311 captured frames in Test 6 had correct TDEST/TLAST sequence
- Channel-0 leakage during the tone test peaks at ~2.2M (~100× below ch 32) — consistent with the polyphase filter's ~−60 dB stopband prediction

---

## 🐲 Bug Hunt Trophy Case
*Seven bosses slain over the two bring-up sessions. Documented for future-you and for anyone else encountering the same patterns.*

### 1. Testbench `tvalid` sub-delta scheduling collision

**Symptom:** Every-other-cycle sample drops in the burst stimulus; only the first send_sample of a loop visibly pulsed `tvalid`.

**Root cause:** The send_sample procedure scheduled `tvalid <= '1'; wait until rising_edge(clk); tvalid <= '0';` — when the loop spacing landed the procedure entry exactly on a clock edge, both inertial assignments resolved in the same delta cycle and the '1' pulse was wiped out before any consumer could see it. Visible in GHDL/xsim alike.

**Fix:** Reorder the procedure to wait FIRST, then drive `tvalid <= '1'`, wait one clock, then `tvalid <= '0'`. Verified in a GHDL reproducer.

**Pattern to watch for elsewhere:** Any testbench procedure that toggles a 1-cycle strobe in a sequence including `wait until rising_edge(clk)` between the assignment and the deassertion. If the procedure entry timing aligns with the clock, the pulse can vanish.

### 2. X-poisoning via un-gated `chan_re_q`

**Symptom:** `stat_channel_power` solid X for the entire simulation despite `di_sq`, `dq_sq`, `dsum` all showing defined values; alpha registers initialized correctly.

**Root cause:** `p_quantize` (the requantization/saturation stage) had `else` after the reset clause — meaning it updated `chan_re_q`/`chan_im_q` every non-reset clock, including channelizer pipeline-fill cycles where `chan_re_acc` carried `U` bits. The `signed(data_I) * signed(data_I)` in the power_detector then squared garbage. Worst part: the lowpass_ema accumulator feedback loop (`mult_sum → sum → sum_shift → mult_sum`) **permanently trapped any X** that reached it. One cycle of X in `chan_re_q` poisoned every EMA forever.

**Fix:** Change `else` → `elsif chan_valid = '1' then` in `p_quantize`. The requantization registers now only update on cycles the channelizer signals as meaningful.

**Pattern to watch for elsewhere:** Any combinational arithmetic that processes a channelizer/FFT output without gating on its `valid` strobe, *especially* if the result feeds a feedback loop.

### 3. lowpass_ema accumulator un-gated by `data_ena` *(upstream fix)*

**Symptom:** After fix #2, all 64 power_detector instances reported the **identical** EMA value (118,271,539 at end of Test 5; 257,236,623 at end of Test 6). The per-channel `data_ena` dispatch was wired correctly but did nothing.

**Root cause:** `lowpass_ema`'s ELSE branch updated every internal signal unconditionally each clock. `data_ena` was only forwarded to `average_ena` as a passthrough strobe, never actually gating the accumulator. Correct behaviour for streaming inputs (data_ena tied high); incorrect for any multiplexed stream where data_ena selects valid clocks.

**Fix:** Wrap the EMA math in `IF data_ena = '1' THEN ... END IF;` inside the non-reset branch. `average_ena <= data_ena;` stays outside the gate to preserve validity reporting. **This is an upstream fix to `OpenResearchInstitute/lowpass_ema`** — see the open PR. Submodule pointer in this repo bumped to the `fix/data-ena-gate` branch (now folded into `ori/integration`).

**Pattern to watch for elsewhere:** Any module documented as taking a `data_ena` / `valid` strobe but whose internal accumulators update unconditionally. Test by tying data_ena low for a window and observing whether the accumulator state holds (correct) or marches forward with whatever's on the data bus (bug).

### 4. Off-by-one dispatch alignment

**Symptom:** After fixes #2 and #3, DC peak landed at channel **1** (off by one), tone peak at channel **17**. The DC skirt was symmetric around channel 1 (not 0), and the symmetry was *near-perfect* — making it crystal clear we were one register stage too early.

**Root cause:** `pd_data_ena(k)` was combinational on `chan_idx_int` but selected data that came through `chan_re_q`, which had one register stage in `p_quantize`. So when `pd_data_ena(k)` fired at time T, `chan_re_q` at T still held the previous channel's (k-1) data.

**Fix:** New `p_dispatch_align` process that registers `chan_valid` and `chan_idx_int` into `chan_valid_r` and `chan_idx_int_r`. `gen_pd_ena` dispatches off the registered copies. Now the dispatch decision lives at the same pipeline stage as the data it selects.

**Pattern to watch for elsewhere:** Any combinational dispatch logic that selects per-instance behavior based on a control signal, while the data it gates is registered. The dispatch and data must arrive at the consumer in the same pipeline beat.

### 5. `OUTPUT_SHIFT` tuning *(test setup, not a code bug)*

**Symptom:** Tests 5 and 6 reported wildly different peak channels each run (channel 12, then 56, then 32…) with `OUTPUT_SHIFT` values of 0, 4, 8.

**Root cause:** Channelizer DC gain through to bin 0 is `(sum of all FIR taps) × N`, which is far greater than the FFT factor N=64 alone. With small shift values, multiple channels saturated to the same ±32767 boundary, masking selectivity and making the "peak" essentially noise in the EMA convergence order.

**Resolution:** Set `OUTPUT_SHIFT = 16` in Tests 5/6. Channel selectivity becomes visible immediately.

**Pattern to remember:** When debugging a system with a configurable scaling/shifting stage, "real saturation hidden by uniform values across many channels" looks identical to "random peak channel each run." If the peak moves wildly with shift, you're saturating — increase shift until peak stabilizes.

### 6. lowpass_ema `sum` arithmetic overflow under sustained input *(upstream fix)*

**Symptom:** After fixes #1–5 produced a clean dispatch and correct per-channel routing, channel-0 power register read back as `1,785,562,731` (unsigned). Reinterpreted signed: `-361 million`. Clearly wrong for a power magnitude. Test 6 then "passed" by accident — channel 0 read negative, so channel 32 won as peak by default.

**Root cause:** `lowpass_ema`'s combinational `sum` assignment summed two `shift_left`'d signed terms without saturation:
```vhdl
sum <= shift_left(resize(mult_data, PROD_W), MULT_DATA_SHIFT) + 
       shift_left(resize(mult_sum,  PROD_W), MULT_SUM_SHIFT);
```
Under sustained DC into a high-amplitude channel (Test 5's exact use case), the 43-bit signed accumulator integrates past ±2^42 and wraps to negative. The slow time constant (α₂=2⁻¹², TC=4096 frames) that gives the EMA its smoothing power then *locks it into the wrong half-plane* — positive input dynamics can't pull it back.

Smoking gun: Tcl loop sampling `sum` MSB every 10µs across the 1ms test showed the accumulator **actively oscillating through wrap**:
```
270µs: MSB=0  sum ≈ +4.14×10¹²  (climbing to +max)
280µs: MSB=1  sum ≈ −4.4×10¹²   ← WRAP to min
420µs: MSB=0  sum ≈ +0.2×10¹²   ← climbed back through zero
550µs: MSB=0  sum ≈ +4.2×10¹²   (climbing to +max again)
560µs: MSB=1  sum ≈ −4.4×10¹²   ← second WRAP
```

**Fix:** Compute the sum in an `EXTRA_W=4` wider intermediate (`sum_wide`), then clamp to `±(2^(PROD_W-1) - 1)` before assigning. Preserves bit-exact behavior for in-range values; clamps gracefully at the limits. **Upstream fix to `OpenResearchInstitute/lowpass_ema`** — submitted as separate PR (`fix/sum-saturation`), independent of the `data_ena` gate PR. Local builds use `ori/integration` branch (cherry-picks both fixes onto upstream main) until both merge.

**Pattern to watch for elsewhere:** Any signed accumulator with a long time constant and sustained high-amplitude inputs. The "wrap into stable wrong-sign equilibrium" failure mode is particularly insidious: once wrapped, the EMA's own filter behavior keeps it there. Always saturate on cascaded EMAs, never wrap. Verify by sustained-DC stress test with an MSB-doesn't-flip assertion.

### 7. Test 5 → Test 6 state carryover *(testbench design, exposed by fix #6)*

**Symptom:** After fix #6 (saturation), Test 6 *still* failed — channel 0 was the peak (533M positive) instead of channel 32. But channel 0 was now correctly positive, not a wraparound value. The test that "passed" before fix #6 was passing only because the overflow flipped channel 0 negative.

**Root cause:** Test 5 (DC) builds up channel 0's EMA to ~640M over its ~312-frame duration. Test 6 (tone) then runs for another ~310 frames. With α₂=2⁻¹² (TC ≈ 4096 frames), 310 frames of decay retain ~86% of channel 0's prior state — leaving it at ~533M while channel 32 freshly integrates from zero up to only ~90M. Channel 0 wins on legacy DC content.

The wraparound bug in fix #6 had been *masking* this design flaw: pre-fix, channel 0 read negative, so channel 32 won by default. Fixing the arithmetic exposed the testbench shortcut.

**Fix:** Assert `aresetn` between Test 5 and Test 6 in the testbench. Each test starts from a known clean state. Operationally also valid for production — you'd typically reset the SIC pipeline between mode changes anyway.

**Pattern to watch for elsewhere:** Any sequence of tests sharing state through long-time-constant filters. If a buggy fix appears to "accidentally pass" a downstream test, suspect that the bug is masking a separate testbench design issue. Fixing one layer can expose the other. Design tests with explicit state-reset semantics upfront.

### Cross-cutting lessons

- **EMA feedback loops trap X permanently.** One bad cycle is enough. Never let X reach an EMA accumulator.
- **Streaming-pipeline vs strobed-input EMAs are different architectural patterns.** Mixing them silently fails. The lowpass_ema was the former; we needed the latter.
- **Combinational dispatch vs registered data is a classic pipelining mistake.** When in doubt, align all paths at the same register depth.
- **Saturation hides selectivity.** Always tune shift/scale first when reading test results that look "random."
- **Signed accumulators with long time constants need saturation, not wrap.** A wrapped EMA's filter dynamics will keep it locked in the wrong half-plane indefinitely. There is no natural recovery path.
- **A passing test may be masking two bugs at once.** Fixing the upstream one can expose the downstream one. Don't assume tests that pass before a fix will keep passing after — verify all assertions still hold and that the *reasons* they hold are the intended ones.
- **Methodical per-cycle Tcl probing beats waveform-viewer scrubbing for state that evolves slowly.** A `restart; for { } { run 10us; get_value }` loop catches MSB-flip events that wouldn't draw the eye in a 1ms waveform window.
- **Third-party doesn't mean trustworthy.** Even well-tested upstream modules can have edge-case bugs. Use them, but verify them in your own test rig under your specific operating conditions.
- **D&D analogies belong in commit messages.** Heralds, vampires, wizards, dungeons, *Cast PROTECTION FROM OVERFLOW*. Future-you will remember the bug because of the metaphor when nothing else stuck.

---

## 🌉 Phase 2: ADRV9002 Bring-up + PS Infrastructure

### Goal
Get RF samples flowing from the ADRV9002 into the PL fabric as AXIS at
10 MSps complex, with PS-side control plane (tuning, gain, AGC). Establish
Yocto Linux on the PS and the early Takadono observability scaffolding so
that downstream phases have a working OS and a place to put telemetry.

### Scope depends heavily on starting state
- **If ADI `adrv9002_zcu102` reference design has ever booted and produced samples on this hardware:** mostly configuration work and integration into the Haifuraiya block design. Days, not weeks.
- **If starting cold:** weeks. The ADRV9002 is newer than the AD9361 that powered the LibreSDR/Pluto work, so reference design maturity in 2026 is the unknown.

### Subphase 2a: ADRV9002 + sample stream
1. Confirm ADRV9002 ref design state (Open Quest below)
2. Configure ADRV9002 for 10 MSps complex sample rate, mid-band LO
3. Linux IIO driver on PS for tuning, gain, AGC
4. Verify sample stream lands in PL at expected throughput (ILA + counter check)

### Subphase 2b: Yocto/EDF Linux on PS
1. Build a Yocto image for ZCU102 (post-Petalinux EDF flow via `gen-machine-conf`, MACHINE=zcu102-zynqmp)
2. Boot to userspace on the four A53 cores
3. Verify AXI-Lite mmap access from userspace (the channelizer registers from Phase 1 should be readable)
4. Install mosquitto MQTT broker (will host Takadono later)

### Subphase 2c: Takadono v0 (stub)
Just enough scaffolding to validate that the observability path works
end-to-end. Defers the dashboard work until Phase 4 when there's more to
observe.

1. Tiny C program that mmaps the channelizer registers, prints to stdout in a loop
2. Wrap in an MQTT publisher (publishes register values to topics like `haifuraiya/channelizer/frame_count`)
3. **No HTML/CSS yet** — that comes when Phase 4 has interesting state worth visualizing

### Deliverable
ADRV9002 → PL with verifiable sample stream at 10 MSps complex. Yocto
booting on PS with mmap working. Takadono v0 publishing channelizer
registers via MQTT.

---

## 🎯 Phase 3: First Light

### Goal
See the channelizer working on real RF samples for the first time.

### Tasks
1. Build the integration block design: ADRV9002 RX → channelizer IP (from Phase 1) → AXI-DMA → PS DDR
2. PS-side capture program (Python/Octave) reads buffer, FFTs each channel, plots spectrum
3. Inject known CW from Pluto + Interlocutor at various frequency offsets within the 10 MHz uplink band
4. Verify peak appears in the expected channel bin
5. Sweep frequency to walk through all 64 bins; verify channel boundaries

### Why this is the moment of truth
This is where simulation meets silicon meets reality. Either the spectrum
plot matches expectations (channelizer behavior validated end-to-end through
real hardware) or something is off and we debug. Common sources of
"something off" at this stage: sample rate misconfiguration, I/Q swap,
channelizer phase calibration, DC offset.

### Deliverable
Verified 64-channel reception of CW signals; software-side capture and
analysis working.

---

## 🎤 Phase 4: Single-Channel OPV End-to-End + Takadono Dashboard

### Goal
Recover one real OPV transmission, all the way from RF to decoded
voice/data. Build out Takadono's HTML/CSS layer now that there's interesting
state worth visualizing.

### Subphase 4a: Single-channel OPV recovery
1. Pick one channel (whichever has the cleanest test signal)
2. Wire AXIS DMA on just that channel index into a PS buffer
3. Feed buffer into `opv-cxx-demod`
4. Pluto + Interlocutor transmits one OPV signal at the target frequency
5. Confirm: frame sync acquires, FEC decodes, payload bits come out, voice plays
6. Measure: uplink-to-decoded-voice latency baseline

### Subphase 4b: Takadono dashboard
With Takadono v0's MQTT scaffolding from Phase 2 already in place, this is
just the presentation layer.

1. HTML/CSS dashboard derived from Speculator (CSS via Interlocutor)
2. Subscribe to MQTT topics, render widgets:
   - Per-channel power as a 64-bar live spectrum view (the win from Phase 1's
     power detector — exactly the kind of thing you'd want to see during
     band-walking)
   - Frame counter, dropped frames, overflow flags
   - Demod-side state (lock indicator, BER estimate) once Phase 4a is up
3. Iterate on widget design with real lab data in front of you

### Why one channel first
Proves the full chain from RF to recovered voice/data works before we worry
about scale. Debugging at this stage is much easier with one stream than
with 64. And Takadono's dashboard becomes the natural debugging surface
for the multi-channel work in Phase 5.

### Deliverable
One OPV stream recovered end-to-end. Baseline latency and BER numbers.
Live Takadono dashboard showing channelizer + demod state.

---

## 🌌 Phase 5: Kabura-ya MUX + DVB-S2 Downlink

### Goal
Full Haifuraiya transponder loop: 10 MHz OPV uplink → 64 channels →
demodulated → GSE-encapsulated → DVB-S2 modulated → RF downlink.

### Subphase 5a: Scale software demod
- Multi-channel `opv-cxx-demod` (4 → 16 → 64 instances)
- Measure A53 utilization; identify saturation point if any
- If saturating before 64: deploy fallback to 8:1 PL time-shared demods

### Subphase 5b: Kabura-ya GSE MUX (PS-side software)

This is the architecturally interesting bit. Decomposes into:

1. **Per-channel encapsulator**
   - One GSE PDU per OPV frame from each channel
   - Label field carries the originating callsign (6 bytes, padded if shorter)
   - Protocol Type encodes mode: voice / data / telemetry / chat / image / control
   - Use `libgse` (OpenSAND, ETSI TS 102 606 reference impl) for the GSE machinery

2. **Manifest PDU generator**
   - Custom Protocol Type value (we own the assignment)
   - Periodic (suggested: every 1 second)
   - Payload: a directory of currently-active callsigns, with: callsign, mode, grid square (Maidenhead), signal quality estimate, frequency offset from channel center
   - This is what makes the receiver application feel alive — it's a real-time "who's on" view

3. **BBFRAME scheduler**
   - Pack GSE PDUs into DVB-S2 BBFRAMEs
   - Set BBHEADER `TS/GS = 01` (Generic Continuous Stream)
   - Fragment PDUs across BBFRAMEs when needed (GSE handles this natively)
   - Emit (BBHEADER + BBFRAME) tuples to AXIS DMA → dvb_fpga input

4. **Idle handling**
   - When all 64 channels go silent, just emit manifest PDUs + null padding
   - When some subset is active, only those channels produce voice/data PDUs; the rest are absent from the stream until they come back
   - GSE handles intermittent streams gracefully (no continuous-flow requirement per stream, unlike TS)

### Subphase 5c: dvb_fpga ZCU102 port and integration
- Repo currently has board support for zcu106. Port to ZCU102 is mostly board constraint files (pin assignments, clock, voltage settings)
- Integrate as Vivado IP in the block design
- Wire to ADRV9002 TX

### Subphase 5d: End-to-end loop
- Pluto transmits OPV signals into Haifuraiya
- Haifuraiya demodulates, re-encodes as DVB-S2
- Verify with a GNU Radio DVB-S2 receiver loopback
- Bonus: an ORI-published reference receiver app showing the live station directory

### Deliverable
Working transponder. 10 MHz of OPV in → DVB-S2 broadcast out → receiver
decodes any subset of the 64 streams.

---

## 📜 Open Quests
*Decisions / clarifications to resolve before or early in next session*

1. **ADRV9002 reference design state.** Has the ADI `adrv9002_zcu102` ref design ever booted on this hardware? "Yes, sample stream working" vs "never tried" is a multi-week difference in Phase 2 scope.

2. **PS Linux state.** Is Yocto/EDF building cleanly for ZCU102? Or is that also TBD? Affects Phase 4 timeline directly.

3. **AXIS output topology.** TDEST channel index (one channel per beat, ~40 MSps total throughput at 100 MHz) — recommended. Or wide TDATA (all 64 channels per beat, needs wide DMA)?

4. **Per-channel enable mask.** Do we want runtime enable/disable of channels (saves DMA bandwidth, lets us focus A53 capacity on active channels), or always stream all 64 and filter in software?

5. **Sample rate at ADRV9002.** Run native at 10 MSps if its profile supports it cleanly, or run higher and decimate in PL? Easier to run native if possible.

6. **opv-cxx-demod license.** Confirm it's MIT/Apache/BSD-style so it integrates cleanly with the CERN-OHL-licensed RTL components.

7. **Manifest PDU format spec.** Once Phase 5 starts, the contents and cadence of the manifest PDU is a design decision worth getting right early — it directly determines what receiver apps can show. Worth a brief design doc of its own.

8. **Time horizon.** "Lab demo in N months" vs "deployable Phase 4 Ground station" — affects polish on intermediate steps. **Hard date in sight: Friedrichshafen HAM RADIO 2026 (June).**

9. **Receiver software for demo.** Will ORI publish a reference receiver to go with this, or rely on GNU Radio flowgraphs for early demos? Pivotal for the "fun and rewarding" goal.

10. **Upstream PR merge timing.** Both lowpass_ema PRs (`fix/data-ena-gate` and `fix/sum-saturation`) sit with Matthew. If they merge before Friedrichshafen, we revert the submodule to upstream main; if not, we ship from `ori/integration`. Either is fine, but worth tracking.

---

## ⚠️ Monsters to Watch For
*Risks worth keeping in peripheral vision*

| Risk | Likelihood | Impact | Mitigation |
|---|:-:|:-:|---|
| ADRV9002 driver maturity in 2026 | Medium | High (could blow up Phase 2) | Check ADI ref design status early; have AD9361 stack as Plan B fallback |
| A53 throughput insufficient for 64× software demod | Medium | Medium (forces PL time-share fallback) | Measure early; PL 8:1 time-share fallback is well-understood |
| OOC clock propagation (HD.CLK_SRC) | Low — constraint should propagate from parent in real block design | Low | Document for now; revisit if it bites in Phase 1 integration |
| Yocto/EDF maturity on ZCU102 | Medium | High | Start that work in parallel with Phase 1-2 |
| dvb_fpga → ZCU102 port surprises | Low | Low | Repo already supports zcu106; difference is mostly board constraint files |
| Per-channel demod processing latency adding up | Low | Medium | Voice latency tolerance is generous (~100ms); measure during Phase 4 |
| GSE library bugs in `libgse` | Low | Low | OpenSAND-derived implementations are well-tested; we control encapsulation order |
| Other latent EMA overflows under different operating conditions | Low | Medium | Add Test 10 (sustained-amplitude regression): MSB-doesn't-flip assertion. Run before every release. |

---

## 📋 License Compatibility

All components ORI-compatible:

- Haifuraiya channelizer: ORI internal, CERN-OHL-S-2.0 standard
- `dvb_fpga`: CERN-OHL-W-2 (weakly reciprocal)
- `pluto_msk`: CERN-OHL-S-2.0
- `libgse` (OpenSAND): typically LGPL — confirm version
- `opv-cxx-demod`: confirm (MIT/Apache/BSD expected)
- ADI reference designs: typically Apache-2.0 or BSD
- ADRV9002 driver: typically LGPL

CERN-OHL-S (strongly reciprocal) and CERN-OHL-W (weakly reciprocal)
interoperate cleanly. The strongly-reciprocal parts retain their
reciprocity; the weakly-reciprocal parts can be combined without forcing
reciprocity on the strong components.

---

## 🗝️ References to This Session's Work

### Channelizer-timing-closure session (earlier)
- `haifuraiya/rtl/channelizer/fir_branch_parallel.vhd` — half-MAC pipeline
- `haifuraiya/rtl/channelizer/polyphase_filterbank_parallel.vhd` — comment updates only
- `haifuraiya/syn/zcu102/synth_haifuraiya_channelizer.tcl` — OOC synth flow
- `haifuraiya/syn/zcu102/impl_haifuraiya_channelizer.tcl` — impl flow
- `haifuraiya/syn/zcu102/haifuraiya_channelizer_synth.xdc` — XDC with 100 MHz clock + HD.CLK_SRC
- `commit_half_mac_timing.txt` — commit message for the timing-closure work

### Wrapper bring-up session (earlier)
- `haifuraiya/rtl/axi/haifuraiya_channelizer_axi.vhd` — AXIS + AXI-Lite wrapper with 64 power detectors
- `haifuraiya/rtl/axi/axi_lite_regs.vhd` — AXI-Lite register block (stable offsets, Takadono-versioned)
- `haifuraiya/sim/tb_haifuraiya_channelizer_axi.vhd` — testbench (later expanded to 9 tests with inter-test reset)
- `haifuraiya/third_party/lowpass_ema/` — submodule, initially on branch `fix/data-ena-gate`, SHA `ee5879a`
- **Upstream PR #1 open:** `OpenResearchInstitute/lowpass_ema` — "Gate EMA accumulator on data_ena for multiplexed-stream use cases"

### Overflow-debug session (this update)
- `haifuraiya/rtl/channelizer/haifuraiya_channelizer_top.vhd` — output mux defaults to '0' on inter-frame gaps (defensive, prevents U propagation through ch_re/ch_im on quiescent cycles)
- `haifuraiya/sim/tb_haifuraiya_channelizer_axi.vhd` — added `aresetn` pulse between Test 5 and Test 6 to clear EMA state between tests
- `haifuraiya/third_party/lowpass_ema/` — submodule now tracks `ori/integration` branch (SHA `5327d83`), which carries both upstream fixes cherry-picked onto upstream main
- Parent repo commit: `467dcc3` "Phase 1 closeout: all 9 testbench tests pass"
- **Upstream PR #2 open:** `OpenResearchInstitute/lowpass_ema` `fix/sum-saturation` — "Saturate EMA sum to PROD_W range to prevent arithmetic overflow on sustained inputs"

### Key results to remember
- Synth-stage critical path: **9.684 ns** (≈ 100 MHz closes; ~0.3 ns slack)
- Post-route data path delay essentially preserved (DSP cascade routing is silicon-fixed)
- Resource baseline: **1346 DSPs (53%), 116K LUTs (42%), 0 BRAMs, 93K FFs (17%)** *(channelizer only — wrapper adds 64 power_detector instances, ~256 DSPs)*
- **Wrapper testbench: 9/9 PASS.** DC → channel 0 (**639M real power**, no wraparound), tone bin 32 → channel 32 (**266M power**), with inter-test reset clearing prior state. Channel-0 leakage during tone test peaks at ~2.2M (~100× rejection, consistent with filter's −60 dB stopband)
- u_ema_2 `sum` MSB stays 0 throughout the entire 1ms simulation across all 64 EMA cascades — arithmetic is bounded
- DROPPED_FRAMES = 0
- HD.CLK_SRC issue causes WNS=inf, 16.5 ns artifact paths, and 1.2 kW absurd power estimate (all the same root cause; not a real design issue)

---

*Last updated: end of overflow-debug session (7 bugs slain total, 9/9 PASS with bounded arithmetic, two upstream PRs open to `OpenResearchInstitute/lowpass_ema`). When you come back, start at "You Are Here" and update statuses as items move between ⏳ / 🎯 / ✅.*
