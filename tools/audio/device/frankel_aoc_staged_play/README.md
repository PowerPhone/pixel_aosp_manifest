# Frankel staged AoC playback helper

`frankel_aoc_staged_play` controls the AoC playback command ordering required
by Google's upstream `google-modules/aoc` history. Card 0 device 28 needs a live
ASoC route for `HW_PARAMS`.  The DAPM route maps DAI 19 to AoC source 14 for
binding to the speaker sink, while PCM setup and start/stop retain device
number 28.  The helper keeps those namespaces separate and performs this
sequence without closing the frontend PCM:

1. require `TDM_0_RX Mixer US` to already be on;
2. open PCM 0,28, which applies `HW_PARAMS` but not `PREPARE`;
3. issue `PREPARE` with the route bound (the current split-namespace ABI);
4. stream the input, stop playback, unbind the route, and close the PCM.

Device 28 is an MMAP frontend in Google's AoC driver stream-type table. The
helper therefore requests `SNDRV_PCM_ACCESS_MMAP_INTERLEAVED` and transfers
with `pcm_mmap_write()` by default.  `--access rw` remains available as a
diagnostic control; it is not the expected D28 data path.

The automatic ALSA start threshold is all but one configured period,
`period_size * (period_count - 1)`.  For the 512-by-4 configuration this is
three periods: 1536 frames, or 24576 bytes for four-channel S32, matching
AoC's reported D28 watermark.  `--start-threshold FRAMES` overrides it; zero
selects this automatic calculation.

`--prepare-route unbound` retains the older ordering experiment.  It is not
the default because DPCM removes the TDM backend while the route is off, so an
MMAP `PREPARE` cannot complete on the current kernel.

`--rebind-after-prepare` keeps the route bound through `PREPARE`, then toggles
it off and on immediately before transfer.  It is an explicit diagnostic for
refreshing the DAPM source-14-to-speaker binding after PCM endpoint 28 has
been configured.

`--access rw --start-before-write` is the complementary ring-start diagnostic:
it explicitly starts the prepared AoC source before the first RW copy.  This
tests whether the normal copy path's zero writable-ring count is a
producer/consumer start-order deadlock.

For RW playback, the helper issues `SNDRV_PCM_IOCTL_WRITEI_FRAMES` directly
after its initial `pcm_prepare()`. This is intentional: tinyalsa marks the PCM
unprepared after every WRITEI error, which would silently reset the active AoC
stream before a bounded retry. `--rw-efault-retries` (default 32) and
`--rw-efault-sleep-us` (default 1000) control retries of Frankel's transient
full-ring `EFAULT`; the terminal report always includes the actual retry
count. `--post-write-sleep-us` is retained only for explicit timing
experiments and defaults to zero.

An RW ioctl returning status zero is not itself a complete transfer. The
helper now requires `snd_xferi.result` to equal the requested frame count.
A short, zero, negative, or oversized result terminates the stream with an
error; no untransferred tail is silently counted or retried. On both success
and stream failure, `rw_returned_frames` and `rw_returned_bytes` report the
sum of valid frame counts actually returned by successful ioctls, including
a short positive result from the final failed request. The separate
`rw_successful_ioctl_calls` field counts zero-status ioctls, not complete
periods. These are kernel-reported transfer counts, not proof of acoustic
output. Earlier `streamed=...` reports did not inspect this result field and
cannot alone prove that all requested frames were accepted.

The speaker TDM and amplifier controls must be configured separately. The
hardware-qualified native-q192 D0 target is card 0, device 0, stereo S32_LE at
192 kHz, period size 1920, period count two, and start threshold 1920. Each
15,360-byte userspace period is one complete observed D0 physical-ring quantum:

```sh
frankel_aoc_staged_play \
  --card 0 --device 0 \
  --rate 192000 --channels 2 --format s32 \
  --period-size 1920 --period-count 2 --start-threshold 1920 \
  --route-control 'TDM_0_RX Mixer EP1' --access rw \
  /data/local/tmp/chirp-18k-85k-192k-s32-2ch.wav
```

With the one-period-lag `aoc_alsa_dev_util.ko` SHA-256
`37cc7ff81bf9804677699d612621ed75a177597e773709ec54924916811818e6`
and the guarded native-q192 AoC profile active, the 1920x2/1920 configuration
streamed a complete ten-second physical-speaker payload and remained stable
during simultaneous D10 transport. The progress path retains real hardware
mailbox/counter evidence while keeping one physical period of reporting lag;
it does not synthesize consumed bytes. Smaller-period alternatives remain
diagnostics, not qualified defaults.

Pass `--raw FILE` for headerless interleaved PCM, or `--silence-ms N` to stream
generated silence instead of a file. This is a bounded research helper, not a
daemon or an Android audio HAL component.

## Standalone diagnostic build

The result-checked diagnostic can be built without rebuilding the product.
From the manifest repository root, use the existing AOSP compiler, sysroot,
CRT objects, and static tinyalsa archive:

```bash
staged_clang=work/aosp/prebuilts/clang/host/linux-x86/clang-r596125
staged_soong=work/aosp/out_pixel/frankel/soong
staged_variant=android_vendor_arm64_armv9-a_cortex-a76
mkdir -p work/audio-research/frankel/bin
"$staged_clang/bin/clang++" --target=aarch64-linux-android35 \
  --sysroot="$staged_soong/ndk/sysroot" \
  -O2 -std=c++20 -Wall -Wextra -Werror -fPIE -pie \
  -fno-exceptions -fno-rtti -nostartfiles -nostdinc++ -nostdlib++ \
  -isystem "$staged_clang/android_libc++/ndk/aarch64/include/c++/v1" \
  -isystem "$staged_clang/include/c++/v1" \
  -I work/aosp/external/tinyalsa/include \
  "$staged_soong/.intermediates/bionic/libc/crtbegin_dynamic/$staged_variant/crtbegin_dynamic.o" \
  tools/audio/device/frankel_aoc_staged_play/frankel_aoc_staged_play.cpp \
  "$staged_soong/.intermediates/external/tinyalsa/libtinyalsa/${staged_variant}_static/libtinyalsa.a" \
  -Wl,--start-group \
  "$staged_clang/android_libc++/ndk/aarch64/lib/libc++_static.a" \
  "$staged_clang/android_libc++/ndk/aarch64/lib/libc++abi.a" \
  "$staged_clang/runtimes_ndk_cxx/aarch64/libunwind.a" \
  -Wl,--end-group -ldl -lm \
  "$staged_soong/.intermediates/bionic/libc/crtend_android/$staged_variant/crtend_android.o" \
  -o work/audio-research/frankel/bin/frankel_aoc_staged_play-result-checked
```

This links tinyalsa and the C++ runtime statically, but retains Android's
shared Bionic system libraries. It creates a separately named diagnostic
binary and does not replace the device's `/vendor/bin` helper or any flash
image. Building successfully is not a hardware playback qualification.
