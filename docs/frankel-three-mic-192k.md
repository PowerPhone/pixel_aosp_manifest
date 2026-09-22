# Frankel simultaneous three-microphone 192 kHz measurements

Four real-device measurements are complete; originals and analysis are indexed
in [the measurement README](../work/audio-research/frankel/multichannel192-20260916/measurements-v4/README.md).
This is an exclusive direct-ALSA research profile, not three-channel Android
API support or a replacement default boot profile.

The requested experiment records one interleaved PCM16/192,000 Hz WAV from
logical microphones 0, 1, and 2 while playing one physical speaker at a time.
Channel numbers are logical microphone IDs, not established enclosure-hole
labels. Playback uses D5/EP6, stereo PCM32, with the bottom or earpiece
amplifier selected independently. Capture uses D10/EP3 and 1,920-frame periods,
four periods. The WAV includes quiet lead/tail around the complete stimulus.

## Required changes

1. The boot-ready September 12 research image supplies the working native
   192 kHz microphone and speaker paths, cache-maintenance helper, and RT
   playback worker.
2. `tools/audio/patch_frankel_aoc_raw_three_channels.py` changes the matched
   AoC kernel module's raw START/STOP bound from two to three channels. ALSA
   format negotiation already accepted three, but the first real trial was
   rejected at START. The source-equivalent change is `channels > 2` to
   `channels > 3`; the OEM module itself is transformed, not rebuilt from
   unavailable source. Existing playback modifications are retained.
3. The reversible firmware delta in
   `tools/audio/manifests/frankel_d10_three_channel_192k.json` must accompany
   the kernel change. Three channels of 96 S32 samples exceed the existing
   768-byte producer banks and staging planes. The candidate packs the raw
   source into 576 bytes of interleaved S16 and publishes that directly.
   Its assembly and linker script are under `tools/audio/asm/`.
   V4 also skips the unused normal-AP companion destination before it can
   write its equally small bank, and extends the queued RAW-enable check
   to accept channel counts 1 through 3 (still rejecting 0 and 4+).

The kernel extension alone is **not sufficient**. Do not manually request
three-channel D10 against the boot's mono firmware profile. The experiment
wrapper stops all three Android audio services, installs the reviewed delta,
owns both PCM streams, and reverts to the boot's mono profile before restoring
Android audio. It refuses to restore services into an unknown firmware state.

The tested incremental image is
[`kernel-three-channel/image/vendor_kernel_boot.img`](../work/audio-research/frankel/multichannel192-20260916/kernel-three-channel/image/vendor_kernel_boot.img).
The phone already has it installed. To install it again over the matched
September 12 baseline, reboot to bootloader fastboot, confirm `product=frankel`
and the active slot, then flash only that slot's `vendor_kernel_boot` and
reboot. For the tested slot A:

```bash
work/toolchains/platform-tools-37.0.1/platform-tools/fastboot -s 57101FDCR00107 \
  flash vendor_kernel_boot_a \
  work/audio-research/frankel/multichannel192-20260916/kernel-three-channel/image/vendor_kernel_boot.img
work/toolchains/platform-tools-37.0.1/platform-tools/fastboot -s 57101FDCR00107 reboot
```

No userdata wipe or system/vendor image replacement is needed. The original
September 12 `vendor_kernel_boot.img` remains the recovery image. This
incremental image is not a standalone full-install bundle.

## Commands

The host requires Bash, Python 3, NumPy, SciPy, ripgrep, coreutils, and Linux
ADB (use the pinned Platform-Tools 37.0.1 copy). The phone requires root ADB and the current native `frankel_aoc_diag`
helper with `write-raw` support at `/data/local/tmp/frankel_aoc_diag`.
Its build instructions are in `tools/audio/device/frankel_aoc_diag/README.md`.

```bash
export FRANKEL_AUDIO_ADB="$PWD/work/toolchains/platform-tools-37.0.1/platform-tools/adb"
export FRANKEL_AUDIO_ADB_SERVER_PORT=5038
export FRANKEL_AUDIO_SERIAL=57101FDCR00107

# Four trials: CW bottom, CW earpiece, sweep bottom, sweep earpiece.
# Every trial records 34 s containing the 30 s stimulus plus lead/tail.
bash scripts/audio/frankel/three-mic-cw-sweep-suite.sh NEW_OUTPUT_DIRECTORY
```

For one trial with an existing stereo S32/192 kHz stimulus:

```bash
bash scripts/audio/frankel/d5-d10-three-mic-measurement.sh \
  tools/audio/manifests/frankel_d10_three_channel_192k.json \
  STIMULUS.wav NEW_TRIAL_DIRECTORY bottom
```

Each trial retains the original `capture.wav`, `stimulus.wav`, tinyALSA and
playback logs, AoC logs, mixer settings, firmware delta, and restoration
result. A complete WAV and zero reported playback XRUNs establish transport
completion, not acoustic bandwidth or absence of all timing errors. Use
`tools/audio/analyze_frankel_multichannel192.py` for the retained per-channel
waveform evidence; no resampling is applied to the original recordings.

## Real-device history

Evidence root: `work/audio-research/frankel/multichannel192-20260916/`.

- `bringup-v2-bottom`: failed before playback, zero captured frames; kernel
  raw START rejected three channels. Firmware and ordinary audio restored
  successfully; AoC restart/coredump counters stayed at 0/0.
- `kernel-three-channel/image/vendor_kernel_boot.img`: flashed to slot A via
  bootloader fastboot. The phone booted with audio ready, both native profile
  flags set, and AoC counters 0/0. System/vendor/userdata were not replaced.
- The first firmware candidate also exposed an undersized companion normal
  AP ring. Do not reuse the archived v2 delta for another three-channel run.
- `bringup-v3-bottom`: host ADB 36 timed out after transferring the stimulus;
  no capture was attempted. Firmware and services restored successfully.
  The wrapper now transfers before any firmware mutation; subsequent work
  uses the pinned ADB 37.0.1 client.
- `bringup-v3b-bottom`: the kernel started capture, but the firmware's queued
  RAW-enable handler rejected three channels (`AP_FILT` command `0x0070`).
  Zero frames, no playback; restoration succeeded and counters stayed 0/0.
- `bringup-v4-bottom`: 1,144,320 three-channel PCM16 frames (5.96 s), full
  two-second 20 kHz playback, zero reported playback XRUNs, counters 0/0,
  and successful restoration. All three recorded channels are distinct and
  detect the 20 kHz tone. An initial settling/transient interval is retained
  in the recording; the measurement stimulus starts after a two-second lead.

## Completed requested measurements

`measurements-v4/` contains `cw-bottom`, `cw-earpiece`, `sweep-bottom`, and
`sweep-earpiece`. Each original `capture.wav` contains 6,520,320 frames per
channel (33.96 s), covering the full 30 s stimulus with lead/tail. Every run
delivered all 46,080,000 playback bytes, reported zero playback XRUNs, kept
AoC counters at 0/0, and restored the original firmware/mixer/service state.

Both CW runs show 50 kHz on all three channels. The strongest earpiece channel
has no detected phase steps/dropouts over its 29.89 s analyzed interior.
Weaker channels cannot establish clean phase continuity. Both repeated sweeps
show response beyond 48 kHz, tapering toward approximately 60–68 kHz on the
strongest paths. These results do not establish a 96 kHz acoustic response.
Startup transients in approximately the first 0.3 s are retained and reported.

Sweep analysis uses one fixed low-frequency template to determine sample-domain
timing, then applies the same anchor to all channels and repetitions:

```bash
python3 tools/audio/analyze_frankel_multichannel192.py TRIAL/capture.wav \
  --stimulus sweep3 --stimulus-start 2 --stimulus-wav TRIAL/stimulus.wav \
  --output-dir NEW_ANALYSIS_DIRECTORY
```

The final device state is Android booted, both native 192 kHz profile flags
set, all three audio services running, and AoC counters 0/0. The extended
kernel remains installed; the temporary three-channel firmware delta was
reverted, preserving ordinary mono/API behavior between research captures.
