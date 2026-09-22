# Frankel native-ultrasound investigation — 2026-09-05

This is offline analysis of ordinary audio configuration, not a working
192 kHz speaker release. No firmware execution hooks, runtime memory writes,
or device operations are part of this investigation.

## What the hardware has actually established

The [rate-only trials](frankel-speaker-rate-only-20260905.md) establish a
physical 48 kHz reference on Source 5 / EP6. Merely permitting 192 kHz at that
frontend produces quarter-speed playback, even when the codec/backend mixer
requests 192 kHz. D28 at 192 kHz, four-channel S32, stalled with MMAP; RW
accepted 2,048 frames / 32,768 bytes before EIO. These are failures, not
ultrasonic acoustic passes. Initial writes can fill a ring without proving
that its downstream consumer runs.

## D28 has several different identifiers

The locally retained public Google driver declares `audio_ultrasonic` in
`work/upstream/google-modules-aoc/alsa/aoc_alsa_path.c`, with S32, 96 kHz,
and two to four channels depending on the SoC configuration. The actual
repository-baseline module has a wider rate mask, so its accepted HW_PARAMS
must not be confused with this public-source declaration or physical rate
support.

In that source, the normal PCM setup/start path uses PCM index 28 as
`entry_point_idx`. In contrast, `ep_id_to_source()` maps the `US` mixer path
to `SPEAKER_US = 14`. The ordinary backend route is `TDM_0_RX Mixer US`.
These are distinct namespaces; changing both identifiers to 14 is not a
demonstrated fix. An earlier hardware log explicitly rejected playback mode
for entrypoint 14. No reproduction of that earlier experiment is prescribed.

## Speaker startup: where the physical clock comes from

The firmware string `Speaker TDM Started with Clk: ...` identifies the DSP
speaker startup method at `0x403d3fec`. Its ordinary setup code establishes:

| Speaker object member | Observed use |
| --- | --- |
| `+0x284` | Clock-handler object. |
| `+0x288` | Clock argument supplied to its virtual method at vtable `+8`; also printed as clock kHz. |
| `+0x298` | Printed as sample-rate kHz and used in speaker block sizing. |
| `+0x28c` | Printed as the slot count and passed to TDM setup. |
| `+0x320` | TDM controller object. |
| `+0x2e4` | Separate ultrasonic ring; connected to processing channel 6 during speaker binding. |

The clock call is at `0x403d404e`–`0x403d4058`; the log arguments are loaded
at `0x403d4252`–`0x403d425e`. TDM DMA setup uses the ordinary method at
`0x403aa43c`. The separate ultrasonic-ring binding is at
`0x403d44b3`–`0x403d44d1`. These observations explain why frontend rate
metadata alone is insufficient.

## Constructor: board-selected 48/96 kHz, not frontend-selected 192 kHz

The complete firmware container exposes the speaker constructor at
`0x78972b24`. Its identity is established by assigning the speaker vtable
(`0x40275cf8 + 8`) to the object. The previously unidentified method
`0x78973354` is diagnostic printing, not a configuration setter.

The constructor chooses its physical sample-rate field as follows:

| Predicate | Condition observed in the firmware |
| --- | --- |
| `0x403a8268` | A boolean read from the platform object at `+0x1392`. Its precise boot-parameter provenance still requires confirmation. |
| `0x403a7ec0` | Board ID `0x20901` and board revision greater than `0xffff`. |
| `0x403a7eec` | Board ID `0x30801` and board revision greater than `0xffff`. |
| `0x403a8078` | Board ID `0x61001` and board revision greater than `0xffff`. |

If any predicate is true, it stores 96 at speaker `+0x298`
(`0x78972c1d`). Otherwise it stores 48 (`0x78973096`). The two branches
also initialize different processing/resampling resources; this is not just
a displayed rate. Later, the constructor fixes four slots and derives the
clock as `rate_kHz << 7` (`0x78972f2f`–`0x78972f44`), corresponding to four
32-bit slots. Thus the constructed paths use 6,144 or 12,288 kHz bit clocks.
There is no 192 kHz branch in this constructor.

The saved actual Frankel tree, `work/audio-research/frankel/baseline/live-frankel.dts`,
identifies `aoc-board-cfg = "FL5"`, ID `0x70303`, revision `0x10000`.
It does not match any of those three board-ID predicates. Other devices'
board IDs must not be substituted to select a different audio path.

Public kernel source separately defines a normal
`AOC_IOCTL_FORCE_SPEAKER_ULTRASONIC` setting and passes its value as firmware
boot-data key `kAOCForceSpeakerUltrasonic` (`0x1010`). This is an initialization
setting, not a PCM-rate or live speaker-clock command. Its connection to the
first predicate remains to be established, and it must not be described as
a 192 kHz capability. An earlier force-ultrasonic trial also failed to boot;
this document does not prescribe replaying that experiment.

No ordinary runtime setter changing all clock, slots, and processing
resources to 192 kHz has been established. The constructor evidence bounds
the known native paths, rather than proving the amplifier itself cannot
support a higher rate.

## Decoder and provenance cautions

Use the recovered Sky1 Xtensa decoder at
`work/toolchains/sky1-binutils-recovered/bin/xtensa-sky1-elf-objdump` and
`work/audio-research/frankel/ghidra-input/aoc-hifi-sky1-recovered.elf` for the
raw DSP region. Restart disassembly at known function entries and branch
targets after padding or literal pools. A broad linear dump can become
misaligned even with the correct decoder.

The older `aoc-hifi-entry.elf` has zero-filled regions where the raw image
contains code. The installed RT500/HiFi4/HiFi5 decoders also decode several
custom FLIX bundles incorrectly. Neither zeros nor those malformed
decompilations establish absent hardware support.

External methods must be decoded from
`work/audio-research/frankel/speaker-firmware-decomp-20260905/regions-complete/dsp-external.elf`;
shared DSP methods are in the adjacent `shared.elf`. These are extracted
from the actual device's firmware by `tools/audio/extract_frankel_aoc_analysis.py`.
The external region begins at container offset `0xe000`, interpreted at DSP
address `0x7800d000`. The first `regions` and `regions-v2` ELF attempts lacked
section contents and are not valid evidence; use `regions-complete` only.
