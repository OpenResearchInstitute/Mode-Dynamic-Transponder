"""
power_detector_model.py -- cycle-accurate model of ORI power_detector + lowpass_ema
for the Haifuraiya/MDT build (power_detector DATA_W=16, IQ_MOD, EMA_CASCADE).

Sources (public ORI repos, CERN-OHL-W, M. Wishek):
  lowpass_ema    @ 280fe847
  power_detector @ 86bae9a0

Each lowpass_ema: DATA_W=31, ALPHA_W=18, MULT_A_W=33, PROD_W=51
  -> SUM_SHIFT_W=18, MULT_DATA_SHIFT=3, MULT_SUM_SHIFT=1, AVG_SHIFT=20,
     alpha_max=2^17-1, saturate sum to +/-2^50.

Strict two-phase synchronous semantics: compute all next-state from CURRENT
registers + inputs, commit together, return POST-commit registered outputs.
Proven bit-exact to the RTL by dump-compare.
"""

def sresize(x, w):
    m = 1 << w; x &= m - 1
    return x - m if x & (1 << (w - 1)) else x

def uresize(x, w):
    return x & ((1 << w) - 1)

def ashr(x, n):
    return x >> n


class LowpassEMA:
    def __init__(self, DATA_W=31, ALPHA_W=18, MULT_A_W=33, PROD_W=51):
        self.DATA_W = DATA_W; self.ALPHA_W = ALPHA_W; self.PROD_W = PROD_W
        self.alpha_max = (1 << (ALPHA_W - 1)) - 1
        self.SUM_SHIFT_W     = PROD_W - MULT_A_W
        self.MULT_DATA_SHIFT = PROD_W - ALPHA_W - DATA_W + 1
        self.MULT_SUM_SHIFT  = self.SUM_SHIFT_W - (ALPHA_W - 1)
        self.AVG_SHIFT       = PROD_W - DATA_W
        self.SAT_MAX = (1 << (PROD_W - 1)) - 1
        self.SAT_MIN = -(1 << (PROD_W - 1))
        self.r = dict(alpha_signed=0, alpha_m=0, data_signed=0,
                      mult_data=0, mult_sum=0, average=0, average_ena=0)

    def _sum(self):
        sw = (self.r['mult_data'] << self.MULT_DATA_SHIFT) + \
             (self.r['mult_sum']  << self.MULT_SUM_SHIFT)
        if   sw > self.SAT_MAX: return self.SAT_MAX
        elif sw < self.SAT_MIN: return self.SAT_MIN
        return sresize(sw, self.PROD_W)

    def next_state(self, data, data_ena, alpha, init):
        s = self._sum()
        sum_shift = ashr(s, self.SUM_SHIFT_W)
        if init:
            return dict(alpha_signed=0, alpha_m=0, data_signed=0,
                        mult_data=0, mult_sum=0, average=0, average_ena=0)
        r = self.r
        if data_ena:
            ns = dict(
                alpha_signed = sresize(alpha, self.ALPHA_W),
                alpha_m      = self.alpha_max - r['alpha_signed'],
                data_signed  = sresize(data, self.DATA_W),
                mult_data    = sresize(r['data_signed'] * r['alpha_signed'], self.PROD_W),
                mult_sum     = sresize(sum_shift * r['alpha_m'], self.PROD_W),
                average      = sresize(ashr(s, self.AVG_SHIFT), self.DATA_W),
            )
        else:
            ns = dict(alpha_signed=r['alpha_signed'], alpha_m=r['alpha_m'],
                      data_signed=r['data_signed'], mult_data=r['mult_data'],
                      mult_sum=r['mult_sum'], average=r['average'])
        ns['average_ena'] = data_ena
        return ns

    def commit(self, ns):
        self.r = ns


class PowerDetector:
    def __init__(self, DATA_W=16, ALPHA_W=18, EMA_CASCADE=True):
        self.DW = DATA_W; self.PW = 2 * DATA_W - 1
        self.CASC = EMA_CASCADE
        self.f = dict(di_sq=0, dq_sq=0, dsum=0, dsum_e1=0, dsum_e2=0)
        self.ema1 = LowpassEMA(self.PW, ALPHA_W, self.PW + 2, self.PW + 2 + ALPHA_W)
        self.ema2 = LowpassEMA(self.PW, ALPHA_W, self.PW + 2, self.PW + 2 + ALPHA_W)

    def step(self, I, Q, data_ena, alpha1, alpha2, init):
        f = self.f
        if init:
            fn = dict(di_sq=0, dq_sq=0, dsum=0, dsum_e1=0, dsum_e2=0)
        else:
            Is, Qs = sresize(I, self.DW), sresize(Q, self.DW)
            fn = dict(
                dsum_e1 = data_ena,
                dsum_e2 = f['dsum_e1'],
                di_sq   = uresize(Is * Is, self.PW),
                dq_sq   = uresize(Qs * Qs, self.PW),
                dsum    = uresize(f['di_sq'] + f['dq_sq'], self.PW),
            )
        e1n = self.ema1.next_state(f['dsum'], f['dsum_e2'], alpha1, init)
        e2n = self.ema2.next_state(self.ema1.r['average'], self.ema1.r['average_ena'],
                                   alpha2, init)
        self.f = fn
        self.ema1.commit(e1n)
        self.ema2.commit(e2n)
        psq = self.ema2.r['average'] if self.CASC else self.ema1.r['average']
        return (psq, self.f['dsum'], self.f['dsum_e2'],
                self.ema1.r['average'], self.ema1.r['average_ena'])
