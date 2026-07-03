
# Radiation Mitigation and the Fabric Budget (Team Brief)

**Audience:** MDT / Haifuraiya flight-build team.
**Scope:** how radiation mitigation interacts with the FPGA resource budget on the
flight target (XQR Versal AI Core XQRVC1902). One question drove this: "we never
allocated fabric for XilSEM, could it bust our budget?" Short answer: no, but read on,
because the part that CAN cost fabric is a different thing.

---

## The one-sentence version

On Versal, XilSEM costs you no programmable-logic fabric (it is PMC firmware, not a
soft IP core), so it does not threaten the DSP/LUT/BRAM budget; the fabric cost of
radiation mitigation lives in selective TMR of critical logic, and the 16:1 baseline
was chosen partly to leave headroom for exactly that.

---

## What changed from the older parts (why this is not like UltraScale+)

XilSEM (Xilinx Soft Error Mitigation) scrubs configuration memory (CRAM) to keep
single-event upsets from accumulating in the bits that define your routing and logic.

- **UltraScale+ / 7-series:** XilSEM was a SOFT IP core. It synthesized into the
  programmable logic and cost real fabric (LUTs, flip-flops, BRAM). On those parts you
  had to budget for it.
- **Versal (our flight part):** XilSEM MOVED into the hardened Platform Management
  Controller (PMC). It is firmware running on the PMC's MicroBlaze (PPU), using
  dedicated config-frame scan hardware and the PMC's own RAM. It does NOT synthesize
  into the programmable logic.

Net effect for us: enabling XilSEM consumes PMC processor cycles and PMC RAM, not the
DSP / LUT / BRAM that the channelizer, demod cores, and DVB-S2 encoder compete for.
It does not move the ~1,495 DSP / 76% number at all.

---

## The distinction that matters: scrubbing is not the same as protection

XilSEM keeps configuration memory clean, but it corrects on a scan cycle with
millisecond-scale latency. During that window an upset can still cause wrong behavior.
Scrubbing prevents ACCUMULATION of upsets; it does not by itself protect against the
immediate functional effect of one, and it is not sufficient on its own for a
high-radiation space environment.

So a real flight design combines two mechanisms:

1. **XilSEM (config-memory hygiene):** fabric-free on Versal. Prevents fault
   accumulation in CRAM and NPI registers. Essentially free in our budget.
2. **Selective TMR (functional protection):** triple-modular redundancy on the logic
   that cannot tolerate a transient upset. This is where fabric goes: up to 3x plus
   voters on whatever you choose to triplicate.

TMR is a deliberate, SELECTIVE decision, applied to the most upset-critical logic, not
a blanket tax on the whole design. But it is the real fabric-cost lever, and it is the
thing to size against our headroom.

---

## Why the 16:1 baseline already accounts for this

This is the concrete reason we chose 16:1 (76% DSP on the flight part) over 8:1
(~91%):

- 16:1 leaves ~24% of the DSP free on the XQRVC1902, plus we reclaimed ~450 DSP by
  sharing the power detector.
- That headroom is the budget selective TMR draws against when the radiation work item
  is executed.
- At 8:1 (~91%) there would be almost no room to triplicate anything. The 16:1 margin
  is not slack; it is reserved space for functional redundancy.

So radiation mitigation is not unbudgeted. XilSEM is fabric-free, and the TMR headroom
was deliberately preserved by the baseline decision.

---

## Where XilSEM's costs actually land (so nobody is surprised)

XilSEM is free in FABRIC, not free everywhere. Its costs belong in other budgets:

- **Power:** the background scan adds power draw -> flight power/thermal budget.
- **PMC RAM:** XilSEM firmware and state live in PMC RAM -> PMC memory budget.
- **Latency / reliability:** millisecond scrub-and-correct latency -> reliability and
  FDIR (fault detection, isolation, recovery) analysis, including SEFI handling.

None of these touch DSP / LUT / BRAM. Record them in the radiation work item, not the
fabric tally.

---

## What XilSEM does and does not cover

- **Covers:** configuration memory (CRAM) upsets, and NPI (NoC peripheral interface)
  register corruption. It detects and corrects; AMD reports 100% correctable SEUs and
  ultra-low SEFI on the XQRVC1902, and the PMC itself is triple-redundant so the
  scrubber is protected.
- **Does not cover:** user flip-flop / datapath STATE (that needs TMR), and user
  BRAM/URAM data CONTENT (that uses the block-RAM hardware ECC, enabled separately,
  small-to-no fabric cost). Plan these explicitly; do not assume XilSEM catches them.

---

## Part 2: What to actually harden - the state-classification model

The reflex that busts the budget is "triplicate everything." It is the wrong model for
a streaming communications payload, and it never fits. The right model is a domain
model of state: classify every register and RAM not by what it is, but by what a single
bit-flip does to it and how long the damage lasts. Do that pass and the mitigation
falls out mechanically - and cheaply, because only one class is expensive and it is the
smallest.

### The three buckets

**Bucket 1 - self-healing (transient-tolerant streaming state).** A flip corrupts one
sample, which flushes out of the pipeline in a handful of clocks and is gone. It is
indistinguishable from an RF noise hit, and you already fly a machine whose whole job is
absorbing those: the FEC (the Viterbi decoder, and the ground receiver's LDPC). No TMR.
This is the DSP-heavy majority of the design, and it stays single.

**Bucket 2 - self-recovering (loop and adaptive state).** A flip can knock a loop out of
lock or perturb an average, but the loop's job is to re-converge, so it heals itself. No
TMR. You add a cheap watchdog that notices "unlocked too long" and triggers re-acquire,
which matches how the loop already behaves.

**Bucket 3 - persistent control state (does not self-heal).** Control FSMs, sequencers,
counters, and set-once config registers. A flip here does not flush and does not
re-converge; it hangs or mis-sequences the block until reset, and on a 16:1 core a stuck
sequencer corrupts all sixteen channels at once. This is what earns TMR. It is a few
percent of the fabric, so tripling it is noise on a part you run at ~13% LUT.

### The D&D framing (for the team)

You are not plate-armoring every hit point - that is full TMR, and it is why it never
fits. You run layered defenses matched to the threat:

- **XilSEM scrubbing** is the cleric re-consecrating the ground every round, keeping the
  rules of reality (the configuration that defines the circuit) from corrupting. A
  separate hardened NPC; costs the party no resources.
- **The datapath has regeneration.** A transient hit is a scratch that heals next turn;
  the FEC is the regeneration spell. You do not armor the arrows - samples are
  consumable.
- **Heavy armor goes on the one caster who, if confused, wipes the party** - the
  control-flow logic. Only it gets a triple-vote on "what do we do next."
- **Memories get a ward that auto-corrects a smudged rune** - BRAM/URAM ECC.
- **The DM keeps a "reset the scene if it all glitches" rule** - the SEFI watchdog.

### MDT / Haifuraiya classification

| MDT block / state | Class | Effect of a single upset | Mitigation (fabric cost) |
|---|---|---|---|
| Polyphase filterbanks, FFT, halfband, channel EQ | Self-healing | one corrupted sample, flushes in a few clocks | none; flush + FEC (no cost) |
| de Buda FIR, square, mix | Self-healing | one bad sample; the loop treats it as noise | none (no cost) |
| CORDIC (16 stages) | Self-healing | one bad angle, flushes in 16 clocks | none (no cost) |
| Power-detector squaring (I^2 + Q^2) | Self-healing | one bad power sample, absorbed by the EMA | none (no cost) |
| DVB-S2 encode datapath (BCH, LDPC, map, shape) | Self-healing | one bad TX symbol; the ground LDPC absorbs it | none (no cost) |
| Costas f1/f2 NCO phase + loop-filter accumulators | Self-recovering | possible loss of lock; the loop re-acquires | lock watchdog + re-acquire (negligible) |
| de Buda common carrier NCO + PI integrator | Self-recovering | carrier wander or unlock; re-converges | watchdog (negligible) |
| Costas lock-detect accumulators / counters | Self-recovering | false lock/unlock; re-evaluated continuously | watchdog + hysteresis (negligible) |
| AGC / power-detector EMA feedback (51-bit mult_sum) | Self-recovering | transient wrong gain; decays over ~1/alpha, saturation bounds it | ECC on the state RAM + existing SAT clamp (negligible) |
| Symbol-timing recovery state | Self-recovering | timing slip; re-locks | watchdog (negligible) |
| 16:1 interleave sequencer / channel counter | TMR-critical | wrong-channel addressing; corrupts all 16 channels; persists | TMR: triplicate + vote (small: a few FF + voter) |
| WP2 power-detector channel counter | TMR-critical | wrong-channel addressing; persists | TMR (small) |
| Frame-sync FSM (sync detect, boundaries) | TMR-critical | lost frame alignment; wrong TLAST/TDEST; persists | TMR core FSM + robust re-sync (small) |
| AXI-Stream handshake / control FSMs | TMR-critical | protocol violation or deadlock; persists | TMR (small) |
| DVB-S2 PLframe / header sequencer | TMR-critical | malformed frames; ground loses lock; persists | TMR control FSM (small) |
| Config registers (alpha, shifts, modes, thresholds) | TMR-critical (persistent) | silently wrong config for the rest of the mission | TMR the bits, or periodic refresh from a PMC golden copy (tiny) |
| All state RAMs (WP1 interleave state, WP2 EMA table, FIR windows) | Memory content | corrupted stored value until read | BRAM/URAM hardware ECC (no fabric) |
| Constant memories (channelizer coeffs, LDPC/BCH tables) | Memory content | corrupted constant until reload | ECC or periodic reload from golden (no fabric) |
| CRAM + NPI config bits (define the circuit itself) | Config memory | routing/logic corruption anywhere until scrubbed (~ms) | XilSEM (PMC firmware, no fabric) |

### What the RTL change actually is (it is contained)

- **TMR of an FSM:** three copies of that FSM's registers plus a majority voter on its
  outputs. A local edit to a small module, not a datapath rewrite. Vivado can assist,
  and paired with XilSEM you usually avoid the heavy physically-isolated TMR flow,
  because the triplication catches the transient flop upset and the scrubber repairs the
  underlying config before a second copy can accumulate an upset.
- **BRAM/URAM ECC:** a primitive mode or attribute on the RAM, plus handling the
  corrected and uncorrectable flags. Not fabric.
- **Watchdogs:** mostly PS/PMC firmware plus a little liveness logic.

None of this touches the DSP columns.

### Budget impact

The DSP number that binds you barely moves, because the DSP-heavy datapath is Bucket 1
and stays single. The cost lands in LUTs for triplicated control, which is small on a
part running at ~13% LUT. The ~76% DSP picture survives essentially intact, and the 24%
headroom is more than selective control-TMR needs. Full TMR of the datapath (the
"triplicate everything" reflex) would be ~3x and would not fit - which is exactly why
you classify first and triplicate only Bucket 3.

The real deliverable of the radiation work item is the classification pass itself: for
every state element, decide self-healing / self-recovering / persistent-critical. The
risk is misclassifying a couple of elements, not the fabric. Do the pass; do not assume
it.

---

## Team takeaways

1. Do not triplicate everything. Classify state first by fault behavior - self-healing,
   self-recovering, persistent-critical - and TMR only the last bucket.
2. The DSP-heavy datapath is self-healing (flush + FEC), so it stays single. The DSP
   budget barely moves and the ~76% picture survives.
3. TMR goes on control only: sequencers, FSMs, config registers. That is a few percent
   of fabric, small on a part at ~13% LUT.
4. Loops get watchdogs, not triplication - they re-acquire on their own.
5. All state and constant RAMs get hardware ECC (no fabric); XilSEM covers config
   memory (PMC firmware, no fabric). Neither threatens the budget.
6. Do not budget fabric for XilSEM on Versal. It is PMC firmware, not soft IP. Its real
   costs are power, PMC RAM, and scrub latency - put those in the power/reliability
   analyses.
7. Scrubbing plus selective TMR is the flight combination: XilSEM stops accumulation,
   TMR handles the immediate transient on the logic that cannot self-heal.
8. The deliverable is the classification pass. The risk is misclassifying an element,
   not the fabric. Do the pass for real.

---

## Provenance

Based on AMD/Xilinx primary sources and peer-reviewed literature: XilSEM migrated from
soft IP to PMC firmware on 7nm Versal (IEEE/NSREC proton-test paper; AMD Versal PLM
documentation), the UltraScale+ vs Versal soft-IP-vs-PMC distinction and the
scrubbing-latency / not-sufficient-alone caveats (ScienceDirect fault-tolerance
survey), and the XQRVC1902 SEE results (AMD SEFUW 2023/2025 presentations: NO SEL,
100% correctable SEUs, ultra-low SEFI). Confirm specifics against the current DS946
data sheet and the XilSEM chapter of UG1304 before freezing the flight radiation plan.
