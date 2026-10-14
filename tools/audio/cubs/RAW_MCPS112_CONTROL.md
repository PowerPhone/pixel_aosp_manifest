# Cubs paired RAW MCPS112 scheduling control

This is a reboot-volatile prototype with the bounded hardware results
below, not a qualified image or Android framework profile. It changes only
RAW type2's paired processing-budget deltas from +28/-28 to +112/-112; it
does not change kernel timeouts, return codes, source clocks, geometry,
or other MCPS clients. The vote is not a measured DSP frequency.

## Why this experiment

The first RAW3 run timed out waiting for controller command0x1272 and
triggered an AoC reset. Its real core is retained at
`work/audio-research/cubs/raw3-packed-v1-direct192-20260922/sscd-aoc.bin`.
The coherent AP object has2300 completed callbacks. The actual
`audio_capture2` service region has `tx=0x142980`, exactly2294 blocks of
576 bytes, `rx=0`, and `wp=0x7980` in a92160-byte host ring. Thus firmware
was publishing while the host had not received its start response.
The subsequent controlled MCPS112 trial removed that observed start
failure. Together these support scheduling/control-response starvation
as the explanation, although they do not identify every scheduler or
frequency transition involved.

Separately, the original mono 20731-Hz long-tone capture showed 867 phase
events and a maximum 2.3017-radian step, close to the 2.2965 radians expected
from losing one 96-sample block. Its tone occupied only 29.68 seconds of a
30-second source. A nearly block-commensurate 30013-Hz tone had obscured
this defect. A successful command or benign single-tone phase alone is
therefore insufficient.

## Measured RAW3 results

Evidence root:
`work/audio-research/cubs/raw3-packed-v2-mcps112-20260922/`.
The measured profile was `cubs_d10_raw3_packed_mcps112_control.json`,
combined with the separately guarded direct192 speaker worker using
ENTRY96. Ordinary Android audio remained quarantined.

- `quiet3/`: 560640 three-channel frames, 2.92 seconds from a three-second
  request, no AoC reset. F1 command0x1272 entry, +112 vote, and successful
  reply all appear at logcat time01:39:18.767. No kernel command-latency
  warning above its 10-ms threshold appeared. This is bounded log evidence,
  not a sub-millisecond latency measurement. Stop command0x126a removes112
  and returns the vote to zero.
- `bottom-all-20731-30s/`: 6704640 frames / 34.92 seconds from a 35-second
  capture. Each channel contains the full 30.00-second tone, with 29.90
  seconds analyzed after fixed 50-ms margins at both ends. No internal
  interval was discarded.
- `top-all-20731-30s/`: the same 34.92-second capture duration; all three
  tone intervals span 30.00–30.01 seconds, with 29.90–29.91 seconds analyzed.

Each table row has zero detected phase events above 0.35 radians, zero
amplitude-dropout blocks, and zero clipped samples. Channels are original
interleaved indices; the analysis did not resample or rewrite the WAV.

| Speaker | Channel | Phase-fit frequency (Hz) | Maximum phase step (rad) |
| --- | --- | ---: | ---: |
| Bottom | 0 | 20730.999901 | 0.00561 |
| Bottom | 1 | 20730.999984 | 0.03471 |
| Bottom | 2 | 20730.999728 | 0.15148 |
| Top | 0 | 20730.999513 | 0.09054 |
| Top | 1 | 20730.999960 | 0.00987 |
| Top | 2 | 20730.999899 | 0.00916 |

Metrics are retained under each run's `analysis/channel-N/tone/metrics.json`.
The fixed 80-ms startup deficit remains explicit. These measurements support
correct continuous simultaneous three-channel capture under this load; they
do not independently prove a 96-kHz acoustic passband, distinguish every
electrical-coupling contribution, validate arbitrary concurrent workloads,
or qualify Java/AAudio. The separate mono MCPS112 variant still needs its
own long-run hardware test.

## Processing-budget lesson

Changing PDM timing and sample geometry increases work without automatically
increasing the firmware's rate-independent RAW vote. At 192 kHz, the old
28-MCPS request was inadequate in these observed runs even when ALSA accepted
the rate and firmware kept publishing. Raise only the active RAW client's
budget and remove the same amount on stop; do not replace this with a
permanent boot-time maximum-frequency setting or extend the command timeout
to hide missed deadlines. The paired112 vote passed this tested load, but
its exact physical frequency, energy cost, and headroom under other loads
remain unmeasured. Fresh-boot repetition and long non-block-commensurate
tones remain necessary when changing the profile.

## Scoped implementation

The immutable cost table at40205b50 is unchanged. Windowless hooks at
40279a06 and40279a22 replace only RAW type2's enable/disable deltas.
Other types retain their original table loads. Caves at4027aba4 and
4027abb0 occupy old processor code made unreachable by the existing
RAW direct return. No stack locals, allocations, or new calls are added.
The obsolete inherited `raw_bytes` write overlaps that unused area and
is omitted from these two variants. The applier installs both cave
bodies and the RAW return before either vote hook; Stream2 activation
remains last, followed by the existing coherent cache synchronization.

Build the actual ISA payloads without changing either baseline manifest:

```sh
python3 tools/audio/cubs/build_raw_mcps112_control.py \
  --base tools/audio/manifests/cubs_d10_raw3_packed_candidate.json \
  --manifest tools/audio/manifests/cubs_d10_raw3_packed_mcps112_control.json \
  --output-dir work/audio-research/cubs/raw3-mcps112-control-20260923

python3 tools/audio/cubs/build_raw_mcps112_control.py \
  --base tools/audio/manifests/cubs_d10_native192_edge0_control.json \
  --manifest tools/audio/manifests/cubs_d10_native192_edge0_mcps112_control.json \
  --output-dir work/audio-research/cubs/mono192-edge0-mcps112-control-20260923
```

On a fresh boot, explicitly select the appropriate manifest with
`apply_mono192_candidate.py --manifest ...`; this argument is mandatory,
and no historical profile is silently selected. RAW3 still requires
the widened kernel admission and current-boot provenance described in
[RAW3_PACKED_CANDIDATE.md](RAW3_PACKED_CANDIDATE.md), plus its success-only
four-line RAW3 capability marker. Mono retains its original admission
and marker behavior. Optional speaker manifests remain separate.

For subsequent trials, retain all start/stop logs and check that the RAW
vote adds112 and subsequently removes112. Repeat short quiet capture
before a long non-block-commensurate tone whenever the profile changes.
Preserve any command, continuity, or reset failure; the successful runs
above do not supersede failures from different profiles.
