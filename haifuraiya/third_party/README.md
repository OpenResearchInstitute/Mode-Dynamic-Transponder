# haifuraiya/third_party — External ORI Dependencies

This directory contains git submodules pointing to sibling ORI repositories
used by the Haifuraiya channelizer wrapper. Each one is its own repo,
maintained independently, brought in here as a versioned reference.

## Submodules

| Path | Source | License | Used by |
|------|--------|---------|---------|
| `power_detector/` | https://github.com/OpenResearchInstitute/power_detector | CERN-OHL-W-2 | `haifuraiya_channelizer_axi` — 64 instances, one per channel |
| `lowpass_ema/` | https://github.com/OpenResearchInstitute/lowpass_ema | CERN-OHL-W-2 | (transitive) used internally by `power_detector` |

The `lowpass_ema` repo is a transitive dependency: `power_detector.vhd`
instantiates `entity work.lowpass_ema(rtl)` and expects it to be visible
in the compile library. Both must be in the synthesis source list.

## Cloning

```sh
# Fresh clone with submodules
git clone --recurse-submodules <haifuraiya repo URL>

# Or, if you already cloned without --recurse-submodules:
git submodule update --init --recursive
```

## License compliance

Both submodules are CERN-OHL-W-2 (Weakly Reciprocal). Per §4 of the
license, the **Source Location** of each external component must be
maintained — that's why the URLs are recorded in `.gitmodules` (machine
readable) and in this README (human readable). If you redistribute
hardware built from this source, the Source Location must also be visible
on the external case of the product.

The `power_detector.vhd` source header has a `Source location: TBD`
field that should be updated upstream to point at its own canonical URL.
That's an upstream repo concern, not something we patch downstream.

## Adding more submodules

ORI has been growing a collection of small focused RTL components (one
component per repo). When pulling another one in here, follow the same
pattern:

```sh
git submodule add https://github.com/OpenResearchInstitute/<name>.git \
    haifuraiya/third_party/<name>
```

Then add the new RTL paths to the synthesis source list in
`haifuraiya/syn/zcu102/synth_haifuraiya_channelizer.tcl`.
