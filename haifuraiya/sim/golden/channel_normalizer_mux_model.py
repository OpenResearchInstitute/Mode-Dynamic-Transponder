#!/usr/bin/env python3
"""channel_normalizer_mux_model.py -- fixed-point reference for
channel_normalizer_mux.vhd. Numpy-free.

Mirrors the RTL exactly, including the state-RAM discipline:

  edge n:
    p_s0  reads env_ram/gain_ram/... at in_chan  (values as of the START of the
          edge -- p_s1's write for THIS edge has not landed yet)
          computes s0_pow = sat(in_i^2 + in_q^2)
          registers in_i/in_q/in_chan/in_valid
    p_s1  consumes the stage-0 snapshot, computes the new state, WRITES it back
          to the RAM at s0_chan, and forwards n_gain to s1_gain
    p_s2  multiplies s1_i * s1_gain, rounds half-up, saturates

  So the sample presented at in_i[n] is multiplied by the gain computed from
  that same beat's power, and emerges 3 clocks later with out_valid.

  Because a channel reappears only every N_CHANNELS beats, the write-back at
  edge n+1 always lands long before that channel is read again. There is no
  forwarding path and none is needed. The testbench asserts this.

NOTE: Python's >> on a negative int floors toward -inf, exactly as VHDL's
shift_right(signed, n) does. Do not "fix" this.

License: CERN-OHL-S-2.0
"""

DATA_W     = 16
GAIN_W     = 16
GAIN_FRAC  = 10
POWER_W    = 31
HYST_DWELL = 16

MAX_POS = 2**(DATA_W - 1) - 1
MIN_NEG = -(2**(DATA_W - 1))
POW_MAX = 2**POWER_W - 1
UNITY   = 1 << GAIN_FRAC


def round_sat(prod, frac=GAIN_FRAC):
    r = (prod + (1 << (frac - 1))) >> frac
    if r > MAX_POS:
        return MAX_POS
    if r < MIN_NEG:
        return MIN_NEG
    return r


def saturated(prod, frac=GAIN_FRAC):
    r = (prod + (1 << (frac - 1))) >> frac
    return r > MAX_POS or r < MIN_NEG


def leading_one(v):
    e = 0
    for k in range(POWER_W):
        if (v >> k) & 1:
            e = k
    return e


def power_sat(i, q):
    p = i * i + q * q
    return POW_MAX if p > POW_MAX else p


class ChannelNormalizerMux:
    def __init__(self, lut, n_channels=64, gain_mode=1, gain_manual=UNITY,
                 attack_shift=10, release_shift=13, squelch_thr=0, freeze=0):
        assert len(lut) == 32
        self.N = n_channels
        self.lut = list(lut)
        self.gain_mode = gain_mode
        self.gain_manual = gain_manual
        self.attack_shift = attack_shift
        self.release_shift = release_shift
        self.squelch_thr = squelch_thr
        self.freeze = freeze
        self.reset()

    def reset(self):
        N = self.N
        self.env = [0] * N
        self.gain = [UNITY] * N
        self.expr = [0] * N
        self.cand = [0] * N
        self.dwell = [0] * N
        self.hold = [0] * N
        self.s0 = dict(valid=0, chan=0, i=0, q=0, pow=0,
                       env=0, gain=UNITY, expr=0, cand=0, dwell=0)
        self.s1 = dict(valid=0, chan=0, i=0, q=0, gain=UNITY)
        self.out = dict(valid=0, chan=0, i=0, q=0, sat=0)

    def step(self, in_valid, in_chan, in_i, in_q):
        """One rising edge. Returns the OUTPUT VISIBLE AFTER this edge."""
        # --- p_s2 first: it consumes the OLD s1 ---
        pi = self.s1["i"] * self.s1["gain"]
        pq = self.s1["q"] * self.s1["gain"]
        n_out = dict(valid=self.s1["valid"], chan=self.s1["chan"],
                     i=round_sat(pi), q=round_sat(pq),
                     sat=1 if (saturated(pi) or saturated(pq)) else 0)

        # --- p_s0 READ: in VHDL, p_s0 reads env_ram/gain_ram/... as of the
        # START of the edge. p_s1's write for this same edge has NOT landed yet
        # (signals update after all processes run). So the read must happen
        # BEFORE the write below, or a back-to-back repeat of the same channel
        # would see its own future. Legal streams never repeat within 3 beats,
        # but the model must be right for the illegal case too, or it cannot be
        # used to prove the no-forwarding assumption.
        n_s0 = dict(valid=in_valid, chan=in_chan, i=in_i, q=in_q,
                    pow=power_sat(in_i, in_q),
                    env=self.env[in_chan], gain=self.gain[in_chan],
                    expr=self.expr[in_chan], cand=self.cand[in_chan],
                    dwell=self.dwell[in_chan])

        # --- p_s1: consumes the OLD s0, writes state ---
        s0 = self.s0
        idx = s0["chan"]
        n_env, n_gain = s0["env"], s0["gain"]
        n_expr, n_cand, n_dwl = s0["expr"], s0["cand"], s0["dwell"]
        n_hold = self.hold[idx]

        if s0["valid"]:
            quiet = s0["pow"] < self.squelch_thr
            diff = s0["pow"] - s0["env"]
            sh = self.attack_shift if diff > 0 else self.release_shift
            if quiet or self.freeze:
                n_hold = 1                      # retain env and gain
            else:
                n_hold = 0
                envn = s0["env"] + (diff >> sh)
                if envn < 0:
                    envn = 0
                n_env = envn & POW_MAX

                e = leading_one(s0["env"])      # OLD env: one-sample lag
                if e == s0["cand"]:
                    if s0["dwell"] >= HYST_DWELL:
                        n_expr = s0["cand"]
                    else:
                        n_dwl = s0["dwell"] + 1
                else:
                    n_cand = e
                    n_dwl = 0

                n_gain = self.lut[s0["expr"]]

            if self.gain_mode == 0:
                n_gain = self.gain_manual

            self.env[idx] = n_env
            self.gain[idx] = n_gain
            self.expr[idx] = n_expr
            self.cand[idx] = n_cand
            self.dwell[idx] = n_dwl
            self.hold[idx] = n_hold

        n_s1 = dict(valid=s0["valid"], chan=s0["chan"], i=s0["i"], q=s0["q"],
                    gain=n_gain)

        self.out, self.s1, self.s0 = n_out, n_s1, n_s0
        return dict(out_valid=self.out["valid"], out_chan=self.out["chan"],
                    out_i=self.out["i"], out_q=self.out["q"], sat=self.out["sat"])


def build_lut(target_amp=16384, safe_floor_exp=20, safe_gain=UNITY):
    """gain = target / sqrt(power), one entry per power octave.

    Below safe_floor_exp the reciprocal-sqrt gain explodes, so those entries get
    a SMALL, SAFE gain: a dead or squelched channel must never amplify noise to
    full scale.
    """
    lut = []
    for e in range(32):
        if e < safe_floor_exp:
            lut.append(safe_gain)
        else:
            g = target_amp / (2.0 ** (e / 2.0)) * UNITY
            lut.append(min(int(g + 0.5), 2**GAIN_W - 1))
    return lut
