# Mode-Dynamic-Transponder

A polyphase channelizer implementation in VHDL for the AMSAT-UK FunCube+
Mode-Dynamic-Transponder (MDT), designed for spectrum monitoring and
successive interference cancellation (SIC) signal processing — and for
the parallel ground-station channelizer that complements it.

## Overview

This repository contains two independent polyphase channelizer
implementations, both targeting amateur radio satellite signal
processing. They share design heritage (same Python reference model,
same filter design approach) but have separate hardware targets,
toolchains, and build flows.

| Subproject | Channels | Sample rate | Hardware target | Application |
|---|---|---|---|---|
| **MDT-SIC** | 4 | 40 ksps | iCE40UP5K + STM32H753ZI | FunCube+ satellite payload (spectrum monitoring + SIC) |
| **Haifuraiya** | 64 | 10 Msps | ZCU102 + ADRV9002 | Opulent Voice FDMA ground station |

## Getting started

Pick the subproject that matches your target:

- For the iCE40 + STM32 satellite payload, see [`mdt_sic/README.md`](mdt_sic/README.md)
- For the ZCU102 + ADRV9002 ground-station channelizer, see [`haifuraiya/README.md`](haifuraiya/README.md)
- To regenerate filter coefficients, see [`docs/README.md`](docs/README.md)

For cross-cutting build targets that span both subprojects:

```bash
make help
```

## What is a polyphase channelizer?

A polyphase channelizer efficiently splits a wideband signal into N
frequency channels using two stages:

1. **Polyphase filterbank** — N parallel FIR filters, each processing
   every Nth sample
2. **FFT** — converts the filtered outputs to the frequency domain

This is computationally efficient compared to running N separate
bandpass filters, and is widely used in software-defined radio,
satellite communications, and spectrum analyzers.

```
                    ┌─────────────────────────────────────────────┐
                    │         Polyphase Channelizer               │
                    │                                             │
 Wideband   ───────►│  ┌─────────────┐      ┌─────┐               │
 Input              │  │ Polyphase   │      │     │  Channel 0 ──►│
                    │  │ Filterbank  │─────►│ FFT │  Channel 1 ──►│
                    │  │ (N branches)│      │     │  Channel 2 ──►│
                    │  └─────────────┘      └─────┘     ...    ──►│
                    │                                             │
                    └─────────────────────────────────────────────┘
```

The same conceptual structure is implemented at two scales: a 4-channel
serial-MAC variant for the cubesat payload (resource-constrained
iCE40UP5K) and a 64-channel parallel-MAC variant for the ground station
(resource-rich Zynq UltraScale+). The shared Python reference
implementation in [`docs/polyphase_channelizer.ipynb`](docs/polyphase_channelizer.ipynb)
exports the filter coefficients for both designs.

## Repository layout

```
Mode-Dynamic-Transponder/
├── README.md          this file
├── LICENSE
├── Makefile           cross-cutting build targets (see `make help`)
├── docs/              shared documentation: notebook, wire protocol, mission concept
├── mdt_sic/           iCE40UP5K + STM32H753ZI SIC receiver subproject
│                      See mdt_sic/README.md
└── haifuraiya/        ZCU102 + ADRV9002 64-channel channelizer subproject
                       See haifuraiya/README.md
```

## Related projects

- [Martin Ling's dynamic-transponder](https://github.com/martinling/dynamic-transponder) — hardware reference design
- [Opulent Voice protocol](https://github.com/OpenResearchInstitute/pluto_msk) — digital voice protocol that drives the Haifuraiya subproject's 64-channel design
- AMSAT-UK FunCube+ — the satellite mission the MDT-SIC subproject targets

## Contributing

This is an Open Research Institute project. Contributions are welcome.

1. Fork the repository
2. Create a feature branch
3. Submit a pull request
4. Have fun

For questions or discussion, join the
[ORI community channels](https://openresearch.institute/getting-started).

## License

Open source, using CERN OHL 2.0 and other OSI-approved licenses.
See LICENSE for details.

## Acknowledgments

- Open Research Institute engineering team
- AMSAT-UK community for FunCube documentation, participation, and leadership
- David Bowman G0MRF for the MDT concept
- Martin Ling for the hardware design reference
- Daniel Estévez EA4GPZ for the pm-remez library
- F5OEO for filter design feedback

---

*Open Research Institute — Advancing open source digital radio for space and terrestrial use*
