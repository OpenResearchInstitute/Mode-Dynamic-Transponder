# VCK-190 User Guide
_Open Research Institute digital signal processing work_

## High-Level Overview

### What is Versal?

The Versal AI Core Series chip is a system on chip (SOC) FPGA. 
It has programmable logic, scalar processors and dedicated AI and 
DSP engines. The embedded ARMs are a dual-core Cortex A72 processor 
and a dual-core Cortex R5 real-time processor. It has 8GB DDR4 and 
8GB LPDDR4. It's used for 5G radio and beamforming, which puts it 
squarely in the category of device ORI needs in order to do
open source microwave band digital multiplexing communications 
satellite (Haifuraiya) implementations. 

Versal AI Core Series chip: XCVC1902-2MSEVSVA2197

### How is Versal Organized?

Versal designs require a CIPS (Control, Interfaces and Processing 
System) block. This is the successor to the Zynq MPSoC processing-system 
IP. CIPS is used even for mostly-PL designs, like ours, because boot and 
configuration flow through CIPS.

DDR and PS to PL traffic route through the NoC (Network on Chip) via AXI 
NoC IP. We do not have direct AXI ports on the Versal, like we do with
the 7000/Ultrascale type FPGAs we've been using. Our AXI-Lite control 
plane and things like memory buffers that we capture get re-done for
Versal. 

Transceivers are instantiated through the GT Quad IP. The ESIstream 
package’s block design, from Teledyne, is going to handle this for us.

Clocking, I/O banks (1.5 V XPIO), and constraints are all new, of course.

The input side changes. No LVDS/radio-chip front end here. Eventually 
ESIstream RX goes to "reassembler" goes to DDC (digital downconverter).

### What Needed to Change for Versal?

New platforms like Versal live under /platforms/

The zcu102 stays in its sim/ syn/ petalinux/ and yocto/ directories, and
the build system (makefile) for Haifuraiya stays the same. No changes to
any of that. 

## How to Simulate on the VCK190

We have a tcl script runner that calls up a VHDL test bench. 

`run_mdt_vck190_sim.tcl`

To use it, create the stimulus file first. 

`python3 opv_stim.py --preamble --clock-offset-ppm 11.5 --carrier-offset 500 --ebn0 10 --seed 1 --out opv_chan_stim.txt`

This sets up a 40 ms preamble and then makes six 40 ms frames. There is 
some resampling from the ppm offset, to give our circuits something to do!

With noise and CFO in the stimulus, the soft codes should leave the rails and 
populate the middle values, `cfo_word` and `est_hz` in the CFO group should 
move towards `--carrier-offset`, and `sym_clk_offset` in Symbol_Lock should 
settle near the ppm we injected.
