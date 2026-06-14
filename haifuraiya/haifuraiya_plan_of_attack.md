# Haifuraiya: The Dungeon Map

*Plan of attack for getting Phase 4 Ground from "channelizer closes timing"
to "64-channel OPV transponder running on the lab bench."*

---

## ⚔️ You Are Here

Quick orientation when you come back to this doc weeks later:

| Status | Item | Notes |
|:-:|---|---|
| ✅ | Haifuraiya channelizer RTL | Closes 100 MHz on ZCU102 standalone. Route clean, bit-true tests pass. |
| ✅ | **Phase 1 AXI-Stream + AXI-Lite wrapper** | **10/10 testbench PASS. DC → ch0 (639M power) and tone bin 32 → ch32 (266M power) with clean inter-test reset and bounded EMA arithmetic. 8 bugs found and fixed during bring-up (see Bug Hunt section).** |
| ✅ | **Phase 1 IP-XACT packaging** | **`openresearch.institute:ip:haifuraiya_channelizer_axi:0.1` published to local IP catalog. Integrity check passed. 3 AXI interfaces, 72-register memory map, 2 user-tunable generics. Visible in Vivado IP Catalog as "Haifuraiya Channelizer (AXI)".** |
| ✅ | **Phase 1 Task 8 block-design smoke test** | **BD with AXI/AXIS/clock/reset VIPs validates without warnings. 72-register memory map auto-maps at 0x0000_0000 [4K]. Reusable smoke-test script at `bd/smoke_test/`. PHASE 1 IS CLOSED.** |
| ✅ | DVB-S2 encoder | ORI's `dvb_fpga` repo, tested vs GNU Radio, runs on zcu106 |
| ✅ | OPV demodulator RTL | `pluto_msk`, working on LibreSDR; would need 64× or time-shared |
| ✅ | OPV demodulator software | `opv-cxx-demod`, real-time on Pluto's A9 |
| ⏳ | lowpass_ema upstream PRs | **TWO open PRs** to `OpenResearchInstitute/lowpass_ema`: `fix/data-ena-gate` (multiplexed-stream gating) and `fix/sum-saturation` (PROD_W-range clamping). Local builds use `ori/integration` branch until both merge. |
| ✅ | **power_detector width-mismatch fix** | **Upstream fix pushed to `OpenResearchInstitute/power_detector` main: `lowpass_ema` instantiations now pass full width generics so `MULT_DATA_SHIFT` doesn't go negative when power_detector's POWER_WIDTH exceeds lowpass_ema's default DATA_W ≤ 26. Parent repo submodule pointer bumped.** |
| ✅ | **Phase 2b: PetaLinux on ZCU102 PS** | **PetaLinux Tools 2022.2 build, JTAG boot to login prompt, ADRV9002 driver enumeration confirmed (`adrv9002 spi1.0: ... Firmware 0.22.30, Stream 0.7.11.0, API version: 68.13.7 successfully initialized`). All four AXI infrastructure cores (RX ADC, 2× TX DDS, 2× TDD) come up clean.** |
| ✅ | **Phase 2a: ADRV9002 + ZCU102 board** | **ADI HDL `hdl_2022_r2` reference design build closed, meta-adi 2022_R2 integration verified, ADRV9002 enumerates and reports valid firmware/stream/API.** |
| ✅ | **Phase 3: Channelizer integrated into ZCU102 build** | **`system_bd.tcl` Phase A+B overrides splice channelizer_rx1 + axis_iq_wrapper_rx1 + CDC FIFO into RX1 datapath; RX2/TX1/TX2 preserved as ADI baseline. Timing now CLOSED on a clean `system_top.xsa` (quarter-MAC split — see the timing row below; no more `bad_timing` rename). PetaLinux boots with channelizer AXI-Lite responding at 0x84A70000 (devmem reads version 1.0 + populated config regs). Rebuilt + rebooted from a fresh `green/` clone 2026-05-27.** |
| ✅ | **meta-ori orphan layer fix** | **Layer registered as `CONFIG_USER_LAYER_2`, debug-tweaks enabled, openssh replaces dropbear (via `rootfs_config`), coreutils added for `timeout` et al. SSH from external host verified. 96GB stale `/home/abraxas3d/yocto/` from the abandoned pure-Yocto experiment was deleted during this fix (it had been silently masking our in-tree bbappend edits via bitbake's BBFILE_COLLECTIONS deduplication).** |
| ✅ | **Reproducibility validated** | **Fresh `green/` clone built and booted end-to-end without manual intervention beyond power-cycling the ZCU102. One Makefile bug found (`haifuraiya-boot` referenced undefined `HAIFURAIYA_PETALINUX_PROJECT`) and fixed. The "must manually edit `/tmp/boot.tcl`" dance proved vestigial — PetaLinux's unmodified auto-generated boot.tcl works when the board is power-cycled first.** |
| ✅ | **Documentation set landed** | **Three subproject READMEs: top-level (slimmed to overview + polyphase intro + getting-started pointers), `mdt_sic/README.md` (extracted from old top-level), `haifuraiya/README.md` (Vivado + PetaLinux build/deploy guide), `docs/README.md` (notebook environment + spotting guide). Cross-references all resolve.** |
| 🟡 | **Sample stream verified through libiio** | **Chip-side configuration is unblocked (see Phase 4 Ground update). TES-generated 1T1R FDD CMOS profile loads cleanly on the board, LOs retune to W2 frequencies (5.6 GHz RX, 5.8 GHz TX verified), and the channelizer keeps producing frames through the profile reload (Bouro confirms). dma_listen still shows "DEFAULT-PROFILE BINARY (no real ADC)" because `oriinit-cli run-calibrations` hits a libiio failure on disabled RX2/TX2 channels in 1T1R mode — needs a small patch (filter disabled channels before iio writes) to actually run the LO-Change Procedure at the new frequency. Once cal completes at the new LO, real ADC samples should flow.** |
| ✅ | **TES profile generation pipeline** | **End-to-end validated 2026-05-27: TES 0.23.1 → JSON export at 38.4 MHz device clock → board load → chip state matches every prediction (RX mask 0x41, TX mask 0x4, VCO 8.847 GHz, FDD CMOS, 1.92 Msps). Dead-zone table from UG-1828 page 100-101 navigated; CMOS 1-Lane SDR has a hard ceiling near 1.92 Msps (pin-rate physics: 32 bits × 1.92 Msps = 61.44 Mbps lane rate). Production target profile generated: 1T1R FDD LVDS 20 Msps / 10 MHz BW for the LVDS HDL build. LO carrier frequencies are NOT serialized into the JSON — they're set separately at runtime via `iio_attr altvoltage{0,1,2,3}/frequency`. |
| ✅ | **Driver enforces HDL ↔ profile SSI consistency** | **Discovered 2026-05-27: loading an LVDS profile against the CMOS HDL build produces `adrv9002: SSI interface mismatch. PHY=1, RX1=2` followed by `cat: write error: Invalid argument`. The driver validates the profile's SSI mode against the FPGA's reported capability. **Important caveat: the rejection is NOT cleanly transactional** — even though the write returns an error, the chip's data path can land in a wedged state where no frames flow. Recovery: reload the previously-working profile (or reboot the board). Verified on the bench. |
| ✅ | **Vivado integrated-build timing closure** | **CLOSED 2026-05-27 via the quarter-MAC split ("Cast HASTE", commit `6ffc273`). The -188 ps WNS path was a 12-DSP cascade in `fir_branch_parallel.vhd` spilling across DSP columns (forcing ~600 ps fabric CARRY8 hops). Fix: partition each branch MAC into four registered 6-tap quarter-MACs (`mac_quarter` regs + `p_combine_halves`) so each cascade fits a single DSP column. Branch latency 3→4 cycles; MAC result bit-identical (xsim: tones in bins 4/16/28/40, 59.8 dB adjacent rejection, 0 dropped). Result: `clk_pl_0` WNS -0.188 → **+0.341 ns**; overall design WNS **+0.010 ns**, all constraints met. No more `bad_timing` rename. (The +0.010 global path lives off `clk_pl_0` — see Open Quest #25.)** |
| ✅ | **Dropped frames eliminated — pipelined R2SDF FFT (hardware-confirmed 2026-06-03)** | **Replaced the dual-`fft_n_pt` round-robin + drop path with a single pipelined R2SDF FFT — drop-free by *construction* (no arbiter to lose a race). Bit-exact at every level (core == golden == `fft_n_pt`; new channelizer == old; AXI Tests 1–9 PASS in xsim) and synthesized clean (`clk_pl_0` WNS **+0.938 ns**, 0 failing). **Hardware: 123,535,702 frames, dropped total = 0** (old core would have shed ~600–1,100). See Trophy Case #9. Lone failing timing path is the known `proto_hdr` SSI crossing (Open Quest #25), not the channelizer.** |
| ⏳ | Yocto Linux on ZCU102 PS | **Superseded by PetaLinux Tools 2022.2** — strategic shift documented in Phase 2. AMD has deprecated PetaLinux for 2024.1+ but it's the canonical happy path for the hdl_2022_r2 stack era. |
| ⏳ | Phase 5+: production credentials | meta-adi-xilinx hardcodes root password `analog`. Plan: override via meta-ori bbappend with authorized_keys + `PermitRootLogin without-password`, disable debug-tweaks. ADI's own README at `third_party/meta-adi/meta-adi-xilinx/README.md:146` documents the override mechanism. |
| 🎯 | **Next session focus** | **(a) Patch `liboriinit` `run-calibrations` to skip disabled channels (RX2/TX2 in 1T1R), so the LO-Change Procedure can complete and produce real ADC samples at W2 frequencies. (b) Verify real samples through `dma_listen` after calibration completes. (c) ✅ DONE — FIR MAC timing closed via the quarter-MAC split (commit `6ffc273`); integrated XSA rebuilt clean and booted on the green clone. (d) LVDS HDL port — rebuild the channelizer + ADRV9002 SSI interface for LVDS 2-Lane DDR to support the 20 Msps / 10 MHz BW production profile (covers Haifuraiya's full 64-channel 10 MHz uplink span). The Production-target profile is already generated and validated through TES (`tes_0231_Haifuraiya_FDD_LVDS_20Msps_10MHz.json`). LVDS pin-mapping idiom is known from the LibreSDR `pluto_msk` port. |
| ❓ | HD.CLK_SRC OOC clock prop | Unresolved; cosmetic for now |

If you only have 5 minutes when returning to this doc, read this section,
then jump to **Phase 3** (channelizer integration, just closed) and
**Open Quests** (decisions you owe yourself).
**Phase 1 done. Phase 2a done. Phase 2b done. Phase 3 done — integrated-build timing now CLOSED (quarter-MAC "HASTE", `clk_pl_0` +0.341 ns; clean XSA rebuilt + rebooted on the green clone). Phase 4 Ground in progress: chip-side configuration unblocked (profile generation + load + LO retune all working). Real ADC samples still blocked on a small `liboriinit` patch (run-calibrations needs 1T1R awareness). LVDS HDL port is the next architectural milestone for production-rate operation.**

---

## 🗺️ The Big Picture

```
   ▲ uplink (10 MHz of OPV, 64 narrowband signals)
   │
ADRV9002 RX
   │
   ▼ AXIS @ 10 MSps complex
┌─────────────────┐
│  Haifuraiya    │  PL — closes 100 MHz, 53% DSPs
│  channelizer   │  64 channels @ 625 kSps each (10 MSps / M=16)
│  ✅ DONE       │  ✅ IP-XACT packaged as VLNV 0.1
│                │  ✅ BD smoke-tested
└─────────────────┘
   │
   ▼ AXIS w/ TDEST = channel index, 0..63
┌─────────────────┐
│  AXI-DMA       │  PL → PS DDR
└─────────────────┘
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
┌─────────────────┐
│  dvb_fpga      │  PL — ~6.5K LUT, tiny next to channelizer
│  DVB-S2 enc    │
│  ✅ HAVE IT    │
└─────────────────┘
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
remains is integration glue, drivers, and software. **Phase 1 closed today:
Haifuraiya is now IP-XACT packaged, BD-validated, and drag-droppable into any
ZCU102 block design.**

---

## 🎒 Component Inventory

### What we have (party roster)

| Component | Type | Source | Resource cost | License |
|---|---|---|---|---|
| Haifuraiya channelizer | PL IP (IP-XACT v0.1, BD-smoke-tested) | this session | 1346 DSP / 116K LUT / 0 BRAM @ 100 MHz | ORI internal (CERN-OHL-S-2.0 standard) |
| `dvb_fpga` DVB-S2 encoder | PL IP | `github.com/OpenResearchInstitute/dvb_fpga` | ~6.5K LUT / 64 DSP / 20 BRAM @ 300 MHz | CERN-OHL-W-2 |
| `pluto_msk` OPV TX+RX modem | PL IP | ORI / LibreSDR build | ~48K LUT total (TX+RX+infra), ~10K LUT for RX only (estimate) | CERN-OHL-S-2.0 |
| `opv-cxx-demod` | PS software | C++, working stack | per-stream small on A53 | (verify license) |

### What we need

| Item | Type | Estimated effort | Phase |
|---|---|---|---|
| ~~Channelizer AXI-Stream wrapper~~ ✅ DONE | PL RTL + packaging | ~~1-2 sessions~~ | 1 |
| ~~Output serializer (parallel 64-ch → AXIS with TDEST)~~ ✅ DONE | PL RTL | ~~included in P1~~ | 1 |
| ~~IP-XACT packaging~~ ✅ DONE | Vivado | ~~1 session~~ | 1 |
| ~~Block-design smoke test~~ ✅ DONE | Vivado | ~~1 session~~ | 1 |
| ADRV9002 reference design integration | Vivado + Linux driver | ~~hours-weeks (depends on starting state)~~ ✅ DONE | 2 |
| ~~Yocto~~ **PetaLinux Tools 2022.2** Linux on ZCU102 PS | Build system + recipes | ~~unknown~~ ✅ DONE (boots to login, ADRV9002 enumerates) | 2 |
| First captured sample stream from ADRV9002 (libiio) | PS userspace | 1 session | 2 |
| First-light block design | Vivado | hours | 3 |
| opv-cxx-demod ↔ AXIS DMA glue | C++ + Linux DMA driver | 1-2 sessions | 4 |
| Kabura-ya GSE MUX | C++ on PS | 1-3 sessions | 5 |
| Manifest PDU generator | C++ on PS | 1 session | 5 |
| dvb_fpga ZCU102 port | Vivado board files | hours | 5 |


| Status | Item | Notes |
|:-:|---|---|
| done | Seam-B validated (sim) | frame_sync_detector_soft -> opv-decode -3. Decoder equivalence proven numerically (opv-decode -3 == ov_frame_decoder_soft, all 2144 positions). Standalone-TB 11-symbol offset traced to TB demod-phase approximation, not RTL. Full msk_top + pinned submodules build clean under ghdl. Artifacts in docs/seam-sim/. |
| next | Channelizer -> demod hookup | New wrapper above haifuraiya_channelizer_axi: m_axis_chans (complex I/Q, TDEST) -> demux one channel -> msk_demodulator -> frame_sync_detector_soft -> AXIS/DMA -> opv-decode -3. Submodule deps: msk_demodulator + nco + pi_controller. Retune NCO/Costas for channel rate (~625 ksps, SPS ~11.53). See CHANNELIZER_DEMOD_CONTRACT.md. |
| watch | Fractional SPS at channel rate | SPS ~11.53 is non-integer; confirm demod symbol timing handles it (or pick a friendlier build rate). |

**All Phase 1 work items are complete. Phase 2 is the next quest.**

---

## 🧭 Strategic Architecture (the decisions and the why)

### Path: PL channelize + PL demod + PL frame-sync; PS decode-only

Decision: channelization, MSK demodulation, and frame sync all in PL fabric; the A53 runs
opv-decode in DECODE-ONLY mode (-3) on the 3-bit soft-bit stream. Broadcast format generation in
PS software, DVB-S2 encoding in PL.

Why the change from "demod in software":
- Moving demod + frame-sync into fabric means the A53 only does the Viterbi/derandomize decode,
  not the full per-stream demod -- lighter PS load.
- The fabric soft seam (frame_sync_detector_soft.m_axis_soft_bit, 3-bit, 2144/frame) is validated:
  opv-decode -3 consumes it byte-for-byte identically to the PL decoder ov_frame_decoder_soft
  (same quantizer, same 67x32 deinterleave + MSB-first correction over all 2144 positions, same
  soft Viterbi metric). So opv-decode -3 is a proven drop-in for the PL decoder.
- (Software full-demod remains the fallback if fabric demod resources/timing don't fit.)

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

### Pipelined FFT back end (drop-free by construction)

**Decision:** The channelizer's DFT stage is a single **pipelined R2SDF FFT**
(radix-2 single-path delay feedback), not the original iterative-block
`fft_n_pt` running two-deep in a round-robin.

**Why:** At the production `M_DECIMATION = 16`, frames arrive every 160 fabric
cycles and each iterative FFT is busy 320, so the dual-FFT round-robin
alternated frames with *zero* timing margin. On hardware, jitter (the ADC
valid crossing into `clk_pl_0`, slow corners) pushed the occasional frame onto
a both-FFTs-busy cycle and it was dropped — single-digit ppm, but a receiver
cannot silently lose frames. A pipelined FFT ingests a frame in 64 cycles
against the 160-cycle interval (~40% utilization) and has no arbitration and no
drop path to fire: drop-free by *construction*, not by margin. R2SDF is the
textbook streaming-FFT architecture (Wold & Despain 1984; He & Torkelson 1996)
and the canonical back end for a polyphase channelizer (Harris) — this moves us
*toward* the standard design, not away from it.

**Fixed-point spec & verification:** transplanted verbatim from `fft_n_pt`
(40-bit datapath, Q1.14 twiddles, truncating multiply, wrap, DIF) so the new
core is bit-exact and a numerical drop-in — `OUTPUT_SHIFT`, the power
detectors, EQ, and `m_axis` widths are unaffected. Design + recipe in
`docs/pipelined_fft.md`; the bit-exact golden model the RTL is checked against
is `model/r2sdf_fft_model.py`.

---

## 🏰 Phase 1: AXI Wrap the Channelizer
**✅ COMPLETE — all eight tasks closed**

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

2. **(skipped — already done inside the channelizer).** The channelizer's existing `haifuraiya_channelizer_top` entity already exposes one-channel-per-clock outputs via `channel_re / channel_im / channel_idx / channel_valid / channel_last`. The pipelined R2SDF FFT back end produces those one-channel-per-clock outputs directly — it replaced the original dual-FFT round-robin (see the *Pipelined FFT back end* decision and Trophy Case #9). The AXI wrapper just renames these to AXIS pins — no separate serializer block needed.

3. **Per-channel power detector (existing component reused).** Two ORI submodules under `haifuraiya/third_party/`:
   - `power_detector` from https://github.com/OpenResearchInstitute/power_detector
   - `lowpass_ema` from https://github.com/OpenResearchInstitute/lowpass_ema (transitive — `power_detector` instantiates `entity work.lowpass_ema(rtl)` for its filtering stages)

   Both CERN-OHL-W-2. URLs are captured in `.gitmodules` and documented in `haifuraiya/third_party/README.md` to satisfy CERN-OHL-W §4 Source Location requirements.

   Instantiate **64 copies of `power_detector` in parallel**, one per channel, all reading the streaming `channel_re/im` (requantized to 16-bit). Each instance's `data_ena` fires when `channel_idx == k AND channel_valid='1'` — selector logic decoded from the channel index. Generics: `DATA_W=16, IQ_MOD=True, I_USED=True, Q_USED=True, EMA_CASCADE=True`. *Why this matters operationally:* channels see substantial power variation from orbit — edge-of-coverage channels and band-edge channels where the satellite transponder gain rolls off are significantly weaker than channels in the satellite's sweet spot. Power detection per channel becomes a real operational signal for AGC, squelch, and dynamic compute allocation. The dual-stage EMA handles fast scintillation/fading and slower geometry-driven variation simultaneously. Cost: ~4 DSPs per channel × 64 = ~256 DSPs (about 10% of the ZCU102 budget).

4. **AXI-Stream + AXI-Lite shell.** `haifuraiya_channelizer_axi.vhd` instantiates `haifuraiya_channelizer_top`, adds the AXIS pin-renaming, the requantization stage, the 64 power detectors, and the AXI-Lite register block.

5. **AXI-Lite control plane.** Register map:

   | Offset | Name | Type | Description |
   |---|---|---|---|
   | 0x00 | VERSION | RO | major.minor.patch (reads 0x00010000 = v0.1.0) |
   | 0x04 | CONTROL | RW | bit 0: soft reset (sticky); bit 1: enable |
   | 0x08 | STATUS | RO | bit 0: ready; bit 1: overflow sticky; bit 2: backpressure sticky |
   | 0x0C | FRAME_COUNT | RO | output frames since reset (32-bit) |
   | 0x10 | DROPPED_FRAMES | RO | count of frames dropped at the FFT input. The pipelined-FFT back end removes the drop path → structurally 0; retained as a health monitor (see Trophy Case #9) |
   | 0x14 | OUTPUT_SHIFT | RW | right-shift applied to the 40-bit channelizer output before AXIS (default 16; valid 0..24) |
   | 0x18 | POWER_ALPHA1 | RW | first-stage EMA α (default: fast tracker, e.g. α=2^-6) |
   | 0x1C | POWER_ALPHA2 | RW | second-stage EMA α (default: slower smoother, e.g. α=2^-12) |
   | 0x100-0x1FC | CHANNEL_POWER[0..63] | RO | per-channel latest integrated power, 32-bit each |

   Stable offsets — treated as a versioned interface for Bouro telemetry. **All 72 registers are encoded in the IP-XACT memory map and visible to Vivado's Address Editor / Vitis header generation / Petalinux device tree.**

6. **Testbench.** `tb_haifuraiya_channelizer_axi.vhd` drives AXIS in, reads AXIS out, exercises AXI-Lite reads/writes, and verifies bit-true output behavior. 10/10 PASS with inter-test reset between Test 5 and Test 6 (Test 10 is the sustained-DC stress regression).

7. **Vivado IP-XACT packaging.** ✅ **COMPLETE.** VLNV `openresearch.institute:ip:haifuraiya_channelizer_axi:0.1`. Integrity check passed. Catalog rendering verified. See "IP-XACT Packaging Lessons" section below.

8. **Smoke test in a tiny block design.** ✅ **COMPLETE.** Reusable Tcl script at `bd/smoke_test/bd_smoke_test.tcl` instantiates the IP with `clk_vip`, `rst_vip`, two `axi4stream_vip` instances, and one `axi_vip` master. Validates clean with zero warnings. Address segment `s_axi_ctrl/reg0` auto-maps at `0x0000_0000` with range 4K. Script is path-portable across working trees via `[info script]` resolution.

### Deliverable
A versioned Vivado IP that downstream phases can instantiate. Bit-true vs
current channelizer behavior. Self-contained. BD-validated. **Achieved.**

### Status after all Phase 1 sessions

| Task | Status | Notes |
|---|:-:|---|
| 1. Interface design | ✅ | All decisions held up under load |
| 2. (skipped, internal to channelizer) | ✅ | Channelizer's existing outputs renamed cleanly |
| 3. 64× power_detector instantiation | ✅ | Works correctly with both upstream lowpass_ema fixes in place |
| 4. AXIS + AXI-Lite shell (`haifuraiya_channelizer_axi.vhd`) | ✅ | Committed; passes 10/10 |
| 5. AXI-Lite register block (`axi_lite_regs.vhd`) | ✅ | Committed; passes 10/10 |
| 6. Testbench (`tb_haifuraiya_channelizer_axi.vhd`) | ✅ | 10 tests all PASS, with inter-test reset between Test 5 and Test 6 |
| 7. Vivado IP-XACT packaging | ✅ | VLNV 0.1, 72 registers encoded, integrity check passed, catalog verified |
| **8. Block-design smoke test** | **✅** | **Validated clean with axi/axi4stream/clk/rst VIPs; no warnings; bd/smoke_test/bd_smoke_test.tcl is re-runnable** |
| Bonus: DROPPED_FRAMES=0 in Test 9 | ✅ | Resolved in dispatch-alignment session |
| Bonus: EMA arithmetic bounded (no overflow) | ✅ | `fix/sum-saturation` PR open to upstream lowpass_ema |
| Bonus: Sustained-amplitude regression test | ✅ | Test 10 added; asserts ch 0 in [500M, 800M] under max-DC stress |
| Bonus: aresetn ASSOCIATED_BUSIF fix | ✅ | Removed bad parameter; `fix_ipxact_aresetn.tcl` archived for posterity |

**Measured results after the full Phase 1 arc:**
- DC at amplitude 20000 → peak at channel 0 (**639M power**, real value, no wraparound), 1ms test runtime
- Tone at FFT bin 32 → peak at channel 32 (**266M power**), with inter-test reset clearing prior DC state
- u_ema_2 `sum` MSB stays 0 throughout the entire 1ms simulation — no signed-range wraps
- DROPPED_FRAMES = 0, all 311 captured frames in Test 6 had correct TDEST/TLAST sequence
- Channel-0 leakage during the tone test peaks at ~2.2M (~100× below ch 32) — consistent with the polyphase filter's ~−60 dB stopband prediction
- Test 10 (sustained DC stress): ch 0 = 651M, within 2% of Test 5's value, MSB stays 0 throughout
- **Block-design smoke test: zero warnings after the aresetn fix. 72-register memory map auto-maps at 0x0000_0000 [4K].**

---

## 🏛️ IP-XACT Packaging Lessons
*Vivado packager gotchas learned the hard way. Future-you and any
collaborator packaging an ORI IP should read this section first.*

### What worked beautifully

- **Naming conventions buy auto-inference.** `s_axi_*`, `m_axis_*`, `s_axis_*`,
  `aclk`, `aresetn` prefixes let Vivado correctly identify all three AXI bus
  interfaces in a single pass — TDATA/TVALID/TREADY/TDEST/TLAST grouped without
  a single manual click. Discipline upstream saves 20 minutes of fiddly
  port-by-port grouping downstream.

- **Tcl bulk register encoding.** 72 registers (8 control + 64 channel power)
  went from "hours of GUI clicking" to a 30-second loop:
  ```tcl
  proc add_reg {abi name offset access desc} { ... }
  for {set k 0} {$k < 64} {incr k} { ... }
  ```
  Pattern is reusable for the next ORI IP's register map.

- **The `ori/integration` submodule branch.** Carrying both upstream PR
  fixes on a local branch let packaging proceed without blocking on Matthew's
  merge timing. Component.xml ships with known-good submodule pointers.

- **Path-portable smoke test script.** `bd_smoke_test.tcl` derives `ip_repo_path`
  from `[info script]`, so it works from any working tree (brown, orange,
  burnt_sienna, etc.) without editing. Anyone who clones the repo can run
  the smoke test out of the box.

### What bit us

- **`ipx::infer_core` silently fails without project context.** Returns empty
  error from `catch{}`. Component.xml never appears. The actual diagnostic
  came from `ipx::package_project`, which loudly reported "no source files
  from the current project to package."

- **The wizard's "Package a specified directory" mode doesn't actually
  package the directory.** It still needs files to be added to the current
  project first via `add_files`, plus `set_property top` to declare the entry
  point. The wizard implied this would be automatic; it isn't.

- **`ipx::` and `ipgui::` are NOT interchangeable.**
  `ipx::` manipulates IP-XACT metadata (vendor, library, ports, register map).
  `ipgui::` manipulates the customization GUI layout. Hiding parameters from
  users requires `ipgui::remove_param`, not `set_property enablement_value`.
  My first attempt to hide the 7 coefficient-coupled generics set
  `enablement_value=false` and the GUI happily showed them anyway.

- **The "Display name" field on Review and Package is misleading.** It shows
  the IP module name (e.g., `haifuraiya_channelizer_axi_v1_0`), not the
  IP-XACT `<spirit:displayName>` we entered on Identification. The IP-XACT
  metadata is correct; only the Review page renders it confusingly. Verify
  by inspecting component.xml directly.

- **Clock and reset `ASSOCIATED_BUSIF` parameters are ASYMMETRIC.** Auto-inference
  associates `aclk`'s `ASSOCIATED_BUSIF` with only the first bus interface it
  finds. For multi-bus IPs, expand to a colon-separated list:
  `m_axis_chans:s_axis_data:s_axi_ctrl`. **But do NOT mirror this onto the
  reset** — `ASSOCIATED_BUSIF` belongs on clocks only. Adding it to the reset
  causes Vivado to interpret the reset as a second clock-like signal on every
  bus, producing CRITICAL WARNINGs in downstream BDs. The reset's
  bus-association is inferred via the clock's `ASSOCIATED_RESET` parameter.
  *(See Bug #8 in the trophy case for the full diagnosis.)*

- **Empty packaging project = empty IP.** If `current_project` returns a
  project with no files, `ipx::package_project` reports
  `CRITICAL WARNING: There are no source files from the current project
  to package.` Always verify file count with
  `llength [get_files -of_objects [get_filesets sources_1]]` before
  invoking the packager.

- **The hex coefficient file must be added explicitly to both Synthesis
  AND Simulation file groups.** Vivado's auto-population picks up .vhd files
  but misses .hex data files. Symptom on a downstream user: IP instantiates
  but synthesis fails at elaboration time with "cannot open file
  haifuraiya_coeffs.hex". Add via the GUI `+` button or via Tcl:
  ```tcl
  ipx::add_file rtl/coeffs/haifuraiya_coeffs.hex \
      [ipx::get_file_groups xilinx_anylanguagesynthesis -of [ipx::current_core]]
  ```

- **AXI VIPs are named `axi4stream_vip`, not `axis_vip`.** Block-design Tcl
  fails silently with "no cells matched" if you guess the VLNV wrong. Always
  check the actual VLNV in the IP Catalog GUI before scripting `create_bd_cell`.

- **`rst_vip` has no clock input pin.** Unlike `axi_vip` and `axi4stream_vip`
  which have `aclk` and `aresetn` scalar pins, `rst_vip` has only `rst_in` and
  `rst_out`. Don't try to connect a clock to it.

- **BD changes are in-memory until `save_bd_design`.** If your Tcl script
  errors out partway through BD construction, the file on disk reflects the
  state at the last save, not the runtime state. Save checkpoints after
  major milestones (cell instantiation, wiring complete) so partial state is
  inspectable when something fails.

### Workflow recipe (for the next ORI IP)

```tcl
# 1. Open or create an empty Vivado project (any part will do for packaging)
create_project package_<ip_name> /tmp/package_<ip_name> -part xczu9eg-ffvb1156-2-e

# 2. Add ALL files that should be part of the IP
add_files /path/to/ip/rtl
add_files /path/to/ip/third_party
add_files /path/to/ip/rtl/coeffs   ;# don't forget data files

# 3. Tell Vivado the top entity
set_property top <top_entity_name> [current_fileset]

# 4. Package
ipx::package_project -root_dir /path/to/ip \
    -vendor openresearch.institute \
    -library ip \
    -taxonomy /OpenResearchInstitute/<IP_Family>

# 5. Fill in metadata: vendor display name, company URL, descriptions...
# 6. Fix multi-bus clock association (aclk's ASSOCIATED_BUSIF = colon-separated list)
#    DO NOT add ASSOCIATED_BUSIF to the reset; the asymmetry is intentional.
# 7. Bulk-encode register map via Tcl loop
# 8. ipgui::remove_param for locked generics (NOT set_property enablement_value)
# 9. ipx::save_core; update_ip_catalog
# 10. Run block-design smoke test (instantiate with VIPs; validate_bd_design clean)
```

---

## 🐲 Bug Hunt Trophy Case
*Nine bosses slain over the bring-up + packaging + integration + live-bring-up sessions.
Documented for future-you and for anyone else encountering the same patterns.*

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

**Symptom:** After fixes #1–5 produced a clean dispatch and correct per-channel routing, channel-0 power register read back as `1,785,562,731` (unsigned). Reinterpreted signed: `−361 million`. Clearly wrong for a power magnitude. Test 6 then "passed" by accident — channel 0 read negative, so channel 32 won as peak by default.

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

### 8. ASSOCIATED_BUSIF mistakenly added to reset bus interface *(IP-XACT, exposed only at block-design instantiation)*

**Symptom:** Block design instantiation produces three CRITICAL WARNINGs
([BD 41-1732]) — "Bus interface X is found to be associated with multiple
clock-pins. List of associated clock-pins: aclk, aresetn." — one for each
of the three AXI bus interfaces (s_axi_ctrl, m_axis_chans, s_axis_data).
Validation passes (warnings, not errors), but the warnings would propagate
to every downstream BD that uses the IP. Found while running Phase 1 Task 8
(block-design smoke test) and noticing the noise during `regenerate_bd_layout`.

**Root cause:** During IP-XACT packaging, the `ASSOCIATED_BUSIF` parameter
was added to both `aclk` (correct — "this clock drives these buses") AND
`aresetn` (incorrect — parameter belongs on clocks, not resets). Vivado
interpreted the reset's `ASSOCIATED_BUSIF` as declaring it a second
clock-like signal for each bus, hence the "multiple clock-pins" warning.

The correct IP-XACT convention is asymmetric:
- `aclk` has `ASSOCIATED_BUSIF` = list of buses it clocks
- `aclk` has `ASSOCIATED_RESET` = name of the reset signal
- `aresetn` has `POLARITY` = ACTIVE_LOW
- `aresetn` should NOT have `ASSOCIATED_BUSIF`; its association with
  the buses is inferred via aclk's ASSOCIATED_RESET

**Fix:** Tcl one-liner removing the parameter:
```tcl
ipx::remove_bus_parameter ASSOCIATED_BUSIF \
    [ipx::get_bus_interfaces aresetn -of [ipx::current_core]]
ipx::save_core [ipx::current_core]
```

Standalone script archived at `bd/smoke_test/fix_ipxact_aresetn.tcl` for
future reference. Verified post-fix: smoke test produces zero warnings on
`regenerate_bd_layout`. Fix applied in-place at v0.1 (no version bump,
since the IP hadn't been released anywhere yet).

**Pattern to watch for elsewhere:** IP-XACT clock vs reset metadata is
asymmetric. `ASSOCIATED_BUSIF` lives on clocks. `ASSOCIATED_RESET` lives
on clocks too (pointing at the reset). Resets only declare `POLARITY`.
Symmetry feels right but is wrong. This is a footgun for anyone packaging
an IP with the natural-feeling "mirror what I did for the clock onto the
reset" instinct.

### 9. Dropped frames on hardware — zero-margin dual-FFT at M=16

**Symptom:** Bouro showed a steady trickle of `DROPPED_FRAMES` on the live M=16 build — single-digit ppm (~5–9 per ~1.2M frames). They persisted with `dma_listen -c 100000` actively draining the stream, so it was *not* a downstream-consumer problem.

**Root cause:** Read straight out of `haifuraiya_channelizer_top` — the output stage ran two iterative `fft_n_pt` cores round-robin and dropped a frame when *both* were busy (`frame_dropped_r <= '1'`). At M=16 a frame arrives every 160 fabric cycles and each FFT is busy 320, so the two had to alternate frames with *exactly zero* timing margin — the comment itself said "they alternate frames exactly." The "anticipate-IDLE-by-2" busy signal bought a sliver, so it mostly kept up; real-world jitter (the ADC valid crossing into `clk_pl_0`) occasionally landed a frame on a both-busy cycle → drop. The drop is at the FFT *input*, so a lost frame is invisible to both `m_axis` and the power detectors — it never gets transformed at all.

**Fix:** Replace the iterative-block FFT + dual-FFT round-robin + drop path with a single **pipelined R2SDF FFT** (see the *Pipelined FFT back end* decision). Drop-free by construction — no arbitration, ~40% utilization, no drop path to fire. Fixed-point recipe transplanted from `fft_n_pt`, bit-exact, verified against `model/r2sdf_fft_model.py`. The old core lives in git history; it is not carried in the tree behind a generic.

**Verified (sim → silicon, each rung the authority for the one below):** R2SDF == golden model == `fft_n_pt`, bit-exact over 8 frames in GHDL *and* in your xsim (`run_r2sdf_sim.tcl`, packed and bursty/GAPS feeds). New `haifuraiya_channelizer_top` == the old dual-FFT core, bit-exact over 5 frames × 64 bins (`tb_channelizer_equiv`), plus a standalone check that the stream obeys TDEST 0..63 / TLAST-on-63 / first-beat-0. AXI smoke test Tests 1–9 PASS — DC → ch0, tone → ch16, **154 frames all TDEST 0..63 / TLAST on 63, DROPPED_FRAMES = 0**. Synthesis: `clk_pl_0` meets timing at **WNS +0.938 ns, 0 / 417,547 failing endpoints** (the pipelined core is *easier* to close than the iterative one — registers between every butterfly stage). **Hardware (Bouro): 123,535,702 frames, dropped total = 0.** The old core, at ~5–9 ppm, would have shed ~600–1,100 frames by here; the R2SDF shows none. The lone failing timing path is the pre-existing `proto_hdr_OBUF[0]` ← `rx1_dclk_out` SSI crossing (−0.122 ns, not `clk_pl_0` — see Open Quest #25). Build retired `fft_n_pt` from `component.xml` (both file sets) and the sim tcl; the R2SDF trio (`r2sdf_stage` → `r2sdf_reorder` → `r2sdf_fft`) added in dependency order. (`fft_pkg` left in place — only `fft_n_pt` used it; drop it once a repo-wide grep confirms nothing else does.)

**Pattern to watch for elsewhere:** "Alternate frames *exactly*" is a zero-margin design and a red flag. Deterministic sim cannot see it — with no jitter the perfect hand-off holds, so every prior `DROPPED_FRAMES = 0` sim result was truthful — but hardware has CDC and corner jitter a zero-margin hand-off can't absorb. The hardware register read (Bouro) was the authority that surfaced it. Fix by sizing for throughput margin plus a FIFO, or by removing the contended resource entirely (a pipelined FFT removes the arbitration). Margin keeps it up on average; a FIFO absorbs the instantaneous.

### Cross-cutting lessons

- **EMA feedback loops trap X permanently.** One bad cycle is enough. Never let X reach an EMA accumulator.
- **Streaming-pipeline vs strobed-input EMAs are different architectural patterns.** Mixing them silently fails. The lowpass_ema was the former; we needed the latter.
- **Combinational dispatch vs registered data is a classic pipelining mistake.** When in doubt, align all paths at the same register depth.
- **Saturation hides selectivity.** Always tune shift/scale first when reading test results that look "random."
- **Signed accumulators with long time constants need saturation, not wrap.** A wrapped EMA's filter dynamics will keep it locked in the wrong half-plane indefinitely. There is no natural recovery path.
- **A passing test may be masking two bugs at once.** Fixing the upstream one can expose the downstream one. Don't assume tests that pass before a fix will keep passing after — verify all assertions still hold and that the *reasons* they hold are the intended ones.
- **Methodical per-cycle Tcl probing beats waveform-viewer scrubbing for state that evolves slowly.** A `restart; for { } { run 10us; get_value }` loop catches MSB-flip events that wouldn't draw the eye in a 1ms waveform window.
- **Third-party doesn't mean trustworthy.** Even well-tested upstream modules can have edge-case bugs. Use them, but verify them in your own test rig under your specific operating conditions.
- **Vivado IP packager has two parallel layers (`ipx::` and `ipgui::`) that look interchangeable but aren't.** Always check which layer your operation actually targets.
- **IP-XACT clock/reset metadata is asymmetric.** The natural instinct to mirror clock parameters onto the reset (`ASSOCIATED_BUSIF` in particular) is wrong and produces CRITICAL WARNINGs at every block-design instantiation. The reset's relationship to buses is inferred through the clock's `ASSOCIATED_RESET` parameter, not declared on the reset itself.
- **A block-design smoke test catches what IP-XACT integrity check misses.** `ipx::check_integrity` passed last night, but the multi-clock-pin association bug only surfaced at `regenerate_bd_layout` during BD instantiation. Both checks are necessary; neither is sufficient.
- **Path-portable scripts via `[info script]`.** Hardcoded `/home/user/<colorname>/...` paths are brittle and embarrassing. Resolving paths relative to the script's own location makes scripts work in any working tree and across collaborators.
- **D&D analogies belong in commit messages.** Heralds, vampires, wizards, dungeons, *Cast PROTECTION FROM OVERFLOW*, *Cast PACKAGE OBJECT*, *Cast PROTECTION FROM CLOCK CONFUSION*. Future-you will remember the bug because of the metaphor when nothing else stuck.

---

## 🌉 Phase 2: ADRV9002 Bring-up + PS Infrastructure
**🟢 Subphase 2b done + extended (meta-ori orphan layer fix, openssh, coreutils, debug-tweaks, fresh-clone reproducibility validated on green/ clone 2026-05-24). Subphase 2a tasks 1-3 done; tasks 4-6 pending (require ADRV9002 profile load + initial calibration + sync_start_enable arm — standard ADI workflow, not yet automated for haifuraiya). Subphase 2c (Bouro v0 stub) not started.**

### Goal
Get RF samples flowing from the ADRV9002 into the PL fabric as AXIS at
10 MSps complex, with PS-side control plane (tuning, gain, AGC). Establish
Linux on the PS and the early Bouro observability scaffolding so
that downstream phases have a working OS and a place to put telemetry.

### Strategic shift: PetaLinux Tools 2022.2, not pure Yocto

The original plan called for "Yocto/EDF Linux on PS via gen-machine-conf."
We tried that path first. It does not work for ADI reference designs in
the hdl_2022_r2 era: `meta-xilinx-tools`' PMU/FSBL BSP template hardcodes
`axi_intc_0` (which ADI XSAs don't include), and `device-tree-xilinx`
expects PetaLinux convention files (`system-conf.dtsi`) that meta-adi
doesn't ship. After a day and a half of patching seams, we pivoted to
PetaLinux Tools 2022.2 — which is the documented happy path for this
stack. AMD has deprecated PetaLinux Tools as of 2024.1 in favor of pure
Yocto + gen-machine-conf, but that flow targets Vivado 2024.x and a
newer meta-adi release. For our hdl_2022_r2 / meta-adi 2022_R2 era,
**PetaLinux Tools is what ADI's documentation assumes and what works
without fighting the tools.** Strategic principle: don't fight the
documented happy path of your stack era.

### Architecture (operational)

- **Build host:** `mymelody`. PetaLinux project at `<MDT>/haifuraiya/petalinux/haifuraiya/`. ADI HDL submodule at `<MDT>/haifuraiya/third_party/hdl/` (branch `hdl_2022_r2`). meta-adi clone at `<MDT>/haifuraiya/third_party/meta-adi/` (branch `2022_R2`). PetaLinux Tools install at `~/petalinux/2022.2/`.
- **JTAG / lab host:** `keroppi` (10.73.1.94). `hw_server -d` on default port 3121. ZCU102 over USB JTAG. Serial console at `/dev/zcu102_uart1` 115200.
- **Target:** ZCU102 + ADRV9002. Static IP `10.73.1.16` (configured in `petalinux-config`; verification via `ip addr` post-boot pending the systemd-network porting step).
- **Boot path:** `petalinux-boot --jtag --prebuilt 3 --hw_server-url TCP:keroppi:3121 --after-connect "targets 1" --tcl <path>` to generate the xsdb script, then hand-edit to insert `rst -processor -clear-registers` before the U-Boot `dow` (workaround for an MMU-on-after-FSBL bug — see the PetaLinux Build Lessons section), then `xsdb <path>` to run.
- **Cross-machine wiring:** xsdb on mymelody connects to hw_server on keroppi via `--hw_server-url`. Boot artifacts stream from mymelody over the network through hw_server's JTAG to the board. **No file-copy step to keroppi is required** — the old `copy_to_keroppi.sh` and TFTP-based Yocto boot path are retired.

### Subphase 2a: ADRV9002 + sample stream
1. ✅ ADI reference design build closed (`hdl_2022_r2` branch, `make CMOS_LVDS_N=0` in `projects/adrv9001/zcu102/`, `system_top.xsa` exported with bitstream included).
2. ✅ ADRV9002 driver probes, talks SPI, reports valid firmware (0.22.30) / stream (0.7.11.0) / API (68.13.7).
3. ✅ Full AXI infrastructure enumerates: `cf_axi_adc` (RX), `cf_axi_dds` ×2 (TX1, TX2), `cf_axi_tdd` ×2 (TDD1, TDD2).
4. ⏳ Configure ADRV9002 for 10 MSps complex sample rate, mid-band LO. *(needs TES-generated profile or libiio attribute writes)*
5. ⏳ Verify sample stream lands in PL at expected throughput (ILA + counter check, OR libiio `iio_readdev` capture).
6. ⏳ Custom RFIC profiles for Mode-Dynamic-Transponder frequencies. *(uses ADI's Transceiver Evaluation Software offline to generate)*

### Subphase 2b: PetaLinux Linux on PS
1. ✅ PetaLinux Tools 2022.2 installed on Ubuntu 22.04 (officially unsupported, works with `/bin/sh = /bin/bash`).
2. ✅ Project created (`petalinux-create -t project --template zynqMP --name haifuraiya`).
3. ✅ meta-adi cloned at `2022_R2` branch and added as User Layers via `petalinux-config` menuconfig (slot 0 = meta-adi-core, slot 1 = meta-adi-xilinx).
4. ✅ XSA imported (`petalinux-config --get-hw-description`).
5. ✅ `KERNEL_DTB = "zynqmp-zcu102-rev10-adrv9002"` in `petalinuxbsp.conf`.
6. ✅ `petalinux-build` succeeds (4571 tasks, ADI fork kernel 5.15.36-xilinx-v2022.2).
7. ✅ `petalinux-package --boot --fsbl --fpga --u-boot --force` produces BOOT.BIN.
8. ✅ `petalinux-package --prebuilt --force` populates the prebuilt directory.
9. ✅ JTAG boot to login prompt via `xsdb`. *Originally documented as requiring a `rst -processor -clear-registers` workaround inserted into a hand-edited `/tmp/boot.tcl`; on 2026-05-24 we verified this is vestigial when the ZCU102 is power-cycled before each boot attempt. PetaLinux's unmodified auto-generated boot.tcl works as-is. See the updated "🐉 The big one" entry in the PetaLinux Build Lessons section.*

### Subphase 2c: Bouro v0 (stub) — not started
Just enough scaffolding to validate that the observability path works
end-to-end. Defers the dashboard work until Phase 4 when there's more to
observe.

1. ⏳ Tiny C program that mmaps the channelizer registers, prints to stdout in a loop. **Bonus thanks to Phase 1 Task 7:** since the IP-XACT memory map is encoded, this C program can be auto-generated from `component.xml` via the IP-XACT-to-C tooling. No hand-maintained register address constants needed.
2. ⏳ Wrap in an MQTT publisher (publishes register values to topics like `haifuraiya/channelizer/frame_count`).
3. **No HTML/CSS yet** — that comes when Phase 4 has interesting state worth visualizing.

### Verified signature for "Phase 2 success" (paste-into-doc reference)

```
adrv9002 spi1.0: adrv9002-phy Rev 12.0, Firmware 0.22.30, Stream 0.7.11.0,
                 API version: 68.13.7 successfully initialized
cf_axi_adc 84a00000.axi-adrv9002-rx-lpc:  ADC ADRV9002 as MASTER
cf_axi_dds 84a0a000.axi-adrv9002-tx-lpc:  DDS ADRV9002 (TX1)
cf_axi_dds 84a0c000.axi-adrv9002-tx2-lpc: DDS ADRV9002 (TX2)
cf_axi_tdd 84a0c800.axi-adrv9002-core-tdd1-lpc: CF_AXI_TDD MASTER
cf_axi_tdd 84a0cc00.axi-adrv9002-core-tdd2-lpc: CF_AXI_TDD MASTER
```

### Deliverable
ADRV9002 driver alive, all RX/TX/TDD AXI cores enumerated, Linux user space
booting to login on the four A53 cores from a JTAG-streamed build. **Done.**
What remains for full Phase 2: configure the RFIC profile, capture a first
sample stream, build the Bouro v0 MQTT publisher.

---

## 🛠️ PetaLinux Build Lessons
*Tooling gotchas learned during Phase 2b. Read before bringing PetaLinux up
on any future ZynqMP target.*

### What worked beautifully

- **Cross-machine build + JTAG is a clean architecture.** `petalinux-boot --jtag --hw_server-url TCP:<jtag-host>:3121` lets xsdb on the build host stream binaries through hw_server on the JTAG host to the board. No file-copy step between machines. The old Yocto-era `copy_to_keroppi.sh` and TFTP-orchestration scripts are obsolete and retired.

- **`--tcl` flag to dump the boot script.** `petalinux-boot --jtag ... --tcl /tmp/boot.tcl` generates the xsdb sequence *without running it*. Inspect it, run via `xsdb /tmp/boot.tcl`. Indispensable when the default sequence has a bug for your hardware combination.

- **`--after-connect "<xsdb command>"` flag** is the documented way to inject xsdb commands right after the `connect` step. Useful for JTAG target disambiguation. The bottom of `petalinux-boot --jtag --help` shows the full flag list; the summary `--help` is incomplete.

- **meta-adi as a sibling clone, referenced by absolute path via User Layers menuconfig.** PetaLinux's "User Layers" feature is the documented integration point. No bbappends in `project-spec/meta-user` needed for the ADI BSP itself; meta-adi is self-contained.

### What bit us

- **Pure-Yocto-with-meta-adi-for-ADI-reference-designs is undocumented and breaks.** `meta-xilinx-tools`' PMU/FSBL BSP template (`zynqmp-pmufw`, `zynqmp-fsbl`) hardcodes `axi_intc_0` which ADI XSAs don't include — `do_compile` fails at `bspconfig` time with "No IP instance named axi_intc_0 present in hardware design." `device-tree-xilinx` expects `system-conf.dtsi` which meta-adi doesn't ship. After a day and a half of bbappend patching, we pivoted. **Use PetaLinux Tools for the 2022.2-era stack.** Save yourself the tour.

- **PetaLinux installer needs `--dir` or it scatters files into your home directory.** Always: `./petalinux-v2022.2-10141622-installer.run --dir ~/petalinux/2022.2`.

- **`/bin/sh = dash` on Ubuntu 22.04 silently breaks PetaLinux scripts.** Multiple build steps fail with cryptic errors. Fix: `sudo ln -sf /bin/bash /bin/sh`. PetaLinux's official supported OS list is Ubuntu 18.04 / 20.04, but 22.04 works in practice once this is fixed.

- **Stale `PETALINUX` and friends in shell env from earlier failed installs persist.** Symptom: nonsensical paths like `PETALINUX=/home/abraxas3d/ip_version` show up. Fix: open a fresh terminal *after* the new install completes, before sourcing `settings.sh`.

- **User layers added via direct edit of `project-spec/configs/config` look right but don't fully register.** Layers MUST be added via `petalinux-config` menuconfig → Yocto Settings → User Layers. The menuconfig save triggers additional internal state updates that the hand-edit doesn't. Verify with `grep USER_LAYER project-spec/configs/config` after.

- **Layer order matters.** meta-adi-core first (slot 0), meta-adi-xilinx second (slot 1). Reverse order produces undefined behavior at recipe-parse time.

- **`KERNEL_DTB` selection is required for ADI hardware.** Without `KERNEL_DTB = "zynqmp-zcu102-rev10-adrv9002"` in `petalinuxbsp.conf`, the build uses the default zcu102 device tree and ADRV9002 is invisible to Linux.

- **TFTPBOOT warning at end of build is benign** on a build host without `/tftpboot`. Build still succeeds; artifacts are in `images/linux/`.

- **`petalinux-package --prebuilt --force` is mandatory** before `petalinux-boot --jtag --prebuilt N` works. The prebuilt directory (`pre-built/linux/images/`) is separate from `images/linux/`. Forgetting this produces "fsbl image doesn't exist" with an unhelpful path.

- **ZCU102 multi-FPGA JTAG ambiguity.** ZCU102 enumerates both xczu9eg (target 1, ZynqMP PL) and onboard xc7z020 system controller (target 17). PetaLinux's xsdb doesn't auto-disambiguate. Solution: `--after-connect "targets 1"`. The hw_server `-e "set jtag-port-filter Xilinx"` approach picks the WRONG target (both chips match "Xilinx"); `xczu9eg` filter matches nothing (port name filter ≠ chip name).

- **🐉 The big one: MMU translation fault on `dow u-boot.elf` to DDR 0x8000000.** PetaLinux's generated xsdb script halts FSBL via `after 4000; stop` with the A53 still holding active MMU translation tables that FSBL set up during its 4-second run. The subsequent `dow u-boot.elf` writes through the active MMU and faults because FSBL's tables don't cover 0x8000000. **Original fix:** `--tcl` to dump, insert `rst -processor -clear-registers` between `psu_ps_pl_reset_config` and `dow u-boot.elf`, run via `xsdb` directly. **Update 2026-05-24:** this workaround turned out to be vestigial when the ZCU102 is power-cycled before each `make haifuraiya-boot` invocation. PetaLinux's unmodified auto-generated boot.tcl works as-is on a freshly-reset board — the assumption baked into PetaLinux's generator is "fresh power-on state," which power-cycling restores. The original fault was triggered by re-booting an already-running board where FSBL's MMU tables persisted from the prior boot. Documented for posterity: if you're trying to re-flash without power-cycling, this is what bites. The Open Quest about "automating the rst-processor insertion" is now moot.

- **JTAG board state wedges between failed boot attempts.** Symptoms on retry: "EDITR timeout" on OCM writes, xsdb segfault. Recovery: `rst -system` via a PSU-filtered target (not target 1 — that returns "Invalid reset type"), then restart hw_server if it died, then retry. Physical power-cycle always works as a last resort.

- **`rst -system` on a top-level FPGA target (target 1) returns "Invalid reset type."** Must use a PSU or processor target: `targets -set -nocase -filter {name =~ "*PSU*"}; rst -system`.

- **`rst -system` sometimes kills hw_server.** Watch for "Connection refused" on the next attempt; restart hw_server on the JTAG host if so.

- **xsdb cosmetic core-dump on exit when fed via heredoc** is functionally harmless. The commands completed before the dump. Annoying but ignorable.

- **Shell-to-tcl quote escaping is fragile for `--after-connect` complex filter expressions.** Bash single-quotes preserve inner double-quotes for the shell, but PetaLinux's script processing strips them before they reach xsdb. Use simple `"targets 1"` for index-based selection, or generate the tcl with `--tcl` and edit it directly for anything more complex.

- **`zynqmp_clk_divider_set_rate() set divider failed for spi1_ref_div1, ret = -13`** in dmesg is a benign cosmetic warning. PMUFW manages that clock; the kernel driver retries gracefully, no functional impact on ADRV9002 operation.

- **🐉 `rst -system` is required before every JTAG re-boot attempt.** xsdb's debug target tree accumulates state across boots — running A53 cores from a prior Linux session, renamed targets, etc. Yesterday-successful boot scripts fail today because the board never went through a clean reset. Symptoms when you forget: "Multiple FPGA devices found, please use targets command to select one of: 1, 17" (because the debug target tree restructured and `targets 1` now points to "PS TAP" instead of xczu9eg) or "bitstream is not compatible with the target" (selected an FPGA on the wrong chain). **Original cure:** add a PSU-target `rst -system` as the first step of the boot sequence:
  ```tcl
  connect -url TCP:keroppi:3121
  targets -set -filter {name =~ "*PSU*"}
  rst -system
  after 1000
  # ... rest of the boot sequence
  ```
  This restores the target tree to a clean state where `targets 1` reliably points to the ZynqMP. Bonus: `rst -system` sometimes kills hw_server — restart it on the JTAG host if so. **Update 2026-05-24:** same vestigial-workaround story as the MMU translation fault entry above. Physical power-cycling the ZCU102 between boot attempts produces the same clean-state result without needing to inject xsdb commands. The Makefile target `make haifuraiya-boot` documents the power-cycle prerequisite explicitly. Keep this entry as reference for cases where physical power-cycling isn't available (remote labs, etc.).

- **🐉 `petalinux-config → Subsystem AUTO Hardware Settings → Ethernet Settings` writes a broken `wired.network` for systemd.** Symptom: `ifconfig eth0` on the booted target shows `inet addr:10.73.1.16  Bcast:10.255.255.255  Mask:255.0.0.0` instead of the expected `/24` (`255.255.255.0`). Same-subnet SSH still works (both sides treat each other as local), but cross-subnet routing is broken. **Initial theory was menuconfig defaults; the actual root cause is worse.** PetaLinux's autogenerator for `project-spec/configs/systemd-conf/wired.network` writes the file in a malformed shape:
  ```
  [Network]
  Address=10.73.1.16       ← missing /24 CIDR suffix
  DNS=255.255.255.0         ← the netmask is in the DNS field
  Gateway=10.73.1.1
  ```
  systemd-networkd requires CIDR notation in `Address=` (per the spec — confirmed via ArchWiki and the systemd-networkd manpage); without it, the netmask defaults to `/32` and the address effectively gets a class-A `/8` from the kernel's class-routing fallback. The garbage `DNS=` line is silently ignored. **The parallel `init-ifupdown/interfaces` file is correctly formed** with proper `netmask 255.255.255.0` — only the systemd-networkd autogenerator has the bug, and PetaLinux's systemd subsystem is what actually runs on the ZCU102. **Fix:** hand-edit `project-spec/configs/systemd-conf/wired.network` to use proper CIDR + real DNS:
  ```
  [Network]
  Address=10.73.1.16/24
  Gateway=10.73.1.1
  DNS=8.8.8.8
  DNS=1.1.1.1
  ```
  Caveat: if anyone re-runs `petalinux-config → Ethernet Settings`, PetaLinux's autogenerator will overwrite this file with the malformed form again. The proper long-term fix is a bbappend that locks in the correct format (tracked as Action Item #3). This bug is shared with archinstall and some other static-IP installers (filed against archinstall in October 2024, same class of issue); it does NOT appear to be widely reported as a PetaLinux bug specifically — likely because most PetaLinux users use DHCP and never hit it.

- **🐉 `petalinux-config` bakes ABSOLUTE PATHS into `project-spec/configs/config` AND `.petalinux/metadata`.** Two specific offenders:
  - **User Layer paths.** Adding meta-adi via Yocto Settings → User Layers writes `CONFIG_USER_LAYER_0="/home/<user>/<whatever>/Mode-Dynamic-Transponder/haifuraiya/third_party/meta-adi/meta-adi-core"` (literal absolute path) into `project-spec/configs/config`. Committing this breaks for anyone cloning the repo to a different directory.
  - **HARDWARE_PATH.** `petalinux-config --get-hw-description=<xsa-path>` writes that absolute path into `.petalinux/metadata` (which IS tracked, via explicit un-ignore in `.gitignore`). Only consulted when re-importing hardware, but still a `/home/<user>/...` reference in a committed file.

  `petalinux-config` does not support relative paths, environment variables, or any token substitution — the paths it writes are literal strings. The fix we converged on for MDT: a setup script `haifuraiya/petalinux/scripts/setup-petalinux.sh` that derives the repo root from its own filesystem location and rewrites both files in place; a top-level `Makefile` that wraps it (`make haifuraiya-configure`, `make haifuraiya-build`, `make haifuraiya-revert-paths`); and **sentinel placeholder paths** (`/PLEASE_RUN_make_haifuraiya-configure_FIRST/...`) in the committed files that fail loudly with a self-explanatory error if anyone bypasses the Makefile. See the "Repository Portability" subsection below for the full architecture.
  
  - **🐉 bitbake silently deduplicates layers by `BBFILE_COLLECTIONS` name.** Two different layer directories that declare the same `BBFILE_COLLECTIONS += "<name>"` in their respective `conf/layer.conf` will both appear in `bblayers.conf` (no error, no warning), but bitbake will register the collection ONCE and load recipes/bbappends from only one of them — typically the first one encountered, NOT the one you most recently added. The other layer's files are silently ignored. We hit this on 2026-05-24 when a stale `/home/abraxas3d/yocto/haifuraiya/sources/meta-ori/` left over from an abandoned pure-Yocto experiment was loaded INSTEAD of our in-tree `haifuraiya/yocto/meta-ori/`, despite both paths appearing in the active `build/conf/bblayers.conf`. Every edit we made to the in-tree bbappend was invisible to the build because bitbake was reading the stale copy. **Diagnostic:** run `bitbake-layers show-layers` and compare the paths shown to what's in `build/conf/bblayers.conf`. If a layer with the same name appears in `show-layers` from a path that's NOT in your bblayers.conf, you have a duplicate collection somewhere. **Cure:** find and delete (or rename) the duplicate. Clear `build/cache/` after to force bitbake to re-scan layers. **Why this is mean:** the deduplication is silent — no log message, no warning, no hint in `bitbake -e` that there's a conflict. The first time you'll notice is when your bbappend edits don't take effect, and you'll spend hours debugging the bbappend before suspecting layer enumeration. This footgun is filed against the bitbake project as a long-standing UX issue; it has not been addressed in the Honister / Kirkstone era. Defensive practice: keep your layer paths CLEAN. One layer name = one layer directory anywhere on the build host.

- **`petalinux-config → Subsystem AUTO Hardware Settings → Ethernet Settings` ALSO defaults netmask to `/8` in menuconfig.** The netmask field exists but defaults to `255.0.0.0` instead of asking. Setting it to `255.255.255.0` makes `init-ifupdown/interfaces` correct but does NOT fix `wired.network` (see above). The menuconfig default is a minor pitfall on top of the bigger systemd-networkd bug.

- **🐉 Dropbear's default `-w` flag blocks root SSH.** PetaLinux ships `/etc/default/dropbear` with `DROPBEAR_EXTRA_ARGS="-w"` (the comment in the file says "Disallow root logins by default"). Console login as root works fine; SSH as root returns "Permission denied" even with the right password. **Immediate fix on the target** (doesn't survive reboot, since rootfs reloads from JTAG initramfs each boot):
  ```bash
  sed -i 's/DROPBEAR_EXTRA_ARGS="-w"/DROPBEAR_EXTRA_ARGS=""/' /etc/default/dropbear
  systemctl restart dropbear.socket
  killall dropbear 2>/dev/null
  ```
  **RESOLVED 2026-05-24:** the permanent fix took the "replace dropbear with openssh" route. The switch is at the rootfs_config layer, not via a dropbear-recipe bbappend: flip both `CONFIG_packagegroup-core-ssh-dropbear` AND `CONFIG_imagefeature-ssh-server-dropbear` to "is not set", flip `CONFIG_imagefeature-ssh-server-openssh=y`. Flipping only one of the two leaves the dependency chain intact and dnf fails at do_rootfs with a dropbear-vs-openssh package conflict. `coreutils` was added to IMAGE_INSTALL in the same change (provides `timeout` and other common commands missing from PetaLinux's BusyBox subset). meta-adi-xilinx hardcodes root password `analog`; per-developer authorized_keys + disabled password login is filed as Phase 5+ work.

- **🐉 ADI HDL library Makefiles race in parallel builds** The library Makefile at third_party/hdl/library/Makefile recurses into each IP subdirectory, but inter-IP dependencies (like axi_ad7606x → util_cdc, axi_spi_engine → util_axis_fifo) are not declared at the parent level. Running make -j N produces "No rule to make target '../X/component.xml'" errors when a dependent library checks for a prereq before the prereq has finished generating its component.xml. Cure: sequential build (make without -j). Takes 30-60 minutes for the full library. Why this is mean: the partial parallel build still completes some IPs successfully, so the error makes it look like a real dependency problem in your project — not a race in ADI's makefile. The fix is in the build system, not your code.

### Workflow recipe (for the next ZynqMP PetaLinux project)

```
# 1. Ensure /bin/sh is bash
sudo ln -sf /bin/bash /bin/sh

# 2. Install PetaLinux Tools (always --dir)
./petalinux-v2022.2-installer.run --dir ~/petalinux/2022.2

# 3. Fresh terminal, then source
source ~/petalinux/2022.2/settings.sh

# 4. Vivado HDL build for the XSA (separately, in its own sourced env)
source /tools/Xilinx/Vivado/2022.2/settings64.sh
# ... clone ADI hdl repo, checkout matching branch, make
# ... open in Vivado, export hardware with bitstream

# 5. PetaLinux project create + meta-adi
petalinux-create -t project --template zynqMP --name <PROJECT_NAME>
cd <PROJECT_NAME>
git clone -b 2022_R2 https://github.com/analogdevicesinc/meta-adi.git ../meta-adi

# 6. Import XSA, then add meta-adi via menuconfig
petalinux-config --get-hw-description=<path-to-xsa>
# In menuconfig: Yocto Settings → User Layers → add meta-adi-core (0), meta-adi-xilinx (1)

# 7. Set KERNEL_DTB
echo 'KERNEL_DTB = "<adi-dtb-name>"' >> project-spec/meta-user/conf/petalinuxbsp.conf

# 8. (Optional but recommended) Set static IP in Subsystem AUTO Hardware Settings → Ethernet
#    Critically: set BOTH IP address AND netmask. The menuconfig defaults netmask to 255.0.0.0 (/8)
#    which works for same-subnet SSH but breaks cross-subnet routing. Set netmask to 255.255.255.0.

# 9. Build + package
petalinux-build
petalinux-package --boot --fsbl --fpga --u-boot --force
petalinux-package --prebuilt --force

# 10. JTAG boot: generate, edit, run
petalinux-boot --jtag --prebuilt 3 --hw_server-url TCP:<jtag-host>:3121 \
               --after-connect "targets 1" --tcl /tmp/boot.tcl
xsdb /tmp/boot.tcl

# 11. Monitor serial console on the JTAG host in parallel:
# (on JTAG host) screen /dev/zcu102_uart1 115200
```

### Repository Portability

*The PetaLinux project's committed config files contain absolute paths
that `petalinux-config` writes. Without intervention, the repo is only
buildable by the person who ran `petalinux-config` (because their home
directory path is baked into the config). The MDT repo solves this with
a setup script + Makefile + sentinel placeholder paths. Architecture
captured here so the pattern can be repeated for future ORI projects
that wrap PetaLinux.*

**The problem (two committed files with hardcoded absolute paths):**

- `haifuraiya/petalinux/haifuraiya/project-spec/configs/config` — lines `CONFIG_USER_LAYER_0` and `CONFIG_USER_LAYER_1` hold absolute paths to the meta-adi-core and meta-adi-xilinx layers.
- `haifuraiya/petalinux/haifuraiya/.petalinux/metadata` — line `HARDWARE_PATH` holds the absolute path to the XSA used at last hardware import. This file is explicitly tracked (`!.petalinux/metadata` in `.gitignore`).

**The architecture:**

- **Sentinel paths in the committed files.** Instead of any specific user's paths, the committed files have placeholder paths:
  ```
  CONFIG_USER_LAYER_0="/PLEASE_RUN_make_haifuraiya-configure_FIRST/meta-adi-core"
  CONFIG_USER_LAYER_1="/PLEASE_RUN_make_haifuraiya-configure_FIRST/meta-adi-xilinx"
  HARDWARE_PATH=/PLEASE_RUN_make_haifuraiya-configure_FIRST/system_top.xsa
  ```
  Anyone who tries to `petalinux-build` without running setup first gets a path-doesn't-exist error that LITERALLY reads "PLEASE RUN make haifuraiya-configure FIRST". Self-curing failure mode.

- **Setup script `haifuraiya/petalinux/scripts/setup-petalinux.sh`.** Resolves its own filesystem location via `${BASH_SOURCE[0]}` and derives the MDT repo root three directories up. Computes the correct absolute paths for the local clone. Rewrites both files in place via `sed -i`. Idempotent — safe to re-run after every `petalinux-config` edit (which would otherwise re-bake the user's local paths into the committed config). Includes a GNU sed precondition check at the top — fails cleanly on macOS with a message pointing at this document, since PetaLinux Tools is Linux-only.

- **Top-level `Makefile` at MDT repo root.** Project-specific targets dispatch to the right places:
  - `make haifuraiya-configure` — runs the setup script
  - `make haifuraiya-build` — configure → `petalinux-build` → `petalinux-package --boot` → `petalinux-package --prebuilt`, then prints the SD card artifact paths
  - `make haifuraiya-boot` — currently prints the manual JTAG boot recipe with `rst -system` + `rst -processor` edits (full automation is Action Item #7)
  - `make haifuraiya-clean` — wipes `build/`, `images/`, `pre-built/`
  - `make haifuraiya-revert-paths` — restores both files to sentinel form. Run before `git commit` if the workflow has ever touched `petalinux-config`.

  Targets are prefixed `haifuraiya-` because the MDT repo contains two parallel projects (haifuraiya and mdt_sic) that don't share a bitstream.

- **Workflow for a fresh clone (regardless of directory name):**
  ```bash
  git clone https://github.com/OpenResearchInstitute/Mode-Dynamic-Transponder.git
  cd Mode-Dynamic-Transponder
  git submodule update --init --recursive
  make haifuraiya-build
  ```
  Works whether the user cloned to `/MDT/`, `/orange/`, `/the-fellowship-of-the-channelizer/`, or anywhere else.

- **Workflow for someone editing the PetaLinux config:**
  ```bash
  cd haifuraiya/petalinux/haifuraiya
  petalinux-config        # makes intentional edits — but ALSO re-bakes local paths
  cd <repo root>
  make haifuraiya-configure    # re-rewrites paths (idempotent)
  # ... build / test ...
  make haifuraiya-revert-paths # before commit, to restore sentinel form
  git commit ...
  ```

**Lessons for future ORI PetaLinux projects:**

- `petalinux-config` is a one-way path-baking machine. If you commit `project-spec/configs/config` and `.petalinux/metadata` as-is, your repo only works for you. Solve this on the first commit, not the tenth.
- Sentinel paths (`/PLEASE_RUN_<thing>_FIRST/...`) are better than empty strings or user-specific paths. Empty strings silently miss meta-adi at build time (very confusing); user-specific paths fail for everyone else; sentinels fail for everyone identically with instructions baked into the path itself.
- The setup script must be idempotent. Anyone running `petalinux-config` will re-bake their local paths into the committed files. The setup script must be the natural way to "fix it again."
- A Makefile wrapper composes well with the JTAG boot automation that will eventually exist (Action #7). The user-facing command stays `make haifuraiya-build` regardless of how many internal steps grow under it.
- **Track the git executable bit on shell scripts deliberately.** `git update-index --chmod=+x <script>` is the recipe; verify with `git ls-files -s <script>` showing `100755`. Discovered when a fresh-cloner couldn't invoke `make haifuraiya-build` because the setup script came down without executable permission. Fixed via the explicit chmod commit; lesson captured here so it isn't rediscovered next project.

### Hardware Regeneration Workflow

*When RTL, IP-XACT packaging, or the block design changes, the XSA must
be rebuilt in Vivado and re-imported into PetaLinux before the new
hardware appears in the booted image. The Makefile has four targets that
chain this cleanly. Documented here so the canonical path is obvious to
anyone (including future-self) coming back after weeks away.*

**The four-step regeneration chain:**

```bash
# 1. Edit RTL / IP-XACT / system_bd.tcl
#    ... your changes ...

# 2. Rebuild XSA (Vivado batch, ~5 hours)
make haifuraiya-xsa

# 3. Re-import XSA into PetaLinux project
#    Updates project-spec/hw-description/ and HARDWARE_CHECKSUM
make haifuraiya-import-xsa

# 4. Build PetaLinux image with the new hardware
make haifuraiya-build
```

**Why these are separate, not chained:**

- **`haifuraiya-xsa` requires Vivado on PATH (~5 hour blocker).** Forcing it as a dependency of `haifuraiya-build` would make every PetaLinux iteration a half-day operation. Most PetaLinux changes (kernel config, rootfs packages, etc.) don't need a fresh XSA.
- **`haifuraiya-import-xsa` is destructive in subtle ways.** It overwrites the cached `project-spec/hw-description/` and updates `HARDWARE_CHECKSUM` in `.petalinux/metadata`. Should be an explicit "yes I want this" step, not implicit.
- **`haifuraiya-build` works WITHOUT Vivado** for anyone who hasn't changed hardware. The cached hw-description in `project-spec/hw-description/` is committed and self-sufficient. Verified by Paul (KB5MU)'s fresh-clone test on mymelody.

**Precondition checks built into the targets:**

- `haifuraiya-check-vivado` — verifies `vivado` is on PATH; if not, prints exact `source /tools/Xilinx/Vivado/2022.2/settings64.sh` instruction. Dependency of `haifuraiya-xsa`.
- `haifuraiya-check-env` — verifies `petalinux-build` is on PATH; if not, prints exact `source ~/petalinux/2022.2/settings.sh` instruction. Dependency of `haifuraiya-build` and `haifuraiya-import-xsa`.

Both checks fail fast with actionable error messages. They were added in response to Paul's fresh-eyes test, where the original Makefile silently invoked `petalinux-build` and failed cryptically when PetaLinux Tools hadn't been sourced.

**Where this will evolve (Phase 3 and beyond):**

The current `haifuraiya-xsa` target invokes the upstream ADI reference design `make` directly. When the Haifuraiya channelizer IP needs to be inserted into the block design (Phase 3 / 4), this target will need to grow — see Open Quest #16 for the three architectural options under consideration. The expected outcome is that the user-facing four-step recipe above stays unchanged; only the internals of `haifuraiya-xsa` evolve.

### Cross-cutting lessons

- **Don't fight the documented happy path of your stack era.** PetaLinux is officially deprecated, but for hdl_2022_r2 / meta-adi 2022_R2 it's what ADI's documentation assumes and what works. The pure-Yocto-with-gen-machine-conf flow is the future, but it targets Vivado 2024.x and a newer meta-adi.
- **Cross-machine build + JTAG separations is sustainable** if the JTAG host runs hw_server and exposes it via TCP. No file-copy script needed. Cleaner than the old Yocto-era TFTP plumbing.
- **PetaLinux's generated xsdb script is editable and inspectable.** When it has a bug for your hardware combination, `--tcl` dump + hand-edit + run-directly is a legitimate engineering workflow, not a hack. Document the edit; consider automating it eventually.
- **JTAG boot is comfortable for verification, painful for routine iteration.** ~10 minutes per boot streaming everything via JTAG. For the iterate-on-userspace workflow, set up TFTP for kernel/initramfs delivery via Ethernet (post-bring-up infrastructure task).

---

## 🎯 Phase 3: First Light
**🟡 Task 1 done (integration). Tasks 2-5 blocked on the same ADRV9002 profile/cal/arm sequence as Phase 2a tasks 4-6 — once samples are flowing, those four tasks become a contained Python/Octave + Pluto exercise.**

### Goal
See the channelizer working on real RF samples for the first time.

### Tasks
1. ✅ Build the integration block design: ADRV9002 RX → channelizer IP (from Phase 1) → AXI-DMA → PS DDR. **Note: the Phase 1 IP is already smoke-tested in a BD, so this step is shorter than it would have been.** *Done 2026-05-23 (Builds 9-12 in `system_bd.tcl` Phase A+B overrides — RX1 datapath spliced; RX2/TX1/TX2 preserved as ADI baseline). Build 12 produced a working bitstream + XSA with -188 ps WNS on the FIR MAC chain (`system_top_bad_timing.xsa`, ran reliably at room temp). **Timing CLOSED 2026-05-27 via the quarter-MAC split (commit `6ffc273`, "Cast HASTE"): each branch MAC partitioned into four registered 6-tap quarter-MACs so the DSP cascade fits one column — `clk_pl_0` WNS -0.188 → +0.341 ns, clean `system_top.xsa`, rebuilt and rebooted from the green clone; channelizer answers at 0x84A70000 (devmem version 1.0).** PetaLinux boots, channelizer AXI-Lite responds at 0x84A70000, IIO devices enumerate. **2026-05-27: channelizer confirmed receiving frames from the ADRV9002** (Bouro reports moving `frame_count/delta` through profile reloads). Frames carry `DEFAULT-PROFILE BINARY` zero samples pre-calibration; real ADC samples gated on the `liboriinit` 1T1R patch.*
2. ⏳ PS-side capture program (Python/Octave) reads buffer, FFTs each channel, plots spectrum
3. ⏳ Inject known CW from Pluto + Interlocutor at various frequency offsets within the 10 MHz uplink band
4. ⏳ Verify peak appears in the expected channel bin
5. ⏳ Sweep frequency to walk through all 64 bins; verify channel boundaries

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

## 🎤 Phase 4: Single-Channel OPV End-to-End + Bouro Dashboard

### Goal
Recover one real OPV transmission, all the way from RF to decoded
voice/data. Build out Bouro's HTML/CSS layer now that there's interesting
state worth visualizing.

### Subphase 4a: Single-channel OPV recovery
1. Pick one channel (whichever has the cleanest test signal)
2. Wire AXIS DMA on just that channel index into a PS buffer
3. Feed buffer into `opv-cxx-demod`
4. Pluto + Interlocutor transmits one OPV signal at the target frequency
5. Confirm: frame sync acquires, FEC decodes, payload bits come out, voice plays
6. Measure: uplink-to-decoded-voice latency baseline

### Subphase 4b: Bouro dashboard
With Bouro v0's MQTT scaffolding from Phase 2 already in place, this is
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
with 64. And Bouro's dashboard becomes the natural debugging surface
for the multi-channel work in Phase 5.

### Deliverable
One OPV stream recovered end-to-end. Baseline latency and BER numbers.
Live Bouro dashboard showing channelizer + demod state.

---

## Phase 5 Pre-Requisite: Scaling Worksheet for going from 1 to 64 channels

## RX scaling: 1 → 64 channels is DSP-bound — Option B (TDM) selected

**Status:** Decided 2026-06-12 on measured placed-design utilization. The
*device-fit* conclusion (Option A doesn't fit, Option B does) is **MEASURED** —
it follows directly from the channelizer's DSP count and the device's DSP
budget. The *per-channel state size* for Option B is still an **ESTIMATE**
pending an RTL audit (see Open Items).

### Provenance (measurement authority)

- Report: `system_top_utilization_placed.rpt` (`report_utilization`, design state *Fully Placed*)
- Tool / device: Vivado 2022.2, `xczu9eg-ffvb1156-2-e` (ZCU102), speed `-2`
- Build under test: 1-channel RX, `TARGET_CHANNEL=0`, `CMOS_LVDS_N=0`, `ila_rx_demod` present
- Per-block split read from the Vivado *hierarchical* utilization view of the same placed design

Device resources available: **274,080** LUT · **548,160** Reg · **2,520** DSP · **912** BRAM tiles.

### MEASURED — current 1-channel build

Top-level (`system_top`):

| Resource | Used | Avail | Util% |
|---|---|---|---|
| CLB LUTs | 138,022 | 274,080 | 50.4 |
| CLB Registers | 148,571 | 548,160 | 27.1 |
| DSPs | **1,592** | 2,520 | **63.2** |
| BRAM tiles | 34 | 912 | 3.7 |

Per-block (the blocks that drive the scaling math):

| Block | LUT | Reg | DSP | BRAM | Note |
|---|---|---|---|---|---|
| `u_chan` (channelizer + R2SDF FFT) | 96,654 | 107,376 | **1,556** | 0 | **shared** — produces all 64 channels regardless of demod count |
| `u_demod` (one MSK demod) | 2,307 | 1,211 | 24 | 0 | `U_f1` / `U_f2` = 10 DSP each + 4 |
| `u_fsync` (frame-sync detector) | 632 | 515 | 0 | 0.5 | |
| **per-channel unit (demod + fsync)** | **2,939** | **1,726** | **24** | **0.5** | the replicable cost |
| `ila_rx_demod` (debug) | 2,762 | 4,088 | 0 | 29.5 | reclaimable for flight |
| `axi_adrv9001` (infra) | 17,128 | 23,658 | 12 | 0 | |

DSP accounting checks out: 1,556 (`u_chan`) + 24 (`u_demod`) = 1,580 (`channelizer_rx1`); + 12 (`axi_adrv9001`) ≈ 1,592 (top).

### DERIVED — 64-channel projection (from the measured per-channel unit)

The whole decision turns on one **measured** number: the channelizer costs
**1,556 DSPs (62% of the device)**, paid once. That leaves **964 DSPs** for demods.

**Option A — 64 parallel demods**

| Resource | Projection | vs device |
|---|---|---|
| DSP | 1,556 + 64×24 + ~16 infra ≈ **3,104** | 2,520 → **123%, over by ~580** |
| LUT | 96,654 + 64×2,939 + ~23k infra ≈ **~308k** | 274,080 → ~113%, over |

- **Max channels before the DSP wall = ⌊964 / 24⌋ = 39.** (MEASURED-derived hard ceiling.)
- **Verdict: INFEASIBLE for 64.** Not a placement/tuning problem — the silicon
  cannot hold 64 parallel demods. Caps at ~39 channels, and LUTs bust too.

**Option B — TDM: one demod, 64 channel-indexed state contexts**

| Resource | Projection | vs device |
|---|---|---|
| DSP | ~1,592 (arithmetic time-shared, unchanged from today) | 2,520 → ~63%, **fits** |
| State (64 contexts) | ESTIMATE — upper bound 64×1,726 ≈ 110k Reg if kept in flops, or a few BRAM tiles | 548k Reg / 912 BRAM → fits with margin |
| LUT | base + modest context addressing/mux growth | fits |

- **Verdict: FITS, and is the only route to full 64-channel coverage.** Cost is
  *redesign complexity* (save/restore demod context per channel as the stream
  cycles), not silicon. Natural fit: the channelizer already emits the 64
  channels time-multiplexed by TDEST.

### Decision

**Adopt Option B (TDM demod with channel-indexed state).** Forced by the
measured 1,556-DSP channelizer: time-sharing the DSP-heavy arithmetic is
mandatory, parallel replication is impossible. Single-channel
(`TARGET_CHANNEL=0`) remains the correct first milestone; 64-channel is the
demod redesign that follows, not a wiring change.

### Open items (ESTIMATES to confirm — do not treat as measured)

1. **Cycle budget for TDM.** Aggregate channelized rate ≈ 64 × 625 ksps =
   40 Msps against the fabric clock; need ⌈cycles-per-channel-sample⌉ to confirm
   one demod can service all 64 in time. Headroom *looks* large but is unmeasured.
2. **Actual per-channel state size.** 1,726 Reg is the *whole demod's* register
   count — an upper bound, not the state to replicate. The real context is only
   the stateful subset (NCO phase accumulator, loop-filter integrators, symbol
   timing, lock-detect counters, frame-sync correlator window); pipeline/staging
   registers do not replicate. Size it by RTL audit before committing the Reg/BRAM
   estimate.
3. **Flight vs dev footprint.** Removing `ila_rx_demod` reclaims 2,762 LUT + 29.5 BRAM.

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

## ⚡ Immediate Action Items
*Things that should happen in the next session or two, before we move on to
the next strategic chunk. Numbered for ordering; all are near-term.*

1. **Clean-clone-rebuild test (now concrete).** The portability tooling is in place; what's left is end-to-end verification on a truly fresh clone in a different directory.
   ```bash
   cd /tmp                          # or any directory other than /brown/, /fuschia/, etc.
   git clone https://github.com/OpenResearchInstitute/Mode-Dynamic-Transponder.git verify-clone
   cd verify-clone
   git submodule update --init --recursive
   # Verify sentinel paths are present in committed state
   grep CONFIG_USER_LAYER_ haifuraiya/petalinux/haifuraiya/project-spec/configs/config
   grep HARDWARE_PATH      haifuraiya/petalinux/haifuraiya/.petalinux/metadata
   # Now build (this also tests that `make haifuraiya-configure` rewrites paths correctly)
   make haifuraiya-build
   # Then JTAG boot via the printed manual recipe
   ```
   Pass criteria: build completes, BOOT.BIN and image.ub appear in `images/linux/`, JTAG boot reaches login, ADRV9002 enumerates. Catches any remaining "this only works because of files in my current clone" issues. Action #10 (path-portability fix) and Action #2 (commit everything) are preconditions; both ✅ done.

2. **Commit everything. ✅ DONE.** The PetaLinux project metadata (`project-spec/configs/config`, `project-spec/meta-user/conf/petalinuxbsp.conf`, custom systemd `wired.network`) is committed. `.gitignore` excludes build artifacts (`components/yocto/`, `images/`, `build/`, `pre-built/`, `.petalinux/*` except `metadata`). meta-adi is a pinned submodule at branch `2022_R2`. Yocto-era work is archived under `haifuraiya/yocto/`. See "Repository Portability" subsection in PetaLinux Build Lessons for the portability machinery.

3a. **wired.network source-tree corruption** — gitignored. ✅ DONE. The file is no longer tracked; PetaLinux's autogenerator can overwrite it without creating git churn. See commit <sha> ("Cast SILENCE — gitignore PetaLinux's auto-corrupted wired.network"). Runtime networking is handled by meta-ori's 10-eth0.network which alphabetically wins over wired.network in /etc/systemd/network/.
3b. **Remove wired.network from the rootfs** entirely (still open). The bbappend or ROOTFS_POSTPROCESS hook that deletes /etc/systemd/network/wired.network from the image — eliminating the alphabetical-ordering dependency — wasn't implemented. The current state works because of ordering luck; future systemd-networkd version updates or interface renames could change the precedence. Low priority while 10-eth0.network's [Match] is solid; promote to medium priority if the network plumbing is ever touched again.

4. **First libiio smoke test.** From the booted target:
   ```
   iio_info | grep -A 5 adrv9002
   iio_attr -a -c adrv9002-phy
   ```
   Confirm RX/TX channels enumerate with reasonable attribute trees. This is the gate from "Linux works" to "SDR is actually accessible." Closes the remaining piece of Subphase 2a.

5. **First captured sample stream.** `iio_readdev` or a small pyadi-iio script to capture I/Q samples from the ADRV9002 at a known frequency, plot the spectrum, sanity-check. Closes Subphase 2a fully.

6. **Set up TFTP fast-iteration path.** `--prebuilt 2` + U-Boot TFTP from `keroppi:/tftpboot/abraxas3d-haifuraiya/` brings boot times from ~10 minutes (everything-via-JTAG) to ~30 seconds. Required for routine dev iteration. Trimmed copy_to_keroppi.sh (or a new ship_to_tftp.sh) handles the kernel/dtb/initramfs deployment to keroppi after each build.

7. **Investigate automating the rst-processor injection.** Either a `petalinux-boot` flag or env var we haven't found, or a small wrapper script (`pl-boot.sh`) that runs `petalinux-boot --tcl`, sed-injects the line, and runs `xsdb`. Wrapper is the obvious fallback. Either way, document the rationale.

8. **Update the Open Research Institute Remote Labs FPGA documentation.** ✅ done tonight — the existing zcu102+ADRV9002+PetaLinux section was replaced with the verified recipe.

9. **Make SSH access permanent across rebuilds.** Tonight's quick fix (`sed -i 's/-w//' /etc/default/dropbear`) lives in JTAG-loaded initramfs and dies on the next boot. Two options:
   - **Quick:** bbappend in `project-spec/meta-user/recipes-core/dropbear/dropbear_%.bbappend` that overrides `/etc/default/dropbear` to drop the `-w` flag.
   - **Proper:** swap dropbear out for `openssh-server`, configure `sshd_config` with key-based auth, set up per-user authorized_keys for each developer who needs access. This is the correct remote-lab posture — password auth in a multi-developer environment is fragile.

   Until either is done, every JTAG boot requires the manual `sed` fix on the target before SSH works. Should be addressed as part of the systemd-networkd port (Action #3) since both touch project-spec/meta-user/recipes-core/.

10. **Repository portability. ✅ DONE.** `petalinux-config` was writing user-specific absolute paths into committed files (`CONFIG_USER_LAYER_*` in `project-spec/configs/config`, `HARDWARE_PATH` in `.petalinux/metadata`), making the repo unbuildable for anyone cloning to a different directory. Resolved via setup script + top-level Makefile + sentinel placeholder paths. See "Repository Portability" subsection in PetaLinux Build Lessons.

11. **Optional: add ARCHIVED marker to `haifuraiya/yocto/`.** The Yocto-era scripts and recipes in `haifuraiya/yocto/` (including `copy_to_keroppi.sh`, `make_boot_scr.sh`, `meta-ori/`) reference Michelle's `/brown/` lab paths and the abandoned pure-Yocto approach. Anyone following them would be doing the wrong thing. A top-level `haifuraiya/yocto/README.md` (or banner in the existing one) saying "ARCHIVED — Yocto approach abandoned in favor of PetaLinux Tools; see plan-of-attack" would prevent confusion. Low priority; not blocking anything.

---



## 📜 Open Quests
*Decisions / clarifications to resolve before or early in next session*

1. ✅ **ADRV9002 reference design state — RESOLVED.** ADI `adrv9001/zcu102` reference design from `hdl_2022_r2` builds and runs cleanly. ADRV9002 driver probes successfully, reports valid firmware/stream/API versions. Sample stream not yet captured but the chip is alive.

2. ✅ **PS Linux state — RESOLVED via strategic shift.** PetaLinux Tools 2022.2 with meta-adi 2022_R2 builds and boots cleanly. Yocto/EDF was attempted first and abandoned due to undocumented incompatibilities with ADI reference designs in the 2022.2 stack era. PetaLinux is the documented happy path for this stack.

3. **AXIS output topology.** TDEST channel index (one channel per beat, ~40 MSps total throughput at 100 MHz) — recommended. Or wide TDATA (all 64 channels per beat, needs wide DMA)?

4. **Per-channel enable mask.** Do we want runtime enable/disable of channels (saves DMA bandwidth, lets us focus A53 capacity on active channels), or always stream all 64 and filter in software?

5. **Sample rate at ADRV9002.** Run native at 10 MSps if its profile supports it cleanly, or run higher and decimate in PL? Easier to run native if possible.

6. **opv-cxx-demod license.** Confirm it's MIT/Apache/BSD-style so it integrates cleanly with the CERN-OHL-licensed RTL components.

7. **Manifest PDU format spec.** Once Phase 5 starts, the contents and cadence of the manifest PDU is a design decision worth getting right early — it directly determines what receiver apps can show. Worth a brief design doc of its own.

8. **Time horizon.** "Lab demo in N months" vs "deployable Phase 4 Ground station" — affects polish on intermediate steps. **Hard date in sight: Friedrichshafen HAM RADIO 2026 (June).** With Phase 1 done and Phase 2b done, demo prep for Friedrichshafen is now realistic. (Quest #12 sharpens this.)

9. **Receiver software for demo.** Will ORI publish a reference receiver to go with this, or rely on GNU Radio flowgraphs for early demos? Pivotal for the "fun and rewarding" goal.

10. **Upstream PR merge timing.** Both lowpass_ema PRs (`fix/data-ena-gate` and `fix/sum-saturation`) sit with Matthew. If they merge before Friedrichshafen, we revert the submodule to upstream main; if not, we ship from `ori/integration`. Either is fine, but worth tracking.

11. **IP-XACT versioning policy.** v0.1 ships with broad family compatibility (zynquplus + kintexuplus + virtexuplus + others). Should we narrow to just zynquplus for v0.2 since that's the only family we've actually tested on? Or keep broad on the theory that other UltraScale+ families will work without intervention?

12. **First Friedrichshafen-targeted deliverable.** Now that Phase 1 + Phase 2b are done: what's the most compelling single thing to demo? Live channelizer + spectrum view on a laptop hooked up to the ZCU102 + ADRV9002 receiving real signals? Single OPV recovery (Phase 4a) over the air? A two-board loop showing transponder behavior? Worth choosing in the next session or two to focus the next month or two of work.

13. **Automating the rst-processor injection in `petalinux-boot --jtag`.** Is there a documented PetaLinux flag, env var, or `.bbappend` that does this cleanly? If not, a small wrapper script is the obvious workaround. Worth ~30 minutes of investigation before committing to the wrapper. *(Tracked as Action Item #7.)*

14. **QSPI boot path.** ZCU102 has 128 MB QSPI flash (mt25qu512a, enumerated cleanly in dmesg with the standard 4-partition layout). One-time flash of BOOT.BIN to QSPI would let the board boot autonomously on power-up, no JTAG, no SD card. Useful for unattended remote-lab operation. Investigate after demo prep stabilizes.

15. **Complex `--after-connect` filter quoting.** If we need name-filter target selection (more robust to JTAG target renumbering across xsdb sessions), how do we cleanly pass `targets -set -filter {name =~ "xczu9eg*"}` through the shell-to-tcl chain? Pertinent if/when we encounter target index renumbering during routine use.

16. **🐉 Inserting Haifuraiya IP into the ADI reference block design.** Phase 3 requires integrating the Haifuraiya channelizer IP (the IP-XACT package from Phase 1) into the existing ADI `adrv9001/zcu102` reference design. The current `haifuraiya-xsa` target just invokes the upstream ADI `make`; it doesn't add our IP. Three architectural options to investigate before committing to a path:

    - **Option A: Patch the upstream `system_bd.tcl` in-place before invoking `make`.** Apply a sed/patch to insert Haifuraiya IP instantiation, then run Vivado batch. Simple but fragile — if upstream changes structure (e.g., on a future `hdl_2023_r2` bump), the patch breaks silently or noisily. Easy to demo, hard to maintain.

    - **Option B: Custom `system_haifuraiya_bd.tcl` that wraps or extends the ADI one.** Depends on whether ADI's upstream Makefile offers a hook (environment variable, "sourced after" convention) for downstream extensions. If such a hook exists, this is the cleanest answer — we own a small file, upstream owns the rest, and bumps work without modification. Need to read the ADI Makefile and any `bd.tcl` files in `hdl/projects/adrv9001/zcu102/` to find out.

    - **Option C: Custom Haifuraiya Vivado project outside the hdl submodule entirely.** Reuse ADI's IP cores via `add_repo_path $hdl_repo/library` but build a project we fully control in `haifuraiya/syn/zcu102/` (where we already have our XDC and synth/impl tcl scripts from Phase 1). Most isolation, most upfront work, most independence from upstream churn. Probably the right long-term answer if Phase 3 reveals we need to do nontrivial topology surgery on the reference design.

    The decision affects how `haifuraiya-xsa` evolves. Decision criteria: (a) does upstream offer a hook for B?, (b) how much does Phase 3 need to modify topology vs just add a tap point?, (c) how stable do we expect the ADI reference design to be across hdl_2022_r2 → future revisions?. Worth ~1-2 hours of investigation early in Phase 3 before committing to a path.

17. **Channelizer soft_reset is incomplete** Pulsing control[0] clears frame_count and dropped_frames but NOT the status sticky bits (overflow, backpressure). Suggests partial reset fanout in HDL. Add soft_reset to the FF clear path for both sticky bits in fsm_proc (or equivalent).

18. **Backpressure_sticky W1C path may be missing or saturating** Writing 0x06 to status[2:1] cleared overflow but left backpressure asserted. Test (next session) by writing 0x04 alone with no userspace consumer attached; if it stays set, W1C isn't wired. If it briefly clears then re-asserts, the bit is fine and the backpressure is structural (no DMA consumer).

19. **ADRV9002 default state saturates I/Q briefly at startup** Without explicit profile load + calibration, the front-end's startup transient pushes samples to ±32767 long enough to trip overflow_sticky. Not a bug per se but worth documenting so future "spectrum looks saturated" observations don't waste debugging time.

20. **ADRV9002 TES profile generation is an ADI ecosystem trap** TES is published only for the most-recent linux/driver versions, which don't match our PetaLinux 2022.2 build. ORI has tried to get help through official channels (IMS2023 in-person) and been unsuccessful. The practical implication: we cannot easily generate custom profiles for our deployed configuration. Mitigation paths: (a) work from saved TES exports we already have, (b) drive a stock profile via the kernel's built-in defaults and parameterize only what we strictly need at runtime, (c) reverse-engineer the JSON schema enough to hand-edit profiles, (d) eventually fork the driver to accept a more recent profile schema. None of these are appealing. The driver auto-loads SOMETHING at boot (we've seen profile_config return a populated description) so option (b) is at least a working starting point.

21. **ADRV9002+AXI-ADC streaming is a brittle dance, not the AD9363 hands-off model** Dialogus on Pluto uses the standard libiio pattern (configure → enable channels → create buffer → refill loop) with no manual ENSM or sync_start_enable touching, and the AD9363 driver handles all state internally. The ADRV9002+axi-adrv9002-rx-lpc combination on ZCU102 does NOT exhibit this property — userspace writes to initial_calibrations or sync_start_enable while channels are in rf_enabled can leave the FPGA-side bridge wedged with no driver complaint. Recovery requires reboot because the driver is statically compiled (no module reload). Future ARM-side init code must (a) never touch these attributes after streaming has begun, (b) follow a strict configure-before-rf-enable ordering, and (c) consider a userspace watchdog that detects the wedged state via frame_count stagnation in Bouro and triggers a controlled reboot or driver reset.

22. **Build a Python "TES replacement" notebook (long-term)** The notebook should: (a) parse the saved TES-generated profile JSONs we already have, (b) write the profile to the chip via libiio attribute writes, (c) sequence calibrations correctly from the CALIBRATED state, (d) bring RX/TX channels through PRIMED→RF_ENABLED in the correct order, (e) document each step against what TES would have done. This is the path out of the TES versioning trap. Initial scope: just enough to replicate today's default-profile behavior reproducibly; full custom-profile support is a deeper future project.

23. **🐉 `adc_1_dovf` overflow signal — tie-off vs real telemetry (open since the splice).** Deleting `util_adc_1_pack` in the splice orphans `axi_adrv9001/adc_1_dovf`, which the ADI reference wires *into* the cpack (`adrv9001_bd.tcl` line 226); that dangling output is the source of the `[Opt 31-67]` dangling-LUT5 error. Two terminations exist in the tree: **green** ties `adc_1_dovf` to an xlconstant 0 (matches the pluto_msk libre precedent, which grounds `adc_dovf`); **brown's `d2c73ae`** wires it to the DMA's real `fifo_wr_overflow` (citing `axi_dmac.v:220` — claims the port is live even in AXIS slave mode, `DMA_TYPE_SRC=1`). The deciding question is narrow: does `axi_dmac` actually expose a meaningful `fifo_wr_overflow` output in AXIS-input mode? If yes, brown's wiring buys real RX1 overflow telemetry; if no, the GND tie-off is honest and matches precedent. Settle it by reading `axi_dmac.v`, not the conflicting comments. Not build-blocking — the shipped build uses green's tie-off.

24. **TEST 4 off-bin behavior (k = 16.5) — pre-existing, worth a look.** In the channelizer regression an off-bin tone halfway between bins 16/17 peaks at bin 48 (≈ 64−16.5, the negative-frequency image) instead of splitting cleanly across 16/17, and is soft-flagged `Warning: TEST 4 NOTE`. This is **not** a quarter-MAC regression — the MAC is bit-identical (TEST 3's four tones land perfectly), so TEST 4's result is unchanged from the pre-split design. It's a property of the channelizer's off-bin / image response, flagged since at least the half-MAC era. Worth understanding someday (real-tone image symmetry?), but orthogonal to timing and not blocking.

25. **The +0.010 ns global WNS path lives off `clk_pl_0`.** After the quarter-MAC the channelizer's `clk_pl_0` domain closes at +0.341 ns, but the *overall* design WNS is +0.010 ns — razor-thin, and on a different clock (likely an ADRV9002 interface clock or a CDC / inter-clock path; note the `set_bus_skew` warning on the CDC FIFO). It MET, so the XSA is valid and bootable, but +0.010 ns is the kind of margin a tool re-run or an unrelated change could flip negative. Pull the Inter Clock Table from a routed-checkpoint `report_timing_summary` to identify exactly which path it is, so it's a known quantity rather than a surprise.

    **Identified 2026-06-03 (R2SDF rebuild).** The path is `rx1_dclk_out` → `proto_hdr_OBUF[0]` — the ADRV RX data clock crossing into the proto_hdr SSI output. After the R2SDF FFT swap (an "unrelated change," exactly as predicted) the razor-thin global margin flipped to **WNS −0.122 ns, 12/12 setup endpoints** on this crossing (hold clean). `clk_pl_0` itself is unaffected and comfortable (+0.938 ns), so this is *not* a channelizer path. The XSA still builds and boots and the SSI is functionally tolerable for the demo; the real resolution is a `set_max_delay` / bus-skew constraint on the proto_hdr transfer — promote when touching flight timing.

26. **Channel-power tuning — carrier energy spreading across the 10 MHz span.** A CW carrier walked across the band lights up more non-target channels than wanted. Separate the two mechanisms before reaching for a lever: (a) *real* inter-channel leakage = the polyphase prototype's stopband depth — a rebuild lever (taps / pm-remez spec); (b) *apparent* smear of a moving carrier = the power EMA's slow stage (`power_alpha2`, ~4096-sample TC) behaving like a long-exposure photo of the moving tone — a runtime lever (`power_alpha1` / `power_alpha2`). Also check `OUTPUT_SHIFT` (currently **2** — low; governs where the noise/quant floor sits relative to the skirt and whether the peak rails) and oversampling `M` (scalloping at channel edges). The diagnostic that picks the lever: park the carrier dead-center in one channel and let it sit — a static skirt points at the filter; clean-when-parked-but-smeared-when-walking points at the EMA time constant.

27. **Modernize Tests 10 & 11 in `tb_haifuraiya_channelizer_axi`.** Test 10's `[2M, 4M]` EMA bound is stale (reads ~4.27M now; confirmed swap-independent — bit-exact channel data ⇒ identical EMA input, so the old core reads the same). Replace it with a steady-state bound *derived from* the alpha/shift parameters so it can't go stale again. Test 11 reproduced an already-fixed bimodal hardware bug; replace it with a forward-looking drop-free stress test — broadband noise at production cadence, assert `DROPPED_FRAMES = 0` and `FRAME_COUNT == frames_observed` (every frame accounted for, the property the R2SDF actually buys). Note: Test 11's lone "TDEST got 0 expected 1" was a benign capture-checker artifact — `p_capture` clears `seen_tdest` only on `aresetn`, not on the CONTROL-register soft reset, so the core's correct restart-at-0 read as out-of-sequence (relates to Quest #17).

---

## ⚠️ Monsters to Watch For
*Risks worth keeping in peripheral vision*

| Risk | Likelihood | Impact | Mitigation |
|---|:-:|:-:|---|
| ADRV9002 driver maturity in 2026 | Medium | High (could blow up Phase 2) | Check ADI ref design status early; have AD9361 stack as Plan B fallback |
| A53 throughput insufficient for 64× software demod | Medium | Medium (forces PL time-share fallback) | Measure early; PL 8:1 time-share fallback is well-understood |
| OOC clock propagation (HD.CLK_SRC) | Low — constraint should propagate from parent in real block design | Low | Document for now; revisit if it bites in Phase 1 integration |
| Yocto/EDF maturity on ZCU102 | **Resolved by strategic shift** — see Phase 2 | n/a | We pivoted from pure-Yocto to PetaLinux Tools 2022.2 (the documented happy path for the hdl_2022_r2 era). Will revisit pure-Yocto + gen-machine-conf when we eventually migrate to Vivado 2024.x and a newer meta-adi. |
| dvb_fpga → ZCU102 port surprises | Low | Low | Repo already supports zcu106; difference is mostly board constraint files |
| Per-channel demod processing latency adding up | Low | Medium | Voice latency tolerance is generous (~100ms); measure during Phase 4 |
| GSE library bugs in `libgse` | Low | Low | OpenSAND-derived implementations are well-tested; we control encapsulation order |
| Other latent EMA overflows under different operating conditions | Low | Medium | Test 10 (sustained-amplitude regression) now in CI; MSB-doesn't-flip assertion. Run before every release. |
| IP-XACT package breaks on a future Vivado version | Low | Medium | component.xml is plain XML; readable/editable across versions. Re-package if needed using the recipe in "IP-XACT Packaging Lessons." Smoke test re-runnable for regression. |
| Other latent IP-XACT metadata bugs surface at integration time | Low | Medium | Smoke test catches multi-clock association issues. Re-run after any IP-XACT modification. |
| PetaLinux Tools deprecation in 2024.1+ eventually forces a migration | Low (we're on 2022.2 for the foreseeable future) | Medium when it lands | When ADI releases meta-adi for newer Vivado/Yocto eras, plan the migration. The Vivado/HDL/meta-adi versions are tightly coupled; we move all three at once or none. |
| PetaLinux's xsdb-script-FSBL-MMU bug breaks on a future PetaLinux update | Low (we own the workaround) | Low (we have the `rst -processor` patch, well-understood) | Workaround documented in PetaLinux Build Lessons. If a future PetaLinux release fixes it natively, simplify our boot recipe. |
| Switching IP indices on JTAG between sessions ("targets 1" no longer points to ZynqMP) | Low (haven't seen it yet in this session structure, but xsdb behavior across reboots is not always deterministic) | Low (recovery is just running `targets` and picking the right index) | Document the by-name filter form as a more robust alternative once we crack the quoting. |

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
- `haifuraiya/rtl/axi/axi_lite_regs.vhd` — AXI-Lite register block (stable offsets, Bouro-versioned)
- `haifuraiya/sim/tb_haifuraiya_channelizer_axi.vhd` — testbench (later expanded to 9 tests + Test 10 with inter-test reset)
- `haifuraiya/third_party/lowpass_ema/` — submodule, initially on branch `fix/data-ena-gate`, SHA `ee5879a`
- **Upstream PR #1 open:** `OpenResearchInstitute/lowpass_ema` — "Gate EMA accumulator on data_ena for multiplexed-stream use cases"

### Overflow-debug + regression session (earlier)
- `haifuraiya/rtl/channelizer/haifuraiya_channelizer_top.vhd` — output mux defaults to '0' on inter-frame gaps
- `haifuraiya/sim/tb_haifuraiya_channelizer_axi.vhd` — added `aresetn` pulse between Test 5 and Test 6, plus Test 10 sustained-DC regression
- `haifuraiya/third_party/lowpass_ema/` — submodule now tracks `ori/integration` branch (SHA `5327d83`)
- Parent repo commit: `467dcc3` "Phase 1 closeout: all 9 testbench tests pass", then `f931200`/`05de4db` "Cast DETECT REGRESSION: add Test 10 sustained-DC stress assertion"
- **Upstream PR #2 open:** `OpenResearchInstitute/lowpass_ema` `fix/sum-saturation`

### IP-XACT packaging session (earlier)
- `haifuraiya/component.xml` — IP-XACT manifest, integrity-checked
- `haifuraiya/xgui/haifuraiya_channelizer_axi_v0_1.tcl` — customization GUI (auto-generated from component.xml)
- **VLNV:** `openresearch.institute:ip:haifuraiya_channelizer_axi:0.1`
- **Categories:** `/OpenResearchInstitute/Haifuraiya`
- **Memory map:** 72 registers (8 control + 64 channel power) encoded as IP-XACT
- **Bus interfaces:** 3 — `m_axis_chans` (AXIS master), `s_axis_data` (AXIS slave), `s_axi_ctrl` (AXI-Lite slave)
- **User-exposed generics:** `POWER_ALPHA_W` (default 18, range 8-32), `C_S_AXI_CTRL_ADDR_WIDTH` (default 12, range 8-32)
- **Hidden generics:** N_CHANNELS, M_DECIMATION, TAPS_PER_BRANCH, DATA_WIDTH, COEFF_WIDTH, ACCUM_WIDTH, COEFF_FILE (coupled to bundled coefficient hex)
- Parent repo commit: "Cast PACKAGE OBJECT (level 5 spell)"

### Block-design smoke test session (this update)
- `haifuraiya/bd/smoke_test/bd_smoke_test.tcl` — reusable BD smoke test
  - Path-portable (derives ip_repo_path from script location via `[info script]`)
  - Instantiates clk_vip + rst_vip + 2× axi4stream_vip + axi_vip + Haifuraiya IP
  - Wires interfaces, assigns address, validates
  - Three save_bd_design checkpoints so partial state survives errors
  - Re-runnable as a regression test on any future IP-XACT or RTL change
- `haifuraiya/bd/smoke_test/fix_ipxact_aresetn.tcl` — one-shot fix script for Bug #8
  - Archived for posterity and as a reference pattern for future IP-XACT cleanup
- `haifuraiya/component.xml` — modified (ASSOCIATED_BUSIF removed from aresetn parameter block)
- Parent repo commit: "Cast PROTECTION FROM CLOCK CONFUSION + close Phase 1 with a smoke test"

### Phase 2b: PetaLinux + ADRV9002 bring-up session (this update)
- `<MDT>/haifuraiya/petalinux/haifuraiya/project-spec/configs/config` — User layer registrations for meta-adi-core and meta-adi-xilinx
- `<MDT>/haifuraiya/petalinux/haifuraiya/project-spec/meta-user/conf/petalinuxbsp.conf` — `KERNEL_DTB = "zynqmp-zcu102-rev10-adrv9002"`
- `<MDT>/haifuraiya/third_party/meta-adi/` — Branch `2022_R2`, freshly cloned, pending decision on submodule-ification
- `<MDT>/haifuraiya/third_party/hdl/` — Branch `hdl_2022_r2`, existing submodule
- ORI Remote Labs FPGA documentation — "Working on the ZCU102 and attached ADRV9002 with PetaLinux Tools 2022.2" section replaced (verified recipe + rationale + pitfalls)
- **Verified signature on ZCU102 dmesg:** `adrv9002 spi1.0: adrv9002-phy Rev 12.0, Firmware 0.22.30, Stream 0.7.11.0, API version: 68.13.7 successfully initialized`
- **Boot recipe:** `petalinux-boot --jtag --prebuilt 3 --hw_server-url TCP:keroppi:3121 --after-connect "targets 1" --tcl /tmp/petalinux-boot.tcl`
- **Key strategic decision:** Pivoted from pure-Yocto+gen-machine-conf to PetaLinux Tools 2022.2 after pure-Yocto path proved undocumented + broken for ADI reference designs in this stack era
- Parent repo commit (pending): "Cast SUMMON ADRV9002 (level 7 spell) — PetaLinux Tools 2022.2, meta-adi 2022_R2, full RX/TX/TDD AXI enumeration, root login on JTAG-streamed Linux"

### Phase 2b: Follow-on SSH access bring-up + JTAG re-boot lessons (this update)
- `/etc/default/dropbear` on target — in-RAM edit to remove `-w` flag; pending permanent fix via bbappend or openssh migration (Action #9)
- `/tmp/petalinux-boot-fixed.tcl` updated: includes `rst -system` on PSU target as the first action after `connect` (required for any boot after the board has been running Linux from a prior session)
- Confirmed: `petalinux-config → Ethernet Settings` baked the static IP `10.73.1.16` into the rebuild, but with `/8` netmask (cosmetic for same-subnet ssh from mymelody; matters for cross-subnet routing)
- **Verified:** Paul successfully SSHed into the ZCU102 from outside the immediate lab network after the dropbear `-w` removal. Phase 2b is now multi-user accessible (with the understood ephemeral state caveat until Action #9 is done).
- **Three lessons captured in PetaLinux Build Lessons:** (a) `rst -system` is required before every JTAG re-boot, (b) `petalinux-config` Ethernet defaults to /8 netmask, (c) dropbear `-w` blocks root SSH out of the box.

### Phase 2b: Repository portability + wired.network root-cause session (this update)
- `<MDT>/Makefile` — new top-level Makefile with `haifuraiya-{configure,build,boot,clean,revert-paths}` targets; documented Linux-only, `mdt_sic` deliberately not wired up (independent project)
- `<MDT>/haifuraiya/petalinux/scripts/setup-petalinux.sh` — new portability setup script; resolves repo root from script location, rewrites `CONFIG_USER_LAYER_0/1` and `HARDWARE_PATH` based on local clone; GNU sed precondition with clean macOS-error message; sanity checks for missing meta-adi submodule and missing config files
- `<MDT>/haifuraiya/petalinux/haifuraiya/project-spec/configs/config` — `CONFIG_USER_LAYER_0/1` converted from `/home/abraxas3d/brown/...` to sentinel paths `/PLEASE_RUN_make_haifuraiya-configure_FIRST/...`
- `<MDT>/haifuraiya/petalinux/haifuraiya/.petalinux/metadata` — `HARDWARE_PATH` converted to sentinel form (was previously holding `/home/abraxas3d/brown/...` to the XSA)
- `<MDT>/haifuraiya/petalinux/haifuraiya/project-spec/configs/systemd-conf/wired.network` — hand-corrected from PetaLinux's malformed autogenerator output (`Address=10.73.1.16`, `DNS=255.255.255.0`) to spec-compliant systemd-networkd format (`Address=10.73.1.16/24`, real DNS entries). Root cause traced to PetaLinux's autogenerator, not systemd-networkd — confirmed via ArchWiki and the parallel archinstall bug.
- `<MDT>/haifuraiya/sim/haifuraiya_plan_of_attack.md` — deleted (duplicate of canonical plan-of-attack at `haifuraiya/haifuraiya_plan_of_attack.md`)
- Three audit rounds completed (zip upload → check → fix → re-upload pattern); final audit shows zero `/brown/`, `/Users/w5nyv/`, or `/home/abraxas3d/` references in any live tracked file
- **Strategic insight:** The "build only works for the original author" trap is universal across PetaLinux projects. Solving it on the first commit (instead of the tenth) is the right call. Architecture is reusable for future ORI projects that wrap PetaLinux.
- Parent repo commits: "Cast PORTAL TO ANYWHERE — fix /brown/ hardcoded paths" + "Cast WARD AGAINST CHAOS — finish portability fix and netmask bug"

### Phase 2b: Paul fresh-eyes test + Vivado/XSA target chain (this update)
- **Paul (KB5MU) clean-clone test on mymelody from `~/Documents/git/Mode-Dynamic-Transponder/`.** Two real reproducibility bugs found:
  - `setup-petalinux.sh` was committed without git's executable bit. Required `chmod +x` before `make` could invoke. Fixed via `git update-index --chmod=+x`.
  - `make haifuraiya-build` assumed `petalinux-build` was on PATH; failed cryptically when PetaLinux Tools settings hadn't been sourced. Fixed via new `haifuraiya-check-env` preflight target with actionable error message.
- **Confirmed working in Paul's environment:** the portability machinery itself. `setup-petalinux.sh` correctly resolved `/home/kb5mu/Documents/git/Mode-Dynamic-Transponder/` as the repo root and rewrote all three paths (CONFIG_USER_LAYER_0/1 + HARDWARE_PATH) to point into Paul's clone. **No `/brown/` contamination of any kind.** This is the empirical proof the portability fix works for a different user in a different directory.
- **Anticipating Phase 3:** Michelle flagged that Vivado will be required as soon as Haifuraiya is inserted into the ADI reference block design. Added four new Makefile targets to wire that path now:
  - `haifuraiya-check-vivado` — preflight, similar shape to haifuraiya-check-env
  - `haifuraiya-xsa` — Vivado batch build of the adrv9001/zcu102 reference XSA (~5 hour blocker)
  - `haifuraiya-import-xsa` — `petalinux-config --silentconfig --get-hw-description=$(XSA)` to update cached hw-description and HARDWARE_CHECKSUM
  - These are intentionally NOT chained into `haifuraiya-build` — they're explicit "yes I want this 5-hour operation" steps.
- **Documentation added:** new "Hardware Regeneration Workflow" subsection in PetaLinux Build Lessons describing the four-step RTL-change-to-board recipe. New Open Quest #16 about how to insert Haifuraiya IP into the ADI reference block design (three options under investigation).
- Parent repo commits: "Cast HALLOW BLADE — Paul fresh-eyes test fixes" + a follow-on commit adding the Vivado/XSA targets and Hardware Regeneration Workflow documentation.

### Phase 4 Ground: ADRV9002 chip-side configuration unblocked (this update)

**Headline result:** TES-generated profile loaded cleanly on the ZCU102+ADRV9002 for the first time, all predicted state changes verified, LOs retuned to W2 frequencies, channelizer survived the reload — the chip-side configuration path that was the critical-path blocker for Phase 4 Ground is now provably working end-to-end.

**The day's arc.** Started the morning still in the "TES is the critical path, we can't generate profiles without crashes" state. Worked through UG-1828 systematically (Single-Band 2T2R FDD application p.13-14, Clock Generation p.99-101, Dead Zones tables) until the chip's constraint network made sense — then in TES discovered:
- The "Clocks" sectional accepts 38.4 MHz to match the board's on-board VCXO (matched in the FDD LTE template after `setting device clock`)
- The "Swap LO Mapping" checkbox controls the conventional vs. board-matching LO assignment (board uses RX→LO2, TX→LO1 which is opposite ADI's convention but matches the existing HDL build)
- The LO Source dropdown (External / Internal) is purely cosmetic for export — the JSON only carries external-LO fields when actual external frequencies are set
- Custom mode supports arbitrary sample rates BUT respects the chip's dead zones (UG-1828 Tables 42/43); 17 Msps sits inside dead zone 19 (16.7-18.75 MSPS in LVDS DDR), shifted up to 20 Msps to land in a valid range
- CMOS 1-Lane SDR has a hard ceiling near 1.92 Msps because of pin-rate physics (32 bits × 1.92 Msps = 61.44 Mbps lane rate, at the CMOS pin's practical limit)
- LO carrier frequencies are NOT serialized in the profile JSON — they're runtime-only via `iio_attr altvoltage{0,1,2,3}/frequency`

**Three profiles generated, all TES-green-dot:**
- `tes_0231_Haifuraiya_FDD_CMOS_1.92Msps_1.008MHz.json` — matches the existing CMOS HDL build, 1T1R FDD
- `tes_0231_Haifuraiya_FDD_LVDS_20Msps_10MHz.json` — production target, 1T1R FDD, 10 MHz BW (full channelizer span)
- `tes_0231_Haifuraiya_FDD_30_72Msps_18MHz.json` — high-rate test variant (also LVDS)

**Verified on the bench (CMOS profile load):**
- `cat $CMOS > $PROF` returned exit code 0, dmesg silent — no version-mismatch issues despite TES 0.23.1 expecting FW 0.22.13 / API 68.5.0 and the board running FW 0.22.30 / API 68.13.7 (JSON parser is backwards-compatible, as hoped)
- Every predicted post-load state matched: RX Channel Mask `0xc3 → 0x41`, TX Channel Mask `0xc → 0x4`, VCO unchanged at 8.847 GHz, sample rate stays 1.92 Msps, FDD/CMOS preserved, RX2/TX2 now in `ensm: unknown / enabled: no` state
- Bouro kept publishing throughout — `frame_count/delta` continued advancing through the profile reload (the channelizer pipes survived the chip reconfiguration cleanly)
- LO retune to W2 territory via `iio_attr -c adrv9002-phy -o altvoltage0 frequency 5600000000` actually changed the chip state this time (was silently ignored before the new profile was loaded); RX1_lo_hz = 5.6 GHz, TX1_lo_hz = 5.8 GHz both confirmed via `oriinit-cli status`

**Discovered driver behavior (cross-SSI profile load):**
- Loading `LVDS_20Msps_10MHz.json` against the CMOS HDL build returns: `adrv9002 spi1.0: SSI interface mismatch. PHY=1, RX1=2` → `cat: write error: Invalid argument` (exit 1)
- The driver validates the profile's SSI mode against the FPGA's reported capability (`PHY=1` = HDL reports CMOS, `RX1=2` = profile requests LVDS) and refuses the write
- **However**, the rejection is NOT cleanly transactional — the failed write leaves the chip's data path in a wedged state. Bouro shows zero `frame_count/delta` after the rejected write.
- **Recovery is reloading the previously-known-good profile** (not a reboot). Verified: `cat $CMOS > $PROF` after the rejected LVDS load brought the radio fully back to a working 1T1R FDD CMOS state, Bouro frames resumed flowing.

**Known small bug (tomorrow's patch):**
- `oriinit-cli run-calibrations` returns `libiio read/write failure` in the 1T1R configuration. Root cause: the safe-sequence implementation iterates over RX1/RX2/TX1/TX2 doing iio writes, but RX2/TX2 are now `ensm: unknown / enabled: no` in 1T1R mode, so iio operations on those channels fail. **Fix scope:** filter out disabled channels (or check enable state) before the iio calls in `liboriinit/src/oriinit.c`. Small, well-scoped patch. Until this is fixed, calibrations don't complete after a profile load → RX path doesn't fully wake up → `dma_listen` reads `DEFAULT-PROFILE BINARY (no real ADC)` zeros instead of real samples.

**Lab-bench setup confirmed (`2026-05-25_08_55_42.jpg` photo):** No external connections to the radio card — DEVMCS_IN, DEVCLK_IN, EXT_LO1, EXT_LO2 all empty; RX1A/RX2A inputs and TX outputs all 50Ω terminated. On-board VCXO supplies the 38.4 MHz device clock (`CLOCK POWER OK`, `DEVCLK OK`, `VCXO ENABLED` LEDs all green). This matches the chip-side configuration we picked in TES (`Internal LO` for both PLL1 and PLL2; no external LO infrastructure needed for the ADRV9002 generation, unlike the earlier ZC706+ADRV9009 setup which had an external oscillator).

**Files referenced/created:**
- `~/profile_test_2026-05-27/` on the board — baseline + per-experiment capture directory
- `~/profile_test_2026-05-27/{baseline_status.txt, baseline_profile_summary.txt, baseline_dmesg.txt, baseline_dma.txt}` — pre-load state
- `~/profile_test_2026-05-27/cmos_test/{post_cmos_status.txt, post_cmos_summary.txt}` — first clean load verification
- `/home/root/tes_0231_Haifuraiya_FDD_CMOS_1.92Msps_1.008MHz.json` and `/home/root/tes_0231_Haifuraiya_FDD_LVDS_20Msps_10MHz.json` — staged on the board
- `/home/root/oriinit-cli` — verified working for status + LO read; `run-calibrations` needs the 1T1R patch

**Strategic implications:**
- The Haifuraiya RF chain is no longer blocked on chip-side mysteries. Remaining engineering is straightforward: patch `liboriinit`, run cals, watch real samples flow.
- Adauchi (programmatic TES-replacement in Python) remains a valuable future tool but is **no longer a critical-path dependency** for the radio to work. TES + this validated workflow is sufficient through Phase 5.
- The LVDS HDL port becomes the next architectural milestone. Production rate is 20 Msps complex (10 MHz BW) which requires LVDS 2-Lane DDR — outside CMOS 1-Lane SDR's pin-rate limit. LibreSDR `pluto_msk` port gives the LVDS idiom (4× sample rate `l_clk`, BUFG-based divider).
- TES 0.23.1 / FW 0.22.13 / API 68.5.0 version manifest is preserved in three places (Dropbox, USB thumb, Mac) — this is the artifact ADI gatekeeps. Forward-compatibility holds for the actual firmware running on the board (0.22.30 / 68.13.7).

**Pending repo commits (from this session):**
- `dogu/liboriinit/src/oriinit.c` — 1T1R channel-enabled gating patch (next session)
- Plan-of-attack updates (this commit)
- Additional READMEs to be updated in follow-on commits

### Phase 4 Ground: 仇討ち (Adauchi) deferred (this update)

The original plan included Adauchi — a Python tool to programmatically generate ADRV9002 profile JSON, replicating TES's constraint-solver. The motivation was avoiding TES (crashy, GUI-only, gatekept artifact, version-mismatched). After the chip-side configuration breakthrough above, the picture changed:

- TES + the validated workflow is sufficient for Haifuraiya through Phase 5
- The "TES is unobtainable" risk is permanently mitigated by the triple-backup of TES 0.23.1
- The "TES is crashy" risk is navigable with the lessons learned (Setup presets only, avoid arbitrary-rate Custom mode when reference clock isn't matched, dead zones are real)

Adauchi remains valuable for: full programmatic CI of profile generation, independence from ADI's gatekeeping for long-term sustainability, and exploring profile configurations that TES doesn't expose. But it's now a **Phase 6+ research project**, not a Phase 4 ground blocker.

The schema work we did (parser header inspection, top-level structure mapping, FDD-vs-TDD slot reorganization analysis) is preserved in the conversation transcripts for future Adauchi-the-revenant.

### Phase 3: Integrated-build timing closure + first boot on the green clone (this update)
- **`haifuraiya/rtl/channelizer/fir_branch_parallel.vhd`** — quarter-MAC split: each branch MAC partitioned into four registered 6-tap quarter-MACs (`mac_quarter(0..3)`) summed by `p_combine_halves` into two 12-tap partials; added `Q_TAPS`, `valid_ddd`, and a `TAPS_PER_BRANCH mod 4 = 0` elaboration assert. Branch latency 3→4 cycles; MAC result bit-identical. Commit `6ffc273` ("Cast HASTE").
- **`haifuraiya/rtl/channelizer/polyphase_filterbank_parallel.vhd`** — added `frame_complete_d3` stage so `outputs_valid` aligns with the now-4-cycle branch.
- **Result:** `clk_pl_0` WNS -0.188 → **+0.341 ns**; overall design WNS **+0.010 ns** (on a non-channelizer path — Open Quest #25); all constraints met. Utilization: 1488 DSP (59%), 153K LUT (56%), 157K FF (29%), 4 BRAM. DSP count flat (re-partition, not re-multiply). Worst `clk_pl_0` paths are now ordinary `taps_reg` / `mac_quarter_reg` loads — the 12-DSP cascade is gone.
- **Validated in xsim before synthesis:** tones land exactly in bins 4/16/28/40, DC in bin 0, 59.8 dB adjacent-channel rejection, 1342 frames / 0 dropped, 0 hard errors. (TEST 4 off-bin flag is pre-existing — Open Quest #24.)
- **Supporting commits (file-comparison sync brown→green, after abandoning a tangled interactive rebase):** `76a95b7` (HAIFURAIYA_COEFFS_PKG — compiled-in coefficients replacing `file_open`), `ce43876` (VHDL-93 AXI-Lite ready handshakes), `06672d7` (power_detector submodule bump — `lowpass_ema` width fix). The power_detector staleness was caught *by the green fresh-clone test* — green's submodule pointer lagged brown's, which would have failed synth with `MULT_DATA_SHIFT` out of range. A real reproducibility gap caught before it bit anyone else.
- **Integrated XSA build:** 83 min on mymelody, clean exit, `write_hw_platform` succeeded. Path: `haifuraiya/syn/zcu102_with_adrv9001/adrv9001_zcu102_ori.sdk/system_top.xsa`.
- **Fresh-clone import caught the meta-adi sentinel:** `make haifuraiya-import-xsa-integrated` failed with `/PLEASE_RUN_make_haifuraiya-configure_FIRST/meta-adi-core` — the portability placeholder doing exactly its job on a never-configured clone. `make haifuraiya-configure` localized the path; import + build + boot then succeeded.
- **First boot of the timing-clean integrated bitstream:** ADRV9002 RX/RX2/TDD cores, all four DMAs, and the sysid ROM enumerate in `/proc/iomem`. The channelizer has no DT node, so it's invisible to `/proc/iomem` by design — confirmed alive instead via raw read: `devmem 0x84A70000` → `0x00010000` (version 1.0), `+0x4` → `0x2`, `+0x8` → `0x7`.
- **Open items filed:** Open Quests #23 (dovf tie-off vs real telemetry), #24 (TEST 4 off-bin), #25 (+0.010 ns global path).

### Key results from Phase 1 closeout

- Synth-stage critical path: **9.684 ns** (≈ 100 MHz closes; ~0.3 ns slack)
- Post-route data path delay essentially preserved (DSP cascade routing is silicon-fixed)
- Resource baseline: **1346 DSPs (53%), 116K LUTs (42%), 0 BRAMs, 93K FFs (17%)** *(channelizer only — wrapper adds 64 power_detector instances, ~256 DSPs)*
- **Wrapper testbench: 10/10 PASS.** DC → channel 0 (**639M real power**, no wraparound), tone bin 32 → channel 32 (**266M power**), with inter-test reset clearing prior state. Channel-0 leakage during tone test peaks at ~2.2M (~100× rejection, consistent with filter's −60 dB stopband). Test 10 sustained-DC stress: ch 0 = 651M.
- u_ema_2 `sum` MSB stays 0 throughout the entire 1ms simulation across all 64 EMA cascades — arithmetic is bounded
- DROPPED_FRAMES = 0
- **IP catalog rendering:** `Haifuraiya Channelizer (AXI)` under `/OpenResearchInstitute/Haifuraiya`, Status `Production`, License `Included`, AXI4 + AXI4-Stream classified
- **Block-design smoke test: PASS, zero warnings.** Address segment `s_axi_ctrl/reg0` auto-maps at `0x0000_0000 [4K]` on the AXI master VIP's address space. Phase 1 fully closed.
- HD.CLK_SRC issue causes WNS=inf, 16.5 ns artifact paths, and 1.2 kW absurd power estimate (all the same root cause; not a real design issue)

### Key results from Phase 2b closeout
- ADI HDL `hdl_2022_r2` reference design build closed (~5 hours from clean clone to XSA — `make` takes time)
- meta-adi `2022_R2` integration verified end-to-end
- ADRV9002 driver probes successfully via SPI on spi1.0, reports valid firmware/stream/API
- Full PL AXI infrastructure enumerated: `cf_axi_adc` (RX), `cf_axi_dds` ×2 (TX1, TX2), `cf_axi_tdd` ×2
- Kernel: ADI fork `5.15.36-xilinx-v2022.2` boots on all four A53 cores
- Hostname `haifuraiya`, login `root`/`analog` (default; will be hardened)
- Network: eth0 up at 1Gbps full duplex, MAC assigned, IPv6 link-local active (IPv4 pending systemd-network port from meta-ori)
- QSPI flash enumerated cleanly: `mt25qu512a` (128 MB) with standard 4-partition layout
- Boot performance: ~10 min via fully-JTAG-streamed `--prebuilt 3` (acceptable for verification, slow for routine iteration → TFTP fast-path is the next infrastructure task)
- Strategic decision: PetaLinux Tools 2022.2 is the canonical happy path for the hdl_2022_r2 / meta-adi 2022_R2 stack era; pure-Yocto-with-gen-machine-conf is the future direction but targets a later Vivado/HDL release

---

*Last updated: 2026-05-27 (evening) — integrated-build timing CLOSED via the quarter-MAC split ("Cast HASTE", commit `6ffc273`): `clk_pl_0` -0.188 → +0.341 ns, clean `system_top.xsa` rebuilt and rebooted from the green fresh clone, channelizer answering at 0x84A70000 (version 1.0). The green clone caught two reproducibility gaps (stale power_detector submodule pointer; meta-adi configure sentinel) — both resolved. Earlier the same day (Phase 4 Ground lab session): chip-side configuration unblocked. TES-generated 1T1R FDD CMOS profile loaded cleanly on the ZCU102+ADRV9002 for the first time, all predicted state changes verified, LOs retuned to W2 frequencies (5.6 GHz RX, 5.8 GHz TX confirmed), channelizer survived the reload (Bouro frames flowing throughout). Three TES profiles generated and validated: CMOS 1.92 Msps (current HDL), LVDS 20 Msps (production target), LVDS 30.72 Msps (high-rate test). Driver-side SSI mismatch protection discovered (PHY=1 vs RX1=2 rejection), with the important caveat that rejection is not transactional — recovery is reload-previous-profile. Known small `liboriinit` 1T1R bug surfaced: `run-calibrations` fails on disabled channels (RX2/TX2 in `ensm: unknown` state); patch is to filter disabled channels before iio writes. Adauchi (programmatic profile generation) downgraded from critical-path to Phase 6+ research project — TES + this workflow is sufficient through Phase 5. When you come back, start at "You Are Here" — the next session is the small `liboriinit` patch + first real ADC samples + then the LVDS HDL port to enable the production 20 Msps 10 MHz profile. The forest remembers.*
