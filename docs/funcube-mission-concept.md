# Mode Dynamic Transponder (MDT-SIC)

_Mission Concept_

An autonomous spectrum cataloging instrument for the 70 cm amateur satellite subband.

Open Research Institute

May 2026

## 1. Summary

The MDT-SIC payload, proposed for AMSAT-UK’s FunCube+ 2U CubeSat, operates as an autonomous spectrum cataloging instrument for a configurable 30 kHz slice of the 70 cm amateur satellite subband. The payload uses Successive Interference Cancellation (SIC) to suppress strong masking signals, revealing weak emissions that would otherwise be undetectable from a low-Earth-orbit platform. Each detection produces a compact characterization record. This record includes timestamp, frequency, bandwidth, signal-to-noise ratio, modulation classification, and optional decoded payload. The record is stored on board and downlinked as telemetry. The product is an open-data catalog of the amateur satellite subband as observed from orbit. To the best of our knowledge, no comparable on-orbit dataset like this exists.

## 2. Background

The MDT concept originated at AMSAT-UK with the proposed FunCube+ 2U mission. The original framing, presented by David Bowman G0MRF in November 2025, was a digital regenerator: ground stations transmit short BPSK packets, the satellite decodes them on board, and the satellite re-transmits the decoded content using a more bandwidth-efficient mode (such as FT4) on the VHF downlink. The motivation was the well-known effective-isotropic-radiated-power disparity between UHF uplink and VHF downlink on small satellites. Going digital mid-pipeline allows scarce downlink power to be spent more efficiently than relaying noisy SSB.
MDT Project Lead Martin Ling redefined the payload as a weak-signal detector. ORI is now developing this implementation. AMSAT-UK is the platform host.

## 3. Mission objectives

### Primary

Demonstrate multi-mode SIC in space, and produce a downlinkable catalog of detections in a 30 kHz slice of the 70 cm amateur satellite subband, as observed from low Earth orbit.

### Secondary

Contribute open data on amateur satellite subband occupancy, useful for IARU frequency coordination, future mission planning, propagation studies, and characterization of weak-signal experiments conducted by the amateur community.

### Tertiary

Establish an open-source software and gateware foundation for follow-on missions that extend SIC catalog scope, frequency coverage, and detection sensitivity.

## 4. Architecture overview

The signal-processing subsystem consists of a Lattice iCE40 UltraPlus FPGA implementing a four-channel polyphase channelizer over the 30 kHz input passband, paired with an STMicroelectronics STM32H7 microcontroller. The FPGA performs wideband filtering and channel separation; the STM32 performs magnitude computation, peak detection, modulation classification, decoding, signal reconstruction, and the SIC iteration loop. The 0.5 W envelope on the signal-processing subsystem is compatible with 2U CubeSat deployment.

The current build implements the front end. The channelizer, magnitude calculation, and peak detection. End to end hardware operation has been verified. In other words, real channelizer data flows across the FPGA-MCU SPI link. Modulation classification, decoding, and the full SIC iteration are in development.
The gateware and firmware are open-source under CERN-OHL-2.0 and other OSI-approved licenses, consistent with ORI organizational practice and AMSAT-UK community expectations.

## 5. Catalog and SIC scope

SIC operates on signals the receiver can decode and reconstruct. The technique generally requires a discrete signaling alphabet. We restrict cancellation to digital modulations. Analog signals, primarily SSB voice and CW from neighboring linear-transponder users, are treated as colored noise. Detection of weak signals continues despite their presence, with the understanding that detection sensitivity is reduced in the immediate frequency neighborhood of analog transmissions.
The cancellation catalog is initially scoped out in two tiers.

**Tier 1 — full decode-reconstruct-subtract**

- BPSK 1200 baud (UZ7HO-compatible, Greencube digipeater format)
- AX.25 1200 baud AFSK packet
- AX.25 9600 baud GMSK packet

**Tier 2 — sync-word-anchored estimation without full decode**

- BPSK telemetry beacons in the FUNcube and CubeSat telemetry lineage

Detection targets are open. The instrument records every signal exceeding a configurable threshold above the residual noise floor after SIC. Modulation classification is attempted using a sync-word-and-pulse-shape classifier. Unclassified signals are recorded with their measured parameters and a class code of 0x00 (unknown).

## 6. Downlink data product

The instrument produces a stream of detection records. Each record consists of a 16-byte fixed header (timestamp, frequency offset from configurable band center, bandwidth, SNR, modulation class, classifier confidence, status flags) plus an optional decoded payload of up to 255 bytes. Records are wrapped in numbered frames with CRC-16 integrity protection.

Detection records are public-domain telemetry, and the protocol is open. The complete wire format is specified in the companion document MDT-SIC Detection Record Protocol. A ground-side reference decoder will be released with the flight firmware.

## 7. Novelty and significance

Successive interference cancellation is well-established in commercial cellular and satellite systems. In amateur radio, SIC is currently deployed only on the ground, in the WSJT-X FT8 multi-pass decoder, where a single mode is peeled iteratively from a single received audio stream. To the best of our knowledge, the proposed payload would be the first multi-mode SIC implementation in amateur radio, the first space-based SIC payload in amateur radio, and the first orbital catalog of amateur satellite subband occupancy.

The orbital perspective is essential. Ground-based observers cannot see distant low-power emitters in the satellite subband. An orbital instrument can. Combined with the noise-floor reduction that SIC provides, the payload accesses signals that no single ground station can detect. The dataset has direct utility for spectrum coordination, propagation research, and amateur experimentation.

## 8. Phased implementation plan

**Phase 1 — Foundation (current)**

Polyphase channelizer (hardware verified), magnitude computation, peak detection, complex-valued I/Q channelizer.

**Phase 2 — Cancellation core** 

Implement the BPSK 1200 baud (UZ7HO-compatible) decoder and regenerator on the STM32. Demonstrate single-mode SIC end-to-end against realistic test signals including representative interferers.

**Phase 3 — Catalog expansion**

Add AX.25 1200 baud AFSK and AX.25 9600 baud GMSK decoders and regenerators. Implement multi-mode classifier (sync-word correlator bank plus pulse-shape and baud-rate fingerprinting). Add Tier 2 partial-SIC for FUNcube-family BPSK telemetry beacons.

**Phase 4 — Downlink integration**

Detection record formatter, frame wrapper, CRC computation, integration with the FunCube+ telemetry pipeline. Ground-side reference decoder. Public publication channel for detection record data.

**Phase 5 — Flight readiness**

Environmental testing, flight qualification, integration with the FunCube+ bus, launch and on-orbit commissioning support.

## 9. Open questions for AMSAT-UK coordination

The following items would benefit from explicit AMSAT-UK input.
-Confirmation that 30 kHz is the correct slot bandwidth.
-Documented center frequency for the slot, with provision for in-flight reconfiguration via uplinked command.
-Allocation of detection record bandwidth in the FunCube+ telemetry budget.
-Operational policy for detection record publication (real-time, delayed, archive).
-Mission integration schedule and interface control documents.
-ORI is prepared to proceed under this concept absent further specification. This document constitutes ORI’s working specification for the MDT-SIC payload, fully open to revision as AMSAT-UK and the ORI engineering team refine requirements and interfaces. 
