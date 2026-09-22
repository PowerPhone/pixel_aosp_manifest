# Frankel PCM source 0 gain

This narrow diagnostic uses the normal HAL tuning character device
`/dev/acd-audio_output_tuning`. Its only address is speaker block 16,
component 0, key 0: the source 0 volume selected by the public kernel's
`aoc_audio_volume_set()`. It has no memory-address or arbitrary-command mode.
Only this known source-0 parameter is supported; the helper intentionally has
no source selector. Successful playback through another PCM does not establish
that its source number is a supported tuning-parameter key.

```sh
frankel_aoc_source_gain          # Read only (default)
frankel_aoc_source_gain set 1000 # Print original, set, verify readback
frankel_aoc_source_gain restore ORIGINAL_VALUE
```

Set/restore accept 0 through 1000, matching the public PCM volume range.
The device open is exclusive; stop the stock audio HAL before accessing
its tuning channel. Each request has a two-second response deadline.
Writes persist until another tuning update or firmware restart. Restore
the printed original value explicitly after an experiment.

The 18-byte packed ABI and command-header initialization come from
`work/upstream/google-modules-aoc-android16/aoc-interface-zuma.h`:
`CMD_AUDIO_OUTPUT_GET_PARAMETER` (211), `CMD_AUDIO_OUTPUT_SET_PARAMETER`
(209), and `AocCmdHdrSet()`. The stock Frankel HAL library's
`AocTuningCommands::GetParameter()` also uses this 18-byte command.

Build in the existing workspace (no Soong rebuild required):

```sh
work/aosp/prebuilts/clang/host/linux-x86/clang-r596125/bin/clang \
  --target=aarch64-linux-android35 \
  --sysroot=work/aosp/out_pixel/frankel/soong/ndk/sysroot \
  -O2 -std=c11 -Wall -Wextra -Werror -fPIE -pie -nostartfiles \
  work/aosp/out_pixel/frankel/soong/.intermediates/bionic/libc/crtbegin_dynamic/android_vendor_arm64_armv9-a_cortex-a76/crtbegin_dynamic.o \
  tools/audio/device/frankel_aoc_source_gain/frankel_aoc_source_gain.c \
  work/aosp/out_pixel/frankel/soong/.intermediates/bionic/libc/crtend_android/android_vendor_arm64_armv9-a_cortex-a76/crtend_android.o \
  -o work/audio-research/frankel/bin/frankel_aoc_source_gain
```

## Standard AoCx speaker-output tap

[`scripts/audio/frankel/aocx-speaker-tap.sh`](../../../../scripts/audio/frankel/aocx-speaker-tap.sh)
records the normal stock AoCx `core 2 / sspk.0` diagnostic tap around an
existing playback command. This is a separate Binder/control-service route,
not the tuning character device above. It does not install firmware, change
sample-rate profiles, write memory, or enable injection.

Required host packages: `bash`, `python3`, `coreutils` (`timeout`),
`util-linux` (`setsid`), `gawk` or `mawk`, `ripgrep`, and Android platform-tools.
Use the existing root ADB server; the wrapper defaults to this workspace's
platform-tools and server port 5038. The wrapper is deliberately pinned to
Frankel vendor build `CP2A.260805.005`, running stock `aocxd`, and the stock
`aocx.IAocx/default` V3 service. All AoCx buffers and `sspk.0` must initially
be idle and unbound. Do not run another AoCx recorder concurrently.

```bash
scripts/audio/frankel/aocx-speaker-tap.sh \
  --output-directory work/audio-research/frankel/NEW-speaker-tap \
  --permissive-capture --timeout-seconds 180 \
  -- YOUR_EXISTING_PLAYBACK_COMMAND ITS_ARGUMENTS
```

The command after `--` remains responsible for its own mixer/service setup
and cleanup. No playback profile or audio endpoint is silently selected.
`--permissive-capture` explicitly allows temporary SELinux permissive mode
because the stock recorder otherwise could not create our diagnostic WAVs;
the original enforcement state is restored in the exit/signal trap. Omit the
flag when an enforcing policy already permits this capture destination.
The trap stops recording and tapout20 IO, disables and unbinds `sspk.0`, and
retains cleanup replies. Interrupted hardware connectivity may prevent
cleanup; inspect the emitted error before another run.
On interruption, the supplied playback command receives TERM and has ten
seconds to finish its own cleanup before its host process group is killed.
Forced termination is reported as a failure; tap and SELinux restoration
then continue without an unbounded wait for that child.

The primary output is `captures/sspk_tapout20.wav`. The output directory
also holds raw Binder replies, decoded replies, the supplied command and its
exit status, and `playback.log`. Capture files on the phone are retained in
the exact `/data/vendor/audio/powerphone-sspk.*` directory recorded in
`run.txt`; nothing is deleted automatically.

### V3 calls and argument order

The script uses these normal methods on `aocx.IAocx/default`. Every numeric
argument below is passed as `i32`, including booleans and `-1` bindings.
The character tag `sspk` is `0x7373706b`, decimal `1936945259`: the tag's
character order is most-significant byte first, even though Binder integer
bytes are serialized little-endian.

| Transaction | Method | Arguments |
| --- | --- | --- |
| 15 | TapInfo | core `2`, tag `1936945259`, tap number `0` |
| 16 | TapEnable | core, tag, tap number, enabled `1` or `0` |
| 18 | ListTapOutBuffers | none |
| 19 | ListInjectBuffers | none |
| 21 | ConnectTap | core, tag, tap number, output buffer `20`, injection buffer `-1` |
| 22 | StartIo | output buffer `20` |
| 23 | StopIo | output buffer `20` |
| 24 | Debug | string-array count, then each string as `s16` |

Unbinding uses transaction 21 with both buffer arguments `-1`. Only output
buffer 20 is enabled. Injection buffers stay disabled and unbound.
[`decode_aocx_service_reply.py`](../../decode_aocx_service_reply.py) decodes
the stock V3 `CommandResult` parcel, rejects Binder errors and nonzero AoCx
status, and preserves text that must also be checked for recorder errors.

The public kernel ABI is in
`work/upstream/google-modules-aoc-android16/aoc-interface-zuma.h`:
`CMD_AOCX_TAP_ENABLE` 202, `CMD_AOCX_TAP_BIND` 203,
`CMD_AOCX_TAP_LIST` 204, and `CMD_AOCX_TAP_INFO` 205. These are commands for
the AoCx control channel, not `/dev/acd-audio_output_tuning`; numeric command
IDs overlap across services. The stock Binder daemon owns that transport.

### Stock recorder parser bug

The stock help advertises `capture start <buffer name> <file>`, but the
shipped `AocxService::handleCapture()` does not implement single-buffer
selection. It treats argument 2 as a filename prefix, ignores subsequent
arguments, and opens `{prefix}_{buffer-name}.wav` for every tapout and
injection buffer. `capture stop` likewise stops every recorder. The correct
invocations for this binary are:

```sh
service call aocx.IAocx/default 24 \
  i32 3 s16 capture s16 start s16 /data/vendor/audio/EXISTING_DIRECTORY/sspk
service call aocx.IAocx/default 24 i32 2 s16 capture s16 stop
```

Opening these recorder files does not itself enable buffer IO or injection.
The wrapper therefore checks that all buffers are idle, enables only
tapout20, and retains the incidental inactive-buffer files as evidence.
Never use the advertised buffer-name syntax: it can report superficially
successful Debug parsing while attempting files with the wrong prefix.

### Interpretation of the real trace

The initial real `sspk192` and `sspk48` captures are retained under
`work/audio-research/frankel/codec-route-live-20260904/`. Both were entirely
zero despite completed playback; the normal source-0 gain read was 1000.
This narrows the problem to data at or before this tap, but does not by
itself prove that the tap represents the final amplifier input or identify
which processing stage muted the signal.

The stock tap advertises 48 kHz / stereo / four bytes per sample / block
length 1920. Its WAV header stayed 48 kHz during the experimental 192 kHz
stream even while the observed frame cadence increased. Do not interpret
the header as a hardware-rate measurement or relabel it as proof of 192 kHz.
The wrapper preserves original bytes and metadata. A nonzero tap would
still require acoustic bandwidth and timing measurements to qualify the
physical speaker path.

The later stock-kernel 48 kHz positive control exposed a second recorder
bug: its four-byte-sample WAV body is not correctly interleaved PCM and
contains an unrecoverable missing half of every packet. The
[stock-48-kHz decoding note](../../../../docs/frankel-aocx-stock48-tap-decoding.md)
documents the supported partial inverse, clean digital 15 kHz references,
and the decoder that preserves missing frames as gaps. Do not infer silence
from a naive FFT of a nonzero stock tap or use its synthetic zero halves as
evidence of transport underruns.
