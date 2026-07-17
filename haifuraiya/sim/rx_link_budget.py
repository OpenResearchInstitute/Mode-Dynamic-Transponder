# %% [markdown]
# # Haifuraiya Receive-Chain Link Budget & Performance Curves
# From the ADC to decoded frames: every dB accounted for, every
# convention declared. Companion to the Phase 0 campaign records.
#
# **PROJECT CONVENTION: Eb/N0 is INFO-BIT unless explicitly marked.**
# coded-bit Eb/N0 = info-bit Eb/N0 - 10*log10(1/R) = info - 3.01 dB @ R=1/2.
# The Phase 0 model sweep harness (ebn0_sweep.py lineage) used the
# CODED-bit axis; its CSVs are relabeled here, not re-run. opv_stim.py
# and this notebook use info-bit. State the axis on every figure.

# %%
import numpy as np
import matplotlib.pyplot as plt
from scipy.special import erfc
import os

def q(x):  return 0.5 * erfc(x / np.sqrt(2.0))
def db(x): return 10 * np.log10(x)

# %% [markdown]
# ## 1. System constants (measured / designed, with provenance)

# %%
FS_ADC      = 20.0e6      # ADC rate as configured (LVDS); RF BW ~10 MHz after chip decimation
N_CHAN      = 64          # polyphase channels
CHAN_SPACING= 156.25e3    # measured convention: fc(k) = k * 156.25 kHz at 20 Msps
CHAN_BW     = 156.25e3    # per-channel noise bandwidth (prototype filter, approx.)
CHAN_RATE   = 625.0e3     # sample rate at the demod (post halfband)
RS          = 54.2e3      # symbol rate (MSK: 1 coded bit / symbol)
R_CODE      = 0.5         # K=7 convolutional, Voyager 171/133
SPS         = CHAN_RATE / RS          # 11.5314 samples/symbol
NORM_TARGET = 9000        # LEVEL_PLAN channel rms (canonical chan5_iq.cs16: rms 9000, peak 9138)

# %% [markdown]
# ## 2. The receive staircase
# Each stage either rejects noise the signal doesn't share, or
# integrates evidence per decision. This is the architecture AS a
# link budget.

# %%
pg_channelizer = db(FS_ADC / CHAN_BW)      # out-of-channel noise rejection
pg_correlator  = db(SPS)                   # per-symbol coherent integration
cg_fec         = 5.0                       # K=7 R=1/2 soft-decision coding gain
                                           # @ BER 1e-5 (textbook; measure ours)
print(f"channelizer processing gain : {pg_channelizer:5.1f} dB "
      f"(reject noise outside {CHAN_BW/1e3:.2f} kHz of {FS_ADC/1e6:.0f} MHz)")
print(f"symbol correlation gain     : {pg_correlator:5.1f} dB "
      f"({SPS:.2f} samples integrated per decision)")
print(f"FEC coding gain (textbook)  : {cg_fec:5.1f} dB (K=7 R=1/2 soft Viterbi)")
print(f"NOTE: gains are vs the noise IN each stage's input bandwidth; they")
print(f"chain as bandwidth narrows. The demod input C/N and the decision-")
print(f"point Eb/N0 are related, not additive line items -- see cell 3.")

# %% [markdown]
# ## 3. Convention translator + sanity chain
# For any stimulus info-bit Eb/N0: what every meter in the chain reads.

# %%
def chain_report(ebn0_info_db):
    ebn0_coded = ebn0_info_db - db(1/R_CODE)      # per coded bit == Es (MSK)
    esn0       = ebn0_coded                        # 1 coded bit / symbol
    cn_chan    = esn0 + db(RS / CHAN_BW)           # C/N in the 156.25 kHz channel
    cn_65k     = esn0 + db(RS / 65.0e3)            # C/N in 65 kHz (opv_stim's meter)
    snr_chanrate = esn0 + db(RS / CHAN_RATE)       # SNR at 625 ks/s (demod input)
    print(f"info Eb/N0 {ebn0_info_db:5.2f} | coded/Es {ebn0_coded:5.2f} | "
          f"C/N({CHAN_BW/1e3:.0f}k) {cn_chan:5.2f} | C/N(65k) {cn_65k:5.2f} | "
          f"SNR@625k {snr_chanrate:6.2f}  [dB]")

for e in (9.0, 7.5, 6.0, 4.5):
    chain_report(e)
# cross-check vs opv_stim printouts: --ebn0 6 -> C/N(65k) = 2.20 dB;
#                                    --ebn0 9 -> C/N(65k) = 5.20 dB. Match.

# %% [markdown]
# ## 4. Theory reference curves (AWGN, perfect sync -- the honest yardstick)

# %%
ebn0_info = np.linspace(0, 14, 200)
ebn0_lin  = 10**(ebn0_info/10)

# Uncoded coherent MSK: BPSK-equivalent per bit
ber_uncoded = q(np.sqrt(2 * ebn0_lin))

# K=7 R=1/2 soft Viterbi union bound (Voyager 171/133 distance spectrum)
dfree, cd = 10, {10:36, 12:211, 14:1404, 16:11633, 18:77433, 20:502690}
ebc = R_CODE * ebn0_lin       # coded-bit energy
ber_coded = sum(c * q(np.sqrt(2 * d * ebc)) for d, c in cd.items())

BITS_PER_FRAME = 1072         # info bits (2144 coded)
fer_coded   = 1 - (1 - np.clip(ber_coded, 0, .5))**BITS_PER_FRAME
fer_uncoded = 1 - (1 - ber_uncoded)**BITS_PER_FRAME

# %% [markdown]
# ## 5. Measured points -- LOADED from the record CSVs, never retyped.
# Set RECORDS to your sim/ paths. `axis=` declares each file's native
# convention; everything is converted to info-bit for plotting.

# %%
RECORDS = {
  # label                  : (path,                axis,    style)
  "MLSE model (Phase 0)"   : ("mlse_sweep_v2.csv", "coded", dict(marker="o")),
  "MLSE fixed-point"       : ("mlse_fp_sweep.csv", "coded", dict(marker="s")),
  "legacy VHDL demod"      : ("baseline_v2.csv",   "coded", dict(marker="x")),
  # fabric system points: build system_fer.csv with header
  #   ebn0,frames_ok,frames_total   (ebn0 INFO-bit), one row per bench run
  # "fabric system (bench)": ("system_fer.csv",    "info",  dict(marker="D")),
}
FER_FLOOR = 1e-4   # zero-FER records plot at the axis floor (finite trials)

def load_record(path, axis):
    """Campaign schema: ebn0,ber,ber_clean,fer_model,slip_p,fer_cxx
       (fer_model = the receiver under test; fer_cxx = C++ reference).
       Fallback schema: ebn0,frames_ok,frames_total (system runs)."""
    a = np.genfromtxt(path, delimiter=",", names=True)
    e = np.atleast_1d(a["ebn0"]) + (db(1/R_CODE) if axis == "coded" else 0.0)
    if "fer_model" in (a.dtype.names or ()):
        fer = np.atleast_1d(a["fer_model"])
        cxx = np.atleast_1d(a["fer_cxx"])
    else:
        fer = 1.0 - np.atleast_1d(a["frames_ok"]) / np.atleast_1d(a["frames_total"])
        cxx = None
    return e, np.clip(fer, FER_FLOOR, 1), (np.clip(cxx, FER_FLOOR, 1)
                                           if cxx is not None else None)

# %% [markdown]
# ## 5. TUTORIAL: how to read a receiver performance chart
# Seven figures, one idea each. Every measured point below is loaded
# from the campaign CSVs -- nothing is retyped. If you are new to FER
# curves, read these in order; the final figure will then make sense.

# %%
# load the records once for the whole tutorial
REC = {}
for label, (path, axis, style) in RECORDS.items():
    if os.path.exists(path):
        REC[label] = (*load_record(path, axis), style)
MLSE_KEY = next((k for k in REC if "MLSE model" in k), None)

def field(title):
    fig, ax = plt.subplots(figsize=(7.5, 5.5))
    ax.set_xlabel("Eb/N0 per INFORMATION bit [dB]  ->  more signal power")
    ax.set_ylabel("Frame Error Rate  (down = better)")
    ax.set_yscale("log"); ax.set_ylim(1e-4, 1.05); ax.set_xlim(3, 16)
    ax.grid(True, which="both", alpha=.3); ax.set_title(title)
    return fig, ax

def save(fig, name):
    fig.tight_layout(); fig.savefig(name, dpi=130); plt.close(fig)
    print("wrote", name)

# %% [markdown]
# ### Tutorial 1 -- the playing field
# X: signal strength per information bit. Y: fraction of frames lost
# (log scale). Good receivers live DOWN and LEFT: fewer errors from
# less power.

# %%
fig, ax = field("Tutorial 1: the playing field")
ax.annotate("GOOD receivers live\nDOWN and LEFT", xy=(4.5, 3e-4),
            fontsize=13, color="green")
ax.annotate("BAD: errors even with\nstrong signal", xy=(13, 0.5),
            fontsize=13, color="firebrick")
save(fig, "tut1_field.png")

# %% [markdown]
# ### Tutorial 2 -- the ruler: "uncoded MSK"
# NOT a system anyone built. It is textbook physics for raw MSK bits
# with no FEC and a perfect receiver -- sea level on a mountain map.
# Measured systems need a dimensionless reference; this is it.

# %%
fig, ax = field("Tutorial 2: the ruler -- uncoded MSK (textbook, not ours)")
ax.semilogy(ebn0_info, fer_uncoded, "--", color="gray", lw=2,
            label="uncoded MSK (physics)")
ax.legend(); save(fig, "tut2_ruler.png")

# %% [markdown]
# ### Tutorial 3 -- what FEC promises (fine print: perfect sync)
# The coded curve is the K=7 R=1/2 union bound: what the code buys IF
# timing, carrier, and frame sync are all perfect. Real receivers pay
# implementation losses against this promise. REMEMBER THE FINE PRINT;
# it becomes the whole story in Tutorial 7.

# %%
fig, ax = field("Tutorial 3: the FEC promise (assumes PERFECT sync)")
ax.semilogy(ebn0_info, fer_uncoded, "--", color="gray", lw=2, label="uncoded MSK")
ax.semilogy(ebn0_info, fer_coded, "-", color="tab:blue", lw=2,
            label="K=7 R=1/2 coded, perfect sync")
ax.annotate("", xy=(5.2, .01), xytext=(10.6, .01),
            arrowprops=dict(arrowstyle="<->", color="tab:blue"))
ax.text(7.9, .014, "coding gain (~5 dB)\nIF sync is perfect",
        ha="center", color="tab:blue", fontsize=11)
ax.legend(); save(fig, "tut3_promise.png")

# %% [markdown]
# ### Tutorial 4 -- where this campaign started
# The C++ reference modem (and the legacy VHDL demod, which matches it:
# same algorithm, and the records show it). Its cliff sits ~13 dB --
# WORSE than the uncoded ruler. A coded system underperforming
# no-coding-at-all means the receiver squandered more than the code
# earned. That paradox is the "missing dB", made visible.

# %%
fig, ax = field("Tutorial 4: the starting point")
ax.semilogy(ebn0_info, fer_uncoded, "--", color="gray", lw=1.5, label="uncoded MSK")
ax.semilogy(ebn0_info, fer_coded, "-", color="tab:blue", lw=1.5, label="coded theory")
if MLSE_KEY:
    e, fer, cxx, _ = REC[MLSE_KEY]
    m = cxx > FER_FLOOR
    ax.semilogy(e[m], cxx[m], "^", ms=9, color="firebrick",
                label="C++ reference (measured)")
ax.legend(loc="lower left"); save(fig, "tut4_start.png")

# %% [markdown]
# ### Tutorial 5 -- the recovery
# The MLSE receiver, measured on the same records. The horizontal
# distance to the reference at matched FER is ~5.8 dB. Because it is a
# DIFFERENCE between two curves measured by the same harness, it is
# immune to any absolute axis-calibration error.

# %%
fig, ax = field("Tutorial 5: the recovery is real")
ax.semilogy(ebn0_info, fer_uncoded, "--", color="gray", lw=1.5, label="uncoded MSK")
ax.semilogy(ebn0_info, fer_coded, "-", color="tab:blue", lw=1.5, label="coded theory")
if MLSE_KEY:
    e, fer, cxx, _ = REC[MLSE_KEY]
    m = cxx > FER_FLOOR
    ax.semilogy(e[m], cxx[m], "^", ms=8, color="firebrick", label="C++ reference")
    mm = fer > FER_FLOOR
    ax.semilogy(e[mm], fer[mm], "o", ms=9, color="tab:green", label="MLSE (measured)")
    ax.annotate("", xy=(8.0, .26), xytext=(13.8, .26),
                arrowprops=dict(arrowstyle="<->", color="black", lw=2))
    ax.text(10.9, .33, "~5.8 dB recovered", ha="center", fontsize=12)
ax.legend(loc="lower left"); save(fig, "tut5_recovery.png")

# %% [markdown]
# ### Tutorial 6 -- the optical illusion: the measurement floor
# Points with ZERO errors in N trials are not zeros; they are bounds
# (FER < 1/N). Plotted as dots they masquerade as a curve at the axis
# floor -- which can photobomb the uncoded ruler and cause needless
# alarm. Honest treatment: downward arrows from the floor.

# %%
fig, ax = field("Tutorial 6: the measurement floor (80 trials sees only to 1/80)")
ax.semilogy(ebn0_info, fer_uncoded, "--", color="gray", lw=1.5, label="uncoded MSK")
ax.semilogy(ebn0_info, fer_coded, "-", color="tab:blue", lw=1.5, label="coded theory")
N_TRIALS = 80
ax.axhspan(1e-4, 1/N_TRIALS, color="orange", alpha=.15)
ax.text(12.6, 3.4e-3, f"{N_TRIALS} trials cannot see below 1/{N_TRIALS}",
        fontsize=10, ha="center")
if MLSE_KEY:
    e, fer, _, _ = REC[MLSE_KEY]
    mm = fer > FER_FLOOR
    ax.semilogy(e[mm], fer[mm], "o", ms=9, color="tab:green", label="MLSE measured")
    for x in e[~mm]:
        ax.annotate("", xy=(x, 1.3e-4), xytext=(x, 1/N_TRIALS),
                    arrowprops=dict(arrowstyle="->", color="tab:green", lw=2))
ax.legend(loc="lower left"); save(fig, "tut6_floor.png")

# %% [markdown]
# ### Tutorial 7 -- naming the gap: the slip decomposition
# The records carry slip_p: the fraction of frames lost to SYNC SLIPS
# (acquisition failures). Total FER nearly equals slip_p at every
# struggling point, so decode-only failures (FER - slips) hug the
# floor: WHEN SYNC HOLDS, THE FEC DECODES. The decoder is essentially
# ideal; the gap to Tutorial 3's curve is the fine print -- that curve
# assumed perfect sync. The low-SNR frontier is acquisition, and it
# has a roadmap entry (PSP theta attractor hardening).

# %%
fig, ax = field("Tutorial 7: the gap has a name -- sync slips")
ax.semilogy(ebn0_info, fer_coded, "-", color="tab:blue", lw=1.5,
            label="coded theory (perfect sync)")
if MLSE_KEY and os.path.exists(RECORDS[MLSE_KEY][0]):
    a = np.genfromtxt(RECORDS[MLSE_KEY][0], delimiter=",", names=True)
    e = np.atleast_1d(a["ebn0"]) + db(1/R_CODE)
    fer = np.clip(np.atleast_1d(a["fer_model"]), FER_FLOOR, 1)
    slip = np.clip(np.atleast_1d(a["slip_p"]), FER_FLOOR, 1)
    mm = fer > FER_FLOOR
    ax.semilogy(e[mm], fer[mm], "o", ms=9, color="tab:green", label="MLSE total FER")
    ax.semilogy(e[slip > FER_FLOOR], slip[slip > FER_FLOOR], "s", ms=8,
                mfc="none", color="purple", label="slip_p (sync slips)")
    resid = np.clip(np.atleast_1d(a["fer_model"]) - np.atleast_1d(a["slip_p"]),
                    FER_FLOOR, 1)
    ax.semilogy(e[mm], resid[mm], "d", ms=8, color="black",
                label="decode-only failures")
ax.legend(loc="lower right", fontsize=9); save(fig, "tut7_slips.png")

# %% [markdown]
# ## 6. The money figure -- everything above, honestly drawn
# Floor-bounded points as arrows; slip decomposition available in
# Tutorial 7; axis convention in the xlabel; trial count in the title.

# %%
fig, ax = field(f"Opulent Voice receiver: measured vs theory\n"
                f"(MSK 54.2 kbaud, K=7 R=1/2; {N_TRIALS}-trial records; "
                f"zero-error points shown as bounds)")
ax.semilogy(ebn0_info, fer_uncoded, "--", color="gray", lw=1, label="theory: uncoded MSK")
ax.semilogy(ebn0_info, fer_coded, "-", color="tab:blue", lw=1.5,
            label="theory: K=7 R=1/2 (perfect sync)")
cxx_drawn = False
for label, (e, fer, cxx, style) in REC.items():
    mm = fer > FER_FLOOR
    ax.semilogy(e[mm], fer[mm], ls="none", label=label, **style)
    for x in e[~mm]:
        ax.annotate("", xy=(x, 1.3e-4), xytext=(x, 1/N_TRIALS),
                    arrowprops=dict(arrowstyle="->", alpha=.6))
    if cxx is not None and not cxx_drawn and "MLSE model" in label:
        m = cxx > FER_FLOOR
        ax.semilogy(e[m], cxx[m], ls="none", marker="^", mfc="none",
                    label="C++ reference modem (same records)")
        cxx_drawn = True
ax.legend(loc="lower left", fontsize=9)
save(fig, "rx_performance.png")

# %% [markdown]
# ## 7. Reading list for reviewers
# 1. Recovery: MLSE vs C++ reference, ~5.8 dB at matched FER
#    (difference of curves -- axis-error-proof).
# 2. Decoder health: Tutorial 7 -- decode-only failures at the floor;
#    losses are sync slips; coding gain is intact and spent nowhere.
# 3. Frontier: acquisition robustness below ~8 dB info (slip_p),
#    roadmap: PSP theta attractor hardening.
# 4. Floor caveat: zero-error points bound FER < 1/N_TRIALS; deeper
#    claims need more trials.
# 5. Conventions: info-bit Eb/N0 throughout; coded = info - 3.01 dB;
#    C/N stated in the 156.25 kHz channel.
