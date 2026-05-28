# Haifuraiya LVDS Port — Inventory & Work Plan

**Status:** Draft, paper inventory only — no HDL changes yet.
**Predecessors:** pluto_msk LibreSDR LVDS port (working precedent), Haifuraiya CMOS build (current production).
**Target:** ZCU102 + ADRV9002 in LVDS 2-Lane DDR mode at 20 Msps complex (10 MHz BW), to support the validated `tes_0231_Haifuraiya_FDD_LVDS_20Msps_10MHz.json` profile.

---

## TL;DR

The Haifuraiya LVDS port is **structurally tiny**. The infrastructure to flip CMOS↔LVDS already exists in our integration code; it just hasn't been exercised yet. Most of pluto_msk's LVDS port pain doesn't transfer to us because our architecture is different — specifically, the channelizer runs on PS clock (100 MHz) with a CDC FIFO bridging the chip-clock domain, whereas pluto_msk had its MSK modem running directly on the chip's l_clk domain and had to derive a divided clock for the modem.

**First-pass plan:**
1. Build with `CMOS_LVDS_N=0` — let the existing infrastructure do its job
2. Watch for timing failures (the new chip-side clock frequency is the main unknown)
3. Deploy + load the LVDS profile + verify cal + verify samples flow
4. Iterate on any surprises

Estimated effort: **0.5–2 days of HDL work** if no surprises (compared to many days for pluto_msk's port). Plus the FIR MAC pipeline-register timing fix that we already have planned, which should happen first.

---

## Architecture comparison

### pluto_msk LibreSDR LVDS port (the precedent)

```
AD9361 LVDS data ──l_clk (245.76 MHz)──> axi_ad9361 ──> [parallel IQ]
                                                         |
                                                         ↓
                                              msk_top.clk (61.44 MHz from clk_div_by4)
                                              msk_top.s_axis_aclk (245.76 MHz from l_clk)
                                              ↑
                              clk_div_by4 (BUFG divider) ─── derives 61.44 MHz
                                              ↑
                                          l_clk (245.76 MHz)
```

The MSK modem's internal DSP runs at the **sample rate** (61.44 MHz). At LVDS rates, the SSI clock is 4× the sample rate, so they needed a divider. Plus pulse stretchers because valid signals from AD9361 are 1-cycle pulses on l_clk that the slower modem clock would miss.

### Haifuraiya CMOS (current)

```
ADRV9002 CMOS data ──adc_1_clk (CMOS rate)──> axi_adrv9001 ──> [parallel IQ]
                                                                |
                                                                ↓
                                                   axis_iq_wrapper (combinational, on adc_1_clk)
                                                                ↓
                                                   data_cdc_fifo_rx1 (async FIFO, IS_ACLK_ASYNC=1)
                                                                ↓
                                                   channelizer_rx1 (on sys_cpu_clk = 100 MHz)
                                                                ↓
                                                   axi_adrv9001_rx1_dma (AXIS, on sys_cpu_clk)
```

Critically: **the channelizer is decoupled from the chip's clock domain by an async FIFO.** Whatever rate the ADRV9002 emits at (CMOS or LVDS), the channelizer just sees AXIS at 100 MHz with appropriate tvalid pacing.

### Haifuraiya LVDS (target)

Same diagram as Haifuraiya CMOS. Just `adc_1_clk` runs at a different frequency. The CDC FIFO absorbs the rate change.

```
ADRV9002 LVDS data ──adc_1_clk (LVDS rate)──> axi_adrv9001 ──> [parallel IQ]
                                                                |
                                                                ↓
                                                   axis_iq_wrapper (combinational, on new adc_1_clk)
                                                                ↓
                                                   data_cdc_fifo_rx1 (handles any slave-side rate)
                                                                ↓
                                                   channelizer_rx1 (unchanged)
                                                                ↓
                                                   axi_adrv9001_rx1_dma (unchanged)
```

The only difference is `adc_1_clk` frequency. The CDC FIFO doesn't care; the channelizer doesn't see it.

---

## File-level change inventory

### Files that need NO changes

These were already designed parametrically or are intrinsically rate-agnostic:

- `haifuraiya/rtl/**` — the channelizer itself runs at 100 MHz internal, fixed sample-rate-independent
- `haifuraiya/syn/zcu102_with_adrv9001/axis_iq_wrapper.vhd` — purely combinational
- `haifuraiya/syn/zcu102_with_adrv9001/system_project.tcl` — already branches on `CMOS_LVDS_N` (line 105–109 picks the right XDC)
- `haifuraiya/syn/zcu102_with_adrv9001/system_bd.tcl` — already passes `CMOS_LVDS_N` through to `axi_adrv9001` IP (line 47–48)

### Files that need verification but probably no changes

- `Makefile` — `haifuraiya-xsa-integrated` target should accept `CMOS_LVDS_N=0` as an env var passed through to the Vivado batch. Currently it doesn't explicitly forward it. **Action: confirm whether `make haifuraiya-xsa-integrated CMOS_LVDS_N=0` propagates correctly, or add explicit forwarding.**

### Files we DON'T own that handle LVDS for us

These live in the ADI submodule (`haifuraiya/third_party/hdl/`):

- `$ad_hdl_dir/projects/adrv9001/zcu102/lvds_constr.xdc` — LVDS pin constraints (IOSTANDARD = LVDS, differential pair mapping)
- `$ad_hdl_dir/projects/adrv9001/common/adrv9001_bd.tcl` — ADRV9002 block-design helper, internally branches on CMOS_LVDS_N to set up the SSI interface inside the axi_adrv9001 IP
- `$ad_hdl_dir/projects/adrv9001/zcu102/system_top.v` — top-level Verilog wrapper, has CMOS_LVDS_N parameter

**We don't touch any of these.** They're tested by ADI and pinned to `hdl_2022_r2`.

---

## Build invocation

Likely correct (verify Makefile forwarding):

```bash
make haifuraiya-xsa-integrated CMOS_LVDS_N=0
```

What this does, traced through:

1. Top-level Makefile → `cd haifuraiya/syn/zcu102_with_adrv9001 && vivado -mode batch -source system_project.tcl`
2. `system_project.tcl` line 79: `set CMOS_LVDS_N [get_env_param CMOS_LVDS_N 1]` — picks up env var, defaults to 1 (CMOS)
3. `system_project.tcl` line 105–109: `if {$CMOS_LVDS_N == 0}` picks up `lvds_constr.xdc`
4. `adi_project` call (line 87–89) passes `CMOS_LVDS_N=0` into the project params
5. `system_bd.tcl` line 48: `ad_ip_parameter axi_adrv9001 CONFIG.USE_RX_CLK_FOR_TX 1` (because `$ad_project_params(CMOS_LVDS_N) == 0`)
6. `system_bd.tcl` line 57: sysid string becomes `"CMOS_LVDS_N=0"` → baked into ROM
7. ADI's `adrv9001_bd.tcl` (sourced from system_bd.tcl line 44) configures the SSI interface for LVDS internally — this is the part we don't have to write

---

## Risks & unknowns

### Likely-to-cause-issues

1. **Timing closure at the new `adc_1_clk` frequency.** We don't yet know what frequency `adc_1_clk` becomes in LVDS mode at 20 Msps. For comparison: pluto_msk's AD9361 at 61.44 Msps had `l_clk` = 245.76 MHz (4× sample rate). If ADRV9002 follows similar serdes math, LVDS at 20 Msps could put `adc_1_clk` somewhere in the 80–160 MHz range. The CDC FIFO doesn't care about the rate but Vivado's timing engine will need it constrained properly. The lvds_constr.xdc should set this.

2. **FIR MAC pipeline register fix should land first.** The CMOS build currently has `system_top_bad_timing.xsa` because of -188 ps WNS on the FIR MAC. Trying LVDS on top of that complicates triage if a new timing fail appears. Do timing fix → close CMOS clean → then attempt LVDS.

3. **`axis_iq_wrapper`'s `aresetn` polarity.** The wrapper is on `adc_1_clk`, which is now a different (higher) frequency. The reset synchronization in ADI's reference might or might not be CDC-safe to PS clock. The existing CDC FIFO has its own reset sync, so probably fine, but worth a careful look at the post-synth simulation if available.

### Probably-fine but worth checking

4. **The channelizer at 20 MSps input.** Documented design point is 10 MSps. From `system_bd.tcl` comment block:
   > "At 100 MHz aclk with 10 MSps complex input and M_DECIMATION=16:
   >  Input AXIS  : up to 1 beat per 10 clocks (~10% of capacity)
   >  Output AXIS : 64 beats every 160 clocks  (~40% of capacity)"
   
   At 20 Msps: ~20% input capacity, ~80% output capacity. Still under 100%, so flow control should still work. But the FIR taps and FFT precision were designed/verified at 10 Msps — we should re-run the channelizer testbench at the higher rate to confirm spectral behavior holds.

5. **Sample rate sysfs reporting on the board.** The CMOS build reports 1.92 Msps after profile load. The LVDS profile reports 20 Msps. `dma_listen` does math on the reported rate (`each refill covers X ms`); should still work but worth confirming the IIO `sampling_frequency` attribute reads back the new value correctly.

### Already known and handled

6. **The driver SSI mismatch check** — discovered yesterday: loading an LVDS profile against the CMOS HDL build gets `adrv9002: SSI interface mismatch. PHY=1, RX1=2 → cat: write error: Invalid argument`. Once the HDL is LVDS, `PHY` becomes 2 and the LVDS profile will match.

### Unique-to-pluto-msk problems that DON'T transfer to us

These are pluto_msk lessons we benefit from *avoiding* — we don't need to solve them:

- ❌ **No clock divider needed.** Channelizer is on PS clock, not chip clock. No `clk_div_by4` equivalent.
- ❌ **No pulse stretcher needed.** Wrapper is combinational on `adc_1_clk`; the valid signal stays in domain until the CDC FIFO synchronizes it to 100 MHz.
- ❌ **No TX-path sync register reshuffling.** TX1 and TX2 are unmodified ADI reference paths in Haifuraiya. We aren't touching them at all.
- ❌ **No ILA monitor mode gotcha.** We don't have an ILA on the channelizer path. If we add one for diagnostics later, remember pluto_msk's lesson: `CONFIG.C_MONITOR_TYPE {Native}`, not AXI.
- ❌ **No spectral spur at byte-rate.** That was pluto_msk's `ov_frame_encoder` debug; we don't have one in this datapath.

---

## Work-package breakdown

### Prerequisite (already planned, in progress)

**WP-0: FIR MAC pipeline registers.** Add 1–2 register stages between the chained DSP slices in `fir_branch_parallel.vhd` to close the -188 ps WNS. Re-run channelizer testbench (10/10 pass expected — no functional change). Rebuild CMOS bitstream → clean `system_top.xsa`. Deploy + verify on bench using the existing 1T1R cal flow.

*This is independent of LVDS but should land first for clean baseline timing.*

### LVDS port proper

**WP-1: Confirm Makefile parameter forwarding.** Test that `make haifuraiya-xsa-integrated CMOS_LVDS_N=0` actually passes the variable through to Vivado's environment. If not, add explicit `-tclargs` or environment forwarding. Time: <1 hour.

**WP-2: First LVDS build attempt.** Run the build, expect synth/impl to complete or fail with clear LVDS-specific errors. Capture vivado.log. Likely outcomes:
- Build succeeds → proceed to WP-3
- Timing fails on `adc_1_clk` chain → tighten or check XDC, possibly add pipeline regs in axis_iq_wrapper
- Synth errors → check ADI submodule LVDS path completeness for our pinned version

Time: 5–6 hours of wall clock (Vivado batch) + triage.

**WP-3: Deploy + initial bring-up.** Import XSA → PetaLinux build → boot. Verify on board:
- `dmesg | grep adrv9002` — clean init
- Sysid ROM reports `CMOS_LVDS_N=0` (vs. current `CMOS_LVDS_N=1`)
- Loading `tes_0231_Haifuraiya_FDD_LVDS_20Msps_10MHz.json` now succeeds (no SSI mismatch)
- `oriinit-cli status` shows 20 Msps sample rate
- `oriinit-cli run-calibrations` completes
- `dma_listen` shows samples flowing at the new rate

Time: 1–2 hours assuming the build worked.

**WP-4: Channelizer behavior verification at 20 Msps.** Re-run `tb_haifuraiya_channelizer_axi.vhd` at 20 Msps input (the current testbench may be at 10 Msps or lower — check and parameterize if needed). Confirm:
- Spectral output looks correct (impulse response, sub-bin frequency response)
- No new timing-related FFT precision issues
- M_DECIMATION=16 still produces clean per-channel decimation at 20 Msps input

Time: 2–4 hours including any TB parameter changes.

**WP-5: End-to-end RF test (when convenient).** Inject a CW from another SDR at the configured RX LO frequency, verify the channelizer detects it in the correct channel bin. This is the "is the LVDS path actually working for signals?" test, analogous to the 1T1R cal test we did for CMOS. Time: 30 min if you have signal generation handy.

### Parallel-able

- WP-1 can happen any time
- WP-2 needs WP-0 done first (clean baseline)
- WP-3 needs WP-2 done
- WP-4 can happen in parallel with WP-2/WP-3 (testbench work, no hardware needed)
- WP-5 needs WP-3 done

---

## Open questions to answer before HDL work starts

1. **What's the actual `adc_1_clk` frequency in LVDS mode at 20 Msps?** Need to check ADRV9002 datasheet or trace through ADI's `adrv9001_bd.tcl` to see the SSI serdes config.

2. **Does `adi_project` propagate env vars to Vivado correctly?** Test with a non-default `CMOS_LVDS_N=0` on a throwaway sanity-check run before triggering a full 5-hour synth.

3. **Is the ZCU102's ADRV9002 carrier wired for LVDS?** Yes — the same physical board pins support both CMOS and LVDS; the difference is which signals the chip drives and the IOSTANDARD on the FPGA side. Confirmed by ADI's reference design supporting both modes on the same board.

4. **Does the channelizer testbench parameterize sample rate?** If it does, just bump and re-run. If it doesn't, parameterize first (small lift), then re-run.

5. **Will the FIR MAC pipeline fix affect the channelizer's IP-XACT packaging or interface signatures?** Almost certainly not (internal change), but worth confirming so re-packaging isn't needed.

---

## Suggested next steps in priority order

1. **Finish WP-0** (FIR MAC pipeline registers). This is the right next thing regardless of LVDS port priority.
2. **Resolve open question 2** (Makefile parameter forwarding). 1-hour task. Could be done in parallel with WP-0.
3. **Investigate open question 1** (LVDS clock frequency at 20 Msps). Pure research, no HDL work. Could be done while WP-0 is running.
4. **WP-1 verify and WP-2 first build attempt.**
5. **WP-3, WP-4 in parallel.**
6. **WP-5 when convenient.**

The LVDS port is well-positioned to be a small, low-risk operation. The architectural decisions made earlier (CDC FIFO between chip-side and channelizer-side clock domains, parameterized `CMOS_LVDS_N` from day one) mean we have most of the structure in place. The pluto_msk port was harder because of fundamentally different architectural choices around clock domains.

仇討ち continues. 🌲🗡️
