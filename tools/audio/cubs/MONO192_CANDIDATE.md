# Cubs D10 mono192 volatile candidate

This is an **unqualified, mono-only hardware experiment**, not a flash image
or a general audio profile. All addresses were derived from the live Cubs
`15876290-polygon` firmware, extracted into
`work/audio-research/cubs/live-aoc-regions-20260922`. No Frankel firmware
offsets are used. The actual kernel's capture192 admission is a separate
prerequisite; admission alone still produced about48k real frames/second.

Build the instruction manifest (no device operation):

```sh
python3 tools/audio/cubs/build_mono192_manifest.py
```

The builder invokes the recovered Sky1 assembler/linker and emits
`tools/audio/manifests/cubs_d10_mono192_candidate.json`. Its28 entries contain
exact before/after bytes. Inputs are the checked-in assembly/linker script
and the extracted live shared image; there is no hash-based acceptance.

## Frame accounting

| Boundary | Candidate |
| --- | --- |
| Stream2 PDM descriptor | Native rate enum7 |
| Requested native microphone clock | 6.4MHz, up from3.2MHz |
| Native timebase | 192000 instead of96000 |
| PDM DMA half-block | Still96 frames |
| Native callback interval | 19200 timestamp ticks =0.5ms observed in the first trial |
| Mono RAW source/S32 staging block | 96×1×4 =384 bytes |
| Each existing staging plane | 0x300 =768 bytes, unchanged |
| Mono S16 host publication | 96×1×2 =192 bytes per callback |

The physical clock/frequency response has not been established by this
assembly. The requested clock value and enum are not acoustic proof. The
first hardware test must establish real wall-time cadence and spectrum,
then distinguish clock error, filtering, dropped blocks and resampling.

The initial23-region hardware trial reached native Stream2/192000 and
measured19200 timestamp ticks per block (0.5ms), but RAW_ENABLE timed out
after AP_FILT's configuration rejection and the old38400-tick checker
reported repeated irregularity. The27-region v3 admitted enum7 and fixed
that checker, but still captured zero frames and reset AoC. Both are failed
trials, not qualified recordings.

The29-region v4 additionally bypasses the legacy processor inside the RAW
stager, after source-ring release. Its first real capture completed with
875520 mono S16 frames and no AoC reset. The5s tinycap deadline yielded a
4.56s WAV; RAW_ENABLE consumed403864us of that deadline, which starts before
the first pcm_read. The duration check remains failed, not waived. The file
has substantial broadband noise, so neither its header nor its noise alone
establishes correct microphone sampling. A controlled acoustic carrier,
bandwidth and continuity measurements remain required. Evidence is under
`work/audio-research/cubs/mono192-v4-20260922/capture-mic0/`.

The previous27-region source, ELF and manifest are preserved under
`work/audio-research/cubs/mono192-candidate-20260922/pre-stage-return-v3/`.

The current v5 restores the stock HPF-control instruction at `0x4025d1e0`
and guards it unchanged. Its polarity was previously misidentified: stock
passes1 when coefficient programming is skipped,0 when it occurs. The real
v5 trial restored a large+0.7014FS DC offset, but its AC noise above1kHz was
essentially unchanged from v4. Therefore restoring this polarity did not
repair the broadband-noise problem; it mainly changed DC blocking. A20kHz
carrier was detectable with increased source amplitude, but the full
interval was not yet qualified for continuity or bandwidth. Evidence is
under `work/audio-research/cubs/mono192-v5-20260922/duplex20k-bottom-mic0/`.
The29-region v4 is preserved under
`work/audio-research/cubs/mono192-candidate-20260922/pre-hpf-restore-v4/`.

`AudioCapturePdm` is PdmV4 on this device. The native96-frame DMA and direct
fanout are retained; enum7 is admitted by the descriptor validator and the
three native selection sites. Both restart/configuration coercions use7 so
the RAW flag cannot silently force the internal native rate back to6.
The stock timestamp/rate conversion switches already implement enum7.

`APInputProcessor` retains fixed planes at `this+0x224` and `this+0x524`.
The candidate bypasses the conditional software filter and changes48-frame
staging, mono quantization and RAW host publication to96. The RAW-only
return after source release at `0x4027b2cf` avoids the processor at
`this+0x840`; the original non-RAW stager continuation is preserved. The
caller then quantizes the unshifted `this+0x524` plane in place, publishes
S16, and resumes its original counter/notification tail. It does not run
the legacy48-frame SRC/effect chain. AP configuration admits enum7 with the
same active/inactive status semantics as stock enum1/5, but this does not
make ordinary processed AP capture192-capable. Hardware HPF/bypass selection
now retains its original coefficient-dependent logic; no arbitrary hardware
register writes are added.

## Quarantine and cache requirements

Only one physical microphone may be selected; use D10/S16/one channel.
Stop framework, hotword and other capture producers/consumers. This profile
does **not** safely implement stereo/Three, concurrent AP capture or normal
framework audio. Do not restore services while the candidate is active.

Before any mutation, guard every original region, the firmware generation,
the HD dispatch literal and the independently derived Cubs cache primitive.
The wire transport must use runtime-verified Cubs noncacheable aliases.
The A32 domain/page-table constants differ from Frankel.

The new clock literal at `0x4025d054` is a data-cache read, not an instruction.
The temporary HD dispatch literal at `0x402392b4` is another data-cache read.
Both must be made visible to F1; whole I-cache invalidation alone does not
prove either. The46-byte wrapper at `0x4027b240` (entry `0x4027b24c`)
performs targeted DHU/DHI for both lines, then MEMW and the stock whole
I-cache invalidator. Its non-leaf entry reserves32 bytes before CALLX8.
It returns64; require that value, then restore the stock HD dispatch through
the NC alias immediately. Any other value requires a cold reboot, not a
blind retry. First installation must be from a cold boot before RAW capture
has executed the overwritten body. Preserve actual logical40xxxxxx pointers when only
the factory transport address is translated to80xxxxxx.

With all clients quiesced, install `stage_gate` first so its former filter
body is unreachable; install both cave bodies before their hooks. Install
the remaining geometry/admission patches and `stream_rate` last, then
perform coherent instruction-cache invalidation and exact-byte readback.
The clean rollback for this temporary prototype is a cold reboot with all
capture stopped. An in-place restoration would also need a separately
proven final cache operation after restoring the wrapper's own overwritten
body; do not restore services merely because byte readback matches stock.

The descriptor-count trampoline occupies10 bytes of the filter body made
unreachable by `stage_gate`; this is **not** unused stock space. The mono
loop-count trampoline occupies six zero bytes skipped by the preceding
unconditional branch. Both originals are included in the manifest.

The candidate deliberately retains the stock RAW channel bound. Merely
requesting one-channel PCM is insufficient: the selected physical mic mask
must also contain exactly one channel, because the staging stride follows
the producer's selected-mask count.
