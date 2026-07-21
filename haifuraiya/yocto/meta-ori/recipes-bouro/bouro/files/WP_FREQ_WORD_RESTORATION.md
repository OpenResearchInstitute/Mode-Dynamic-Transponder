# WP: Restore runtime-configurable tone frequency words (MLSE regression)

**Status:** specified 2026-07-21, from bench-session measurement. Not yet implemented.
**Gate:** simulate before synthesize. Bit-exact gold baseline must reproduce with
registers wired and defaults unchanged before any bitstream is built.

## The violation

Standing project requirement, in force for two years and recorded in doctrine:
*frequency words must be named and configurable even when values are known.*

The MLSE port violated it two ways:

1. **The registers went dead.** `FREQ_WORD_F1/F2` (0x008/0x00C) reach
   `haifuraiya_rx_top` as ports `rx_freq_word_f1/f2` (lines 71-72) and are
   referenced nowhere else in the file. The Costas demod consumed them; the
   MLSE demod never did. They synthesize, close timing, read back correctly,
   and influence nothing.

2. **The replacement is a meaningless build-time constant.**
   `msk_symbol_engine.vhd:34`: `G_INC32 : integer := 93114891` — the name
   carries no frequency, no units, no derivation. Configurable only by
   re-synthesis.

3. **Bonus defect found because of (1):** the dead register value
   (0x058CD20B = 93,180,427) and the live generic (93,114,891) disagree —
   ~9.5 Hz at 625 ksps. Two constants for one tone, one consumed, values
   diverged, nobody could notice because the register does nothing.

## The fix

### RTL
- `msk_symbol_engine`: add ports `freq_word_f1_i, freq_word_f2_i :
  std_logic_vector(31 downto 0)`. All internal tone-NCO uses of `G_INC32`
  switch to the ports (register the values at a safe rate-crossing point;
  tones change only between symbols or on rx_init to avoid mid-symbol phase
  jumps — decide and document which during implementation).
- Rename the generic to `G_FREQ_WORD_F2_RESET : std_logic_vector(31 downto 0)
  := x"058CD20B"` (and derive F1 as its negation, or carry both) — it becomes
  the RESET DEFAULT ONLY, mirrored by the register file's reset branch per
  doctrine. The name states what it is; the comment states the derivation:
  `-- +13550 Hz at 625 ksps: round(13550/625000 * 2^32)`.
- `haifuraiya_rx_top`: connect `rx_freq_word_f1/f2` through
  `msk_demodulator_mlse` (add pass-through ports) into the engine.
- `cfo_afc`: same treatment for `G_SYMBOL_RATE` is a follow-on candidate
  (named, but synthesis-time; a bit-rate experiment currently re-synthesizes
  the AFC). Separate commit; one variable at a time.

### Value reconciliation (decide, then pin everywhere)
Compute the canonical word once, in one place:
`round(13550 / 625000 * 2^32) = 93,114,891 = 0x058CD20B is FALSE — that hex
is 93,180,427.` The canonical value and its hex must be recomputed, agreed,
and then used identically in: the generic default, the register-file reset
branch, tb constants, bring-up.sh DM_FREQ_*, and MQTT_TOPICS.md. The current
tb/bring-up word (0x058CD20B) and the current generic (93114891) cannot both
be right. Resolve by derivation from first principles + one sim run each.

### Acceptance tests (all terminal-verified)
1. Gold baseline reproduces bit-exact with registers wired, defaults untouched.
2. Write a deliberately wrong freq word (e.g. +5 kHz off): decode MUST die.
3. Restore the correct word at runtime: decode MUST recover. This proves the
   register is load-bearing — the test that would have caught this regression.
4. Sweep one off-nominal tone pair in sim (local-IF rehearsal) to prove the
   configurability claim, not just assert it.

### Naming doctrine (add to plan-of-attack)
A constant's name must state its quantity and its role
(`G_FREQ_WORD_F2_RESET`), and its comment must state units and derivation.
`G_INC32` — a width and the word "increment" — is the anti-pattern: it made a
frequency invisible to the person who owns the frequency plan.
