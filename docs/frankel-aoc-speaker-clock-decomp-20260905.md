# Frankel AoC speaker-clock interoperability inspection — 2026-09-05

This is an offline, read-only inspection of the existing firmware-analysis
artifacts. It follows ordinary audio routing and clock initialization, not
authentication, executable modifications, runtime hooks, or device-memory
access. No newly supported 192 kHz configuration API has been established
by this ARM-side pass.

## Projects and evidence

The ARM project reserved for this pass is
`work/audio-research/frankel/ghidra-projects/frankel_aoc_arm.gpr`.
Its program is named `aoc-hifi.bin`, but its declared processor is
`ARM:LE:32:v8`, and its raw mapping covers `0x40000000..0x409fffff`.
The input path recorded by Ghidra is
`work/audio-research/frankel/ghidra-input/aoc-hifi.bin`.
The mapped file includes strings and code for more than one processor;
the filename or presence of a string does not make every address ARM code.

New logs are retained under
`work/audio-research/frankel/speaker-clock-decomp-20260905/`:

- `arm-headless.log` and `arm-speaker-strings.txt`: program identity and
  speaker-start string references.
- `arm-tdm-headless.log` and `arm-tdm-strings.txt`: TDM/I2S driver references.
- `arm-root-clock-headless.log` and `arm-root-clock.txt`: actual ARM PDM and
  DVFS functions. The headless log retains the full multiline decompilation;
  the script log is a compact locator.

All invocations used `-readOnly -noanalysis` on the existing ARM project.
The DSP projects were not opened by this pass. Older logs such as
`/tmp/frankel-speaker-start-ghidra.txt` were read only as historical context;
new results do not depend on their invalid DSP pseudocode.

## Located clock domains

| Locator | Evidence | Interpretation |
| --- | --- | --- |
| ARM function `0x4008e5c4` | References `SetBaseClock` and `pdm_clock_v2.cc`; validates a small source-selector range and configures a PDM clock object | PDM base-clock selection, not speaker sample-rate configuration |
| ARM function `0x40087d7e` | References `SetSystemClocks` and `dvfs_lga.cc`; consults a frequency/voltage table and repeats until votes stabilize | Processor/fabric DVFS, not a PCM frame-rate setter |
| ARM function `0x4008d902` | References `pdm_clock_freq_hz_`, `ConfigHpf`, and `pdm_v3.cc` | Microphone high-pass configuration; irrelevant to raising speaker TDM rate |
| String `0x40275f19`, literal reference `0x403d3fd8` | Speaker-start log reports clock, frame rate, slots, channels, and DMA geometry | The located speaker-start implementation is DSP code, not ARM |
| String `0x402680d4`, literal reference `0x403aa400` | TDM DMA geometry log, alongside `TDMDesignWare` strings | The located low-level speaker TDM implementation is also DSP-side |

The normal ARM functions decompile into coherent control flow, but their
inferred argument/object types remain unnamed. Their names are inferred
from their own assertion/source strings, not from recovered C++ debug
symbols. Processor frequency scaling and audio frame clocks are separate
decisions: finding DVFS support is not evidence that increasing CPU
frequency changes 48 kHz audio into 192 kHz audio.

## DSP follow-up anchors

The speaker-start string's historical containing routine is `0x403d3fec`.
The old generic/incorrect FLIX decoder stopped within a few instructions
and emitted `halt_baddata`; that output is not a reliable implementation
or a basis for a clock-setting change. This routine and the TDM DMA literal
pool at `0x403aa400` require the appropriate DSP instruction decoder.

Additional strings in the same DSP-side image identify a normal audio-clock
abstraction worth following:

| Address | String |
| --- | --- |
| `0x40263b55` | `audio_out_clock_handler_v2.cc` |
| `0x40263b73` | `SetClockSource` |
| `0x40263b82` | `SetClockSourceAlt` |
| `0x40263b94` | `kBaseClockFreqKhz % frequency_khz == 0` |
| `0x40263bbb` | `SetHardwareClockDiv` |

These establish that the binary contains named audio clock-source/divider
logic, but they do not establish a reachable external API, argument layout,
accepted 192 kHz mode, or the physical clock produced by a particular call.
The names `CMD_AUDIO_OUTPUT_MCPROC_ENABLE_CLOCKING` and its disable
counterpart also occur in error messages. They may concern multi-core
processing rather than the speaker serial port. No command IDs or
parameters are inferred from their names, and they are not probe recipes.

## Relation to the real hardware results

The normal Linux playback setup in the actual baseline module already
encodes 192000 as `SR_192KHZ` in `CMD_AUDIO_OUTPUT_EP_SETUP`; this was
confirmed in the surrounding playback command construction, not inferred
from the older upstream source's fallback. That metadata alone therefore
does not explain or fix the active speaker cadence. The real frontend-192 /
backend-48 trial retained a quarter-frequency tone and fourfold duration,
as recorded in the [routing evidence](frankel-speaker-routing-20260904.md).

The next useful offline evidence is a correctly decoded DSP call chain from
the speaker sink's start/configuration path to its clock-source/divider
object, followed by any existing normal command dispatcher that controls
those settings. Until that chain and its argument semantics are established,
the ARM clock functions above provide no justified speaker-192 kHz action.

## Matching DSP disassembler recovered

The existing `/tmp/sky1-binutils-build/binutils/objdump` was recovered into
`work/toolchains/sky1-binutils-recovered/bin/xtensa-sky1-elf-objdump`.
Unlike the other local RT500, Yuzuki HiFi4, and Wuqi HiFi5 configurations,
this Sky1-configured Binutils 2.36.1 decodes the known six/eight-byte audio
FLIX bundles coherently. Configuration sources, original build metadata,
and notices were also retained; see that directory's `README.md`.

A fresh analysis-only ELF was generated from the current raw file:
`work/audio-research/frankel/ghidra-input/aoc-hifi-sky1-recovered.elf`.
The contents flag is explicitly preserved in the ELF conversion. The old
`aoc-hifi-entry.elf` has zero-filled bytes near the actual clock routines
and must not be used for this analysis. The recovered objdump crashes in
raw-binary input mode but works on the fresh ELF.

The routine at `0x4039d5c8` now decodes from its real entry through the
return at `0x4039d62e` and its assertion tails. Its initial instructions
load object offsets 20 and 12, calculate an unsigned quotient of the
offset-20 value by an argument, and check divisibility/range. This permits
following the ordinary audio divider implementation, but does not by
itself establish a normal external command that can select 192 kHz.

Linear disassembly can still drift over padding and literal pools. At
speaker entry `0x403d3fec`, follow the decoded branch to `0x403d400c` with
a fresh bounded disassembly rather than treating padding at
`0x403d400a..0x403d400b` as instructions. No successful Ghidra decompilation
is claimed from this tool recovery; constructor/pcode compatibility is a
separate issue. No firmware or device state was changed.

## The normal CLI object-print command

Offline inspection of the complete current container's ARM/DSP regions
confirms the existing command is already the detailed virtual-object Print
operation:

```text
dbg info -c 2 AHWSinkSPKR
```

The ARM command table at analysis address `0x780e1b74` binds handler
`0x7800ef90` to `info` and the help text `Output debug info`. Its registered
options are `-c`/`--core` and `-s`/`--system`; the named-object path does not
have a separate detail option. The local named-object dispatch at
`0x780124bc` resolves the object and calls its vtable at offset `+8`.
The DSP counterpart at `0x78794504` also calls vtable offset `+8` at
`0x78794545..0x78794547`. This is not just a generic filter-summary call.

The speaker constructor at `0x78972b24` installs vtable `0x40275d00`,
whose `+8` entry is the speaker Print method `0x78973354`. That method
calls its base Print and then unconditionally prints the clock and slot
configuration: object fields `+0x288` and `+0x28c`, with the format string
referenced through literal `0x78973308`. No detail-enable branch gates
these lines. Both the DSP diagnostic dispatch and these speaker-specific
lines use the same firmware printer global at `0x41004730`.

The separate CLI `dump` entry has the explicit help text `Dump memory`;
it is not an alternative object-print command and was not executed or
followed. Generic-only live output therefore is not explained by choosing
`info` instead of another detailed verb. Object lookup selecting a wrapper
or incomplete output collection remain possibilities, not findings proved
by this offline pass.

Retained bounded disassemblies under
`work/audio-research/frankel/speaker-clock-decomp-20260905/`:
`cli-info-arm-handler.dis`, `cli-info-arm-dispatch.dis`,
`cli-info-dsp-dispatch.dis`, and `cli-info-speaker-print.dis`.
No device command was issued in this inspection.

## Device-tree clock-divider is not a speaker clock control

The saved Frankel tree gives `aoc@9000000` a `clock-divider = <1>` property.
In the retained public driver, `aoc.c:2461` reads this into
`prvdata->aoc_clock_divider`; `sys_tick_to_aoc_tick()` at `aoc.c:801`
uses it only in `(sys_tick - clock_offset()) / aoc_clock_divider`.
The two read-only AoC clock attributes consume that conversion. This source
does not route the property into the speaker TDM clock-divider object.
Changing it is therefore not a demonstrated audio-rate modification and
could instead make reported timestamps wrong. The inspected source is
`work/upstream/google-modules-aoc-android16/aoc.c`, not a recovered source
tree for the proprietary DSP firmware.

Likewise, the public boot-data table carries the boolean speaker-ultrasound
enable flag, not a numerical speaker sample-rate parameter. The public
`SR_192KHZ` enum is valid stream metadata, but its presence is not evidence
of a 192 kHz physical speaker-clock setter. These observations do not rule
out additional private interfaces; none has been established here.
