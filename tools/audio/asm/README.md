# Frankel audio instruction fragments

## Primary Android HAL playback

The AArch64 fragments `frankel_primary_hal_prefill_start.*`,
`frankel_primary_hal_d5_fifo90.*`, and `frankel_primary_hal_d5_fmq960.*`
document the guarded proprietary-HAL changes selected by
`../patch_frankel_primary_hal_192k.py`. The FIFO fragment replaces the earlier
prefill fragment's selected success continuation; they are layered fragments,
not competing standalone HAL executables. The FMQ getter changes only the
Android-visible minimum, not the physical ALSA period.

For example, from `pixel_aosp_manifest`, assemble the FMQ fragment with the
matching AOSP compiler:

```sh
work/aosp/prebuilts/clang/host/linux-x86/clang-r596125/bin/clang \
  --target=aarch64-linux-gnu -c tools/audio/asm/frankel_primary_hal_d5_fmq960.S \
  -o work/audio-research/frankel/primary-hal-d5-fmq960.o

work/aosp/prebuilts/clang/host/linux-x86/clang-r596125/bin/ld.lld \
  -T tools/audio/asm/frankel_primary_hal_d5_fmq960.ld \
  work/audio-research/frankel/primary-hal-d5-fmq960.o \
  -o work/audio-research/frankel/primary-hal-d5-fmq960.elf
```

Hardware evidence and image-selection instructions are in
[primary playback](../frankel_primary_playback_192k.md). Assembling these
fragments is not a substitute for actual waveform and sustained-playback
qualification.

## Historical AoC offline assembly review

`frankel_aoc_speaker_192k_analysis.S` and its linker script encode the
instruction fragments referenced by the incomplete semantic manifest. They
do not build an AoC container and must not be treated as signed or loadable
firmware.

The source requires a Sky1-configured Xtensa assembler and linker. Generic
Ubuntu Binutils cannot encode these FLIX bundles. With locally built matching
tools, assemble and decode it without touching the device:

```sh
<sky1-as> --no-transform --no-target-align --no-text-section-literals \
  -o /tmp/frankel-aoc-speaker-192.o \
  tools/audio/asm/frankel_aoc_speaker_192k_analysis.S

<sky1-ld> -T tools/audio/asm/frankel_aoc_speaker_192k_analysis.ld \
  -o /tmp/frankel-aoc-speaker-192.elf \
  /tmp/frankel-aoc-speaker-192.o

work/toolchains/sky1-binutils-recovered/bin/xtensa-sky1-elf-objdump \
  -h -d /tmp/frankel-aoc-speaker-192.elf
```

The linked sections must have these sizes and raw bytes:

| Section | Size | Raw bytes |
| --- | ---: | --- |
| `.patch.scratch_init` | 42 | `c2d202f2a6000c3d690242629fc9b1424c80d262a5c2a06b4262a2f262ad4262a3f262aff0ff11f262ae` |
| `.patch.force_high` | 3 | `c6ffff` |
| `.patch.rate` | 6 | `fe104802e180` |
| `.patch.src_up_shape` | 6 | `7e95455a9b93` |
| `.patch.src_up_frames` | 6 | `ce104c82e180` |
| `.patch.src_down_heap` | 6 | `ee27691aeb92` |
| `.patch.src_down_frames` | 6 | `be104083e180` |

Use `objcopy -O binary --only-section=<name>` before comparing bytes. The
grouped byte field printed by `objdump` is a decoded display and is not a
substitute for the raw section order.

The two heap-shift fragments encode 7,040 and 8,768-byte capacities, above
the conservative statically reconstructed 6,240 and 7,424-byte bounds.
Firmware execution has not verified those calculations. The scratch change
is entirely in place and uses no code cave. It retains the stock null-DMA
assertion arguments by eliminating a redundant size temporary and ordering
the 1,536-byte stores before the 3,072-byte doubling instruction. The original
draft remains `incomplete-design`. The independently reviewed exact-byte copy
is described only by
`../manifests/frankel-aoc-speaker-192k-offline-analysis.json`; its generated
container is unsigned, non-loadable, and hardware-unqualified.
