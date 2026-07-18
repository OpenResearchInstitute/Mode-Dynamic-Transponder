# Demod Register Map: Fate Table (rework campaign-let, step zero)
Draft 2026-07-18 from haifuraiya_demod_regs.vhd. RULE: bring-up runs on
THIS map (proven: 6/6 in-system). Rework lands AFTER first boot, as its
own bench-gated change (AXI smoke tests + system bench regression).

## KEEP -- live and correct
| Addr | Register | Why |
|---|---|---|
| 0x000 | VERSION | identity; bump on map rework |
| 0x004 | CONTROL | live control plane |
| 0x048 | FS_HUNT_THRESH | normalized fsync, PERCENT units (85) |
| 0x04C | FS_VERIFY_THRESH | percent (70) |
| 0x050-58 | QUANT_THR_1/2/3 | 3-bit bins (4942/9884/14826); calibration item |
| 0x05C | DEMOD_INIT | the init bracket; TB + PS use it |
| 0x044 | FRAMES_RX | fsync frame counter (verify it counts on hw) |
| 0x040 | STATUS | audit contents; keep the live bits |
| 0x088 | LOCK_STATUS | REPURPOSE: now reflects single MLSE demod_lock (both legacy bits mirror it) |

## RETIRE -- write parked wires or read tied zeros (Costas era)
0x008/0x00C FREQ_F1/F2; 0x010-0x020 LPF_P/I_GAIN, ALPHA, SHIFTs;
0x024/0x028 SYM_CNT/THR (Costas symbol-lock detector);
0x030 GAIN_MANUAL + 0x038 GAIN_CURRENT (Kd-slice era; job moved to
normalizer setpoint); 0x060 LOOP_CTRL; 0x064 RX_SAMPLE_DISCARD;
0x068/0x06C F1/F2_NCO_ADJUST; 0x070/0x074 F1/F2_ERROR;
0x078/0x07C LPF_ACCUM_F1/F2; 0x080/0x084 CST_LOCKTIME_F1/F2;
0x08C+ CST_ACC_* telemetry.
Rework: return DEAD_BEEF-style readback or repurpose addresses; delete
the write plumbing; PS software drops the writes.

## ADD -- MLSE observability (wrapper ports exist, mapped `open` today)
| Proposed | Register | Source |
|---|---|---|
| new | MLSE_STATUS | ovfl_mlse, ring_lag (sticky), demod_lock, live bits |
| new | MLSE_SYM_COUNT | dbg_sym (24b) -- symbols demodulated |
| new | MLSE_POS_HI | dbg_pos tap (timing loop health) |
| new | MLSE_THETA0 | dbg_th0 (PSP phase tap, debug) |
| new | NORM_GAIN_TARGET | promote NORM_TARGET constant -> AXI (the TODO at haifuraiya_channelizer_axi:236); default 9000 |
| new | NORM_SQUELCH / GAIN_MODE | same TODO family |

## Consumers to update in the same campaign-let
1. tb_haifuraiya_channelizer_axi register bracket (drop Costas writes,
   add MLSE status readback checks).
2. PS software (dogu/oriinit demod layer + headers): drop dead writes,
   add status polls; MQTT_TOPICS.md demod topics -- audit for Costas
   telemetry topics that now publish zeros (channelizer topics: solid).
3. VERSION bump + this doc becomes the map's README.
