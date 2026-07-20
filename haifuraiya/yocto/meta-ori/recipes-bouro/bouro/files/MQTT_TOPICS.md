# Bouro MQTT Topic Surface (v0)

This document describes the MQTT topic structure published by
`bouro_pub.sh` on the ZCU102. Subscribe at `mqtt://<zcu102-ip>:1883`
(TCP) or `ws://<zcu102-ip>:9001/wss` (WebSockets, browser-friendly).
Anonymous, no auth, broker is `mosquitto`.

Companion to the `pluto_msk` overlay's MQTT_TOPICS.md, which documents
the equivalent surface for the OVP modem on the LibreSDR/Pluto. The
publishers share an architecture but instrument different subsystems
(channelizer vs. modem).

## Namespace structure

```
haifuraiya/status/register/<name>          Raw hex from devmem
haifuraiya/status/derived/<name>/<aspect>  Parsed/computed values
haifuraiya/status/heartbeat                Liveness signal (ISO 8601 timestamp)
haifuraiya/status/publisher/<aspect>       Publisher metadata
```

Update rate is approximately **0.3 Hz** on the ZCU102. The publisher
walks 8 scalar registers + 64 channel-power registers per cycle, each
invoking `mosquitto_pub` as a separate process, plus a `sleep 1`. With
~150 topics per cycle, total cycle time is dominated by process-forking
overhead. Sufficient for visual dashboards; insufficient for catching
sub-second transients. Future optimization: rewrite with a single
persistent broker connection (Python+`paho-mqtt` is the natural choice).

Both raw register values and derived values are always published;
bandwidth is irrelevant on a LAN and the raw values aid forensic
debugging.

## How to subscribe

From any machine with `mosquitto-clients` installed:

```sh
# All channelizer topics
mosquitto_sub -h <zcu102-ip> -t 'haifuraiya/status/#' -v

# Just the 64-bar spectrum (JSON array)
mosquitto_sub -h <zcu102-ip> -t 'haifuraiya/status/derived/power_spectrum' -v

# Just frame counters (raw + derived delta)
mosquitto_sub -h <zcu102-ip> -t 'haifuraiya/status/+/frame_count/#' -v
```

From a browser, use the Paho MQTT JavaScript library connecting to
`ws://<zcu102-ip>:9001/wss`. See `bouro.html` for the reference
dashboard.

## Raw register topics

Every channelizer register from `0x000` through `0x1FC` is published.
Topic pattern: `haifuraiya/status/register/<name>`. Payload is the raw
hex string as returned by `devmem` (e.g. `0x00010000`). One topic per
register. Useful for forensic captures and for any subscriber that
wants its own parsing.

### Scalar registers (8)

| Register | Address | Notes |
|---|---|---|
| `version` | 0x000 | RO. Reads `0x00010000` if bitstream loaded |
| `control` | 0x004 | RW. Bit 0 soft_reset (sticky), bit 1 enable |
| `status` | 0x008 | RO. Bit 0 ready, bit 1 overflow sticky, bit 2 backpressure sticky |
| `frame_count` | 0x00C | RO. 32-bit monotonic, wraps at 2³² |
| `dropped_frames` | 0x010 | RO. 32-bit monotonic, lost to downstream FIFO overflow |
| `output_shift` | 0x014 | RW. Right-shift on channelizer output, valid 0..24, default 16 |
| `power_alpha1` | 0x018 | RW. First-stage EMA alpha (fast tracker, ~64-sample TC) |
| `power_alpha2` | 0x01C | RW. Second-stage EMA alpha (slow smoother, ~4096-sample TC) |

### Per-channel power registers (64)

| Register | Address |
|---|---|
| `channel_power_0` | 0x100 |
| `channel_power_1` | 0x104 |
| `…` | `…` |
| `channel_power_63` | 0x1FC |

Each is a 32-bit unsigned integer reflecting the integrated power
detector output for that channel. Channel index matches the
channelizer's TDEST.

## Derived topics

Pre-parsed for convenient subscription. Topic pattern:
`haifuraiya/status/derived/<area>/<aspect>`.

### Signature

| Topic | Type | Meaning |
|---|---|---|
| `derived/signature` | string | `OK` if `version` register matches v0.1.0 magic, else `WRONG` |
| `derived/version/major` | int | Major version field |
| `derived/version/minor` | int | Minor version field |
| `derived/version/patch` | int | Patch version field |

### Control

| Topic | Type | Meaning |
|---|---|---|
| `derived/control/soft_reset` | 0/1 | Sticky soft-reset bit |
| `derived/control/enable` | 0/1 | Channelizer enable bit |

### Status

| Topic | Type | Meaning |
|---|---|---|
| `derived/status/ready` | 0/1 | Channelizer ready bit |
| `derived/status/overflow_sticky` | 0/1 | Overflow has occurred (sticky) |
| `derived/status/backpressure_sticky` | 0/1 | Downstream backpressure observed (sticky) |

### Frame counters

| Topic | Type | Meaning |
|---|---|---|
| `derived/frame_count/value` | int | Raw counter (decimal) |
| `derived/frame_count/delta` | int | Frames received since previous cycle (wrap-aware) |
| `derived/dropped_frames/value` | int | Raw counter (decimal) |
| `derived/dropped_frames/delta` | int | Frames dropped since previous cycle (wrap-aware) |

Subscribers tracking "are frames flowing right now?" should subscribe
to the `delta` topics. Subscribers needing absolute truth (or computing
their own deltas at a different cadence) should use `value`. First
cycle after publisher restart emits delta=0 to avoid bogus startup
spikes.

### Tuning parameters

| Topic | Type | Meaning |
|---|---|---|
| `derived/tuning/output_shift` | int | Current OUTPUT_SHIFT value (decimal) |
| `derived/tuning/power_alpha1` | int | Current POWER_ALPHA1 value (decimal) |
| `derived/tuning/power_alpha2` | int | Current POWER_ALPHA2 value (decimal) |

### Power spectrum (the dashboard centerpiece)

| Topic | Type | Meaning |
|---|---|---|
| `derived/power_spectrum` | JSON array | `[v0, v1, …, v63]` of 64 channel powers, decimal integers |

One MQTT message per cycle carries the full 64-channel snapshot. This
is what the 64-bar live spectrum widget in `bouro.html` subscribes
to. Per-channel raw values are still available at
`register/channel_power_N` for forensic use.

If any channel read fails, that slot is zero-filled to keep the array
length stable at 64.

## Heartbeat and publisher metadata

| Topic | Type | Meaning |
|---|---|---|
| `heartbeat` | ISO 8601 string | Published once per cycle; absence indicates publisher dead |
| `publisher/started` | ISO 8601 string | Published once at startup |
| `publisher/pid` | int | PID of publisher process |
| `publisher/version` | string | Version of `bouro_pub.sh` (currently `0.1`) |

## What's NOT here (yet)

- **IIO topics** for the ADRV9002. Pluto's publisher includes them under
  `pluto/status/ovp/iio/<category>/<attr>`. Haifuraiya v0 omits them
  because (a) the ADRV9002 is still in standby pending the profile load
  + cal + arm sequence, and (b) sample-stream-derived telemetry belongs
  to Phase 4 when there's actual signal flowing. Add a `publish_iio()`
  function alongside `publish_scalars()` when those come online.
- **AXIS DMA throughput counters**. Currently exposed by the DMA IP, not
  the channelizer's register block. Add when DMA integration lands.
- **Per-channel demod state** (lock, BER, frame counts). Phase 4a
  territory — one stream first, then 64.

## Demodulator topics (map v6 -- REGISTER_MAP_V6.md is normative)

Publisher v0.2 gates on DEMOD_VERSION 0x00060000
(`derived/demod/signature` = OK | WRONG).

Derived (decimal payloads unless noted):

| topic | source | meaning |
|---|---|---|
| derived/demod/signature | 0x000 | OK when map v6 |
| derived/demod/frame_sync_locked | 0x040 b0 | fsync FSM LOCKED |
| derived/demod/sym_locked | 0x040 b1 | symbol lock detector verdict (sym_lock_detector.vhd; windowed normalized early-late, hysteresis) |
| derived/demod/in_init | 0x040 b3 | DEMOD_INIT held |
| derived/demod/frames_received, frames_delta | 0x044 | totals / per-cycle |
| derived/demod/rx_invert | 0x004 b0 | soft polarity |
| derived/demod/sym_lock/ratio_pct | 0x0A0[15:8] | live 100*S\|L-E\|/S(L+E); locked well under SYM_LOCK_THRESH (25 default), dead air ~100 |
| derived/demod/sym_lock/window_full | 0x0A0 b1 | mean valid |
| derived/demod/sym_clk_offset/q24 | 0x0CC | timing-loop integrator: estimated symbol-clock rate error, SIGNED Q24 samples/symbol |
| derived/demod/sym_clk_offset/ppm_milli | 0x0CC | q24 * 1e6 / 193478 (= 2^24 * 11.5314) |
| derived/demod/tuning/sym_lock_pct, sym_unlock_pct | 0x0A4/0x0A8 | percent (C++ 25/50 defaults) |
| derived/demod/tuning/sym_window_log2 | 0x0AC | window = 2^n symbols |
| derived/demod/tuning/tim_alpha_q16, tim_beta_q24 | 0x0C4/0x0C8 | C++ timing gains verbatim (328 / 168) |

Raw registers (hex, forensics pane): demod_version, demod_control,
demod_status, demod_frames, demod_sym_lock_status, demod_sym_lock_thresh,
demod_sym_unlock_thresh, demod_sym_lock_window, demod_tim_alpha,
demod_tim_beta, demod_sym_clk_offset, demod_fs_hunt_thresh,
demod_fs_verify_thresh, demod_quant_thr_1..3, demod_init.

RETIRED (v5 Costas relics, 0x008-0x03C / 0x060-0x09C): freq_word_f1/f2,
lpf_*, sym_lock_count/threshold, cst_lock_f1/f2 and all related topics
are no longer published or displayed. Addresses are reserved read-zero
per map v6; stale software reads zeros, never plausible values.
