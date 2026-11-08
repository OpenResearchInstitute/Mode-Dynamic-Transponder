#!/usr/bin/env python3
# esi_rx_check.py STIM esi_rx_samples.txt -- did the core receive exactly the stimulus, and at what spacing?
import sys, numpy as np
stim = np.loadtxt(sys.argv[1], dtype=np.int64)              # columns I Q
rx   = np.loadtxt(sys.argv[2], dtype=np.int64)              # columns I Q gap
n = min(len(stim), len(rx))
print("stimulus samples", len(stim), " received", len(rx), " (received includes the 30000 zero tail if the bench sends it)")
bad = np.nonzero((stim[:n,0] != rx[:n,0]) | (stim[:n,1] != rx[:n,1]))[0]
print("value mismatches in first", n, ":", len(bad), ("first at index %d: stim %s rx %s" % (bad[0], stim[bad[0]], rx[bad[0],:2])) if len(bad) else "")
g = rx[1:,2]
vals, cnts = np.unique(g, return_counts=True)
print("gap histogram (aclk cycles between accepted samples):", dict(zip(vals.tolist(), cnts.tolist())))
