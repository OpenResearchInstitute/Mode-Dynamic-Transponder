#!/usr/bin/env python3
"""
gen_power_detector_vectors.py -- golden-vector generator for tb_power_detector.

Model: power_detector_model (cycle-accurate, proven bit-exact to the ORI RTL
       power_detector @86bae9a0 + lowpass_ema @280fe847 by dump-compare).

ANALYTIC oracle (on the model):
  - DC convergence: constant power in -> power_squared settles to I^2+Q^2 within
    the EMA's fixed-point DC droop (a few percent), monotonically. Confirms the
    two-stage low-pass actually averages/settles.
  - 51-bit feedback trap (WP2): a model that reloads only the 31-bit `average`
    as feedback DIVERGES from the full 51-bit `mult_sum` model. Demonstrated and
    reported (this is why the model/RTL must carry full-width state).

BIT-EXACT feed: pd_input.txt "I Q ena" ; pd_expected.txt "power_squared ema_1".
Stream: DC-ramp segment, step, a data_ena GAP (ema must hold), then random.
alpha1=4096 (2^-6 fast), alpha2=64 (2^-12 slow) -- the channelizer defaults.
"""
import sys, os, random
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
_VEC = os.path.join(os.path.dirname(os.path.abspath(__file__)), "vectors")
os.makedirs(_VEC, exist_ok=True)

from power_detector_model import PowerDetector, LowpassEMA, sresize, ashr

ALPHA1, ALPHA2 = 4096, 64

def analytic_checks():
    fails = []
    # DC convergence
    pd = PowerDetector()
    for _ in range(4): pd.step(0, 0, 0, ALPHA1, ALPHA2, True)
    I, Q = 1500, 0; target = I*I + Q*Q
    prev = -1; monotonic = True; psq = 0
    for n in range(80000):
        psq, *_ = pd.step(I, Q, 1, ALPHA1, ALPHA2, False)
        if psq < prev: monotonic = False
        prev = psq
    droop = 100 * (target - psq) / target
    print(f"  DC convergence: ({I},{Q}) dsum={target} -> power_squared={psq} "
          f"(droop {droop:.2f}%, monotonic {monotonic})")
    if not monotonic:      fails.append("DC ramp not monotonic")
    if not (0 <= droop < 5): fails.append(f"DC droop {droop:.2f}% out of range")

    # 51-bit feedback trap demonstration
    class Trap(LowpassEMA):
        def next_state(self, data, data_ena, alpha, init):
            s = self._sum()
            avg31 = sresize(ashr(s, self.AVG_SHIFT), self.DATA_W)
            sum_shift = ashr(avg31 << self.AVG_SHIFT, self.SUM_SHIFT_W)  # WRONG: truncated fb
            if init: return {k: 0 for k in self.r}
            r = self.r
            if data_ena:
                ns = dict(alpha_signed=sresize(alpha, self.ALPHA_W),
                          alpha_m=self.alpha_max - r['alpha_signed'],
                          data_signed=sresize(data, self.DATA_W),
                          mult_data=sresize(r['data_signed']*r['alpha_signed'], self.PROD_W),
                          mult_sum=sresize(sum_shift * r['alpha_m'], self.PROD_W),
                          average=sresize(ashr(s, self.AVG_SHIFT), self.DATA_W))
            else:
                ns = dict((k, r[k]) for k in ('alpha_signed','alpha_m','data_signed',
                                              'mult_data','mult_sum','average'))
            ns['average_ena'] = data_ena; return ns
    good, bad = LowpassEMA(), Trap(); random.seed(1); md = 0
    for _ in range(20000):
        d = random.randint(0, 2_000_000)
        good.commit(good.next_state(d, 1, ALPHA1, False))
        bad.commit(bad.next_state(d, 1, ALPHA1, False))
        md = max(md, abs(good.r['average'] - bad.r['average']))
    print(f"  51-bit feedback trap: full-width vs 31-bit-feedback differ by up to "
          f"{md} -> {'DIVERGES (full width required)' if md > 0 else 'no diff'}")
    return fails

print("[gen_power_detector_vectors] analytic checks on golden model:")
_f = analytic_checks()
if _f:
    print("  MODEL FAILED:", _f); sys.exit(1)
print("  analytic oracle: PASS\n")

# ---- bit-exact stream ----
random.seed(0xEEA)
stream = []                                   # (I, Q, ena)
for _ in range(150): stream.append((1500, 0, 1))       # DC ramp (monotonic climb)
for _ in range(120): stream.append((3000, 3000, 1))    # step up
for _ in range(12):  stream.append((3000, 3000, 0))    # data_ena GAP: ema holds
for _ in range(120): stream.append((800, -800, 1))     # step down
for _ in range(200): stream.append((random.randint(-9000, 9000),
                                    random.randint(-9000, 9000), 1))

pd = PowerDetector()
for _ in range(4): pd.step(0, 0, 0, ALPHA1, ALPHA2, True)
with open(os.path.join(_VEC, "pd_input.txt"), "w") as fi, \
     open(os.path.join(_VEC, "pd_expected.txt"), "w") as fe:
    for (I, Q, ena) in stream:
        psq, dsum, dse2, e1, e1ena = pd.step(I, Q, ena, ALPHA1, ALPHA2, False)
        fi.write(f"{I} {Q} {ena}\n")
        fe.write(f"{psq} {e1}\n")

print(f"[gen_power_detector_vectors] wrote {len(stream)} cycles "
      f"(DC ramp, step, data_ena gap, random); alpha1={ALPHA1} alpha2={ALPHA2}")
