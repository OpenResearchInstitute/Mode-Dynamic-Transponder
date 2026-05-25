# Takadono MQTT Topic Surface (v0)

This document describes the MQTT topic structure published by
`takadono_pub.sh` on the ZCU102. Subscribe at `mqtt://<zcu102-ip>:1883`
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
`ws://<zcu102-ip>:9001/wss`. See `takadono.html` for the reference
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
is what the 64-bar live spectrum widget in `takadono.html` subscribes
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
| `publisher/version` | string | Version of `takadono_pub.sh` (currently `0.1`) |

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

## Adding new topics

Edit `takadono_pub.sh`. Two patterns:

**For a new register-derived value**, add a `pub_derived` call after the
relevant scalar read. Example:

```sh
# In publish_scalars(), after reading STATUS:
pub_derived "status/some_new_bit" "$(((VAL_DEC >> 8) & 1))"
```

**For a new IIO attribute** (once Phase 4 brings ADRV9002 telemetry
online), copy the `pub_iio` helper pattern from
`pluto_msk/firmware/ori/board/pluto/overlay/root/ovp_status_pub.sh`.

After editing, sanity-check with `sh -n takadono_pub.sh` before
deploying. Bump the `PUB_VERSION` string when shipping changes;
subscribers can use it to detect stale publisher versions.
