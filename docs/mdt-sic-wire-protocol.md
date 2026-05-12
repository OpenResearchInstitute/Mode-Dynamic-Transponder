# MDT-SIC Detection Record Protocol
_Wire format specification, version 0.1 (draft)_

Open Research Institute 

May 2026

For the AMSAT-UK FunCube+ MDT-SIC payload

## 1. Scope

This document specifies the wire format for detection records produced by the Open Research Institute MDT-SIC payload aboard the AMSAT-UK FunCube+ satellite. It defines the per-detection record structure, the frame-level wrapper, the modulation class registry, and a CRC reference implementation. Implementations conforming to this document can correctly encode and decode MDT-SIC detection records. The protocol_minor field allows future revisions. Backward compatibility is intended within the major revision numbers. 

## 2. Conventions

- Multi-byte integer fields are encoded in big-endian byte order (network byte order).
- Timestamps use the Unix epoch: integer seconds since `1970-01-01T00:00:00Z UTC`.
- Sub-second timestamps are encoded as units of 1/65536 second (uint16, range 0–65535). Resolution is approximately 15.26 µs.
- Frequency offsets are signed integers, expressed in hertz, relative to a configurable band center frequency band_center_hz maintained as a reconfigurable spacecraft parameter and reported in periodic configuration telemetry. The detection records in this protocol carry only the offset. Consumers must apply the corresponding band_center_hz to recover absolute frequency.
- Reserved fields must be set to zero by encoders and ignored by decoders.
- CRC-16 uses the CCITT polynomial 0x1021, initial value 0xFFFF, no final XOR, no bit reflection. See section 7.

## 3. Frame Format

A frame is the unit of transmission. Each frame carries one or more detection records and a CRC over the frame contents. Minimum frame size is 26 bytes (8-byte header + 16-byte minimum record + 2-byte CRC). Maximum frame size is implementation-defined and is bounded by the FunCube+ telemetry packet size.

Offset | Size | Field | Description
--- | --- | --- | --- 
0 | 1 | protocol_major | Major protocol version.
1 | 1 | protocol_minor | Minor protocol version. 
2 | 1 | record count | Number of detection records carried in this frame (1 - 255). 
3 | 1 | frame_seq | Frame sequence number. Big endian uint32. Increments per emitted frame. Wraps at 2^32. 
7 | 4 | source_id | Source identifier. 0xFC = FunCube + MDT-SIC. Other values reserved.
8 | var | records | Concatenated detection records. See section 4.
end - 2 | 2 | crc16 | CRC-16-CCITT over all preceding frame bytes. Big endian.

## 4. Detection Record Format

A detection record consists of a fixed 16-byte header followed by an optional decoded payload of 0–255 bytes. Records are concatenated within a frame. No inter-record padding or framing bytes are used.

Offset | Size | Field | Description
--- | --- | --- | ---
0 | 4 | timestamp_sec | Unix epoch seconds, big-endian uint32 (seconds since `1970-01-01T00:00:00Z UTC`).
4 | 2 | timestamp_subsec | Big-endian uint16, units of 1/65536 second (about 15.26 µs resolution).
6 | 3 | freq_offset_hz | Big-endian signed int24, hertz offset from band_center_hz. Range +/- 8,388,607 Hz.
9 | 2 | bandwidth_hz | Big-endian uint16, occupied bandwidth in hertz (0–65,535).
11 | 1 | snr_db | Signed int8, signal-to-noise ratio in 0.5 dB units. Range −64.0 to +63.5 dB.
12 | 1 | modulation_class | Modulation class identifier. See section 5.
13 | 1 | confidence | Classifier confidence, uint8 (0–255). 255 = highest.
14 | 1 | flags | Status bitfield. See note below.
15 | 1 | payload_len | Length of decoded payload in bytes (0–255).
16 | var | payload | Optional decoded payload, present only if payload_len > 0.

Flags bitfield (bit 0 is the least significant bit):
- Bit 0: decode succeeded (1 = decoded, 0 = not decoded).
- Bit 1: SIC subtraction was applied to this signal during detection.
- Bit 2: residual energy remained above floor after SIC subtraction (1 = incomplete cancellation).
- Bit 3: detection occurred in a re-detection pass over the residual (1 = second-pass or later, 0 = first-pass detection).
- Bit 4: classifier matched a Tier 1 mode with full decode-reconstruct-subtract support (1 = Tier 1, 0 = Tier 2 partial-SIC or unclassified).
- Bits 5–7: reserved for catalog growth, must be zero.

## 5. Modulation class registry

The modulation_class field is a uint8 lookup value. Categories are defined by value range, with specific protocol identifiers within each range. The category boundaries align with how the SIC pipeline treats signals. 0x01–0x1F are analog and never subjected to SIC. 0x20–0x7F are SIC-tractable digital modes. 0x80 and above are identify-but-do-not-decode by default.
 
Category numbering may be extended within reserved ranges. Renumbering of existing assignments shall not occur in a v0.x revision.

## 6. Worked example

A frame containing one detection record. The record reports a successfully decoded BPSK 1200 baud (UZ7HO-format) packet, observed 2.5 kHz below band center, with 12.0 dB SNR, classifier confidence 230/255, decoded and SIC-subtracted (Tier 1, first-pass detection). Decoded payload is the 30-byte ASCII string `“DE W5NYV ORI MDT TEST PACKET 1”.`

```
Encoded frame, 56 bytes, hexadecimal:
01 00 01 00 00 00 2A FC 67 74 85 80 80 00 FF F6
3C 07 D0 18 42 E6 13 1E 44 45 20 57 35 4E 59 56
20 4F 52 49 20 4D 44 54 20 54 45 53 54 20 50 41
43 4B 45 54 20 31 50 09
 
Annotated decode:
Frame header (8 bytes):
  01           protocol_major   = 0
  00           protocol_minor   = 1
  01           record_count     = 1
  00 00 00 2A  frame_seq        = 42
  FC           source_id        = FunCube+ MDT-SIC

Detection record header (16 bytes):
  67 74 85 80  timestamp_sec    = 1735689600 (2025-01-01T00:00:00Z)
  80 00        timestamp_subsec = 32768  (= 0.500000 s)
  FF F6 3C     freq_offset_hz   = -2500   (2.5 kHz below band_center_hz)
  07 D0        bandwidth_hz     = 2000
  18           snr_db           = 24      (= +12.0 dB)
  42           modulation_class = BPSK 1200 UZ7HO (Greencube-compatible)
  E6           confidence       = 230
  13           flags            = 0001 0011
                                  bit 0: decoded
                                  bit 1: SIC subtracted
                                  bit 4: Tier 1 mode
  1E           payload_len      = 30

Detection record payload (30 bytes, ASCII):
  44 45 20 57 35 4E 59 56 20 4F 52 49 20 4D 44 54
  20 54 45 53 54 20 50 41 43 4B 45 54 20 31
  ASCII: "DE W5NYV ORI MDT TEST PACKET 1"

Frame trailer (2 bytes):
  50 09        crc16            = 0x5009  (verified, big-endian)
```

## 7. CRC-16 reference implementation

The CRC algorithm is CRC-16-CCITT (polynomial 0x1021, initial value 0xFFFF, no final XOR, no bit reflection). The CRC is computed over all frame bytes preceding the CRC field itself, and the result is appended to the frame in big-endian byte order. The reference implementation in C below is suitable for the STM32 firmware and for ground-side decoders.

```
#include <stdint.h>
#include <stddef.h>

uint16_t mdt_crc16(const uint8_t *data, size_t len) {
    uint16_t crc = 0xFFFF;
    for (size_t i = 0; i < len; i++) {
        crc ^= ((uint16_t)data[i]) << 8;
        for (int j = 0; j < 8; j++) {
            crc = (crc & 0x8000) ? ((crc << 1) ^ 0x1021) : (crc << 1);
        }
    }
    return crc;
}
```
 
A self-test vector: applying mdt_crc16 to the 54-byte body of the section 6 worked example (frame header + record header + payload) returns 0x5009.
