"""
channelizer_top_model.py -- composed golden model for haifuraiya_channelizer_top.

  sample_re -> polyphase(I) \
                             -> complex[k]=bi[k]+j*bq[k] -> FFT(64) -> rotation -> channel
  sample_im -> polyphase(Q) /

Reuses the PROVEN bit-exact leaf models:
  polyphase_model.branch_vector  (filterbank, 40-bit, M=16 frame stride)
  fft_model.fft_fixed            (64-pt DIF, 40-bit datapath, natural order)

New glue (this file): P2S complex assembly, the (-j)^((k*m) mod 4) output rotation,
and the per-frame block counter m. Frame f newest sample = M*(f+1)-1.
Alignment of the first EMITTED frame and the m phase is pinned by dump-compare.
"""
import polyphase_model as pm
import fft_model as fm

N = 64
M = 16

def _rot(sel, re, im):
    sel &= 3
    if sel == 0: return ( re,  im)   # x 1
    if sel == 1: return (-im,  re)   # x +j
    if sel == 2: return (-re, -im)   # x -1
    return ( im, -re)                # x -j

def channelize(x_re, x_im, m_offset=0):
    """Return list of output frames; each is 64 (re,im) tuples after rotation.
       Frame f uses newest sample M*(f+1)-1 and block m=(f+m_offset) mod 4."""
    frames = []
    f = 0
    while M * (f + 1) - 1 < len(x_re):
        n = M * (f + 1) - 1
        bi = pm.branch_vector(x_re, n)
        bq = pm.branch_vector(x_im, n)
        cin = [(bi[k], bq[k]) for k in range(N)]     # complex = bi + j*bq
        bins = fm.fft_fixed(cin)
        m = (f + m_offset) & 3
        frames.append([_rot((k * m) & 3, bins[k][0], bins[k][1]) for k in range(N)])
        f += 1
    return frames

def channelize_unrotated(x_re, x_im):
    """FFT bins per frame with NO rotation -- for the pure ordering/energy test."""
    frames = []
    f = 0
    while M * (f + 1) - 1 < len(x_re):
        n = M * (f + 1) - 1
        bi = pm.branch_vector(x_re, n)
        bq = pm.branch_vector(x_im, n)
        bins = fm.fft_fixed([(bi[k], bq[k]) for k in range(N)])
        frames.append(bins)
        f += 1
    return frames
