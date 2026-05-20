# Haifuraiya: The Dungeon Map

*Plan of attack for getting Phase 4 Ground from "channelizer closes timing"
to "64-channel OPV transponder running on the lab bench."*

---

## ⚔️ You Are Here

Quick orientation when you come back to this doc weeks later:

| Status | Item | Notes |
|:-:|---|---|
| ✅ | Haifuraiya channelizer RTL | Closes 100 MHz on ZCU102, route clean, bit-true tests pass |
| ✅ | **Phase 1 AXI-Stream + AXI-Lite wrapper** | **10/10 testbench PASS. DC → ch0 (639M power) and tone bin 32 → ch32 (266M power) with clean inter-test reset and bounded EMA arithmetic. 8 bugs found and fixed during bring-up (see Bug Hunt section).** |
| ✅ | **Phase 1 IP-XACT packaging** | **`openresearch.institute:ip:haifuraiya_channelizer_axi:0.1` published to local IP catalog. Integrity check passed. 3 AXI interfaces, 72-register memory map, 2 user-tunable generics. Visible in Vivado IP Catalog as "Haifuraiya Channelizer (AXI)".** |
| ✅ | **Phase 1 Task 8 block-design smoke test** | **BD with AXI/AXIS/clock/reset VIPs validates without warnings. 72-register memory map auto-maps at 0x0000_0000 [4K]. Reusable smoke-test script at `bd/smoke_test/`. PHASE 1 IS CLOSED.** |
| ✅ | DVB-S2 encoder | ORI's `dvb_fpga` repo, tested vs GNU Radio, runs on zcu106 |
| ✅ | OPV demodulator RTL | `pluto_msk`, working on LibreSDR; would need 64× or time-shared |
| ✅ | OPV demodulator software | `opv-cxx-demod`, real-time on Pluto's A9 |
| ⏳ | lowpass_ema upstream PRs | **TWO open PRs** to `OpenResearchInstitute/lowpass_ema`: `fix/data-ena-gate` (multiplexed-stream gating) and `fix/sum-saturation` (PROD_W-range clamping). Local builds use `ori/integration` branch until both merge. |
| ✅ | **Phase 2b: PetaLinux on ZCU102 PS** | **PetaLinux Tools 2022.2 build, JTAG boot to login prompt, ADRV9002 driver enumeration confirmed (`adrv9002 spi1.0: ... Firmware 0.22.30, Stream 0.7.11.0, API version: 68.13.7 successfully initialized`). All four AXI infrastructure cores (RX ADC, 2× TX DDS, 2× TDD) come up clean.** |
| ✅ | **Phase 2a: ADRV9002 + ZCU102 board** | **ADI HDL `hdl_2022_r2` reference design build closed, meta-adi 2022_R2 integration verified, ADRV9002 enumerates and reports valid firmware/stream/API. Sample stream verification (next-tier of 2a) is the immediate next step.** |
| 🎯 | **Next session focus** | **(a) Clean-clone-rebuild test + commit everything (catches reproducibility issues while details are fresh); (b) First captured sample stream from ADRV9002 via libiio (gate from "Linux works" to "SDR is actually accessible"); (c) Friedrichshafen demo prep is now realistic.** |
| ⏳ | Sample stream verified through libiio | Driver up, but no `iio_readdev` test yet |
| ⏳ | Yocto Linux on ZCU102 PS | **Superseded by PetaLinux Tools 2022.2** — strategic shift documented in Phase 2. AMD has deprecated PetaLinux for 2024.1+ but it's the canonical happy path for the hdl_2022_r2 stack era. |
| ❓ | HD.CLK_SRC OOC clock prop | Unresolved; cosmetic for now |

If you only have 5 minutes when returning to this doc, read this section,
then jump to **Phase 2** (now mostly done — see what's left for full 2a closure)
and **Open Quests** (decisions you owe yourself).
**Phase 1 is done. Phase 2b is done. Phase 2a is partially done: chip enumerates, sample stream verification is next.**

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

**All Phase 1 work items are complete. Phase 2 is the next quest.**

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

2. **(skipped — already done inside the channelizer).** The channelizer's existing `haifuraiya_channelizer_top` entity already exposes one-channel-per-clock outputs via `channel_re / channel_im / channel_idx / channel_valid / channel_last`. The internal dual-FFT arbitration takes care of serialization. The AXI wrapper just renames these to AXIS pins — no separate serializer block needed.

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
   | 0x10 | DROPPED_FRAMES | RO | count of frames lost to FIFO overflow |
   | 0x14 | OUTPUT_SHIFT | RW | right-shift applied to the 40-bit channelizer output before AXIS (default 16; valid 0..24) |
   | 0x18 | POWER_ALPHA1 | RW | first-stage EMA α (default: fast tracker, e.g. α=2^-6) |
   | 0x1C | POWER_ALPHA2 | RW | second-stage EMA α (default: slower smoother, e.g. α=2^-12) |
   | 0x100-0x1FC | CHANNEL_POWER[0..63] | RO | per-channel latest integrated power, 32-bit each |

   Stable offsets — treated as a versioned interface for Takadono telemetry. **All 72 registers are encoded in the IP-XACT memory map and visible to Vivado's Address Editor / Vitis header generation / Petalinux device tree.**

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
*Eight bosses slain over the bring-up + packaging + integration sessions.
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
**🟡 Substantially complete. Subphase 2b done; 2a partially done; 2c pending.**

### Goal
Get RF samples flowing from the ADRV9002 into the PL fabric as AXIS at
10 MSps complex, with PS-side control plane (tuning, gain, AGC). Establish
Linux on the PS and the early Takadono observability scaffolding so
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
9. ✅ JTAG boot to login prompt via `xsdb` with rst-processor workaround.

### Subphase 2c: Takadono v0 (stub) — not started
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
sample stream, build the Takadono v0 MQTT publisher.

---

## 🛠️ PetaLinux Build Lessons
*Tooling gotchas learned during Phase 2b. Read before bringing PetaLinux up
on any future ZynqMP target.*

### What worked beautifully

- **Cross-machine build + JTAG is a clean architecture.** `petalinux-boot --jtag --hw_server-url TCP:<jtag-host>:3121` lets xsdb on the build host stream binaries through hw_server on the JTAG host to the board. No file-copy step between machines. The old Yocto-era `copy_to_keroppi.sh` and TFTP-orchestration scripts are obsolete and retired.

- **`--tcl` flag to dump the boot script.** `petalinux-boot --jtag ... --tcl /tmp/boot.tcl` generates the xsdb sequence *without running it*. Inspect it, edit it, run via `xsdb /tmp/boot.tcl`. Indispensable when the default sequence has a bug for your hardware combination.

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

- **🐉 The big one: MMU translation fault on `dow u-boot.elf` to DDR 0x8000000.** PetaLinux's generated xsdb script halts FSBL via `after 4000; stop` with the A53 still holding active MMU translation tables that FSBL set up during its 4-second run. The subsequent `dow u-boot.elf` writes through the active MMU and faults because FSBL's tables don't cover 0x8000000. **Fix:** `--tcl` to dump, insert `rst -processor -clear-registers` between `psu_ps_pl_reset_config` and `dow u-boot.elf`, run via `xsdb` directly. Open question (Open Quest below): can this be automated cleanly?

- **JTAG board state wedges between failed boot attempts.** Symptoms on retry: "EDITR timeout" on OCM writes, xsdb segfault. Recovery: `rst -system` via a PSU-filtered target (not target 1 — that returns "Invalid reset type"), then restart hw_server if it died, then retry. Physical power-cycle always works as a last resort.

- **`rst -system` on a top-level FPGA target (target 1) returns "Invalid reset type."** Must use a PSU or processor target: `targets -set -nocase -filter {name =~ "*PSU*"}; rst -system`.

- **`rst -system` sometimes kills hw_server.** Watch for "Connection refused" on the next attempt; restart hw_server on the JTAG host if so.

- **xsdb cosmetic core-dump on exit when fed via heredoc** is functionally harmless. The commands completed before the dump. Annoying but ignorable.

- **Shell-to-tcl quote escaping is fragile for `--after-connect` complex filter expressions.** Bash single-quotes preserve inner double-quotes for the shell, but PetaLinux's script processing strips them before they reach xsdb. Use simple `"targets 1"` for index-based selection, or generate the tcl with `--tcl` and edit it directly for anything more complex.

- **`zynqmp_clk_divider_set_rate() set divider failed for spi1_ref_div1, ret = -13`** in dmesg is a benign cosmetic warning. PMUFW manages that clock; the kernel driver retries gracefully, no functional impact on ADRV9002 operation.

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

# 8. (Optional) Set static IP in Subsystem AUTO Hardware Settings → Ethernet

# 9. Build + package
petalinux-build
petalinux-package --boot --fsbl --fpga --u-boot --force
petalinux-package --prebuilt --force

# 10. JTAG boot: generate, edit, run
petalinux-boot --jtag --prebuilt 3 --hw_server-url TCP:<jtag-host>:3121 \
               --after-connect "targets 1" --tcl /tmp/boot.tcl
# Edit /tmp/boot.tcl to inject `rst -processor -clear-registers` between
# `psu_ps_pl_reset_config` and `dow u-boot.elf`. Then:
xsdb /tmp/boot.tcl

# 11. Monitor serial console on the JTAG host in parallel:
# (on JTAG host) screen /dev/zcu102_uart1 115200
```

### Cross-cutting lessons

- **Don't fight the documented happy path of your stack era.** PetaLinux is officially deprecated, but for hdl_2022_r2 / meta-adi 2022_R2 it's what ADI's documentation assumes and what works. The pure-Yocto-with-gen-machine-conf flow is the future, but it targets Vivado 2024.x and a newer meta-adi.
- **Cross-machine build + JTAG separations is sustainable** if the JTAG host runs hw_server and exposes it via TCP. No file-copy script needed. Cleaner than the old Yocto-era TFTP plumbing.
- **PetaLinux's generated xsdb script is editable and inspectable.** When it has a bug for your hardware combination, `--tcl` dump + hand-edit + run-directly is a legitimate engineering workflow, not a hack. Document the edit; consider automating it eventually.
- **JTAG boot is comfortable for verification, painful for routine iteration.** ~10 minutes per boot streaming everything via JTAG. For the iterate-on-userspace workflow, set up TFTP for kernel/initramfs delivery via Ethernet (post-bring-up infrastructure task).

---

## 🎯 Phase 3: First Light

### Goal
See the channelizer working on real RF samples for the first time.

### Tasks
1. Build the integration block design: ADRV9002 RX → channelizer IP (from Phase 1) → AXI-DMA → PS DDR. **Note: the Phase 1 IP is already smoke-tested in a BD, so this step is shorter than it would have been.**
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

## ⚡ Immediate Action Items
*Things that should happen in the next session or two, before we move on to
the next strategic chunk. Numbered for ordering; all are near-term.*

1. **Clean-clone-rebuild test.** Move the current MDT working tree aside (`mv brown brown-bak` or equivalent), `git clone` the repo fresh into a clean directory, and try to reproduce tonight's success path purely from the documented procedure (Remote Labs doc + this plan). Catches "this only works because of files in my current clone" issues while the bring-up is fresh in mind. **Important precondition: commit everything first** (action #2).

2. **Commit everything.** The PetaLinux project metadata (`project-spec/configs/config`, `project-spec/meta-user/conf/petalinuxbsp.conf`, any custom recipes we may add for systemd) and a sensible `.gitignore` to exclude build artifacts (`components/yocto/`, `images/`, `build/tmp/`, `pre-built/`, `cache/`). Consider whether meta-adi belongs as a git submodule (consistent with the existing ADI HDL submodule) for pinning to a known-good commit. Write a `petalinux/README.md` summarizing the recipe so the plan-of-attack stays strategic-not-procedural.

3. **Port systemd static IP config from meta-ori into the PetaLinux project.** The `10-eth0.network` file (the only piece of meta-ori that genuinely survives the Yocto→PetaLinux transition) belongs in `project-spec/meta-user/recipes-core/systemd/`. After rebuild + reboot, verify `10.73.1.16` is up.

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
- `haifuraiya/rtl/axi/axi_lite_regs.vhd` — AXI-Lite register block (stable offsets, Takadono-versioned)
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
- **Boot recipe:** `petalinux-boot --jtag --prebuilt 3 --hw_server-url TCP:keroppi:3121 --after-connect "targets 1" --tcl /tmp/petalinux-boot.tcl` → hand-edit to inject `rst -processor -clear-registers` between FSBL halt and U-Boot dow → `xsdb /tmp/petalinux-boot.tcl`
- **Key strategic decision:** Pivoted from pure-Yocto+gen-machine-conf to PetaLinux Tools 2022.2 after pure-Yocto path proved undocumented + broken for ADI reference designs in this stack era
- Parent repo commit (pending): "Cast SUMMON ADRV9002 (level 7 spell) — PetaLinux Tools 2022.2, meta-adi 2022_R2, full RX/TX/TDD AXI enumeration, root login on JTAG-streamed Linux"

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

*Last updated: end of Phase 2b closeout session (PetaLinux Tools 2022.2 build + JTAG boot to login + ADRV9002 driver enumeration verified; strategic pivot from pure-Yocto to PetaLinux documented; 14 PetaLinux build lessons captured; 5 Open Quests resolved, 4 new ones added; Action Items list created for the immediate session — clean-clone rebuild test, commit everything, port systemd static IP, first libiio smoke test). When you come back, start at "You Are Here" — Phase 1 and Phase 2b are done, Phase 2a wraps with first sample stream verification, Friedrichshafen demo prep is now realistic. Update statuses as items move between ⏳ / 🎯 / ✅.*
