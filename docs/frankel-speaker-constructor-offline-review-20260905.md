# Independent offline constructor-candidate review

## Current proposal: in-place initialization with diagnostics preserved

The current assembly source is
[`frankel_aoc_speaker_192k_analysis.S`](../tools/audio/asm/frankel_aoc_speaker_192k_analysis.S).
Its `.patch.scratch_init` section in the supplied analysis ELF was independently
decoded at its actual address. It is exactly 42 bytes, replacing complete stock
instructions at `0x78972b86..0x78972baf`, and falls through directly to the
unchanged `bnez a5, 0x78972bc2` at `0x78972bb0`. It contains no jump, call,
return, literal load, loop, or new execution entry. No padding is used.

Conclusion: **normal successful construction (`a5 != 0`) has equivalent
control flow and memory effects except the intended two capacity increases**.
The original null-DMA diagnostic arguments are also preserved. This is not
bit-identical register state at `0x78972bb0`: `a14/a15` differ as described
below, but those size temporaries have no additional use in the reviewed
continuation or diagnostic handler.

| State or store | Stock | In-place candidate | Review |
| --- | --- | --- | --- |
| Object `+0x2b4` | 768 bytes | 1,536 bytes | Intended native high-rate staging increase. |
| Object `+0x2b8` | 1,536 bytes | 3,072 bytes | Intended four-channel high-rate staging increase. |
| Object `+0x2bc` | 1,536 bytes | 1,536 bytes | Stored from `a15` before it is doubled. |
| Object vtable; `+0x27c/+0x288/+0x28c/+0x294`; byte `+0x280`; stack `a1+44` | Original initialization | Same values and store order | Preserved. |
| `a14/a15` on exit | `0x300/0x600` | Incoming `a14` / `0xc00` | Unneeded `a14` assignment removed; both overwritten at `0x78972bc2`. |
| `a12` on exit | 107 | 107 | Diagnostic line-number argument preserved. |
| Other general registers | Original values | Same values | No additional general-register clobber in this block. |

The final sequence uses `a15=0x600` for both `+0x2b4` and `+0x2bc`, then
doubles it immediately before writing `+0x2b8`. This removes the stock
`a14=0x300` instruction while retaining `movi a12, 107` within the same
42-byte extent. It needs no code cave and no omitted diagnostic argument.

The only reordered memory operations are the two final size-field stores:
`+0x2bc` now precedes `+0x2b8`. They are distinct, non-overlapping ordinary
constructor fields, and both are initialized before fallthrough; no call,
field read, synchronization or publication occurs between them. Their final
values are the intended ones. This review assumes ordinary construction,
not an unestablished concurrent observer reading a partially constructed
object. The split FLIX operations have no inter-operation dependency that
changes the reviewed initialization when expanded to scalar instructions.

### Null-DMA diagnostic is retained

`a5` is the incoming DMA dependency, not a directly preceding allocation
result: it is loaded from the constructor's incoming stack argument at
`0x78972b27`, saved at stack `+36` at `0x78972b33`, and reloaded at
`0x78972b80`. A non-null value branches over the diagnostic. A null value
falls through to the existing diagnostic for expression `dma`, source
`audio_hardware_sink_speaker.cc`, originally line 107.

The final proposal preserves `movi a12, 107` and all four diagnostic arguments
in caller registers `a10..a13`. The handler resolves to `0x4046205c`, uses a
`%d` line-number field, and has both a returning log path (`retw.n` at
`0x40462079`) and a separate escalation path. It does not consume the incoming
size temporaries in caller `a14/a15`: its corresponding incoming register is
overwritten before use. Thus the final variant preserves the diagnostic
condition, message arguments, handler and selected failure policy. No claim
that this diagnostic is unconditionally fatal is required.

### Scope and status

This supersedes the earlier code-cave proposal below: cave ownership,
redirect/return correctness and out-of-line placement are no longer blockers
for this in-place block. It also supersedes the intermediate in-place variant
that omitted the line-number argument. Local initialization and diagnostic
argument review is complete. Normal-path equivalence
does not establish all possible alternate entries into the changed block,
and does not qualify other constructor/SRC edits, clocking, codec behavior,
timing, firmware loading or physical 192 kHz acoustics. No device operation
or firmware output was performed in this review.

Recommended local status: `normal_success_path_review_complete`,
`diagnostic_arguments_preserved`, and `padding_ownership_not_applicable`.
Whole-mode and hardware qualification remain separate and unverified.

### Superseded intermediate in-place variant

An earlier 42-byte candidate enlarged the same fields but omitted
`movi a12, 107`, leaving an object-derived value in the diagnostic's line
argument. Its successful construction path had no extra dependency on that
value, but its null-DMA diagnostic was not equivalent. That candidate is
retired; this diagnostic caveat does not apply to the current assembly.

## Historical proposal: superseded code cave

The following findings apply only to the retired out-of-line proposal, not
to the current 42-byte replacement. Scope: the audio constructor redirect, 47-byte initialization
fragment, high-rate branch selection, and rate constant. No complete firmware
was produced by this review; no loader, runtime-write mechanism, device
operation or authentication change was used.

### Historical local instruction and state review

The supplied candidate fragments were independently decoded with the
recovered Sky1 decoder and compared with the unchanged constructor.

| Site | Decoded result |
| --- | --- |
| `0x78972b86` | Unconditional jump to `0x7897e2c1`. |
| `0x7897e2c1..0x7897e2ef` | Exactly 47 bytes; last instruction at `0x7897e2ed` jumps to `0x78972bb0`. |
| `0x78972c02` | Unconditional jump to the immediately following bundle at `0x78972c05`, selecting the existing high-rate topology. |
| `0x78972c05` | Bundle sets `a15=192` and retains `a10=32`. |

The redirect starts at the beginning of a six-byte stock FLIX bundle. It
replaces its first three bytes with a complete scalar jump; the remaining
three stock bytes are not reached by ordinary fallthrough. Returning at
`0x78972bb0` skips exactly the initialization reconstructed in the fragment.
This reasoning assumes no independent entry into the displaced block.

The fragment preserves the object-vtable store, stack slot `a1+44`, byte
store at object `+0x280`, and stores at `+0x27c/+0x288/+0x28c/+0x294`.
The intended capacity changes are:

| Object size field | Stock bytes | Candidate bytes |
| --- | ---: | ---: |
| `+0x2b4` | 768 | 1,536 |
| `+0x2b8` | 1,536 | 3,072 |
| `+0x2bc` | 1,536 | 1,536 |

The final `+0x2bc` store uses `a14`, not the enlarged `a15`, correctly
retaining that 48 kHz-domain capacity. All other general-register outputs
match the replaced sequence, except the deliberately changed temporary
`a14/a15` size values. The next normal constructor block overwrites both
at `0x78972bc2`. The intermediate null-pointer diagnostic path should not
be described as having bit-identical unused argument-register contents.
There are no new calls, window-entry/return instructions, literal loads,
or loop instructions in the fragment. The branch offsets decode to their
intended destinations. This is an instruction/state review, not execution
or hardware qualification.

### Historical proposed padding ownership

The stock region follows an empty function whose `retw.n` occupies
`0x7897e2bf..0x7897e2c0`. Zeros continue from `0x7897e2c1` through
`0x7897e2ff`. Two live literal words begin at `0x7897e300/0x7897e304` and
are referenced by the function at `0x7897e308`. The proposed fragment
does not overlap those literals or the neighboring functions.

A byte-alignment-independent scan of the full unchanged container found
no little-endian absolute word into the proposed 47-byte region, using
either its `0x7897...` analysis alias or `0x9897...` mapped alias.
The location is inside the already identified external firmware section,
not an extracted section-table row. Its neighborhood is consistent with
alignment padding, but **unused ownership is not established**.

The scan does not exclude relative branches/literal references, computed
addresses, runtime initialization, reserved data, or an external relocation
consumer. No original linker map, symbols or complete relocation ownership
record is available. Synthetic analysis ELFs lacking relocation sections
are not evidence that the original image has no such references. Whole-image
linear disassembly is also not a reliable absence proof because decoding
can drift across literal pools and padding.

### Why that code-cave manifest remained incomplete

- Padding ownership and absence of alternate entries remain unresolved.
- The forced high-rate branch changes constructor semantics for every board
  predicate outcome; it is not merely a scratch-capacity adjustment.
- The existing SRC configuration and retained 48 kHz feedback boundary still
  need a validated 192-to-48 design. These edits do not supply that missing
  processing support or a qualified native high-rate input route.
- Clock-source/divider, duplex codec configuration, deadlines, firmware
  container integrity/loading requirements and actual acoustics are outside
  this local review. No supported deployment was established here.

For that superseded cave proposal, the recommended status was
`local_instruction_review_complete`, with separate
`padding_ownership_unverified`, `audio_design_incomplete` and
`hardware_unverified` flags. Do not mark the complete candidate
`reviewed-complete`, deployable or 192 kHz-qualified on this evidence.

Local review fragments are retained under
`work/audio-research/frankel/speaker-firmware-decomp-20260905/offline-constructor-review/`.
Their small analysis ELFs have section address zero; the disassembly review
applied the explicit site addresses shown above. They are isolated review
inputs, not a firmware image or installation tool.
