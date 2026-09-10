# Frankel speaker 192 kHz design dependencies — 2026-09-05

This is an offline interoperability design note and binary-analysis record,
not a loadable firmware release. The phone was not changed. Existing 48 kHz
acoustic evidence and failed rate-only trials remain the hardware status; no
native 192 kHz playback or flashable release is established. The exact
candidate instruction sources are in
`tools/audio/asm/frankel_aoc_speaker_192k_analysis.S`; applying their bytes
invalidates the OEM signature.

Inputs are the unchanged device container and valid
`work/audio-research/frankel/speaker-firmware-decomp-20260905/regions-complete/`
ELFs. Addresses below identify evidence in this firmware version only.
Use the recovered Sky1 decoder at actual entry/branch boundaries; its linear
output can drift over padding. The [earlier constructor findings](frankel-native-ultrasound-decomp-20260905.md)
already establish board-selected 48/96 kHz. This pass distinguishes what
scales automatically from what remains explicitly tied to those rates.

## Derived serial-port geometry

Let `r` be the speaker rate field in kHz (`+0x298`). The constructor at
`0x78972b24` derives the following values; the 192 column is arithmetic,
not a tested configuration:

| Item | 48 kHz | 96 kHz | Hypothetical 192 kHz |
| --- | ---: | ---: | ---: |
| Frames in a 1 ms block, `r` | 48 | 96 | 192 |
| Four-slot, 32-bit BCLK, `128r` kHz | 6,144 | 12,288 | 24,576 |
| Single-channel byte count, `4r`, field `+0x2a0` | 192 | 384 | 768 |
| Four-channel block bytes, `16r`, fields `+0x29c/+0x2a4/+0x2a8` | 768 | 1,536 | 3,072 |
| Each TX/RX double-buffer allocation, `32r` bytes | 1,536 | 3,072 | 6,144 |
| DMA loop iterations, `r/8` | 6 | 12 | 24 |

Rate-derived sizes are set at `0x78972e04..0x78972e1a`. The two shifts in
the FLIX bundle use the incoming rate value: `4r` and `16r`, not a serial
composition of both shifts. `SPKR_TX_DMA` and `SPKR_RX_DMA` constructors
receive twice `+0x29c`, with 64-byte alignment. Their allocator at
`0x7879b458` actually allocates the supplied size; these are not just labels.
Startup uses one half of the allocated buffer plus `r` to configure DMA.

The DMA setup routine `0x403aa43c` requires a whole number of
eight-frame iterations, at most 256 iterations, four/eight enabled slots,
and 64-byte-aligned half-state structures. A 192-frame block satisfies
these particular numeric checks. This is not proof of DMA throughput,
clock generation, codec acceptance, or execution-time margin at 192 kHz.

## Explicit 48/96 processing boundary

The 96 kHz branch constructs two actual `SrcBlock` objects:

| Speaker member | Constructor arguments observed | Operational use |
| --- | --- | --- |
| `+0x2ac` | 48/96 block-frame counts and 48000/96000 Hz | Converts the 48 kHz playback staging block before high-rate output; called at `0x403d3b45`. |
| `+0x2b0` | 96/48 block-frame counts and 96000/48000 Hz | Converts high-rate feedback into the 48 kHz processing domain; called at `0x403d3763`. |

These arguments are literal constants at `0x78972d52..0x78972db7`, not
computed from `r`. Keeping this structure for a 192 kHz serial port would
require validated 48-to-192 and 192-to-48 converter configurations, with
matching block counts and filter/workspace requirements. Changing `r`
alone would leave these converters at 48/96.

The wrapper at `0x4040fb10`, identified by `src_block.cc`/`SrcBlock`, stores
the supplied rates/counts and calls the normal ASP SRC configuration method.
The latter at `0x403ff6fc` passes those settings into the underlying library
and checks its return statuses. This is not the separate `AspSrcIIR` mode
selector at `0x40400070`; that unrelated selector's 96 kHz assertions do not
constrain this speaker `SrcBlock`.

The normal converter's pair selector at `0x404635f0` maps 48, 96 and 192 kHz
to indices 8, 11 and 14. Its 15-by-15, 12-byte-entry table at `0x40374070`
contains actual ratio-4 pipelines:

| Pair | Table entry | Stage sequence |
| --- | --- | --- |
| 48 to 192 kHz | `0x403746b8`: `01 17 ff ff ff ff ff ff 00 00 00 00` | 1, 23 |
| 192 to 48 kHz | `0x40374aa8`: `1a 07 ff ff ff ff ff ff 00 00 00 00` | 26, 7 |

Stages 1 and 7 use 84-tap descriptors; stages 23 and 26 use 16-tap
descriptors. This proves that the shipped normal SRC library contains both
required conversion topologies. Configuration at `0x40463980` queries its
own memory tables and allocates the returned sizes from the caller-provided
private heap. A larger caller capacity is accepted; no equality check against
the stock capacity was found.

The normal sizing path was reconstructed through the memory descriptors at
`0x404630ed..0x40463149`. For four channels, stages 1+23 require 1,376 bytes
of table-0 state; stages 26+7 require 2,560. Both ratio-4 directions use a
4,608-byte table 1. The wrapper loop at `0x403ff8fc..0x403ff902` allocates
only table indices 0 and 1 from this heap; streaming tables 2 and 3 are not
private-heap allocations. Including the 80-byte descriptor block gives raw
requests of 6,064 and 7,248 bytes. Both stock capacities exceed their
corresponding recovered raw request by exactly 176 bytes. Direct allocator
inspection indicates a slightly smaller 152-byte header/node cost for these
three eight-byte-aligned allocations, but exact-fit behavior was not executed.
Retaining the stock 176-byte allowance gives conservative reconstructed
bounds of 6,240 and 7,424 bytes.

The offline candidate encodes 7,040 and 8,768 bytes, leaving 800 and 1,344
bytes beyond those bounds. The arithmetic and allocation loop were
independently decoded, but only a successful constructor run can qualify
them in the complete firmware and establish available global RAM.

Many other small objects initially resembling processing resources are
actually `TapPoint` descriptors (`0x40384bfc`, identified by `tap_points.cc`).
`RX`/`TX` stay tagged 48 kHz; the 96 branch adds `RX96`/`TX96` and tags
`PRE_DEL`/`POST_DEL` as 96 kHz. `A_AEC` stays 48 kHz. Updating tap metadata
would make diagnostics interpretable but would not change signal bandwidth.

## Fixed scratch allocations and frame counts

The constructor initializes three scratch sizes independently of `r`:

| Allocation | Fixed capacity | Consequence for a higher-rate mode |
| --- | ---: | --- |
| `+0x2c0`, size stored at `+0x2b4` | 768 bytes | The native ultrasonic path consumes two S32 samples per frame from this buffer, bounded by `r` (`0x403d3c94` onward). At 192 frames this needs 1,536 bytes when that path is enabled. |
| `+0x2c4`, size at `+0x2b8` | 1,536 bytes | High-rate four-slot output staging spans `4r` S32 values. At 192 frames its allocation and clear need 3,072 bytes. The native route writes two selected S32 slots per frame and leaves the other two slots zero. |
| `+0x2c8`, size at `+0x2bc` | 1,536 bytes | Used as 48 kHz playback/SRC input staging. It does not follow that this buffer should grow merely because the hardware rate grows; its required capacity depends on the chosen processing topology. |

The sizes are set near `0x78972b96..0x78972bad`, then allocated and
zero-initialized at `0x78972ecb..0x78972f2c`. Increasing DMA allocations
does not increase these separate allocations.

The processing code intentionally retains multiple 48-frame operations:
mixing calls in `0x403d388c`, a 768-byte feedback publication at
`0x403d3839`, and a conditional 48-frame copy near `0x403d3d86`.
These cannot all be replaced with 192: some belong to the retained 48 kHz
domain. Conversely, a genuinely wideband application path cannot pass its
content through that 48 kHz domain before upsampling. It needs an explicitly
qualified high-rate input route alongside, or instead of, that processing.

## Exact offline candidate shape

The candidate is tied to `15070001-polygon` and consists of seven guarded,
equal-length substitutions. Semantically it:

1. rewrites the complete 42-byte fixed scratch initialization in place;
2. selects the existing high-rate object topology on Frankel;
3. changes the physical rate from 96 to 192 frames/ms, which also makes the
   existing arithmetic derive a 24.576 MHz four-slot S32 bit clock and
   6,144-byte TX/RX double buffers;
4. changes the playback converter from 48/96 to 48/192 and the feedback
   converter from 96/48 to 192/48, with 7,040/8,768-byte private capacities;
5. expands `+0x2b4` from `0x300` to `0x600` and `+0x2b8` from `0x600` to
   `0xc00`, while retaining the 48 kHz input staging capacity at `+0x2bc`.

The in-place sequence ends at `0x78972baf`, exactly where the stock sequence
ends. It obtains the extra size-doubling instruction by eliminating the
separate `a14` size temporary, storing both 1,536-byte fields from `a15`, then
doubling `a15` immediately before the 3,072-byte store. The stock
`movi a12,107` null-DMA assertion argument and every non-size member store are
retained. The size temporaries are overwritten at `0x78972bc2` before their
next normal-path use. The
[independent constructor review](frankel-speaker-constructor-offline-review-20260905.md)
records this bounded equivalence; no code cave or ownership assumption remains.

The original semantic byte draft remains explicitly incomplete. Independent
instruction, SRC sizing, and manifest review produced a separate exact-byte
manifest, `frankel-aoc-speaker-192k-offline-analysis.json`, and an ignored-work
analysis copy. Its review completeness means only that the intended bytes,
stock guards, and documented offline semantics were reviewed. The copy is
unsigned, non-loadable, non-flashable, and hardware-unqualified.

## What a coordinated mode still requires

1. A supported way to authenticate and load an audio-modified firmware; no
   normal 192 kHz setter has been found. No authentication or
   runtime-execution workaround is proposed here.
2. Constructor qualification of the proved SRC rate pairs and statically
   bounded private heaps. A 48-to-192 converter supports ordinary
   compatibility playback but cannot restore frequencies already removed by
   48 kHz processing; wideband content must use the native high-rate ring.
3. Updated high-rate scratch capacities and transfer lengths while retaining
   legitimate 48 kHz feedback/AEC boundaries. Merely enlarging DMA buffers
   leaves concrete staging overruns/mismatches in the inferred design.
4. Matching ALSA route, codec clock/rate/slot configuration and actual
   1 ms processing deadlines. Numeric DMA checks alone prove none of these.
5. Real duration/pacing, underrun/overrun, and independent acoustic bandwidth
   qualification. No output header, tap metadata or successful PCM write
   count establishes native-rate acoustic operation.

Evidence files added beside `speaker-constructor.txt`:
`speaker-feedback-block.dis`, `speaker-playback-block.dis`,
`speaker-srcblock-constructor.dis`, `speaker-src-config-entry.dis`, and
`speaker-tdm-dma-size-guards.dis`. The normal SRC pair/filter analysis is in
`frankel-aoc-aspsrc-192-analysis-20260905.md`. No loadable firmware, kernel,
flash image, or phone state was modified by this analysis.
