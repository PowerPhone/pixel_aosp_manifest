# Frankel read-only PDM Device Tree probe

`frankel_pdm_dt_probe.ko` is a deliberately non-invasive inventory module for
the Pixel 10 (`frankel`) GKI. It reports Device Tree nodes whose name or
`compatible` string contains `pdm`, `dmic`, or `aoc`, and translates their
declared `reg` properties to resource ranges. Optional `include_audio=1` also
reports generic audio nodes.

The module does **not** call `ioremap`, `readl`, `writel`, `of_iomap`, DMA,
clock, IRQ, or FIFO APIs. `of_address_to_resource()` only translates Device
Tree metadata; it does not access the resource. The module does not contain
Frankel MMIO addresses.

## Exact target

This directory is built against Android CI build `15739706`, target
`kernel_aarch64`:

- kernel release:
  `6.6.118-android15-8-g1831c2a45d9b-ab15739706-4k`;
- common source commit:
  `1831c2a45d9bfe94d277d9ec67b9dc2a903f2d76`;
- compiler: Android clang `r510928` (18.0.0);
- Kleaf commit: `f71dbd37ecb1a45fadbcce80d1beeb5fb1833166`;
- exact CI `Module.symvers`, DDK header archive, generated config,
  `modules_prepare`, and kernel release from the CI filegroup archive.

The official `init_ddk.zip` workflow is used because
`kernel_aarch64_ddk_headers_archive.tar.gz` contains DDK source headers, not a
standalone Kbuild output tree. The matching common source under
`work/upstream/kernel-common-frankel` is retained for source audit; the DDK
archive's representative headers match that commit byte-for-byte.

## Host requirements

Ubuntu packages used by bootstrap/build/audit:

```sh
sudo apt-get install curl git repo python3 unzip tar binutils kmod ripgrep
```

The CI scaffold downloads its own Bazel, r510928 compiler, NDK, and hermetic
build tools. Bootstrap downloads several gigabytes of pinned CI artifacts and
projects into the mounted workspace.

## Bootstrap and build

From `pixel_aosp_manifest`:

```sh
tools/audio/kernel/frankel_pdm_dt_probe/bootstrap-frankel-ddk.sh
tools/audio/kernel/frankel_pdm_dt_probe/build-frankel-gki.sh
```

The stable outputs are:

```text
work/upstream/frankel-gki-15739706/modules/frankel_pdm_dt_probe.ko
work/upstream/frankel-gki-15739706/modules/frankel_pdm_dt_probe.unstripped.ko
```

The direct build command inside an initialized scaffold is:

```sh
cd work/upstream/frankel-gki-15739706/ddk-workspace
tools/bazel build //probes/frankel_pdm_dt_probe:frankel_pdm_dt_probe
```

`build-frankel-gki.sh` copies the source into the isolated DDK workspace,
builds it, verifies the exact vermagic and every imported symbol CRC against
the CI `Module.symvers`, and rejects MMIO/FIFO/DMA/IRQ/clock-access imports.

## Loading on a matching userdebug kernel

First verify the running release exactly matches the module:

```sh
adb shell uname -r
modinfo -F vermagic \
  work/upstream/frankel-gki-15739706/modules/frankel_pdm_dt_probe.ko
```

On a userdebug build that permits unsigned development modules:

```sh
adb root
adb push work/upstream/frankel-gki-15739706/modules/frankel_pdm_dt_probe.ko \
  /data/local/tmp/
adb shell insmod /data/local/tmp/frankel_pdm_dt_probe.ko
adb shell 'dmesg | grep frankel_pdm_dt_probe'
adb shell rmmod frankel_pdm_dt_probe
```

To include generic audio nodes while keeping the probe read-only:

```sh
adb shell insmod /data/local/tmp/frankel_pdm_dt_probe.ko include_audio=1
```

The CI external-module defconfig intentionally leaves the artifact unsigned.
Do not weaken signature, SELinux, or module-loading policy on a production
device merely to load this probe; use the existing userdebug development
policy or package/sign it through the device kernel workflow.
