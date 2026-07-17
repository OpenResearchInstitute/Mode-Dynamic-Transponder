# Per-Channel Normalizer: the three registers

Open Research Institute / Mode-Dynamic-Transponder / Haifuraiya
2026-07-10

---

## What the normalizer is

Every channel out of the channelizer carries a different station, at a different
signal strength. The demodulator's 3-bit soft-decision quantizer has fixed
thresholds, so it only works correctly at one input level. The normalizer scales
each channel so every channel arrives at the demodulator at the **same
amplitude**, no matter how strong or weak the station is.

It is one line of arithmetic:

```
    gain = GAIN_TARGET / sqrt( max(channel_power, SQUELCH_THR) )
    out  = saturate( in * gain )
```

`channel_power` is `I^2 + Q^2`, already measured per channel by the existing
`power_detector`. Nothing new measures anything.

It sits **between `channel_eq` and the AXI-Stream master.** The power detectors
keep tapping the un-normalized equalizer output. Sense before, correct after.
This is a **feed-forward** correction, not a feedback loop: the gain is computed
from a measurement taken *upstream* of the gain, so nothing the gain does can
ever change the measurement.

---

## GAIN_MODE

**What it is:** one bit. `0` = off. `1` = on.

**What it does:**

| value | behaviour |
|---|---|
| `0` (default) | The normalizer multiplies by `GAIN_MANUAL` and nothing else. With `GAIN_MANUAL = 0x0400` (unity in Q6.10) the output is **bit-for-bit identical to the input**. The block is invisible. |
| `1` | The normalizer computes `gain = GAIN_TARGET / sqrt(power)` per channel and applies it. |

**Why it exists:** so the receiver can be operated, observed, and debugged with
no automatic gain of any kind. Every channel passes through untouched and you see
raw, un-normalized levels on the AXI-Stream and in Bouro. This is the mode you
want for characterisation, for comparing against old captures, and for proving
that inserting the block changed nothing.

`GAIN_MODE = 0` is the reset default. **A receiver that has never been configured
behaves exactly as it did before the normalizer existed.**

---

## GAIN_TARGET

**What it is:** a 16-bit unsigned number. The amplitude, in ADC counts, that
every normalized channel is scaled to.

**Units:** counts of the 16-bit channel sample (full scale = 32767).

**Recommended value:** `16000`, which is -6.2 dBFS.

**What it does:** it *is* the setpoint. After normalization, a channel carrying a
constant-envelope MSK signal has `|I + jQ| = GAIN_TARGET`, regardless of how
strong the station was.

**Why it exists:** every fixed constant downstream of the normalizer is
calibrated against this one number:

- `QUANT_THR_1/2/3`, the soft-decision thresholds
- `SYM_LOCK_THRESHOLD`
- `FS_HUNT_THRESH` / `FS_VERIFY_THRESH`

Set `GAIN_TARGET` once. Then set those. Then never touch any of them again.
That is the entire point of the block: **gain is the only thing that varies;
everything after it is permanent.**

**How to choose it.** Two constraints pull in opposite directions:

- *Too high* and a strong station saturates the multiply. `gain_sat` telemetry
  goes high. MSK is constant-envelope, so peak = RMS, and 16000 leaves ~6 dB of
  headroom for the acquisition transient before the gain has settled.
- *Too low* and weak channels lose resolution in the 16-bit word, and the maximum
  gain needed exceeds what the Q6.10 gain word can express (63.99x, +36.1 dB).

`16000` is comfortably inside both. `16384` is **not** a good choice despite
being a power of two: it needs a gain of exactly 65536 at the weakest tracked
channel, which is one code past the 16-bit gain word, and it silently costs a
whole octave (6 dB) of dynamic range.

---

## SQUELCH_THR

**What it is:** a 31-bit unsigned number. A power level, in the same units as
`CHANNEL_POWER[k]` that Bouro already displays (`I^2 + Q^2`).

**Recommended value:** `65536` (channel amplitude 256), pending a measurement of
the actual channelizer noise floor.

**What it does, and it does two jobs:**

**Job 1 -- it stops the gain from exploding.** `gain = TARGET / sqrt(power)` goes
to infinity as power goes to zero. An empty channel, containing nothing but
receiver noise, would be amplified to full scale. `SQUELCH_THR` is the floor:
below it, the gain stops growing.

```
    gain = GAIN_TARGET / sqrt( max(power, SQUELCH_THR) )
                               ^^^^^^^^^^^^^^^^^^^^^^^
```

**Job 2 -- it defines "this channel is active."** A channel whose power sits
below `SQUELCH_THR` has no station on it. That is the channel-occupancy
threshold the transponder needs anyway, for scheduling and for telemetry. One
register, both jobs, and they cannot disagree with each other.

**How to choose it.** Measure the per-channel noise floor with no transmitter:
read `CHANNEL_POWER[1..63]` from Bouro with the antenna terminated. **Skip
channel 0** -- it carries the LO leakage DC spike. Channels 28-31 and 33-36 read
up to +2.67 dB high; that is `channel_eq`'s droop correction, not noise. Then

```
    SQUELCH_THR ~= 4 x (measured noise floor)      (6 dB of margin)
```

**There is a hard constraint.** The gain word is Q6.10, so it cannot express a
gain above 63.99x. If `SQUELCH_THR` is set too low, the gain hits that ceiling
before it reaches the squelch floor, and `SQUELCH_THR` becomes inert -- the
ceiling silently does the clamping instead, at a level you did not choose.

```
    SQUELCH_THR  >=  ( GAIN_TARGET * 1024 / 65535 )^2
```

For `GAIN_TARGET = 16000` that is `SQUELCH_THR >= 62500`. The recommended 65536
satisfies it with margin. **The RTL asserts this.**

**What this gives you.** With `GAIN_TARGET = 16000` and `SQUELCH_THR = 65536`:

```
    weakest tracked channel amplitude    256   (gain +35.9 dB)
    strongest before clipping          32767   (gain  -6.2 dB)
    usable dynamic range                42.1 dB
```

For reference: a PlutoSDR's own RF AGC railed after 34 dB on a real link
(kb5mu, 2026-07-06). Haifuraiya has no RF AGC at all -- 64 stations share one
ADC, so an RF AGC would see only the composite and one loud station keying up
would desense the other 63. This block is the **only** gain control in the chain.
42 dB is what it must cover.

---

## What is NOT here, and why

An earlier draft of this block had `attack_shift`, `release_shift`,
`squelch_hang`, `freeze`, a dwell-hysteresis counter, a 32-entry AXI-writable
gain LUT, and six per-channel state RAMs. All of it is gone.

| removed | why it was not needed |
|---|---|
| `attack_shift` / `release_shift` | An envelope filter, built next to the 64 envelope filters `power_detector` already has. The AGC time constant is `POWER_ALPHA1`/`POWER_ALPHA2`, which exist. |
| asymmetric attack vs release | Rides modulation nulls. OPV is constant-envelope MSK. There are no nulls -- measured steady-state power ripple is +-10%. |
| `squelch_hang`, hold, clear, `qcnt` | Cured a problem *caused by* the asymmetry: a quiet station landing on a channel a loud one just left had to travel the slow release path. Symmetric tracking makes both directions equal. Disease and cure both removed. |
| `freeze` | Stop adapting on frame lock. Nothing to wander from with a constant envelope, and a real fade should be tracked, not frozen. |
| `HYST_DWELL` | Guarded against 3 dB dither at an octave boundary. The gain step is now 0.017 dB. |
| 32-entry AXI gain LUT | `gain = TARGET * 2^(-e/2)` is fixed math. It is now a 128-entry **compiled-in** reciprocal-sqrt ROM. Nothing to program. |
| per-channel state RAM | `power_detector` already holds the per-channel state. The normalizer is stateless. |

**Per-channel state in the normalizer: none.**
**Registers: three.**
**DSP: two multiplies.**
