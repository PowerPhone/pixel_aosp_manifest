# Frankel CS35L43 192 kHz high-rate core

This directory preserves the source-provenance experiment for Pixel 10
Frankel's `snd-soc-cs35l43.ko`. **Do not package its source-built module.** A
hardware boot test stalled before Android USB appeared because Google's exact
`g852c20a29246` source/toolchain ABI is unavailable. The production research
selection instead patches one instruction in Google's exact, booted stock
module with `tools/audio/patch_frankel_cs35l43_global_fs96.py`.

The stock driver hard-codes a 48 kHz base whenever `Ultrasonic Mode` is either
`In Band` or `Out of Band`. Those two enum values have identical register
semantics. A 48 kHz base plus the FS-times-two amplifier path is only 96
ksample/s, so accepting a 192 kHz ALSA stream cannot by itself preserve
content above 48 kHz.

## Source and ABI provenance

- Public source: Cirrus Logic `linux-drivers`, branch
  `google/v6.6-cs35l43`, revision
  `52c12e1e7c342edccfe4fc76908870e9a0a0fff3`.
- Functional patch:
  `patches/cirrus-cs35l43/0001-frankel-192k-use-96k-ultrasonic-base.patch`.
- Build ABI: Android CI `kernel_aarch64` build `15739706`, kernel release
  `6.6.118-android15-8-g1831c2a45d9b-ab15739706-4k`.
- Stock Frankel input:
  `work/aosp/vendor/google_devices/frankel/stock-kernel/snd-soc-cs35l43.ko`,
  SHA-256 `8db0c2795f11585cb3d30382169606130e5f8aa9b6c001b6508b758b29ca99d3`,
  embedded SCM version `g852c20a29246`.

Google's exact `g852c20a29246` source revision is not public. The pinned
Cirrus Google branch contains the same ultrasonic function and rate table as
the stock module's symbol-level/disassembly evidence. Its differences from
the public non-Google `v6.6-cs35l43` head are unrelated delta-tuning locking
and boost errata. The small `frankel-core-exports.c` adapter reproduces the
nine-symbol split-core API consumed by Google's unchanged I2C/SPI modules;
Cirrus's public Makefile instead links the core into each transport module.

The build extracts the 21 non-GKI symbol CRCs for the already-installed
`fw_cs_dsp` and `snd-soc-wm-adsp` dependencies from the guarded stock module.
It takes all GKI CRCs and headers from the existing provenance-locked CI DDK
workspace. Android's modversion loader ignores the release-string prefix when
symbol CRCs are present, but every import is still checked by this build.

## Boot-safe exact-stock build

Select the one-instruction transform directly in the generated build tree:

```bash
export PIXEL_TARGET=frankel
export POWERPHONE_AOC_ALSA_192K=true
export POWERPHONE_AUDIO_SIDECAR=true
export POWERPHONE_CS35L43_192K=true
scripts/sanitize-generated-vendor-frankel.sh
```

The input SHA-256 is `8db0c279...a99d3`; the selected output SHA-256 is
`fc631fc2...58a3a`. They differ at exactly one byte at file offset `0x5ddc`,
changing AArch64 `mov w3, #3` to `mov w3, #4` in the non-disabled ultrasonic
fallback of `cs35l43_pcm_hw_params()`. Module size, CFI, vermagic, imports,
exports, relocation layout, and every unrelated instruction remain stock.

To reproduce the standalone hardware-test pair while preserving the proven
D0 mailbox module:

```bash
tools/audio/build_frankel_d0_mailbox_cs35l43_global_fs96_pair.sh
```

## Rejected public-source experiment

First make sure the existing Frankel DDK workspace and Cirrus checkout are
present, then fetch the pinned Google branch if necessary:

```bash
git -C work/upstream/cirrus-linux-cs35l43 fetch --depth=100 origin \
  google/v6.6-cs35l43:refs/remotes/origin/google-v6.6-cs35l43
tools/audio/kernel/frankel_cs35l43/build-frankel-gki.sh
```

Outputs:

```text
work/upstream/frankel-gki-15739706/modules/snd-soc-cs35l43.powerphone-192k.ko
work/upstream/frankel-gki-15739706/modules/snd-soc-cs35l43.powerphone-192k.unstripped.ko
work/upstream/frankel-gki-15739706/modules/snd-soc-cs35l43.powerphone-192k.SHA256SUMS
```

The public-source output is retained only to document source semantics and
must not be substituted for the exact-stock binary transform.

## Required direct route

For the research path, route ASPRX1 only to the high-rate DAC input:

```text
PCM Source = Zero
High Rate PCM Source = ASPRX1
Ultrasonic Mode = In Band
DSP ... ULTRASONIC_EN = 0
```

`In Band` and `Out of Band` perform the same writes in this driver. The DSP
coefficient `ULTRASONIC_EN` is outside the direct ASPRX1 mux path and is not
required. Enable only one physical amplifier at a time. The Android sidecar
route patch enforces this direct configuration and restores the prior values
on cleanup.
