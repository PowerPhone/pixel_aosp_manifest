# Frankel PowerPhone 192 kHz qualification

Status: transport-qualified on real Pixel 10 hardware for every exposed
built-in acoustic endpoint. Physical ultrasonic bandwidth remains a separate
external-instrument qualification.

## Exact tested system

- Device: `frankel` (Pixel 10)
- Build fingerprint:
  `google/frankel/frankel:17/CP2A.260805.005/pixel_aosp17_r1:userdebug/test-keys`
- Kernel: `6.6.118-android15-8-g1831c2a45d9b-ab15739706-4k`
- SELinux: enforcing
- Boot certificate: `phase=complete`, PDM ready `1`, speaker ready `1`
- AoC counters before/after the API matrix: restart `0 -> 0`, coredump
  `0 -> 0`
- AoC firmware: exact OEM-signed stock image; the retained unsigned cold image
  is an offline decompilation artifact and is not installed or packaged
- AoC ALSA module SHA-256:
  `398eaca28da2d97431b1398b5df93e34e594389fa691616416354b4705bde4e3`

## Exact packaged-image reflash

The final profile was built, attested, packaged at
`artifacts/frankel/powerphone/`, and flashed to physical slot A with the bundled
`flash-all.sh`. Root `vbmeta` was written with verity and verification disabled.
The cold boot reached `phase=complete` on certification attempt 1 with PDM and
speaker readiness both `1`; primary HAL, PowerPhone HAL, and audioserver were
running under enforcing SELinux. The installed proprietary primary HAL SHA-256
was `30d91d73f466f01be26794d917910304bcdc943f2a77b2e203a8be9e63a40342`.

The post-flash API suite under
`../csr460-powerphone/device-test-results/flashed-fixed-primary192-20260910T1554Z/`
passed nine of ten runs in one continuous matrix. The remaining AAudio MIC2
run transferred all 960,000 frames at reported mono S16/192 kHz with zero
xruns, but missed the suite's strict timestamp-derived-rate threshold. An
immediate eight-second isolated retry under
`../csr460-powerphone/device-test-results/flashed-fixed-primary192-mic2-retry-20260910T1557Z/`
passed: 1,536,000 of 1,536,000 frames, mono S16/192 kHz, zero xruns, derived
191144.132 Hz, and stable AoC restart/coredump counters at 0/0. Thus every one
of the ten endpoint/API combinations has passing evidence on the exact flashed
image, while the evidence is transparently split across the matrix and retry.

Normal Android playback was separately verified under
`../csr460-powerphone/device-test-results/flashed-stock48-to-primary192-retry-20260910T1559Z/`.
An ordinary 48 kHz stereo PCM16 `AudioTrack` played all 384,000 frames in
8.254 seconds with zero underruns. During the run, the selected deep-buffer HAL
stream reported stereo 192 kHz with 1,920-frame periods and the route was the
physical built-in speaker; AudioFlinger supplied the rate conversion. AoC
restart/coredump counters remained 0/0. This verifies that the fixed high-rate
physical transport does not require ordinary apps to request 192 kHz.

The selected F1 speaker table has 46 words: 24 code-cave words followed by 22
hook words. The two existing AudioEntrypoint getters at `0x403f03ac` and
`0x403f03bc` are replaced in place with `a3 ? 192 : 1920`. The retired
vtable redirects and zero-filled getter cave are not selected.

The final boot retains the exact stock A32 allocator. The late, warmed F1
allocation and full four-bank rebase succeed, so
`vendor.powerphone.aoc_a32_allocator.ready=0` is the expected certified
state; A32 current/base worker priority remains 7/7.

## Direct tinyALSA results

### Playback

Both physical output routes used PCM0,D0, stereo S32_LE, 192000 Hz,
`period_size=1920`, `period_count=2`, source 0, a 192-frame firmware
quantum, and a two-slot 12.288 MHz TDM backend. Each run submitted all
4608000 bytes of a three-second WAV:

| Route | Elapsed | XRUN | Startup handling |
| --- | ---: | ---: | --- |
| bottom speaker | 3.4649 s | 0 | one accepted first-boundary EFAULT retry |
| earpiece | 3.5642 s | 0 | five bounded first-boundary EFAULT retries |

AoC generation and restart/coredump counters stayed stable. The amplifiers were
tested independently; no simultaneous-amplifier route is exposed.

### Capture

PCM0,D10 used mono S16_LE, 192000 Hz, `period_size=1920`, and
`period_count=4`. Logical PDM selectors 0, 1, and 2 each returned 568320
frames in 2.960000 seconds. For every file, the continuity validator examined
5856 interior 96-frame blocks and found:

- zero zero-valued second halves;
- zero repeated halves; and
- zero short-lag replayed blocks.

The exact retained WAV files are under
`work/audio-research/frankel/final-inplace-getters-stock-a32-20260905/`.

## Android API matrix

All ten endpoint/API combinations passed on the exact flashed image as
described above. An earlier integrated-system run also completed the matrix in
one contiguous suite:

| Physical/logical route | Java API | Native API | Observed hardware format |
| --- | --- | --- | --- |
| earpiece | AudioTrack | AAudio output | S32 stereo, 192000 Hz |
| bottom speaker | AudioTrack | AAudio output | S32 stereo, 192000 Hz |
| logical microphone 0 | AudioRecord UNPROCESSED | AAudio input | S16 mono, 192000 Hz |
| logical microphone 1 | AudioRecord UNPROCESSED | AAudio input | S16 mono, 192000 Hz |
| logical microphone 2 | AudioRecord UNPROCESSED | AAudio input | S16 mono, 192000 Hz |

Each pass required the exact BUS address and device ID, full frame transfer,
live 192 kHz HAL/hardware geometry, zero framework underrun or HAL xrun, and
stable AoC generation. Evidence is retained in
`work/audio-research/frankel/final-inplace-getters-stock-a32-20260905/api-suite-paired-restart/`;
the final flashed-image evidence paths are listed in the packaged-image section.

After host-owned direct tinyALSA, restart the sidecar and audioserver as a pair:

```sh
stop audioserver
stop vendor.audio-hal-powerphone
start vendor.audio-hal-powerphone
start audioserver
```

Restarting audioserver alone leaves stale sidecar port configurations and can
reject a new stream as already open.

## Nyquist-domain interpretation

Retained D10 spectra contain energy above 48 kHz and a rising 55--90 kHz noise
floor, with no local brick-wall cutoff at 24 or 48 kHz. Together with fresh
quantum checks, the 6.4 MHz PDM profile, wall-time cadence, and direct/API
geometry, this supports a real 192 kHz microphone transport and is consistent
with PDM delta-sigma noise shaping.

This does not independently prove each microphone's acoustic sensitivity or
each speaker's response above 48 kHz. A phone-speaker-to-phone-microphone loop
measures the combined path and cannot assign its rolloff. Per-endpoint
ultrasonic bandwidth still requires a calibrated external wideband source for
the microphones and a calibrated wideband receiver/analyzer for the speakers,
plus a controlled logical-selector-to-enclosure-opening mapping experiment.
