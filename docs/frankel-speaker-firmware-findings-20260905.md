# Frankel speaker firmware findings — 2026-09-05

192 kHz physical playback remains unqualified. Offline inspection now
identifies the stock speaker's actual clock initialization, rather than
inferring it from ALSA metadata. The existing firmware was copied from the
phone; no firmware bytes or flash partitions were changed in this pass.

## Findings

The speaker constructor chooses **48 or 96 kHz**, allocates the corresponding
processing resources, selects four 32-bit slots, and derives the bit clock as
`sample_rate_kHz * 128`. Speaker startup then uses those stored settings.
Changing the PCM frontend rate does not change that initialization. This
explains why a rate-mask-only 192 kHz request can be accepted while playback
still takes four times the intended duration.

The 96 kHz selection checks three other board/revision combinations and one
platform flag. The phone reports FL5, board `0x70303`, revision `0x10000`;
none of the three board predicates matches. There is no 192 kHz constructor
branch. This is a limitation of the inspected firmware path, **not proof of
the amplifier's maximum hardware capability**. A coordinated higher-rate
processing/clock configuration and a supported firmware-loading route are
still missing; no normal runtime 192 kHz setter has been established.

See [the constructor and native-ultrasound analysis](frankel-native-ultrasound-decomp-20260905.md)
for the exact control flow, and [the clock/CLI analysis](frankel-aoc-speaker-clock-decomp-20260905.md)
for the separate clock domains and decompiler limitations.

## Reproducible offline extraction

The old analysis image omitted external-memory code, including the speaker
constructor. The full device container includes an external region at file
offset `0xe000` with DSP analysis address `0x7800d000`, plus the shared region
at offset `0xa6fdc0` with address `0x40000000`. The external alias is inferred
from the container section table and matching function-pointer targets and
instruction bytes. It must not be generalized to another firmware version.

From the repository root, using a **new** destination directory:

```bash
python3 tools/audio/extract_frankel_aoc_analysis.py \
  work/audio-research/frankel/speaker-firmware-decomp-20260905/device-aoc.bin \
  work/audio-research/frankel/speaker-firmware-decomp-20260905/another-extraction \
  --objcopy work/toolchains/sky1-binutils-recovered/bin/xtensa-sky1-elf-objcopy
```

This requires Python 3 and the matching configuration-specific Xtensa
Binutils utilities. Their local recovery, build configuration, licenses,
and unresolved original archive URL are documented in
`work/toolchains/sky1-binutils-recovered/README.md`. Generic Ubuntu Binutils
does not replace the custom DSP decoder. Ghidra 12.1.3 uses OpenJDK 21 here,
but its installed FLIX decoder still produces invalid pseudocode; that
pseudocode is not used as evidence. NumPy is used for recording analysis.
No host packages were installed during this pass.

Use `regions-complete/{dsp-external,shared}.elf` for this pass's actual outputs.
Earlier `regions` and `regions-v2` ELF attempts omitted section contents and
are invalid analysis artifacts. The extractor now explicitly preserves
`contents`. With the recovered Sky1 objdump, restart disassembly at actual
function entries and branch targets; padding and literal pools can misalign
a broad linear dump.

The extractor only reads the proprietary container and creates local
analysis files. It does not sign, rewrite, load, or flash firmware. Keep
these binaries below ignored `work/`, not in a public source release.

## Normal ultrasound switch: real-device attempt

The existing helper invoked the public
`AOC_IOCTL_FORCE_SPEAKER_ULTRASONIC` with value 1, followed by the normal
AoC `force_reload` operation, with the three audio services stopped.
The ioctl succeeded. After the subsystem's coredump/restart sequence, the
kernel logged the ultrasound enable flag and loaded the unchanged signed
firmware, but the security controller failed to start AoC (`-5`). AoC
services did not return. This does not establish why startup failed, does
not prove the flag caused the failure, and is not an acoustic-rate trial.

The flag was cleared to 0 and the entire phone was rebooted normally.
No additional reload or authentication workaround was attempted. After
reboot, AoC's restart counter was 0, its debug service existed, and Google
audio HAL, PowerPhone HAL, and audioserver were running with SELinux
Enforcing. No flash image was written.

## Restoration check

The first app launches were canceled because the display was asleep; they
are retained as failures, not reported as passes. After waking the display
and relaunching the separate stock diagnostic, AudioTrack completed
384,000 frames at 48 kHz in 7.942 seconds with zero reported underruns.
AudioRecord captured 477,120 mono frames through the bottom microphone.
A 0.8-second window beginning at 2 seconds contains an 18 kHz line at
approximately -99 dBFS versus a nearby median floor of -123 dBFS;
pre-tone exact-bin amplitude was approximately -124 dBFS. Other parts
of the recording contain stronger ambient noise. This is ordinary acoustic
presence/transport evidence, not a wideband response or jitter qualification.

Evidence is under `work/audio-research/frankel/speaker-firmware-decomp-20260905/`:

- `device-aoc.bin`, `regions-complete/`, `speaker-constructor.txt`,
  and `clock-divider.txt`: offline inputs and decoded functions.
- `native-us-enable-reload.txt`, `native-us-reload-dmesg.txt`:
  unsuccessful normal reload attempt.
- `restored-android48-final.txt`, `restored-physical-mic.wav`:
  completed restoration check, alongside earlier canceled runs.

The phone retains the previously booted EP6 rate-mask-only kernel and all
other existing partitions. Baseline release bundles remain unchanged.
There is still **no verified 192 kHz flash-all bundle**.

## Firmware-change follow-up

The later source inspection separates two requirements that must not be
conflated:

- The retained CS35L43 driver has a normal 192000 Hz PCM configuration
  (`GLOBAL_FS = 0x05`), and its PLL table accepts a 24.576 MHz reference.
  With four 32-bit TDM slots, that is the expected bit clock for 192 kHz.
  These are driver capabilities, not measured speaker bandwidth.
- AoC's known high-rate constructor selects 96 kHz and creates explicit
  48-to-96 / 96-to-48 processing stages. Raising only the ALSA rate or codec
  clock request does not update those stages or prove coherent DMA geometry.

The codec's separate ultrasonic mode is not equivalent to normal 192 kHz
PCM: the retained public driver forces a 48 kHz base rate in that mode.
Earlier custom-module changes must not be attributed to the public driver.
The [codec constraints](frankel-cs35l43-192k-constraints-20260905.md) record
the matching normal-path clock, slot, duplex and protection requirements.

The [192 kHz design dependencies](frankel-speaker-192-design-20260905.md)
trace the additional fixed scratch capacities. Although DMA allocations
scale with the rate field, high-rate output staging remains 1,536 bytes
where a 192-frame four-S32 block needs 3,072; the enabled native-ultrasonic
input also needs its two-channel staging capacity reconsidered. A blind
96-to-192 constant replacement is therefore not a complete audio patch.
The note distinguishes these high-rate buffers from retained 48 kHz
processing and feedback boundaries.

Deeper inspection now establishes that the normal `AspSrc` library really
contains 48-to-192 and 192-to-48 filter plans (stages 1+23 and 26+7). This is
not the separate `AspSrcIIR` implementation with a 96 kHz assertion. The
[SRC analysis](frankel-aoc-aspsrc-192-analysis-20260905.md) records the exact
table entries and allocation query sequence. Static allocator reconstruction
gives conservative 6,240/7,424-byte ratio-4 bounds; the candidate uses
7,040/8,768 bytes. Those bounds are independently decoded but still need
constructor execution.

The original exact seven-edit draft is retained as
`tools/audio/manifests/frankel-aoc-speaker-192k-constructor-candidate.incomplete.json`,
with reviewable Sky1 source in
`tools/audio/asm/frankel_aoc_speaker_192k_analysis.S`. It coordinates the
physical rate, both converter directions, high-rate scratch capacities, and
the constructor branch. The
[independent constructor review](frankel-speaker-constructor-offline-review-20260905.md)
confirms its local branch and scratch-store encodings. The newer scratch
sequence fits the original 42-byte extent and needs no code cave. It retains
the null-DMA assertion arguments by eliminating a redundant size temporary
and ordering the two 1,536-byte stores before the added doubling instruction.
That draft remains `incomplete-design`. Independent instruction, SRC sizing,
and manifest review produced the separate
`tools/audio/manifests/frankel-aoc-speaker-192k-offline-analysis.json` and the
ignored-work copy
`candidate-aoc-speaker192.UNSIGNED-NOT-FLASHABLE.bin`. “Reviewed” is limited
to exact offline byte construction: the OEM signature is invalid, and loading,
runtime initialization, physical 192 kHz cadence, and acoustics are all
unqualified.

No new live firmware patch, subsystem reload, flash, or acoustic trial was
performed in this follow-up. Read-only device checks found boot completion,
all three audio services running, AoC restart count zero, and SELinux
Enforcing. The previous PDM implementation's runtime code modification and
execution-redirection mechanism was not reused. A supported way to load and
test the audio-modified firmware remains unestablished; the generated offline
copy is not a loadable or qualified build.
