# VCK-190 User Guide
_Open Research Institute digital signal processing work_

## What is Versal?

The Versal AI Core Series chip is a system on chip (SOC) FPGA. 
It has programmable logic, scalar processors and dedicated AI and 
DSP engines. The embedded ARMs are a dual-core Cortex A72 processor 
and a dual-core Cortex R5 real-time processor. It has 8GB DDR4 and 
8GB LPDDR4. It's used for 5G radio and beamforming, which puts it 
squarely in the category of device ORI needs in order to do
open source microwave band digital multiplexing communications 
satellite (Haifuraiya) implementations. 

Versal AI Core Series chip: XCVC1902-2MSEVSVA2197

## How is Versal Organized?

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

## What Needed to Change for Versal?

New platforms like Versal live under /platforms/

The zcu102 stays in its sim/ syn/ petalinux/ and yocto/ directories, and
the build system (makefile) for Haifuraiya stays the same. No changes to
any of that. 


