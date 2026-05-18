# Yocto build configuration templates

These files document the configuration that produced a working vanilla
ZCU102 image at M1 (2026-05-18). They are **templates** — not the actual
files used during a build. Yocto's actual `local.conf` and `bblayers.conf`
live in your build tree at `~/yocto/haifuraiya/build/conf/`, outside this
repo.

## Using these templates

After `repo init` + `repo sync` and `source sources/yocto-scripts/setupsdk`:

```bash
cd ~/yocto/haifuraiya/build

# AMD's setupsdk generates initial conf/ files; back them up first
mv conf/local.conf conf/local.conf.amd-default
mv conf/bblayers.conf conf/bblayers.conf.amd-default

# Then copy our templates
cp ~/brown/Mode-Dynamic-Transponder/haifuraiya/yocto/conf/local.conf.template conf/local.conf
cp ~/brown/Mode-Dynamic-Transponder/haifuraiya/yocto/conf/bblayers.conf.template conf/bblayers.conf

# Build
bitbake petalinux-image-minimal
```

Adjust `BB_NUMBER_THREADS` / `PARALLEL_MAKE` in local.conf for your host.

## Why these aren't the live config

The live `local.conf` and `bblayers.conf` have per-developer details
(absolute paths, parallelism tuned to host, sometimes credentials for
internal mirrors) that don't belong in source control. The templates
capture the project-wide decisions that everyone needs; the live files
capture per-machine reality.

## When to update these templates

- Adding a layer to bblayers (e.g., meta-ori, meta-adi-xilinx in M2)
- Adding a new local.conf setting that everyone should have
- Removing a workaround that's no longer needed (e.g., when upstream
  finally fixes a SHA-drift bug, we can stop blacklisting htop)

The plan-of-attack at `../yocto_plan_of_attack.md` is the canonical
narrative; these templates are the canonical machine-readable
configuration.
