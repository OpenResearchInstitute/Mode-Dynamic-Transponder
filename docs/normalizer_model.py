"""
normalizer_model.py -- executable reference model for the OPV per-channel
normalize-and-requantize block (see docs/OPV_CHANNEL_NORMALIZER_SPEC.md).

This is the golden model the future RTL will be proven bit-exact against, and
the executable form of the spec: it pins the gain arithmetic and demonstrates
the amplitude contract (every ACTIVE channel leaves at target RMS T).

Chain per spec Sec 4:  measure -> gate -> gain(coarse shift + fine mult) ->
apply on 40-bit -> saturate to 16-bit -> export applied gain (TUSER).

All parameters are labeled. T, ACT_MARGIN_DB, MAX_GAIN_DB are DEFERRED calib
values (spec Sec 9): placeholders here, set from sim/hardware later. The model
is correct for any T within the gain range.
"""
import math

FS16      = 32767
ACCUM_W   = 40
# ---- deferred calibration placeholders (spec Sec 9) ----
T_DBFS       = -12.0                     # target RMS, placeholder (set from demod)
T_RMS        = FS16 * 10**(T_DBFS/20)    # ~8231 codes
ACT_MARGIN_DB= 3.0                       # activity gate: this many dB over noise
MAX_GAIN_DB  = 48.0                      # max boost clamp
NOISE_DBFS   = -36.0                      # where EMPTY channels' noise floor sits
NOISE_TGT_RMS= FS16 * 10**(NOISE_DBFS/20)  # ~520 codes (deferred calib)
# ---- fixed datapath choices (spec Sec 5, "must size now") ----
FINE_BITS    = 10                        # mantissa Q1.10 -> ~0.1% (<< 1% R2 req)
MAX_SHIFT    = 20                        # coarse shift range (covers >100 dB)

def decompose_gain(g):
    """float gain -> (coarse shift s, fine mantissa integer in [2^F, 2^(F+1)))."""
    if g <= 0: return 0, (1 << FINE_BITS)
    s = math.floor(math.log2(g))
    s = max(-MAX_SHIFT, min(MAX_SHIFT, s))
    fine = g / (2.0**s)                          # in [1,2)
    fine_q = int(round(fine * (1 << FINE_BITS)))  # Q1.F
    if fine_q >= (2 << FINE_BITS):               # rounding pushed to 2.0
        fine_q >>= 1; s += 1
    return s, fine_q

def apply_gain(x, s, fine_q):
    """hardware apply: x(40b) * mantissa, shift by (F - s), round-half-up, sat16."""
    prod = x * fine_q
    tshift = FINE_BITS - s
    if tshift > 0:
        scaled = (prod + (1 << (tshift-1))) >> tshift
    else:
        scaled = prod << (-tshift)
    return max(-FS16, min(FS16, scaled))

def normalize_channel(samples, noise_rms, droop=1.0):
    """samples: list of complex ints (40-bit domain). Returns dict of results."""
    # [1] MEASURE power (steady-state EMA equivalent = mean |x|^2)
    p_meas = sum((s.real*s.real + s.imag*s.imag) for s in samples)/len(samples)
    rms_in = math.sqrt(p_meas)
    # [2] GATE
    active = rms_in > (10**(ACT_MARGIN_DB/20) * noise_rms)
    # [3] GAIN
    if active:
        g = (T_RMS / rms_in) * droop
        g = min(g, 10**(MAX_GAIN_DB/20))         # clamp
    else:
        # EMPTY: do NOT normalize noise up to T (false activity) and do NOT hold
        # unity (40-bit noise floor would saturate 16-bit). Place the noise floor
        # at a fixed low level so downstream sees a quiet, consistent channel.
        g = NOISE_TGT_RMS / rms_in if rms_in > 0 else 1.0
    s, fine_q = decompose_gain(g)
    applied = (fine_q / (1 << FINE_BITS)) * (2.0**s)
    # [4]+[5] APPLY + SATURATE
    out = [complex(apply_gain(int(round(x.real)), s, fine_q),
                   apply_gain(int(round(x.imag)), s, fine_q)) for x in samples]
    rms_out = math.sqrt(sum(o.real*o.real+o.imag*o.imag for o in out)/len(out))
    clip = sum(1 for o in out if abs(o.real)>=FS16 or abs(o.imag)>=FS16)/len(out)
    return dict(active=active, rms_in=rms_in, rms_out=rms_out, gain=applied,
                s=s, fine_q=fine_q, clip=clip, p_meas=p_meas)
