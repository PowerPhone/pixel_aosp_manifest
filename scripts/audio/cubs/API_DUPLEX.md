# API duplex acoustic reference

`api-duplex-reference.sh` drives the installed `StockPlaybackActivity`. It pairs
**Java AudioRecord UNPROCESSED** at 192 kHz on one exact microphone BUS with
either Java AudioTrack or native AAudio 192 kHz playback. Native AAudio input is
tested separately by the app matrix; this existing activity does not implement
an AAudio-input duplex mode. No APK change is required for these paired runs.

From the manifest repository root, after boot qualification and the API matrix:

```sh
for api in java aaudio; do
  for speaker in bottom top; do
    scripts/audio/cubs/api-duplex-reference.sh \
      --output-dir "work/audio-research/cubs/API-NEW/${api}-${speaker}-mic0" \
      --output-api "$api" --speaker "$speaker" --mic 0 \
      --duration 8 --tone 20731 --peak 0.08 \
      --adb work/toolchains/platform-tools/adb --adb-server-port 5038
  done
done
```

Use the operator's pinned ADB path/serial where applicable. Every output must be
new. Requires the existing microphone runtime permission, already-rooted adbd
for passive profile/generation checks, and the analysis NumPy/SciPy/Matplotlib
environment at `work/toolchains/hf-plot-venv/bin/python`. Override its path with
`POWERPHONE_ANALYSIS_PYTHON`. The script itself never roots, installs, grants
permissions, modifies app-op policy, changes gain/mixers, or restarts services.
Only the diagnostic app is force-stopped before a new trial or on failure.

The harness wakes the device, dismisses keyguard, and checks that the activity
is resumed on an awake device. `KEEP_SCREEN_ON` alone does not wake an asleep
phone; background capture can be framework-silenced after several seconds.
App-op status is recorded, not overridden. Framework silencing and HAL errors,
including route-teardown errors after the tone, fail transport/lifecycle status.

For Cubs, the matrix and duplex harness additionally require an **exclusive-PCM
test precondition**, not a boot warm-up: after wake/dismiss, the real default
KeyguardController must report keyguard/AOD hidden and no keyguard-going-away
transition. The native `/vendor/bin/cubs_powerphone_boot --check-idle` must then
report closed PCMs for at least 500 ms of consecutive observations. Busy samples
or observation gaps over 250 ms restart that interval; the complete preflight is
bounded at five seconds. Keyguard and PCM are checked again at the end. Evidence
and host-monotonic timings are saved under `exclusive-pcm-preflight/`.

This specifically avoids launching the research-only experiment while queued
unlock sounds are still acquiring ordinary playback. It is sampled readiness,
not a hardware lease or support for arbitrary concurrent UI/research playback.
No audio service is stopped, no firmware/property is changed, no HAL error is
filtered out, and previous contention failures remain failures. Receiver-based
overlap tests are separate explicit concurrency experiments.

Media/BUS volume is deliberately unchanged. A low existing volume can place the
tone near microphone noise and make phase analysis unmeasurable; this is not a
reason to relax the gate. Record any operator volume change as a separate trial.
Keep the app foreground throughout the trial. Its capture starts one second
before playback and ends one second after; an additional four-second log tail
catches lifecycle failures.

Artifacts include the original unmodified `capture.wav`, fresh PID/native run
ID, launch command, endpoint/foreground/app-op evidence, passive logs, complete
native report, and `qualification.json`. Tone analysis retains the full detected
active interval, removes only fixed 50-ms boundary fades, and checks duration,
pitch within 1 Hz, zero phase events above 0.35 rad, zero dropouts, no clipping,
and at least 10 dB intended-line contrast. API transport and acoustic outcomes
remain separate, including when waveform evidence passes but teardown fails.

`quiet-noise-ramp.json` and `quiet-psd.csv` use fixed quiet sample coordinates
0.2–0.8 seconds: Hann 16384/8192 Welch, 11.71875-Hz resolution. They compare
48–60 kHz and 84–95 kHz median density. A rising noise floor is compatible with
noise shaping but is not independent proof of microphone acoustic sensitivity
to 96 kHz, a physical clock measurement, or speaker response above 48 kHz.

All tools are Cubs-scoped; Frankel scripts and exact endpoint addresses remain
unchanged. To select another Cubs microphone, use `--mic 1` or `--mic 2`.
