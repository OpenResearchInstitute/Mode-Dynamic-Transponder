#!/usr/bin/env python3
"""gen_mlse_golden.py -- golden generator for msk_mlse4.
Input: golden_engine.txt (the VERIFIED symbol-engine output: block 1's
bit-exact Y stream) + lut16.txt (offset-encoded shared table).
Output: mlse_golden.txt: one line per emitted soft decision:
        t soft best_state th0 th1 th2 th3
(the four theta words are debug taps for divergence localization).
This is the executable specification of msk_mlse4.vhd, integer for
integer. ASCII only. 73."""
lutc, luts = [], []
for line in open("lut16.txt"):
    c, s = line.split(); lutc.append(int(c)-32768); luts.append(int(s)-32768)

Y1, Y2 = [], []
for line in open("golden_engine.txt"):
    v = [int(x) for x in line.split()]
    Y1.append((v[3], v[4])); Y2.append((v[5], v[6]))

PAIR = {(1,1):0,(0,0):1,(1,0):2,(0,1):3}
TB_D = 64
n = len(Y1)
Q = [((-1 if k % 2 == 0 else 1)*Y2[k][0],
      (-1 if k % 2 == 0 else 1)*Y2[k][1]) for k in range(n)]
V = []
for k in range(n-1):
    V.append(((Y1[k][0]+Y1[k+1][0], Y1[k][1]+Y1[k+1][1]),
              (Q[k][0]-Q[k+1][0],   Q[k][1]-Q[k+1][1]),
              (Y1[k][0]-Q[k+1][0],  Y1[k][1]-Q[k+1][1]),
              (Q[k][0]+Y1[k+1][0],  Q[k][1]+Y1[k+1][1])))
nw = n-1
NS = 4
cur = [0]*NS
th  = [0, 8192, 16384, 24576]
hp = [[0]*NS for _ in range(nw)]
hb = [[0]*NS for _ in range(nw)]
hm = [[0]*NS for _ in range(nw)]
out = []
for t in range(nw):
    nxt = [None]*NS; nth = [0]*NS
    for st2 in range(NS):
        s_ = 1 if (st2 >> 1) == 0 else -1
        bnew = st2 & 1
        sp = s_ if bnew == 1 else -s_
        win = None
        for pb in (0, 1):
            stp = ((0 if sp > 0 else 1) << 1) | pb
            vr0, vi0 = V[t][PAIR[(pb, bnew)]]
            c = lutc[th[stp] & 0xFFFF]; sn = luts[th[stp] & 0xFFFF]
            vr = (vr0*c + vi0*sn) >> 15
            vi = (vi0*c - vr0*sn) >> 15
            bm = cur[stp] + sp*vr
            if win is None:
                win = [bm, stp, vr, vi, None]
            elif bm > win[0]:
                win = [bm, stp, vr, vi, win[0]]
            else:
                win[4] = bm
        w_, pw, vr, vi, lose = win
        nxt[st2] = w_
        hp[t][st2] = pw; hb[t][st2] = bnew
        hm[t][st2] = min(w_ - (lose if lose is not None else w_ - 32767), 32767)
        ir = sp*vr; ii = sp*vi
        e = ii if ir >= 0 else -ii
        d = e >> 8
        if d >  256: d =  256
        if d < -256: d = -256
        nth[st2] = (th[pw] + d) & 0xFFFF
    mx = max(nxt)
    cur = [v - mx for v in nxt]
    th = nth
    if t >= TB_D - 1:
        st = max(range(NS), key=lambda i: cur[i])
        best_st = st
        for bt in range(t, t - TB_D, -1):
            b = hb[bt][st]; mg = hm[bt][st]
            if bt == t - TB_D + 1:
                soft = mg if b == 1 else -mg
            st = hp[bt][st]
        out.append((t - TB_D + 1, soft, best_st, th[0], th[1], th[2], th[3]))
with open("mlse_golden.txt", "w") as f:
    for r in out:
        f.write(" ".join(str(x) for x in r) + "\n")
print(f"mlse_golden.txt: {len(out)} emitted decisions "
      f"(from {nw} trellis steps, traceback depth {TB_D})")
