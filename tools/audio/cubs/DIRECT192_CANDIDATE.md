# Cubs direct D5: 192 kHz serial-input experiment

This is an **unqualified, reboot-volatile** variant of the direct96 worker.
The saved `direct96-template-v3-20260923` output remains unchanged. All ordinary
audio clients must stay stopped until a cold reboot; use low-level stimuli
because the direct path bypasses H0, SRC, and speaker protection processing.

The four-slot running-gate hardware trial failed and caused a forced AoC
restart. The newer two-slot path has passed a bounded two-second interval with
the lower-load capture control, but concurrent native192 capture exposed a
worker stack-frame defect. Its targeted correction eliminated the instrumented
refusals in the same-load hardware repeat; waveform analysis is pending.
This is not a qualified image or a promotion of the failed trials.

TI TAS2572 Table 7-40 explicitly supports 192 kHz FSYNC with a 128-bit frame
and 24.576 MHz SBCLK. Its internal playback processing nevertheless decimates
192 kHz input to 96 kHz; serial acceptance does not establish useful acoustic
bandwidth above 48 kHz. See the [TI datasheet, printed page 41](https://e2e.ti.com/cfs-file/__key/communityserver-discussions-components-files/6/074.02572.0001_5F00_TAS2572YCGR_5F00_SPEC.pdf).

The current live TAS driver advertises up to192 kHz, but its sample-rate switch
selects the default tuning block at192. All sample-rate tuning blocks in the
pulled live configuration are empty, so this does not itself establish a codec
register change or rejection. Check the actual detected clock while playing:
`TDM_DET` at book0/page0/register0x14 should have rate code6 and ratio code6
(`value & 0x7f == 0x36`) for192 kHz with four32-bit slots. Do not equate its
driver's default-rate message with the measured bus clock.

The subsequent register audit found **no omitted manual192-kHz setting**:
TAS2572 `0:0:07` is family selection plus gain, not the `TDM_CFG0`/`SAMP_RATE`
register found in other TAS25xx parts. Live`0x08` selects the correct family;
changing its low bits changes gain. The datasheet explicitly warns of aliasing
above40 kHz during its internal96-kHz conversion. No documented control was
found to enable a different192-kHz anti-alias path. The detailed local audit is
`work/audio-research/cubs/tas2572-capability-20260922.md`.

Actual later RAW3/MCPS112 sweeps showed intended content up to48 kHz followed
by a strong descending96-kHz-domain fold toward6 kHz for90-kHz input, on both
speaker endpoints. That is not successful48–90-kHz reproduction or proof of
full-band192-kHz playback. The sweep alone does not identify every contributing
alias mechanism. Do not patch guessed TAS256x rate bits into the TAS2572 or
promote serial-clock acceptance to an acoustic-bandwidth claim.

## Build and geometry

```bash
python3 tools/audio/cubs/build_direct96_manifest.py --speaker-only \
  --sample-rate 192000 \
  --output-dir work/audio-research/cubs/direct192-TEMPLATE-NEW
```

Historical four-slot output (hardware trial failed):
`work/audio-research/cubs/direct192-template-running-gate-v3-20260923/combined-manifest.json`.
The v1 directory contains a failed linker attempt, not a usable manifest.
The earlier v2 template lacks the native-running gate and its first device
trial failed after consuming one40 ms host buffer; retain it as a failed trial.

The output has six speaker-only patches, a zero endpoint literal for the
existing guarded dynamic resolver, and no capture patches. It retains all
direct96 source/ring/reader/geometry guards,48 frames per callback,384 AP input
bytes,768 DMA output bytes and four32-bit slots. Only the physical clock and
callback timing expectations change:24.576 MHz BCLK,0.25 ms cadence,192,000
stereo frames/second. There is no new allocation or resampler. The existing
D5/kernel rate-admission experiment already encodes192 kHz as firmware enum7.

The running-gate revision mirrors the stock AudioEntrypoint worker's
`MEMW; read byte[this+0x34a]`: only a nonzero native running flag permits source
reads. Start method`0x4026592c` publishes1 at`0x40265a26` after setup/reset;
stop method`0x40265ab8` clears it at`0x40265ad0` before cleanup. Stock worker
`0x40265c3c..0x40265c4a` tests this same byte. This prevents consuming host
prefill between EP_SETUP and EP_ENABLE, and emits silence before start/after
stop. Stats word5 (offset20) separately counts not-running callbacks, also
included in empty-block count. No live write to the flag is introduced.

The hardware owner must make the exclusive harness require D5/192000/S32/stereo
and ASP bypass using the manifest rate; the original direct96-only marker check
must not silently admit a mismatched96 kHz input. Apply to a cold boot through
the existing combined cache-coherent transaction, never as a hot update over
the direct96 worker. Cold reboot is the only rollback.

## Exact callback check

At`0x40274258..0x40274270`, firmware computes a32-bit timestamp difference
`delta=now-previous` and accepts `uint32(delta-lower)<7681`. Timestamp frequency
is38.4 MHz. The previous timestamp is updated after the check; the first sample
initializes it without checking. Only active dispatch mode4 runs this check;
silence mode5 does not. DMA completion/ACK calls remain intact.

| Variant | Lower / upper accepted ticks, inclusive | Expected interval |
| --- | --- | --- |
| Stock |34560..42240|1.0 ms ±0.1 ms|
| direct96 |15360..23040|0.5 ms ±0.1 ms|
| direct192 |5760..13440|0.25 ms ±0.1 ms|

The192 variant writes `movi a5,-45` at`0x40274260` and replaces the original
six-byte packet at`0x40274265` with two three-byte scalar instructions:
`slli a5,a5,7; sub a4,a3,a4`. Thus the offset is exactly−5760, not a rounded
immediate. The original width7681 and warning path remain; warnings are not
suppressed. This check measures dispatch intervals, not an independent analog
clock-jitter bound.

## Preceding real direct96 observation

`work/audio-research/cubs/direct96-v2-20260922/duplex30013-bottom-mic0` completed
the two-second stimulus with4,000 consumed48-frame blocks:192,000 stereo
frames, exactly1,536,000 AP bytes. AoC counters stayed0/0. Physical tone analysis
reported30,013.000161 Hz with no interior phase/dropout events. This is bounded
evidence for direct96, not qualification of this192 variant.

The same run retained startup/teardown warnings: H0 empty-source messages
(expected from the bypass but unnecessary work), two speaker interval warnings
at tone boundaries, a further burst after capture closed, and a duplicate
route-unbind error. Aggregate411 geometry refusals fit the startup time before
PCM configuration but do not establish when each happened. Neither logs nor
lifecycle were clean. Cleanup should unbind the speaker once after playback
and avoid replaying an already-Off route from the snapshot; capture can remain
active through its planned tail. Do not hide these warnings or claim a longer
continuity interval from the two-second result.

## Failed four-slot trial and two-slot fallback

`work/audio-research/cubs/direct192-v2-running-gate-20260922/duplex30013-bottom-mic0`
failed. EP_SETUP completed, and EP_ENABLE returned zero at00:47:02.075;
therefore the retained log does not support a deadlock before publication of
the native running flag. Speaker interval warnings followed, then capture-stop
command0x1223 timed out and forced an AoC restart. TAS clock errors were also
present. No full coredump was armed, so the precise stall cause is unresolved.

The separate two-slot prototype reduces callback frequency from4 kHz to2 kHz
and uses the12.288 MHz bit clock already exercised by direct96. It still needs
real hardware qualification; this is not proof that callback load caused the
preceding failure.

```bash
python3 tools/audio/cubs/build_direct96_manifest.py --speaker-only \
  --sample-rate 192000 --slots 2 \
  --output-dir work/audio-research/cubs/direct192-two-slot-TEMPLATE-NEW
```

Prepared two-slot template:
`work/audio-research/cubs/direct192-two-slot-template-v3-20260923/combined-manifest.json`.
The intermediate v1 failed assembly; v2 was superseded before any hardware use.

The nine speaker patches keep the allocated1536-byte TX/RX rings and768-byte
halves. Native AHWSink fields become96 frames and2 slots before slot register
programming; existing byte fields remain768. The direct worker copies96
stereo S32 frames (768 AP bytes) into768 DMA bytes, preserving the low-eight-bit
mask and native running gate. No constructor or heap allocator is invoked.

Native DMA setup requires a coupled correction, not just a slot mask:

- At0x40251b40, admit2 in addition to the existing4/8-slot cases.
- The TX CCR call at0x40251ba8 normally requests `(slots/4)×16` source bytes
  and `slots×4` destination bytes. Only the new two-slot zero-source-length
  case is changed to one8-byte source burst, matching two4-byte destinations.
  The wrapper forwards all six stack arguments and leaves4/8-slot behavior
  unchanged.
- At0x40274b8a, clamp the native `slots−4` RX padding count to zero only for
  two slots. This prevents underflow;96 frames×2 slots×4 bytes still fills
  exactly768 bytes in either direction.

Callback expectation is19200 ticks/0.5 ms, retaining the existing±3840-tick
warning window. Output slots0/1 remain the amplifier inputs; this experiment
does not qualify IV-sense/protection or ordinary HAL coexistence. The hardware
owner must set the kernel TDM channel/slot controls toTwo, inspect actual codec
clock detection, arm a full coredump, and retain reboot-only rollback.

## Concurrent192 capture: isolated stack-frame defect

The actual instrumented v4 worker with clean96 capture consumed4,000 blocks
with zero geometry refusals. Its30,013-Hz stimulus was measured at
30,012.999589 physical Hz, with zero interior phase, dropout or clipping events.
The same worker with native192 capture completed without an AoC restart but
reported668 geometry refusals, all while running and all in the pointer-bounds
bucket. Every other reason bucket stayed zero. The last rejected pointer was
`0xb80aa400`; the waveform failed with7,826 phase events. Preserve these as
different measured outcomes, not a blanket successful192 claim.

The narrow defect is the worker's `ENTRY64`: stack locals at+32/+36/+40 held
ring base, ring end and the cache-invalidation extent, but those addresses lie
inside the windowed CALL8 extra register-save area at the top32 bytes of that
frame. A register-window spill can overwrite them with live registers. The
saved source pointer at+24 remains outside that area, explaining a plausible
source pointer rejected against corrupted bounds. Higher interrupt pressure
changes when the defect manifests; it does not establish a defective clock.
The ABI uses the frame's top, not its bottom, for these extra saves. See
[Espressif's Xtensa ABI stack layout](https://dl.espressif.com/github_assets/espressif/xtensa-isa-doc/releases/download/latest/Xtensa.pdf)
and the [upstream window-overflow handlers](https://android.googlesource.com/kernel/common/+/d3601e56cf64a3f2df6f6380cccb3644274406e2/arch/xtensa/kernel/vectors.S).

Prepared targeted candidate:
`work/audio-research/cubs/direct192-two-slot-template-v5-window-frame-20260923/combined-manifest.json`.
Only the worker's machine-code `ENTRY64` becomes `ENTRY96`; local offsets,
ring guards, all sixteen counters, clocks, DMA geometry and source consumption
are unchanged. The frame now leaves all local words below the extra-save area.
The same native192 capture-load repeat completed without an AoC restart and
reported5,898 callbacks,4,000 consumed blocks,1,898 empty callbacks (1,897 while
not running), and zero geometry refusals in every reason bucket. This controlled
668-to-zero result supports the identified spill-area collision. Full waveform
analysis of this repeat is pending; transport completion alone is not a
continuity qualification.

Evidence directories:

- `work/audio-research/cubs/direct192-two-slot-v2-reasons-20260922/duplex30013-bottom-mic0`
- `work/audio-research/cubs/direct192-two-slot-v3-reasons-native192-20260922/duplex30013-bottom-mic0`
- `work/audio-research/cubs/direct192-two-slot-v4-frame-native192-20260922/duplex30013-bottom-mic0`
