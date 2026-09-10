# Frankel speaker rate-only hardware trials — 2026-09-05

The earlier D0/Source-0 192 kHz route is **not acoustically qualified**.
This continuation establishes a real acoustic reference before making a
minimal kernel-rate change. No AoC firmware runtime modifications are applied
in these trials.

## Confirmed reference

The phone booted after a bootloader-fastboot flash of the baseline
`artifacts/frankel/device/vendor_kernel_boot.img` to slot A. The previous
installed kernel and vbmeta were retained under
`work/audio-research/frankel/stock-kernel-reference-20260905/device-before/`.
The existing vbmeta and all other partitions were preserved.

The separate `com.csr460.powerphone.StockPlaybackActivity` exercises public
AudioTrack on the actual built-in speaker and optionally AudioRecord on the
bottom microphone. It does not relax the research application's PowerPhone
BUS-route restrictions. Google audio HAL, PowerPhone HAL and audioserver must
all be running: AudioFlinger otherwise waits for the declared PowerPhone
module. The reference uses 48 kHz PCM16, a finite low-level 15 kHz tone, and
logs actual route, playback head, timestamps and underruns.

The baseline Android trial completed 384,000 playback frames with zero
reported underruns. The physical microphone's 15 kHz component rose from
about −120 dBFS before the tone to −82 dBFS during it. This demonstrates
physical sound, not ultrasonic bandwidth.

Direct ALSA Source 5 / EP6 playback subsequently reproduced the 15 kHz tone
on the microphone at approximately −44 dBFS versus −124 dBFS before playback.
Both services were stopped; the bottom amp used normal PCM ASPRX1, high-rate
input Zero, ultrasonic Disabled, gain 6 and digital volume 817. The explicit
WRITEI-result-checked helper confirmed all 384,000 frames / 1,536,000 bytes
accepted at 48 kHz stereo PCM16, with zero EFAULT retries and zero reported
xruns. This validates the selected physical route at 48 kHz only.

The simultaneous tinycap recording is retained as
`source5-48k-physical-mic.wav.failed-capture-575515`: the timed capture saved
718,080 frames (14.96 seconds), below its wrapper's strict 15-second lower
bound. It was not relabeled as a fully qualified recording. Its retained
samples contain the clear tone-on/tone-off response.

Source 0 remained all-zero in the speaker tap even with clean stock AoC
firmware, the baseline kernel and PCM16. Source 5 produced the expected tone
in the tap. Therefore neither a complete WRITEI count nor a powered codec
alone establishes sound on Source 0.

## Direct rate trial command

The legacy `d0-speaker-control-48k.sh` implementation is exposed under the
more general `speaker-alsa-rate-trial.sh` name. Its default remains 48 kHz.
It supports PCM devices 0, 1, 5 and 23 and explicit frontend/backend rates
48/96/192 kHz. It performs no userspace resampling or firmware rewriting.

```bash
scripts/audio/frankel/speaker-alsa-rate-trial.sh \
  --file /path/to/stereo-192k-pcm16.wav --pcm-device 5 \
  --rate 192000 --backend-rate 192000 --endpoint bottom \
  --amp-gain 6 --asp-mode on --player staged \
  --player-bin /data/local/tmp/frankel_aoc_staged_play-result-checked
```

This is an experimental command, not a claim of 192 kHz acoustic support.
On the baseline driver, a real 192 kHz EP6 attempt failed HW_PARAMS with
EINVAL. The kernel candidate changes only EP6's per-DAI rate mask;
native frontend sample-rate mapping is already present.

## Rate-only candidate: real results

The candidate at `ep6-rate-only/vendor_kernel_boot.img` was flashed through
bootloader fastboot and booted successfully. Existing vbmeta already has
flags 3 (verity and verification disabled); no vbmeta rewrite was necessary.
The candidate changes one rate-mask byte relative to the repository baseline,
not the AoC firmware, clocks, ring accounting or other drivers. Rebuild with
`tools/audio/build_frankel_ep6_rate_only.py` into a new output directory.

| Real trial | Result |
| --- | --- |
| EP6 frontend 192 kHz, backend 48 kHz, 8 s / 15 kHz PCM16 stimulus | Accepted all 1,536,000 frames, zero retries/reported xruns, but approximately 32 s elapsed. Decoded tap tone is **3,750 Hz**, not 15 kHz. |
| EP6 frontend and backend 192 kHz, 2 s / 72 kHz PCM16 stimulus | Accepted all 384,000 frames, but approximately 8 s elapsed. No identifiable 18 kHz shifted tone appeared on the simultaneous 48 kHz physical-mic capture. Kernel logs show no amp PLL-lock event during this trial. Native 72 kHz emission is not demonstrated either. |
| D28 native ultrasonic, 192 kHz, four-channel S32, MMAP, 512×4 / threshold 1536 | Stalled; host deadline expired. The remaining remote player was explicitly killed and both amps/US disabled. No AoC restart. |
| D28 same geometry with RW and an on-device deadline | Four successful writes / 2,048 frames / 32,768 bytes, then EIO. Script cleanup left US and both amps off. No AoC restart. |

The direct wrapper now enforces an on-device playback deadline inside its
remote cleanup shell (`--playback-timeout`, default 45 seconds). An outer host
timeout alone cannot guarantee termination of a remote ADB child; it must be
longer than the on-device deadline plus route setup/cleanup time.

These results do not establish 192 kHz speaker output. In particular the
quarter-speed tone falsifies native-rate playback for the EP6 configuration;
the accepted frame count is not a substitute for a clock measurement.

The actual baseline ELF sends opcode `0xce` (EP_SETUP) with metadata rate
enum 7 for a 192000 Hz request. The legacy public-source fallback to 48 kHz
is therefore **not** the active mapper bug. However, the public AoC
[`SINK`/`SINK2` interface](https://android.googlesource.com/kernel/google-modules/aoc/+/refs/heads/android17-6.18-gs101/aoc-interface-zuma.h)
does not expose a speaker sample-rate field. Public card code changes codec
clock expectations, while the AoC backend lacks corresponding clock/slot
programming callbacks. No supported AoC speaker/serial-clock setter was found
in the reviewed public drivers. Further progress requires such a control,
applicable firmware source with a supported loading path, or an independently
documented AP-owned audio-controller path. More frontend masks alone are not
justified by these results.

The stock AoCx WAV recorder itself corrupts S32 packing and omits half of each
packet. Its narrow evidence decoder retains those omissions as gaps; see
[the decoder findings](frankel-aocx-stock48-tap-decoding.md). No reconstructed
continuous WAV or jitter qualification is claimed.

All local evidence for this continuation lives under
`work/audio-research/frankel/stock-kernel-reference-20260905/`.

## Handoff state

The phone is booted on the EP6 rate-mask-only kernel candidate. Normal Google
audio HAL, the declared PowerPhone HAL, and audioserver are running; SELinux
is Enforcing and the AoC restart counter remains zero for this boot. No
firmware runtime profile was applied. The original pre-trial kernel/vbmeta
backup remains available, and baseline release bundles were not overwritten.

After services finished registering, the final ordinary Android 48 kHz
reference completed all 384,000 playback frames in 7.97 seconds with zero
reported underruns and captured 478,080 frames from the bottom microphone.
The earlier immediate-after-service-start attempt is retained separately as a
failed reference-baseline timeout, not hidden or counted as a pass.
Logs are `final-android-48k-ready.log`; the physical reference is
`final-android-48k-physical-mic.wav`.

No native-192-kHz acoustic success, ultrasonic continuity qualification, or
new verified 192 kHz flash-all bundle is claimed.
