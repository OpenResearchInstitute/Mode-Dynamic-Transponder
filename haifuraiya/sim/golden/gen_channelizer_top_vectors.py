#!/usr/bin/env python3
"""
gen_channelizer_top_vectors.py -- vectors for tb_channelizer_top.

Model: channelizer_top_model.channelize -- composed from the PROVEN polyphase and
FFT leaf models + P2S complex assembly (bi + j*bq) + (-j)^(k*m) rotation, first
emitted frame at block m=2. Proven bit-exact to haifuraiya_channelizer_top by
dump-compare (tone + random).

Emits a SWEEP: one random burst (broad bit-exact coverage), then one pure-tone
burst per test channel. For each burst the TB captures a SETTLED frame (index
CAP_IDX) and (a) checks it bit-exact vs the model, (b) reports+asserts which
OUTPUT channel the tone energy peaks in -- the empirical frequency->channel map.

Prints the full model-predicted k -> peak-channel table (k=0..63). Because the
bit-exact oracle proves model == RTL, that table is the hardware's actual map.

Files (VEC_DIR):
  ct_sweep_input.txt     "re im" per input sample, all bursts concatenated
  ct_sweep_expected.txt  per burst: "BURST <k> <exp_peak>" then 64 lines "re im"
                         (the CAP_IDX settled frame, idx 0..63)
Generics for the TB: N_BURSTS, BURST_LEN, CAP_IDX (printed).
"""
import os, sys, math, random
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import channelizer_top_model as ct

N, M = ct.N, ct.M
A = 8000
BURST_LEN = 720
CAP_IDX   = 40                      # settled emitted frame for bit-exact (< ~43)
ENERGY_SKIP = 8                     # frames to skip before accumulating map energy
M_OFFSET  = 2
TEST_KS   = [0, 1, 2, 5, 10, 16, 31, 32, 33, 48, 63]
_VEC = os.path.join(os.path.dirname(os.path.abspath(__file__)), "vectors")
os.makedirs(_VEC, exist_ok=True)

def tone(k, nsamp):
    return ([int(round(A*math.cos(2*math.pi*(k/N)*n))) for n in range(nsamp)],
            [int(round(A*math.sin(2*math.pi*(k/N)*n))) for n in range(nsamp)])

def energy_peak(frames):
    """Dominant channel by energy summed over settled frames -- robust to the
       per-frame rotation scalloping that can flip a single-frame argmax by 1."""
    acc = [0]*N
    for fr in frames[ENERGY_SKIP:]:
        for c, (re, im) in enumerate(fr): acc[c] += re*re + im*im
    return max(range(N), key=lambda c: acc[c])

# ---- analytic: full model map k -> peak channel, and a sanity gate ----
print("[gen_channelizer_top] model-predicted frequency->channel map (k=0..63):")
row = []; pure_reversal = True
for k in range(N):
    xr, xi = tone(k, BURST_LEN)
    fr = ct.channelize(xr, xi, m_offset=M_OFFSET)
    c = energy_peak(fr)
    row.append((k, c))
    if c != (N - k) % N: pure_reversal = False
for i in range(0, N, 8):
    print("   " + "  ".join(f"{k:2d}->{c:2d}" for k, c in row[i:i+8]))
print(f"   pure reversal k->(N-k) mod N ?  {pure_reversal}")
if not pure_reversal:
    print("   NOTE: map is not a pure reversal; TB will report the true per-tone peaks.")
print()

# ---- emit sweep vectors ----
random.seed(0xC0FFEE)
bursts = [(-1, [random.randint(-20000, 20000) for _ in range(BURST_LEN)],
               [random.randint(-20000, 20000) for _ in range(BURST_LEN)])]
for k in TEST_KS:
    xr, xi = tone(k, BURST_LEN); bursts.append((k, xr, xi))

with open(os.path.join(_VEC, "ct_sweep_input.txt"), "w") as fi, \
     open(os.path.join(_VEC, "ct_sweep_expected.txt"), "w") as fe:
    for (k, xr, xi) in bursts:
        for a, b in zip(xr, xi):
            fi.write(f"{a} {b}\n")
        frames = ct.channelize(xr, xi, m_offset=M_OFFSET)
        cap = frames[CAP_IDX]
        exp_peak = -1 if k < 0 else energy_peak(frames)
        fe.write(f"BURST {k} {exp_peak}\n")
        for (re, im) in cap:                      # 40-bit two's complement hex
            fe.write(f"{re & 0xFFFFFFFFFF:010X} {im & 0xFFFFFFFFFF:010X}\n")

print(f"[gen_channelizer_top] wrote {len(bursts)} bursts x {BURST_LEN} samples "
      f"(1 random + {len(TEST_KS)} tones)")
print(f"[gen_channelizer_top] TB generics: N_BURSTS={len(bursts)} BURST_LEN={BURST_LEN} CAP_IDX={CAP_IDX}")
