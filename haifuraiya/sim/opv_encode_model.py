#!/usr/bin/env python3
"""opv_encode_model.py -- OPV frame encoder + channel-rate MSK modulator.

Exact inverse of the opv_demod_model.py decode tail (which is byte-validated
against the untouched C++ reference):
  payload bytes -> CCSDS randomize -> K=7 tail-biting convolve (G1 0x67,
  G2 0x76) -> 67x32 interleave -> prepend sync 0x02B8DB -> on-air bit stream
plus a phase-continuous CPFSK (MSK, h=0.5) modulator synthesized DIRECTLY at
the channel rate (no resampling artifacts): bit '0' -> +FREQ_DEV tone sense
chosen so the receive chain's resolve() lands on positive-soft='0'.
(resolve() self-heals polarity/parity, so the mapping is verified by decode,
not by convention.)

Self-checks in __main__:
  1. encode -> ideal 3-bit soft -> opv_demod_model.frame_decode ->
     metric 0, bytes identical (round trip through the validated decoder)
  2. modulate at 625 ksps -> opv_demod_model full demod -> bytes identical
"""
import numpy as np
from opv_demod_model import (SYNC_WORD, SYNC_BITS, FRAME_BYTES, FRAME_BITS,
                             ENCODED_BITS, FRAME_SYMBOLS, G1_MASK, G2_MASK,
                             DEINT, SOFT_MAX, FREQ_DEV, SYMBOL_RATE,
                             frame_decode, _parity)

def randomize(payload):
    """CCSDS LFSR XOR, identical sequence to the decoder's derandomize."""
    out = np.zeros(FRAME_BYTES, dtype=np.uint8)
    lfsr = 0xFF
    for i in range(FRAME_BYTES):
        r = 0
        for b in range(7, -1, -1):
            r |= ((lfsr >> 7) & 1) << b
            lfsr = ((lfsr << 1) & 0xFF) | (((lfsr >> 7) ^ (lfsr >> 6)
                     ^ (lfsr >> 4) ^ (lfsr >> 2)) & 1)
        out[i] = payload[i] ^ r
    return out

def bytes_to_bits(by):
    """Inverse of the decoder's pack loop:
    packed[i] bit j  <-  bits[FRAME_BITS - 1 - i*8 - j]."""
    bits = np.zeros(FRAME_BITS, dtype=np.uint8)
    for i in range(FRAME_BYTES):
        for j in range(8):
            bits[FRAME_BITS - 1 - i*8 - j] = (by[i] >> j) & 1
    return bits

def conv_tailbiting(bits):
    """K=7 tail-biting: encoder register preloaded with the LAST 6 info bits;
    per bit t: window = (bit<<6)|state, e1 = parity(w & G1), e2 = parity(w & G2),
    matching the decoder trellis (pred s -> next (in<<6|prev)>>1 form)."""
    enc = np.zeros(ENCODED_BITS, dtype=np.uint8)
    # Trellis (from the decoder): pred0[s] = s//2, in = s % 2, window
    # f = (in << 6) | p. Therefore the transition is s_next = (2p + in) & 63:
    # the state shifts LEFT, newest bit at the LSB, so state bit k holds
    # in(t-1-k). Window bit 6 = delay 0, window bit k (k<6) = delay 1+k;
    # G1 0x67 taps delays {0,1,2,3,6}, G2 0x76 taps {0,2,3,5,6}.
    # Tail-biting preload: s(0) bit k = b[FRAME_BITS-1-k].
    s = 0
    for k in range(6):
        s |= int(bits[FRAME_BITS - 1 - k]) << k
    for t in range(FRAME_BITS):
        f = (int(bits[t]) << 6) | s
        enc[2*t]     = _parity(f & G1_MASK)
        enc[2*t + 1] = _parity(f & G2_MASK)
        s = ((s << 1) | int(bits[t])) & 0x3F
    return enc

def interleave(enc):
    """Decoder does deint[i] = onair[DEINT[i]]; so onair[DEINT[i]] = enc[i]."""
    onair = np.zeros(ENCODED_BITS, dtype=np.uint8)
    onair[DEINT] = enc
    return onair

def sync_bits():
    return np.array([(SYNC_WORD >> (SYNC_BITS - 1 - i)) & 1
                     for i in range(SYNC_BITS)], dtype=np.uint8)

def encode_frame(payload):
    """134 payload bytes -> 2168 on-air bits (sync + interleaved coded)."""
    payload = np.asarray(payload, dtype=np.uint8)
    assert len(payload) == FRAME_BYTES
    return np.concatenate([sync_bits(),
                           interleave(conv_tailbiting(
                               bytes_to_bits(randomize(payload))))])

def expected_onair_for_payloads(payload_frames):
    """List/array of 134-byte payloads -> concatenated on-air bit stream."""
    return np.concatenate([encode_frame(p) for p in payload_frames])

# ------------------------------------------------------------- modulator ----
def msk_modulate(bits, fs=625000.0, amp=9000.0, phase0=0.0):
    """Phase-continuous CPFSK h=0.5 with EXACT fractional symbol boundaries.
    The phase at sample n is the exact integral of the instantaneous
    frequency: phase(t) = 2*pi*FREQ_DEV * (S(t)), where S(t) is the signed
    time integral of the bit sequence (+1/-1) up to t, with transitions at
    the true fractional positions k*sps. Eliminates the +/-0.5-sample
    transition jitter of per-sample switching (which the MLSE receiver is
    sensitive enough to see as ~metric-180 ISI)."""
    sps = fs / SYMBOL_RATE
    a = np.where(np.asarray(bits) == 1, 1.0, -1.0)
    # cumulative signed symbol-time at each boundary (units of samples)
    cum = np.concatenate([[0.0], np.cumsum(a) * sps])
    n_out = int(np.floor(len(bits) * sps))
    t = np.arange(n_out, dtype=np.float64)
    k = np.minimum((t / sps).astype(np.int64), len(bits) - 1)
    # exact signed integral up to time t: boundary value + partial symbol
    S = cum[k] + a[k] * (t - k * sps)
    phase = phase0 + 2 * np.pi * FREQ_DEV * S / fs
    return amp * np.exp(1j * phase)

def make_burst(payload_frames, fs=625000.0, amp=9000.0,
               preamble_frames=1, pad_syms=40):
    """Preamble (0xCC pattern frames) + encoded frames, padded, at fs."""
    pre = np.tile(np.array([1,1,0,0,1,1,0,0], dtype=np.uint8),
                  (FRAME_SYMBOLS * preamble_frames) // 8 + 1)[
                  :FRAME_SYMBOLS * preamble_frames]
    bits = np.concatenate([pre, expected_onair_for_payloads(payload_frames),
                           np.zeros(pad_syms, dtype=np.uint8)])
    return msk_modulate(bits, fs, amp)

# ------------------------------------------------------------ self-check ----
if __name__ == "__main__":
    rng = np.random.default_rng(1)
    payload = rng.integers(0, 256, FRAME_BYTES).astype(np.uint8)

    # 1. codec round trip through the validated decoder
    onair = encode_frame(payload)
    soft = np.where(onair[SYNC_BITS:] == 1, -20000.0, 20000.0)  # ideal soft
    metric, by = frame_decode(soft)
    ok1 = metric == 0 and np.array_equal(by, payload)
    print(f"codec round trip: metric={metric}, bytes match={np.array_equal(by, payload)}"
          f"  -> {'PASS' if ok1 else 'FAIL'}")

    # 2. modulate at channel rate, demodulate with the full float model
    from opv_demod_model import CoherentModel, extract_frames
    s = make_burst([payload, payload, payload], preamble_frames=1)
    si = np.clip(np.round(s.real), -32768, 32767) \
         + 1j*np.clip(np.round(s.imag), -32768, 32767)
    m = CoherentModel(625000.0 / SYMBOL_RATE)
    Y1, Y2 = m.track_correlations(si)
    d0, d1 = m.combine(Y1, Y2)
    sf = m.resolve(d0, d1)
    frames = extract_frames(sf)
    ok2 = len(frames) >= 2 and all(np.array_equal(f[2], payload)
                                   for f in frames[1:])
    print(f"mod->demod loop: {len(frames)} frames, payload match on "
          f"settled frames -> {'PASS' if ok2 else 'FAIL'}")
