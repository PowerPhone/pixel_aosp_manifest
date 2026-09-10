# Frankel D10 strict-mono RAW 192 kHz runtime

This path is the qualified direct-capture profile for Pixel 10 (`frankel`)
vendor build `CP2A.260805.005`. It is deliberately reboot-volatile. The F1
patch is never baked into the signed AoC firmware and disappears on an AoC or
device reboot.

The only permitted live topology is:

```text
one logical PDM ID (0, 1, or 2)
  -> PdmV3, 6.4 MHz, 96 frames every 0.5 ms
  -> Stream 2 enum 7
  -> strict one-channel RAW S16 converter
  -> INTERNAL_MIC_TX
  -> EP3
  -> PCM card 0, device 10, mono S16_LE/192000
```

PCM 0,8 (D8/EP1), PCM 0,9 (D9/EP2), PCM 0,12 (D12/EP5), every
multichannel capture, processed capture, and concurrent AudioFlinger capture
are forbidden while this profile is installed. The D10 common RAW geometry
sites are safe only for one source and one RAW output channel. Do not route the
patched shared PDM engine into D8, D9, or D12.

## Prerequisites

The booted kernel image must already contain the exact current build-selected
Frankel AoC ALSA module state (SHA-256
`fc990edad9b77b2bb96cd222f6a07503dc12247804c498a769d0436b5cb61cd0`),
including:

- the general PCM/backend 192 kHz allowances and enum mapping;
- EP3/PCM 0,10's independent 192 kHz ALSA rate mask; and
- the AoC capture host timer at the qualified 0.5 ms cadence.

`POWERPHONE_AOC_ALSA_192K=true` makes the generated-vendor sanitizer select
these changes and the paired `aoc_core.ko` zero-write-pointer reset (SHA-256
`f4b7c9daad2fb3cb2ddc9fa8f80381629b3ffe048194348924e9f7a0ead1024c`)
as one guarded stock-to-qualified transaction. The core change is decisive for
D0 playback startup and is coupled to the same flag so a finished image cannot
silently combine the selected ALSA module with stock ring-reset semantics. The
older
general-192, 1 ms, EP3, and 500 us layer tools remain trial provenance; a
finished image must not compose them at build time or accept an intermediate
digest.

Use a fully booted root-userdebug image, stop `audioserver`, and ensure media,
calls, assistants, and camera capture are inactive. The tool refuses another
device/build, a running `audioserver`, a missing diagnostic or PCM node, an
open D8/D9/D10/D12 fd, any active EP1/EP2/EP3/EP5 input route, a powered
logical MIC control, or anything except this exact inactive mixer setup:

```text
BUILTIN MIC Process Mode=Raw
Audio Capture Mic Source=Builtin_MIC
Mic Spatial Module Enable=Off
BUILDIN MIC ID CAPTURE LIST=0|1|2 -1 -1 -1
INTERNAL_MIC_TX Sample Rate=SR_192K
INTERNAL_MIC_TX Format=S16_LE
INTERNAL_MIC_TX Chan=One
```

All `tinymix` vector writes use the explicit `--` option terminator. Without
it, the three `-1` values can be parsed as options and silently leave a
multichannel capture list behind.

## One guarded capture

The wrapper owns the complete mixer and patch lifetime. It requires the patch
to be uniformly stock at entry, quarantines new opens while each patch
transaction runs, applies the exact profile, captures only D10, reverts to
stock, then restores its mixer snapshot. Its host and remote signal traps turn
EP3 off and attempt the exact guarded revert before ordinary cleanup.

```bash
work/toolchains/platform-tools/adb -P 5038 root
work/toolchains/platform-tools/adb -P 5038 shell stop audioserver

scripts/audio/frankel/d10-raw192-capture.sh \
  --output work/audio-research/frankel/raw192-pdm0.wav \
  --endpoint raw192-pdm0 --duration 10
```

Repeat with `raw192-pdm1` and `raw192-pdm2`. Defaults are mono S16_LE/192000,
1,920-frame periods, and four periods. A successful five-second tinycap may
omit its final incomplete ALSA buffer; the wrapper permits at most one buffer
of end-of-capture difference while still rejecting a 96 kHz or 48 kHz
throughput result.

The logical-microphone selector must be republished after the F1 patch is
active. Hardware trials in `work/audio-research/frankel/hardware-192k-20260904`
isolated this ordering dependency. With the old pre-patch-only selection,
logical microphones 1 and 2 each returned 1,167,360 frames in 12 seconds.
Applying the same 22-site profile while logical microphone 0 was selected and
then selecting microphone 1 or 2 produced exactly 2,304,000 frames in each
12-second WAV. The freshness validator checked 23,936 interior 96-frame
blocks in each file: both had zero empty second halves, zero repeated halves,
and zero short-lag replay. Therefore the profile does not need a per-ID clock
or executable patch. The control write materializes/latches the selected
lane's PdmV3 state.

The standalone wrapper forces a genuine post-patch transition from another
valid logical ID to the requested ID before enabling EP3. It never selects an
empty all-`-1` vector because F1 contains the `pdm_mask != 0` assertion. The
boot orchestrator similarly primes 1, then 2, then 0 under the patched code,
with routes off, PCM nodes quarantined, and exact readback after every value;
logical microphone 0 remains the boot default. These logical IDs are still not
proof of the physical pad or enclosure-opening mapping. The firmware explicitly
logs that logical DMICs are remapped to PDM pads, and DT identifies built-in
physical pads PDM0, PDM2, and PDM3 (not physical PDM1).

On the integrated image, reuse the boot-certified profile directly instead of
performing another factory-diagnostic apply/revert transaction:

```bash
scripts/audio/frankel/d10-raw192-capture.sh \
  --output work/audio-research/frankel/boot-pdm0-192k.wav \
  --endpoint raw192-pdm0 --duration 12 --use-boot-profile
```

This mode requires `vendor.powerphone.pdm.ready=1`, retains the certified F1
profile, and still enforces exclusive direct-PCM ownership, block freshness,
hard-off route cleanup, and unchanged AoC restart/coredump generation.

The patcher can be inspected manually only after establishing the same strict
inactive mixer state:

```bash
export FRANKEL_AOC_DIAG_DEVICE=/data/local/tmp/frankel_aoc_diag
python3 tools/audio/patch_frankel_aoc_live_d10_raw_192k.py check-stock
python3 tools/audio/patch_frankel_aoc_live_d10_raw_192k.py apply
python3 tools/audio/patch_frankel_aoc_live_d10_raw_192k.py check-patched
python3 tools/audio/patch_frankel_aoc_live_d10_raw_192k.py revert
```

If the native helper exists at the default path, the patcher selects it
automatically. `FRANKEL_AOC_DIAG_DEVICE` may name another reviewed device-side
helper. If neither is available, the guarded `factory_diag`/`acd-debug` shell
transport remains available.

## Exact volatile F1 sites

| Address | Stock | D10 RAW 192 kHz |
| --- | --- | --- |
| `0x403daf5d` | `3e44282ee992` | `3e44242ee992` |
| `0x403db6a2` | `2e12b2d11dc9` | `2e000091edc8` |
| `0x403db7a0` | `2ee0108fea92` | `2ee01c8eea92` |
| `0x403db863` | `000000000000000000000000` | `3e41a885016152a06086d9ff` |
| `0x403db7d0` | `3e41a8850161` | `c62300f02000` |
| `0x403db7eb` | `fec7a94e9e93` | `fec7a54e9e93` |
| `0x403db81a` | `3c05` | `3df0` |
| `0x403dbc4f` | `fe00290fe992` | `fe00680fe992` |
| `0x403dbce2` | `b02f11` | `a02f11` |
| `0x403dac3b` | `ae9248d196cf` | `9e9248d196cf` |
| `0x403dac9b` | `ff0a291c56248317` | `ff0a291c5d248317` |
| `0x403dae28` | `2eff71afe992` | `2eff7daee992` |
| `0x403b75c9` | `bf78b8084c0c8014` | `bf88b8084c1c8014` |
| `0x403b7670` | `bf60b5002c088413` | `bf68b5002c088413` |
| `0x403b9eac` | `bf60411a04448617` | `bf68411a04448617` |
| `0x403b84b0` | `00d43000` | `00a86100` |
| `0x403b85f6` | `820580` | `82a000` |
| `0x403b88dd` | `8e9444ee9d93` | `7e9444ee9d93` |
| `0x403ba544` | `8e046c91eb92` | `8e046092eb92` |
| `0x403ba585` | `ee48acfd0f93` | `ee48a0fe0f93` |
| `0x403baa7b` | `ff608414163c8413` | `ff688414163c8413` |
| `0x4038faf4` | `4eb3b8150081` | `4eb3b81d0081` |

The Stream 2 enum-5-to-enum-7 setter is the activation site. Apply writes it
last; revert removes it first. A transaction begins only when every site is
uniformly stock (apply) or uniformly patched (revert). Unknown and mixed
states are refused. A failed write or final verification triggers a reverse
rollback to the complete initial state.

The F1 image contains the little-endian 3,200,000-Hz word `00d43000` exactly
once, at `0x403b84b0`. Together with the successful post-activation selector
tests, this rules out a missing duplicate clock literal for logical microphone
1 or 2. Separate A32 static tracing also shows that physical PDM0/PDM2/PDM3
are constructed with the same hard-coded `PdmClockV2` index 2 and therefore
share the parent/divider/gate; see
`tools/audio/frankel_a32_raw_pdm_ap_handoff.md`.

## Freshness and physical validation

Frame count proves transport cadence, not acoustic bandwidth. The wrapper
also checks the D10 callback geometry: after excluding four edge blocks, every
aligned 96-sample S16 block must contain a nonzero, non-repeated second group
of 48 samples. This rejects the characteristic case where only one 48-sample
half is produced and the other half is zero or stale.

That freshness check is still not Nyquist proof. Retain the WAV and use
`scripts/audio/analyze-wideband.py` plus an external ultrasonic source to show
content/noise above 48 kHz, no sharp 24/48 kHz cutoff, and no periodic phase or
buffer discontinuity. Run each physical endpoint isolation test separately;
logical PDM IDs are not enclosure-location names until mapped acoustically.
