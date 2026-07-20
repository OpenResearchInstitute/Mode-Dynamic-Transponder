#!/bin/sh
#
# bouro_pub.sh - Haifuraiya channelizer telemetry publisher
#
# v0 stub. Companion to Speculator's ovp_status_pub.sh on pluto_msk;
# same architecture, ported to ZCU102 + Haifuraiya channelizer.
#
#   - Reads channelizer registers via `devmem` from /dev/mem mmap
#   - Publishes raw hex AND derived/parsed values to MQTT
#   - 8 scalar registers + 64 per-channel power registers + JSON spectrum
#   - Liveness heartbeat once per cycle
#
# TOPIC STRUCTURE:
#   haifuraiya/status/register/<name>          Raw hex from devmem
#   haifuraiya/status/derived/<area>/<aspect>  Parsed/computed values
#   haifuraiya/status/heartbeat                ISO 8601 timestamp
#   haifuraiya/status/publisher/<aspect>       Publisher metadata
#
# Update rate is ~0.3 Hz with ~150 topics due to fork-per-publish
# overhead from invoking mosquitto_pub once per topic. Acceptable for
# v0 dashboard refresh; insufficient for catching ms-scale transients.
# Future optimization: rewrite with a single persistent broker
# connection (Python+paho-mqtt is the natural choice). See MQTT_TOPICS.md.
#
# Subscribe to verify:
#   mosquitto_sub -h <zcu102-ip> -t 'haifuraiya/status/#' -v

set -u

# =====================================================================
# Configuration
# =====================================================================

ADDR_BASE=0x84A70000             # Channelizer AXI-Lite base (from Phase 3 build)
EXPECTED_VERSION=0x00010000      # v0.1.0 magic — refuse to start otherwise
INTERVAL=1                       # seconds between cycles
PUB_VERSION="0.2"

N_CHANNELS=64
CHANNEL_BASE_OFFSET=0x100        # CHANNEL_POWER_N at 0x100 + 4*N

DEMOD_BASE=0x84A80000            # Demod / frame-sync AXI-Lite base (rx_axi demod_regs)
DEMOD_EXPECTED_VERSION=0x00060000  # map v6 -- consumers gate on this (REGISTER_MAP_V6.md)

# State across cycles (wrap-aware delta computation for monotonic counters).
# Empty on first cycle → first delta published as 0.
PREV_FRAME_COUNT=""
PREV_DROPPED_FRAMES=""
PREV_FRAMES_RX=""

# =====================================================================
# Helpers
# =====================================================================

# Read a 32-bit register at offset from ADDR_BASE. Returns "0xHHHHHHHH"
# or empty string on failure. The explicit "32" width matters on aarch64
# where busybox devmem otherwise defaults to 64-bit word size.
read_reg_hex() {
    OFFSET=$1
    ADDR=$((ADDR_BASE + OFFSET))
    devmem $ADDR 32 2>/dev/null
}

# Same, but against the demod / frame-sync register block (DEMOD_BASE).
read_demod_hex() {
    OFFSET=$1
    ADDR=$((DEMOD_BASE + OFFSET))
    devmem $ADDR 32 2>/dev/null
}

# Convert "0xHHHHHHHH" hex string to unsigned decimal.
hex_to_dec() {
    printf "%d" "$1"
}

# Convert "0xHHHHHHHH" to SIGNED 32-bit decimal (two's complement).
hex_to_sdec() {
    V=$(printf "%d" "$1")
    if [ "$V" -ge 2147483648 ]; then
        echo $((V - 4294967296))
    else
        echo "$V"
    fi
}

# Publish raw register topic.
pub_register() {
    mosquitto_pub -t "haifuraiya/status/register/$1" -m "$2"
}

# Publish derived topic (skip empty payloads).
pub_derived() {
    [ -z "${2:-}" ] && return
    mosquitto_pub -t "haifuraiya/status/derived/$1" -m "$2"
}

# Wrap-aware delta for a 32-bit monotonic counter.
# First cycle (no previous value) emits 0 so the first heartbeat doesn't
# spike a large bogus delta to subscribers.
compute_delta_32() {
    PREV=$1
    CURR=$2
    if [ -z "$PREV" ]; then
        echo "0"
        return
    fi
    if [ "$CURR" -ge "$PREV" ]; then
        echo $((CURR - PREV))
    else
        echo $((4294967296 - PREV + CURR))
    fi
}

# =====================================================================
# Scalar register publishing
# =====================================================================
#
# Each scalar gets its raw hex published unconditionally, then any
# named bitfield decomposition under derived/.
#
# Eight scalars total; written out explicitly rather than table-driven
# because we need state mutation across iterations (delta counters) and
# `echo $TABLE | while read` runs in a subshell that drops mutations.

publish_scalars() {
    # ---- VERSION (0x000) — should read 0x00010000 = v0.1.0
    VAL_HEX=$(read_reg_hex 0x00)
    if [ -n "$VAL_HEX" ]; then
        pub_register "version" "$VAL_HEX"
        VAL_DEC=$(hex_to_dec "$VAL_HEX")
        if [ "$VAL_HEX" = "$EXPECTED_VERSION" ]; then
            pub_derived "signature" "OK"
        else
            pub_derived "signature" "WRONG"
        fi
        pub_derived "version/major" "$(((VAL_DEC >> 16) & 0xFFFF))"
        pub_derived "version/minor" "$(((VAL_DEC >> 8) & 0xFF))"
        pub_derived "version/patch" "$((VAL_DEC & 0xFF))"
    fi

    # ---- CONTROL (0x004) — bit 0 soft_reset (sticky), bit 1 enable
    VAL_HEX=$(read_reg_hex 0x04)
    if [ -n "$VAL_HEX" ]; then
        pub_register "control" "$VAL_HEX"
        VAL_DEC=$(hex_to_dec "$VAL_HEX")
        pub_derived "control/soft_reset" "$((VAL_DEC & 1))"
        pub_derived "control/enable"     "$(((VAL_DEC >> 1) & 1))"
    fi

    # ---- STATUS (0x008) — bit 0 ready, bit 1 overflow_sticky,
    #                        bit 2 backpressure_sticky
    VAL_HEX=$(read_reg_hex 0x08)
    if [ -n "$VAL_HEX" ]; then
        pub_register "status" "$VAL_HEX"
        VAL_DEC=$(hex_to_dec "$VAL_HEX")
        pub_derived "status/ready"                "$((VAL_DEC & 1))"
        pub_derived "status/overflow_sticky"      "$(((VAL_DEC >> 1) & 1))"
        pub_derived "status/backpressure_sticky"  "$(((VAL_DEC >> 2) & 1))"
    fi

    # ---- FRAME_COUNT (0x00C) — monotonic 32-bit, wraps at 2^32
    VAL_HEX=$(read_reg_hex 0x0c)
    if [ -n "$VAL_HEX" ]; then
        pub_register "frame_count" "$VAL_HEX"
        VAL_DEC=$(hex_to_dec "$VAL_HEX")
        DELTA=$(compute_delta_32 "$PREV_FRAME_COUNT" "$VAL_DEC")
        pub_derived "frame_count/value" "$VAL_DEC"
        pub_derived "frame_count/delta" "$DELTA"
        PREV_FRAME_COUNT=$VAL_DEC
    fi

    # ---- DROPPED_FRAMES (0x010) — monotonic 32-bit
    VAL_HEX=$(read_reg_hex 0x10)
    if [ -n "$VAL_HEX" ]; then
        pub_register "dropped_frames" "$VAL_HEX"
        VAL_DEC=$(hex_to_dec "$VAL_HEX")
        DELTA=$(compute_delta_32 "$PREV_DROPPED_FRAMES" "$VAL_DEC")
        pub_derived "dropped_frames/value" "$VAL_DEC"
        pub_derived "dropped_frames/delta" "$DELTA"
        PREV_DROPPED_FRAMES=$VAL_DEC
    fi

    # ---- OUTPUT_SHIFT (0x014) — RW, valid 0..24, default 16
    VAL_HEX=$(read_reg_hex 0x14)
    if [ -n "$VAL_HEX" ]; then
        pub_register "output_shift" "$VAL_HEX"
        pub_derived "tuning/output_shift" "$(hex_to_dec "$VAL_HEX")"
    fi

    # ---- POWER_ALPHA1 (0x018) — RW, fast EMA coefficient
    VAL_HEX=$(read_reg_hex 0x18)
    if [ -n "$VAL_HEX" ]; then
        pub_register "power_alpha1" "$VAL_HEX"
        pub_derived "tuning/power_alpha1" "$(hex_to_dec "$VAL_HEX")"
    fi

    # ---- POWER_ALPHA2 (0x01C) — RW, slow EMA coefficient
    VAL_HEX=$(read_reg_hex 0x1c)
    if [ -n "$VAL_HEX" ]; then
        pub_register "power_alpha2" "$VAL_HEX"
        pub_derived "tuning/power_alpha2" "$(hex_to_dec "$VAL_HEX")"
    fi
}

# =====================================================================
# Per-channel power publishing
# =====================================================================
#
# Two layers, both published every cycle:
#   1. Raw per-channel hex at register/channel_power_N — forensics, "free"
#      since we're calling devmem anyway
#   2. Single JSON array at derived/power_spectrum — payload [v0..v63]
#      for the 64-bar dashboard widget. One MQTT message instead of 64.
#
# JSON build accumulates decimal values comma-separated; if any read
# fails the slot is filled with 0 to keep array length stable at 64.

publish_channel_powers() {
    JSON_BODY=""
    N=0
    while [ $N -lt $N_CHANNELS ]; do
        OFFSET=$((CHANNEL_BASE_OFFSET + N * 4))
        VAL_HEX=$(read_reg_hex $OFFSET)
        if [ -n "$VAL_HEX" ]; then
            VAL_DEC=$(hex_to_dec "$VAL_HEX")
            pub_register "channel_power_$N" "$VAL_HEX"
        else
            VAL_DEC=0
        fi
        if [ -z "$JSON_BODY" ]; then
            JSON_BODY="$VAL_DEC"
        else
            JSON_BODY="${JSON_BODY},${VAL_DEC}"
        fi
        N=$((N + 1))
    done
    pub_derived "power_spectrum" "[${JSON_BODY}]"
}

# =====================================================================
# Demod / frame-sync publishing  (register block at DEMOD_BASE)
# =====================================================================
#
# Same shape as the channelizer scalars, but against the demod regs.
# DEMOD_STATUS bit layout (haifuraiya_demod_regs.vhd):
#   bit 0 frame_sync_locked, bit 1 cst_lock_f1, bit 2 cst_lock_f2.
# FRAMES_RECEIVED is a monotonic 32-bit counter (frames decoded since reset);
# its per-cycle delta is the live "are we locking?" signal.
#
# Non-fatal: if the demod block isn't present (reads empty) the whole
# section quietly skips, so the channelizer dashboard still works.

publish_demod() {
    # ---- DEMOD_VERSION (0x000) -- map v6 gate; publish signature like the
    # channelizer's. Non-fatal on mismatch (dashboard shows WRONG).
    VAL_HEX=$(read_demod_hex 0x00)
    if [ -n "$VAL_HEX" ]; then
        pub_register "demod_version" "$VAL_HEX"
        if [ "$VAL_HEX" = "$DEMOD_EXPECTED_VERSION" ]; then
            pub_derived "demod/signature" "OK"
        else
            pub_derived "demod/signature" "WRONG"
        fi
    fi

    # ---- DEMOD_STATUS (0x040) -- v6 bit dictionary (REGISTER_MAP_V6.md):
    #   bit 0 fs_locked, bit 1 sym_locked (real detector), bit 2 reserved
    #   (cfo_locked, WP2), bit 3 in_init.
    VAL_HEX=$(read_demod_hex 0x40)
    if [ -n "$VAL_HEX" ]; then
        pub_register "demod_status" "$VAL_HEX"
        VAL_DEC=$(hex_to_dec "$VAL_HEX")
        pub_derived "demod/frame_sync_locked" "$((VAL_DEC & 1))"
        pub_derived "demod/sym_locked"        "$(((VAL_DEC >> 1) & 1))"
        pub_derived "demod/in_init"           "$(((VAL_DEC >> 3) & 1))"
    fi

    # ---- FRAMES_RECEIVED (0x044) -- monotonic 32-bit
    VAL_HEX=$(read_demod_hex 0x44)
    if [ -n "$VAL_HEX" ]; then
        pub_register "demod_frames" "$VAL_HEX"
        VAL_DEC=$(hex_to_dec "$VAL_HEX")
        DELTA=$(compute_delta_32 "$PREV_FRAMES_RX" "$VAL_DEC")
        pub_derived "demod/frames_received" "$VAL_DEC"
        pub_derived "demod/frames_delta"    "$DELTA"
        PREV_FRAMES_RX=$VAL_DEC
    fi

    # ---- DEMOD_CONTROL (0x004) -- bit 0 rx_invert
    VAL_HEX=$(read_demod_hex 0x04)
    if [ -n "$VAL_HEX" ]; then
        pub_register "demod_control" "$VAL_HEX"
        pub_derived "demod/rx_invert" "$(( $(hex_to_dec "$VAL_HEX") & 1 ))"
    fi

    # ---- SYM_LOCK_STATUS (0x0A0) -- the symbol lock detector's live view:
    #   bit 0 locked, bit 1 window_full, [15:8] ratio_pct = live
    #   100*S|L-E|/S(L+E). Locked signal sits well under SYM_LOCK_THRESH;
    #   dead air near 100. THE quality gauge (sym_lock_detector.vhd).
    VAL_HEX=$(read_demod_hex 0xA0)
    if [ -n "$VAL_HEX" ]; then
        pub_register "demod_sym_lock_status" "$VAL_HEX"
        VAL_DEC=$(hex_to_dec "$VAL_HEX")
        pub_derived "demod/sym_lock/ratio_pct"   "$(((VAL_DEC >> 8) & 0xFF))"
        pub_derived "demod/sym_lock/window_full" "$(((VAL_DEC >> 1) & 1))"
    fi

    # ---- SYM_CLK_OFFSET (0x0CC) -- timing-loop integrator: estimated
    # symbol-clock rate error, SIGNED Q24 fractional samples/symbol.
    # ppm_milli = q24 * 1000000 / 193478  (2^24 * 11.5314 samples/sym).
    VAL_HEX=$(read_demod_hex 0xCC)
    if [ -n "$VAL_HEX" ]; then
        pub_register "demod_sym_clk_offset" "$VAL_HEX"
        SVAL=$(hex_to_sdec "$VAL_HEX")
        pub_derived "demod/sym_clk_offset/q24"       "$SVAL"
        pub_derived "demod/sym_clk_offset/ppm_milli" "$((SVAL * 1000000 / 193478))"
    fi

    # ---- Tuning readbacks (RW registers, decimal under derived/tuning)
    VAL_HEX=$(read_demod_hex 0xA4)
    [ -n "$VAL_HEX" ] && pub_derived "demod/tuning/sym_lock_pct"   "$(hex_to_dec "$VAL_HEX")"
    VAL_HEX=$(read_demod_hex 0xA8)
    [ -n "$VAL_HEX" ] && pub_derived "demod/tuning/sym_unlock_pct" "$(hex_to_dec "$VAL_HEX")"
    VAL_HEX=$(read_demod_hex 0xAC)
    [ -n "$VAL_HEX" ] && pub_derived "demod/tuning/sym_window_log2" "$(hex_to_dec "$VAL_HEX")"
    VAL_HEX=$(read_demod_hex 0xC4)
    [ -n "$VAL_HEX" ] && pub_derived "demod/tuning/tim_alpha_q16"  "$(hex_to_dec "$VAL_HEX")"
    VAL_HEX=$(read_demod_hex 0xC8)
    [ -n "$VAL_HEX" ] && pub_derived "demod/tuning/tim_beta_q24"   "$(hex_to_dec "$VAL_HEX")"

    # ---- Full raw demod snapshot for the forensics pane -- LIVE v6
    # registers ONLY. The retired Costas block (0x008-0x03C, 0x060-0x09C)
    # is reserved/read-zero per REGISTER_MAP_V6.md and is deliberately
    # NOT published: no more relic display (v5 lesson).
    for pair in fs_hunt_thresh:0x48 fs_verify_thresh:0x4c \
                quant_thr_1:0x50 quant_thr_2:0x54 quant_thr_3:0x58 \
                demod_init:0x5c \
                sym_lock_thresh:0xa4 sym_unlock_thresh:0xa8 \
                sym_lock_window:0xac tim_alpha:0xc4 tim_beta:0xc8; do
        NAME=${pair%%:*}
        OFF=${pair##*:}
        VAL_HEX=$(read_demod_hex $OFF)
        [ -n "$VAL_HEX" ] && pub_register "demod_$NAME" "$VAL_HEX"
    done
}

# =====================================================================
# Startup
# =====================================================================

# Sanity check: is the channelizer alive at the expected address?
# This is the same shape as Pluto's hash_lo==0xAAAA5555 check.
MAGIC=$(read_reg_hex 0x00)
if [ "$MAGIC" != "$EXPECTED_VERSION" ]; then
    echo "ERROR: VERSION at $ADDR_BASE = $MAGIC, expected $EXPECTED_VERSION" >&2
    echo "       Channelizer not present at this address?" >&2
    echo "       Wrong bitstream loaded?" >&2
    echo "       Refusing to start." >&2
    exit 1
fi

# Publish startup metadata so subscribers know we restarted.
mosquitto_pub -t "haifuraiya/status/publisher/started" -m "$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
mosquitto_pub -t "haifuraiya/status/publisher/pid"     -m "$$"
mosquitto_pub -t "haifuraiya/status/publisher/version" -m "$PUB_VERSION"

# =====================================================================
# Main loop
# =====================================================================

while :; do
    TS=$(date -u +'%Y-%m-%dT%H:%M:%SZ')

    publish_scalars
    publish_channel_powers
    publish_demod

    mosquitto_pub -t "haifuraiya/status/heartbeat" -m "$TS"

    sleep $INTERVAL
done
