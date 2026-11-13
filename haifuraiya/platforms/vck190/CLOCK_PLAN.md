# Clock plan — every oscillator in the chain, what disciplines it, and what it costs

_Started 2026-11-12, the day the EV12AQ600-FMC-EVM user guide showed that
the card's sampling-clock synthesizer runs from a free-running crystal.
This file is the one place that says where each clock comes from, which
reference it follows, and how much frequency error each one puts into the
signal. Numbers are labelled: **measured**, **datasheet/guide**,
**arithmetic**, or **estimate**._

## 0. The principle

One reference, and everything derives from it. A converter clock, a local
oscillator or a symbol clock that is not locked to the reference is an
error source that has to be measured and tracked out; one that is locked
is a known quantity. Spacecraft payloads are built this way — a single
master oscillator with a distribution tree — and so is any serious earth
station. The prototype is built the same way from now on, because the
alternative is ±100 kHz of carrier error against a 156.25 kHz channel
spacing (§2).

## 1. The lab reference

**Trimble Thunderbolt** GPS-disciplined clock (confirmed by Paul,
2026-11-12; the enclosure version, label 35119069 / A002206.G1 Rev E,
dated 3/14/05; external GPS antenna), into a **TAPR TADD-series
distribution amplifier** with open ports. Paul is adding both to the
Remote Lab equipment list; that listing is the authority for which TADD
model and which ports are in use.

Thunderbolt figures (Trimble's datasheet):

- 10 MHz output: sinusoidal, **+12.5 ± 2.5 dBm into 50 Ω**;
- accuracy when locked: **1.16 × 10⁻¹²** (one-day average) — at 5.66 GHz
  that is 7 mHz (**arithmetic**): nothing;
- holdover ±1 µs over two hours with ≤ 15 °C change — so the box must
  have satellites: check its lock indicator (or the serial monitor)
  before trusting a measurement;
- 1 PPS to UTC, 20 ns one sigma; +24 V DC prime power.

Still to record: the TADD model and its output level per port (TAPR's
assembly document has it), and whether the EVM's SMA12 input wants the
Thunderbolt's +12.5 dBm attenuated — the HMC1031's reference-input range
is in its datasheet and the EVM guide's SMA12 note; a pad in line if so.

## 2. The numbers that make this matter (arithmetic)

Frequency error scales with carrier frequency; the uplink is at 5.66 GHz
and the downlink at 10.45 GHz.

| source of error | ppm | at 5.66 GHz | at 10.45 GHz |
|---|---|---|---|
| EVM's VCXO free-running, Abracon ABLNO-V, Digi-Key's figure | ±18 | **±102 kHz** | — |
| a plain TCXO (temperature-compensated crystal) | ±1–2 | ±5.7–11.3 kHz | ±10–21 kHz |
| an OCXO (oven-controlled), over temperature and years | ±0.1 | ±566 Hz | ±1.0 kHz |
| a GPS-disciplined oscillator | ~10⁻⁵ | ~0.06 Hz | ~0.1 Hz |
| what the receiver has been exercised at | — | 500 Hz carrier offset (stimulus); 498 Hz measured on the board | — |
| channel spacing (10 MSps / 64) | — | **156.25 kHz** | — |

So a free-running EVM alone could put the test signal most of a channel
away from where the receiver expects it. With both ends on the lab
reference the residual is the reference's own error — a fraction of a
hertz for a GPS-disciplined one.

Symbol timing is a separate, milder effect: a ppm of reference error is a
ppm of symbol-clock error, and the receiver's symbol loop has tracked
−11.4 ppm on the board (**measured**, tier 2) without complaint.

## 3. The bench clock tree for tier 3

```
lab 10 MHz reference ──► distribution amplifier
        ├──► EV12AQ600-FMC-EVM, SMA12 (external reference input)
        │        HMC1031 jitter cleaner, D0/D1 = 1/1 (divide by 10)
        │        disciplines the 100 MHz VCXO ──► LMX2592 ──► 5 GHz f_CLK ──► ADC
        │        REF_SEL = 0 (SMA12), REF_SEL_EXT = 1 (HMC1031 drives the VCXO)
        │        ADC SSO = f_CLK/32 = 156.25 MHz ──► VCK190 FMC1 GBTCLK0 ──► GTY reference
        │        every data clock in the link, and the 20 MSps the receiver sees (f_CLK/250), follow it
        ├──► the Opulent Voice test transmitter's reference input   (TBD: which radio, which input)
        ├──► later: the EV12DD700's external sampling clock source
        └──► a counter / spectrum analyzer, for checking that the others are locked
```

What is **not** on the reference, and why that is fine:

- The VCK190's own clocks — the 100 MHz PL clock from the CIPS, the user
  SI570 that is the tier-2 GT reference. In tier 3 the GT reference is the
  ADC's SSO, so the serial link and every sample clock are the ADC's; the
  PL clock only paces DMA and registers. Its error never touches the
  signal. (The SI570 stays in the design for tier 2 and the loopback
  card; `REFCLK_STRING` selects.)
- The Samtec loopback card's 156.25 MHz generator (tier 2½) — a stand-in
  for the SSO, and in loopback the data clock is its own reference, so
  its error cancels. The clock monitor only asks "is it 156.25 MHz within
  tolerance".

Settings on the card are three FMC control lines (`REF_SEL`, `REF_SEL_EXT`,
`HMC1031_D0/D1`), which means they are register bits under dōgu's
tier-3 bring-up, with `PLL_LOCK` (LA16_P) read back — the bring-up script
refuses to proceed without lock, the same way `opv_play` refuses without
`link_ready`.

## 4. How we will know it is locked (the checks, in order)

1. `PLL_LOCK` reads 1 after the LMX2592 is programmed with the card's
   reference switched to SMA12.
2. The SSO measured on the counter against the 10 MHz: 156.250000 MHz to
   the counter's resolution. Also the link block's `REFCLK_PERIOD`
   register (655 at 156.25 MHz; its resolution is coarse, but 100 MHz
   reads 1024 — it tells "right clock" from "wrong clock").
3. The receiver's `cfo_word` on the board with a test carrier of known
   frequency: the residual, in hertz, is the number to record. With both
   ends locked it should be the reference's error plus the transmitter's
   own synthesis error, not kilohertz.
4. `sym_clk_offset` in the same run: the ppm the symbol loop is
   correcting. Tier 2 read −11.4 ppm because the *stimulus* was stretched
   on purpose; a locked chain with an unstretched stimulus should read
   near zero. Any ppm that appears is an unlocked clock somewhere.

## 5. What the receiver can catch — a measurement to make (open)

The carrier loop has been shown to *hold* a 500 Hz offset. What it can
*acquire* — how far off a carrier can be and still be found — has not
been measured. It is one bench series with the existing tools: the
stimulus generator's `--carrier-offset` stepped outward until frames stop
decoding, both signs, with the result recorded in `VCK190_PLAYBACK_PLAN.md`.
That number decides the system question in §6: whether users must bring a
disciplined reference, or the receiver gains a frequency-search stage in
front of the per-channel demodulator, or both.

## 6. The payload, and the ground (direction, not yet design)

- **Master oscillator.** One space-qualified OCXO (10 or 100 MHz) as the
  payload's reference; every synthesizer — the ADC clock, the DAC clock,
  any local oscillator — locked to it through a distribution tree. The
  EVM's architecture (reference → jitter cleaner → VCXO → LMX2592) is a
  miniature of this; the EVM's `CLK_SEL` = 0 path (an external clock
  straight into the ADC, bypassing the LMX2592 — how Teledyne
  characterized the part) is where a better synthesizer gets tried
  without changing anything else.
- **A beacon**, derived from the master, on the downlink: every ground
  station can measure the payload's reference error and remove it. This
  is how QO-100 made amateur stations workable, and it makes the
  payload's own error a non-problem for users.
- **Users.** A GPS-disciplined reference is cheap now; whether to require
  it, or to design the acquisition range to cover a TCXO's ±2 ppm, is the
  §5 number's decision. Likely both, as on QO-100.
- **Doppler.** Small for a geostationary payload — station-keeping motion
  gives hundreds of hertz of slow wander at these frequencies
  (**estimate**); the beacon covers it. A low-Earth-orbit variant would see
  ±140 kHz at 5.66 GHz (7.5 km/s; **arithmetic**) and would need the
  search stage regardless.
- **Phase noise** is the other half of the clock question and is not
  frequency error: ESISTREAM_NOTES §5 has the LMX2592 estimate (jitter-
  limited SNR about equal to the ADC's own at 5.66 GHz); a space synthesizer
  gets its own line here when one is chosen.

## 7. To do, in order

1. ~~Record the lab reference's make, model and discipline~~ (Trimble Thunderbolt, §1); record the TADD model, its port level, and whether SMA12 needs a pad.
2. Wire SMA12; set `REF_SEL`/`REF_SEL_EXT`/`D0/D1` in the tier-3 bring-up;
   read `PLL_LOCK` (§3, §4) — when the card is in hand.
3. Find the test transmitter's reference input and put it on the
   distribution amplifier (§3).
4. Measure the receiver's acquisition range with the existing stimulus
   tools (§5) — this needs no card and can be done now.
5. Add the clock tree to the payload design notes when the OCXO and the
   beacon are chosen (§6).
