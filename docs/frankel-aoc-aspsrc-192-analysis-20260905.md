# Speaker AspSrc 192 kHz analysis — 2026-09-05

Offline analysis of the unchanged `15070001-polygon` AoC container, using
the recovered Sky1 decoder and the valid `regions-complete/` ELF files.
No device changes or SRC execution were performed. This establishes
configuration evidence, **not successful initialization, acoustic operation,
or a flashable 192 kHz release**.

## Two different converters

The speaker's `SrcBlock` constructor (`0x4040fb10`) allocates a 244-byte
`AspSrc` object through `0x7897ca3c`. Its vptr is `0x4036b0e4`; RTTI names
`N7asp_lib6AspSrcE`. Configuration slot `+96` resolves to `0x403ff6fc`.
The speaker's processing wrapper at `0x4040fd78` calls slot `+152`, which
resolves to `0x403ff444`. Both configuration and processing use the callback
at `0x40462ec0`; processing invokes command 9, index `0x100`.

The separate `getSrcMode` routine at `0x40400070` really does assert that
both rates are at most 96000. However, its source string is
`asp_src_iir.cc` (`0x4036b740`), and caller `0x4040029c` is an entry in a
different vtable at `0x4036b69c`, with RTTI `N7asp_lib9AspSrcIIRE`.
The speaker `SrcBlock` call chain above does not use that IIR method.
Removing its assertions is neither necessary nor proposed.

## Explicit 48 ↔ 192 filter plans

The actual speaker converter's rate setter invokes `0x404634a0`, which
accepts 48000, 96000 and 192000 as internal indices 8, 11 and 14.
These are library indices, not Android or kernel rate enums.

More importantly, initialization at `0x40463980` calls the pair selector
`0x404635f0`. That selector obtains a 12-byte plan at
`table + input_index * 180 + output_index * 12`. There are explicit plans
for both directions; ratio four is not merely inferred from independently
accepted rates.

| Rate pair | Normal table address | Stage IDs, before `ff` terminator |
| --- | --- | --- |
| 48 → 96 kHz | `0x40374694` | 1 |
| 96 → 48 kHz | `0x4037488c` | 7 |
| 48 → 192 kHz | `0x403746b8` | 1, 23 |
| 192 → 48 kHz | `0x40374aa8` | 26, 7 |

Normal table base is `0x40374070` (literal `0x4045aa48`). Another table at
`0x403735e0` (literal `0x4045aa44`), selected when library state `+84` is
nonzero, also has both pairs: 28,1,23 and 26,7,28 respectively. The exact
meaning of that alternate selector is not established here.

The stage table is at `0x40374b00`, 24 bytes per entry. Stages 1 and 23
use interpolation size callback `0x4047effc`, with coefficient lengths 84
and 16. Stages 26 and 7 use decimation size callback `0x4047b4f8`, with
lengths 16 and 84. The observed coefficient-pointer, tap-alignment and
frame-rounding checks do not reject these entries or the 48/96/192 block
counts. The block-count setter permits 1–512 frames before initialization
(`0x40462d58..0x40462ea0`). This is positive configuration evidence, but
not an executed initialization or a complete deadline/working-memory proof.

## Private heaps and normal size queries

The speaker passes **3520 bytes** to its upward converter and **4384
bytes** to its downward converter. These are real private-heap capacities:
`0x7897ca87` stores the argument at AspSrc `+88`; calls near
`0x7897cafe..0x7897cb0d` allocate that backing memory and initialize a heap
using the supplied capacity (`0x4040c220`). They are not quality settings.

The heap initializer treats the supplied size as capacity and subtracts
allocator metadata/alignment overhead. No equality-to-a-required-SRC-size
check was found in this path. A larger successfully allocated backing
region can provide additional capacity; it does not change the converter's
filter plan or prove sufficient global RAM.

The normal library interface used by `0x403ff6fc` already queries memory:

| Command / index | Observed purpose |
| --- | --- |
| 2 / 0 | Query API-object size: 2192 bytes; allocated separately from the private heap. |
| 6 / 0 | Query memory-descriptor block size: 80 bytes, allocated from the private heap. |
| 7 / 0 | Register that descriptor block. |
| 4 / 0, 1, 4, 8, 2 | Set input Hz, output Hz, channels, sample format, and input block count. |
| 3 / `0x200` | Compute the configured memory requirements. |
| 8 / 0 | Query memory-table count: four. |
| 16, 17, 18 / table index | Query each table's byte size, alignment and type. |
| 21 / table index | Register the allocated memory. |
| 3 / `0x300` | Final initialization. |

The wrapper allocates only memory tables **0 and 1** via its private heap,
checks returned alignment and checks initialization status
(`0x403ff90a..0x403ff9fe`). Although the library reports four tables,
`0x403ff902` exits the loop when its incremented index reaches two. The
input/output buffers are subsequently registered by the processing method.
An existing allocation smaller than a newly queried size is rejected.
These are internal legitimate library commands, **not a discovered host
CLI or AoC control-service API**.

### Recovered normal-plan memory budget

The channel count is four, not one: `SrcBlock` writes four at local `sp+28`;
the base constructor loads configuration `+8` and stores outer object `+20`
at `0x7897bf90..0x7897bf96`; configuration command 4/index 4 passes that
field to the library's channel count at `+60`.

The normal plans above produce these internal history sizes:

- Interpolation: history words = `tap_count / 2 + 4`, and per-channel stage
  workspace = `4 * history_words + 32 + 24`.
- Decimation: history words = `tap_count + 16`, with the same workspace
  expression. The factor four is explicit `addx4` at `0x40463b4a`.
- Table 0 is the summed per-channel stage workspace times four channels.
- Table 1 is library `+28 + channels * (+24)`. These normal stages set the
  `+28` contribution to zero; `+24` is four times the sum of alternating
  intermediate-buffer frame maxima. For the 192 pairs those maxima are
  96 and 192, so table 1 is `4 * 4 * (96 + 192) = 4608` bytes.

The table formulas are emitted at `0x404630ed..0x40463149`; intermediate
maxima and stage workspace are computed at `0x40463980..0x40463cc6`.

| Normal conversion | Table 0 | Table 1 | Descriptor | Raw private requests | Conservative capacity allowance | Selected candidate capacity |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 48 → 96 | 960 | 2304 | 80 | 3344 | 3520 | Stock 3520 |
| 96 → 48 | 1824 | 2304 | 80 | 4208 | 4384 | Stock 4384 |
| 48 → 192 | 1376 | 4608 | 80 | 6064 | 6240 | 7040 |
| 192 → 48 | 2560 | 4608 | 80 | 7248 | 7424 | 8768 |

For example, upward stage work is
`4 * ((4 * 46 + 32 + 24) + (4 * 12 + 32 + 24)) = 1376` bytes.
Downward work is
`4 * ((4 * 32 + 32 + 24) + (4 * 100 + 32 + 24)) = 2560` bytes.
Both stock capacities minus the independently recovered stock raw requests
equal 176 bytes, providing a useful cross-check.

The allocator review supports treating 176 as a **conservative allowance,
not an exact minimum**. For 8-byte-aligned backing, initialization puts the
first node at backing `+120` and its terminal node at `+capacity-8`, a fixed
128-byte reserve (`0x4040c220..0x4040c288`). Allocation reads the eight-byte
header size from heap `+108`, aligns the returned pointer, rounds requests
to eight, and constructs the next node after the payload
(`0x4040c933..0x4040ca25`). All three requests here are already multiples of
eight. The apparent node overhead is eight bytes per allocation; allowing
sixteen for each of three allocations gives the conservative 176-byte
reserve used above. Exact-fit/minimum-capacity behavior has not been run.

The selected capacities 7040 and 8768 therefore exceed the recovered
normal-plan conservative budgets by 800 and 1344 bytes. This establishes
a bounded local sizing argument, **not global allocation success, alternate
filter-plan sizing, execution deadline margin, or actual SRC initialization**.
In particular it does not approve the complete constructor candidate or any
firmware loading method.

## Bounded review of four proposed constructor bundles

The separate incomplete candidate manifest is
`tools/audio/manifests/frankel-aoc-speaker-192k-constructor-candidate.incomplete.json`.
Its four SRC bundles were independently decoded from the linked analysis ELF,
and their raw section bytes match the following values. This is instruction
semantics review only; it does **not approve execution or the complete
candidate**. The normal-plan sizing argument is bounded above. The assembly source is
`tools/audio/asm/frankel_aoc_speaker_192k_analysis.S`.

| Address | Candidate bytes, memory order | Decoded operations and resulting values |
| --- | --- | --- |
| `0x78972d58` | `7e95455a9b93` | `slli a5,a5,9; slli a6,a6,7`: incoming `a5=375` becomes **192000**, shared by upward output and downward input Hz; incoming `a6=55` becomes **7040**, the selected upward heap capacity. |
| `0x78972d64` | `ce104c82e180` | `movi a12,192; movi a11,48`: upward output/input frame counts **192/48**. |
| `0x78972d94` | `ee27691aeb92` | `movi a14,375; slli a6,a6,6`: incoming `a6=137`, established at `0x78972d7c`, becomes **8768**, the selected downward heap capacity. `a14` is subsequently shifted by seven at `0x78972da6`, retaining **48000** output Hz. |
| `0x78972d9a` | `be104083e180` | `movi a11,192; movi a12,48`: downward input/output frame counts **192/48**. |

The two heap values encode twice their stock capacities; they are not
exact minimums. They supersede the earlier four-times-stock proposal.
FLIX operations in each bundle use their incoming register
values concurrently, and the shared rate value is reused across both
constructor calls. The reviewed original call chain preserves those
caller-window registers. No frame count or Hz value in this table establishes
that allocation, initialization or physical output succeeds.

## Remaining speaker-path limits

Changing these SRC pairs would preserve the 48 kHz processing boundary:
upsampling cannot recover ultrasonic content already removed there.
The native source path must be qualified separately. In high mode its loop
at `0x403d3d1c..0x403d3d43` writes **two selected slots per frame**, not the
entire four-slot output block. Slot indices come from speaker fields
`+0x290/+0x294`; the other slots depend on earlier staging/clearing.

A candidate that changes the physical rate but leaves the downward SRC at
96→48 also retains incorrect feedback timing: `0x403d377d..0x403d3780`
calls the unchanged downconverter against the new physical block. Avoiding
SRC output in a dedicated native playback trial does not fix that feedback
boundary. Any such candidate remains experimental and incomplete.

See [speaker geometry and scratch dependencies](frankel-speaker-192-design-20260905.md)
and [shared TDM/codec constraints](frankel-speaker-192-coordination-20260905.md).
New bounded evidence files beside `speaker-constructor.txt` include
`speaker-aspsrc-process.dis`, `speaker-aspsrc-private-heap.dis`,
`speaker-src-supported-rates.dis`, and `separate-aspsrciir-mode-caller.dis`.
