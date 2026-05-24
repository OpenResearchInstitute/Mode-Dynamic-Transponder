# `docs/` — Polyphase Channelizer Notebook

This directory holds the Python notebook that designs the Haifuraiya
channelizer's prototype filter and exports the coefficient tables that
the VHDL implementation consumes. It also contains the system engineering 
for the mdt-sic AMSAT-UK version of the channelizer. mdt-sic is a 
spectrum analyzer with overlapping channels, and not a communications 
channelizer, where the channels have gaurd bands. Both designs are 
documented in this Python notebook.

The notebook is `polyphase_channelizer.ipynb`. Most contributors never need
to run it — the artifacts it produces are committed to the repository and
the Vivado/PetaLinux build flow uses those committed artifacts directly.
You only need to run the notebook if you want to change the filter design.

---

# Spotting Guide
_What are these documents and models about anyway?_

The `polyphase_channelizer.ipynb` is the one you want to use for the FPGA design for successive interference cancellation. 

The `mdt-model.ipynb` file records the thought process of the original "fast uplink, slow downlink" interpretation of MDT, where known amateur radio modes would be received, stored, and forwarded.

The `mdt-sic-wire-protocol.md` file explains the format of the report used to document successive interference cancellation attempts. 

The `funcube-mission-concept.md` file explains the mission concept with respect to the FunCube+ Satellite from AMSAT-UK. 

---

## What the notebook produces

Running the notebook end-to-end when configured for haifuraiya emits two 
coefficient files derived from the same numerical design:

| File | Path (from repo root) | Consumer |
|---|---|---|
| `haifuraiya_coeffs.hex` | `haifuraiya/rtl/coeffs/` | Simulation testbenches (`tb_haifuraiya_channelizer_*`, `tb_polyphase_M_timing`) via VHDL `file_open` |
| `haifuraiya_coeffs_pkg.vhd` | `haifuraiya/rtl/channelizer/` | Synthesis — compiled-in VHDL package consumed by `fir_branch_parallel.vhd` via `use work.haifuraiya_coeffs_pkg.all` |

Both files describe the same 1,536 coefficients (64 branches × 24 taps per
branch, Q1.14 signed 16-bit, branch-major layout).

### Why two artifacts for the same data?

In simulation, xsim copies ancillary files (including the `.hex`) into the
sim working directory, so `file_open` succeeds. In Vivado synthesis, however,
each IP block is synthesized in its own run directory rather than the IP
source directory, and `file_open` with a bare path resolves against the
synth-tool working directory — not where the `.hex` actually lives.
Sub-IP synth therefore cannot find the file, and synthesis fails.

The workaround is to also emit the coefficients as a compiled-in VHDL
package (`haifuraiya_coeffs_pkg.vhd`) that gets analyzed alongside the
RTL. The package declares a `constant ALL_COEFFS : coeff_rom_t` that the
FIR branch slices at elaboration time. No file I/O at synth, problem
solved. The `.hex` is kept for the testbenches because they exercise the
file-reading path anyway and the data stays in sync between both files
because they come from the same notebook run.

---

## Setting up the notebook environment

The notebook uses `numpy`, `scipy`, `matplotlib`, `seaborn`, and
`pm-remez` (Daniel Estévez's modern Parks–McClellan implementation —
much more reliable than scipy's legacy `signal.remez` for filter design).

These libraries have version interdependencies that frequently conflict
with what an OS-level Python install carries. The reproducible answer is
to use an isolated virtual environment for the notebook. Do not use
`pip install --user` for these packages — that path leaves you mixing
system scipy (often pinned to numpy < 1.25) with a user-site numpy that
may be 2.x, and you'll spend an evening debugging ABI errors.

### Prerequisites

Ubuntu does not ship the Python `venv` module in the default `python3`
package. Install it once per build host:

```bash
sudo apt install python3-venv
```

You will also need `screen` (for serial console access to the ZCU102),
`openssh-client` (for ssh into the board after first boot), and
`git` (for cloning and submodules). Most build hosts already have these.

### Create and populate the venv

From the repository root:

```bash
cd ~/path/to/Mode-Dynamic-Transponder

python3 -m venv .venv-channelizer
source .venv-channelizer/bin/activate

# Verify activation — all four of these MUST show the venv path
echo "VIRTUAL_ENV: $VIRTUAL_ENV"
which python
which pip
# Your shell prompt should now start with (.venv-channelizer)

pip install --upgrade pip
pip install numpy scipy matplotlib seaborn jupyterlab pm-remez ipykernel
```

If `pip install` reports `Defaulting to user installation because normal
site-packages is not writeable`, **the venv is not active**. Stop and
re-source `.venv-channelizer/bin/activate`. The venv-active state is
non-negotiable for everything that follows.

### Register the kernel with JupyterLab

Still inside the activated venv:

```bash
python -m ipykernel install --user --name=channelizer \
    --display-name="Channelizer (venv)"
```

This creates `~/.local/share/jupyter/kernels/channelizer/kernel.json`.
The critical field is `argv[0]`, which must point to the venv's Python
interpreter (not `/usr/bin/python3`). Verify:

```bash
cat ~/.local/share/jupyter/kernels/channelizer/kernel.json
# argv[0] should be:
# /home/<you>/.../Mode-Dynamic-Transponder/.venv-channelizer/bin/python
```

If you re-create the venv (for example after a clean rebuild), re-register
the kernel from inside the new venv. The kernelspec is just a JSON file
holding a hard-coded path to the Python interpreter — recreate the venv
and the kernelspec points at a dead file.

### .gitignore note

The `.venv-channelizer/` directory should not be committed. It is already
listed in the repository's top-level `.gitignore`; if you choose a
different venv path, add it to `.gitignore` before staging anything.

---

## Running the notebook

Launch JupyterLab from inside the activated venv:

```bash
source .venv-channelizer/bin/activate
jupyter lab
```

Open `docs/polyphase_channelizer.ipynb` in the browser tab JupyterLab
opens. Then:

1. **Kernel → Change Kernel → Channelizer (venv)**.
2. As a sanity check, paste this into a fresh first cell and run it:
   ```python
   import sys
   print(sys.executable)
   ```
   The output must show your `.venv-channelizer/bin/python`. If it shows
   `/usr/bin/python3`, the kernel selection did not take effect — the
   kernelspec is probably stale (see the verify step above).
3. Run all cells in order (Kernel → Restart Kernel and Run All Cells).

The export cells at the end will write the two coefficient files to
their final repository paths (no manual copy step is needed; the notebook
writes directly to `haifuraiya/rtl/coeffs/` and `haifuraiya/rtl/channelizer/`).

---

## Verifying the output

After running the notebook, confirm the artifacts landed and their
contents agree:

```bash
cd ~/path/to/Mode-Dynamic-Transponder

# Both files exist at expected paths
ls -la haifuraiya/rtl/coeffs/haifuraiya_coeffs.hex \
       haifuraiya/rtl/channelizer/haifuraiya_coeffs_pkg.vhd

# Coefficient counts agree (1536 = 64 branches × 24 taps)
wc -l haifuraiya/rtl/coeffs/haifuraiya_coeffs.hex
# Expect: 1536

grep -c '^[[:space:]]*x"' haifuraiya/rtl/channelizer/haifuraiya_coeffs_pkg.vhd
# Expect: 192    (1536 / 8 values per line)

# First .hex value should match first package literal (branch-major order intact)
head -1 haifuraiya/rtl/coeffs/haifuraiya_coeffs.hex
# Compare to:
grep '^[[:space:]]*x"' haifuraiya/rtl/channelizer/haifuraiya_coeffs_pkg.vhd | head -1
```

The package header should also include an auto-generation marker, the
configuration metadata (channels, taps, total coefficients), and a brief
note explaining why the package exists alongside the `.hex`.

---

## When to re-run the notebook

The committed artifacts are the authoritative coefficients for the
current channelizer. You only need to re-run the notebook if you change
the filter design. Reasons to do that include:

- Adjusting the prototype filter's stopband attenuation, passband ripple,
  or transition bandwidth.
- Switching to a different number of channels or taps per branch (these
  are VHDL generics that must be updated in lockstep — the
  `haifuraiya_coeffs_pkg.vhd` package hard-codes `N_TOTAL_TAPS`).
- Replacing `pm-remez` with an alternative design method.

If you change parameters affecting the entity's generics (`N_CHANNELS`,
`TAPS_PER_BRANCH`), you must also update the IP packaging — see the
"After re-running" section below.

If you only change the filter's frequency response (without changing
channel count or tap count), the entity interface is unchanged and the
new coefficients flow through automatically on the next Vivado build.

---

## After re-running the notebook

The notebook only updates the coefficient files. If you also changed
parameters that affect the IP entity's interface (channel count, tap
count, data width, etc.), the IP packaging in `haifuraiya/component.xml`
must also be regenerated:

```bash
cd ~/path/to/Mode-Dynamic-Transponder
vivado -mode batch -source haifuraiya/scripts/repackage_no_coeff_file.tcl
```

This script updates `component.xml` and the XGUI script in the
`haifuraiya/xgui/` directory. Review the diff before committing:

```bash
git diff haifuraiya/component.xml haifuraiya/xgui/
```

Then rebuild the integrated XSA per the haifuraiya `README` (the build
that produces `system_top.xsa` for PetaLinux).

---

## File ownership and provenance

`haifuraiya_coeffs.hex` and `haifuraiya_coeffs_pkg.vhd` are auto-generated
by the notebook. The first lines of the package file are an explicit
"do not edit by hand" notice. Treat both files as build artifacts that
happen to be checked in for reproducibility — if you find yourself
wanting to edit them by hand, you almost certainly want to edit the
notebook's filter-design cells instead and re-export.

---

## See also

- `haifuraiya/README.md` — Vivado/PetaLinux build flow for the
  channelizer (configure / build / boot).
- `haifuraiya/syn/zcu102/README.md` — block-design
  modifications layered on top of the ADI ADRV9002 reference.
- `mdt_sic/README.md` — the separate iCE40+STM32 SIC receiver project
  (different toolchain, different board).
- `Makefile` (top level) — `make help` for the cross-cutting targets.
