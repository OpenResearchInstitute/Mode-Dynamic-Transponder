# WP: Soft-bit drop-policy FIFO (the wedge cure)

**Status:** specified 2026-07-21 from a full day of bench characterization.
Not implemented. Sim-gated. This is the RTL work item; the companion
format contract (dogu: softbit format WP) covers the consumer side.

## Governing principle

**The demodulator never sees downstream tready. Ever.** A real-time
receiver owes the air continuous attention; a slow, stopped, or absent
consumer loses payload (counted), never lock. Standing requirements
(2026-07-21, both violated by the current build):
- Dead air shall never cause radio issues.
- Consumer behavior shall never affect demodulation.

## The defect, as measured

- axis_softbit_widen: "backpressure (tready) propagates directly" (its own
  header). Elastic slack measured ~1 true frame (4288 DMA bytes): FRAMES
  advances ~1 frame past consumer death, then the entire demod freezes --
  every accumulator embalmed mid-value (QUAL, CLK, SYM all frozen), no
  LOST transition (FSM ticks on samples that stopped), no self-recovery.
- Only DEMOD_INIT (0x05C pulse 1->0) revives it. Draining does not.
- Trigger: any unposted-DMA-descriptor window. Measured causes: consumer
  exit on timeout (fixed in dma_listen via -k), consumer restart gaps,
  and -- open question -- possibly spontaneous during posted-buffer flow
  (~30-60 s cadence; fresh4.bin shows onset mid-slip-pocket, so the wedge
  may be a clock-slip event that latches the frame path; see
  WP_SYMBOL_CLOCK_SLIP open question).
- frame_buffer_overflow (fsync port) guards the BYTE-path circ_buffer,
  whose reader is tied tready='1' -- it can never fire as wired. The
  soft path (soft_frame_buf -> m_axis_soft_bit), the one that actually
  jams, has NO overflow witness. (Credit: caught in review 2026-07-21.)

## Design

Insert a frame-granular drop-policy FIFO between frame_sync_detector_soft's
m_axis_soft_bit and axis_softbit_widen:

1. **Input side always ready.** The detector's soft stream is accepted
   unconditionally; backpressure terminates at the FIFO, never upstream.
2. **Whole-frame drop discipline.** If a complete incoming frame will not
   fit, discard THAT ENTIRE frame and increment DROPPED. Never emit a
   partial frame: downstream opv-decode -3 has no resync, so frame
   alignment is worth more than any amount of depth.
3. **Registers (new, demod map):**
   - SOFT_DROPPED     RO, monotonic frame-drop counter
   - SOFT_HIGH_WATER  RO, max FIFO occupancy (frames) since read-clear
   - SOFT_OVF_EVENT   RO sticky: set on any drop; the soft-path overflow
     witness that does not currently exist. Bouro displays all three.
4. **Depth: build generous, size by measurement.** First cut 64 frames
   (137 kB, ~3.3% of ZU9EG BRAM -- verify headroom in the impl_1
   utilization report first). Sizing table at 2144 B/frame, 25 fps:
     2 frames = 80 ms   (today's slack -- measured fatal)
     25       = 1 s     (scheduler tails)
     64       = 2.6 s   (first cut; covers measured 0.48 s stalls with 5x)
     125      = 5 s     (consumer crash + restart, ~2 s iio setup measured)
   After deployment, SOFT_HIGH_WATER over a stress campaign gives the true
   requirement plus margin; shrink (or grow) from measurement, not argument.

Consumer side (dogu, belt to these suspenders): dma_listen -k and -t are
done; add multiple always-posted IIO blocks and run as a supervised
service so unposted windows shrink toward zero. SOFT_HIGH_WATER will show
how much that helps.

## Acceptance campaign (hardware, each test one scar converted to a spec)

- **T1 consumer-kill:** kill consumer 10 s mid-flow, restart. Lock never
  wavers (QUAL breathing throughout, CFO stays HELD); SOFT_DROPPED equals
  the overflow arithmetic exactly; first delivered frame after restart
  decodes aligned (metric 0 or channel-honest).
- **T2 dead-air contract:** unkey TX. Clean HELD->LOST with warm estimate,
  QUAL decays (no freeze); rekey: autonomous reacquisition; zero register
  writes; SOFT_DROPPED unchanged by silence.
- **T3 endurance:** >=1 hour continuous flow, DROPPED==0, HIGH_WATER
  logged, zero DEMOD_INIT pulses. The phrase "pulse DEMOD_INIT" leaves
  the operating vocabulary.
- Sim gate first: gold baseline bit-exact through the FIFO at 0 drops;
  a forced-stall testbench proves whole-frame drop + alignment + counters.

## Interaction with the slip WP

If the wedge proves to be a latching slip event (fresh4 evidence), the
FIFO prevents the freeze from propagating but the latch itself belongs to
WP_SYMBOL_CLOCK_SLIP. SOFT_OVF_EVENT + SLIP_COUNT together discriminate:
wedge-with-drops = backpressure class; wedge-without-drops = frame-path
latch. Build both witnesses in the same bitstream so one campaign answers.
