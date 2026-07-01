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

## Team takeaways

1. Do not budget fabric for XilSEM on Versal. It is PMC firmware, not soft IP.
2. Do budget fabric for selective TMR. That is the real cost, and it is a design
   choice about which logic to triplicate.
3. The 16:1 baseline's ~24% DSP headroom is reserved for that TMR. Treat it as
   allocated, not spare.
4. XilSEM's real costs are power, PMC RAM, and scrub latency. Put them in the
   radiation work item and the power/reliability analyses.
5. Scrubbing plus selective TMR is the flight combination. Neither alone is the
   answer: XilSEM stops accumulation, TMR handles the immediate transient.

---

## Provenance

Based on AMD/Xilinx primary sources and peer-reviewed literature: XilSEM migrated from
soft IP to PMC firmware on 7nm Versal (IEEE/NSREC proton-test paper; AMD Versal PLM
documentation), the UltraScale+ vs Versal soft-IP-vs-PMC distinction and the
scrubbing-latency / not-sufficient-alone caveats (ScienceDirect fault-tolerance
survey), and the XQRVC1902 SEE results (AMD SEFUW 2023/2025 presentations: NO SEL,
100% correctable SEUs, ultra-low SEFI). Confirm specifics against the current DS946
data sheet and the XilSEM chapter of UG1304 before freezing the flight radiation plan.
