# Frankel D5 real-time period delivery

Experimental kernel integration for the Pixel 10 PowerPhone playback profile.
This directory is not a general AoC driver replacement. Its companion ELF
patcher targets the reviewed Frankel `aoc_alsa_dev_util.ko` layout.

## Why this exists

The installed FMQ960/ALSA192×20 image suffered a real midstream playback
underrun. Hardware traces showed the D5 period callback pending for 29.738 ms
and 26.632 ms in the shared unbound `WQ_HIGHPRI` pool; the callbacks themselves
took 9 microseconds. The complete playback ring holds only 20 ms. That pool
also ran GPU work.

Calling `snd_pcm_period_elapsed()` directly in the mailbox interrupt is not
safe: this device sets `pcm->nonatomic=true`, so the callback takes a sleeping
PCM mutex. The helper instead precreates one dedicated FIFO/95 kthread worker.
Mailbox interrupts still perform the original real AoC-counter accounting,
then queue the original period callback onto that sleepable real-time thread.

Only D5 is redirected. Other PCM devices retain their original workqueue.
There is no synthetic pointer, timer substitution, audio resampling, dropped
write acknowledgement, or automatic underrun recovery.

## Build and integration

From `pixel_aosp_manifest`:

```sh
bash tools/audio/kernel/frankel_d5_period_rt/build-frankel-gki.sh
```

This uses the existing matching GKI DDK under
`work/upstream/frankel-gki-15739706/ddk-workspace`. Build outputs are:

- `work/upstream/frankel-gki-15739706/modules/frankel_d5_period_rt.ko`
- `work/upstream/frankel-gki-15739706/modules/frankel_d5_period_rt.Module.symvers`

The companion `tools/audio/patch_frankel_aoc_d5_rt_period_worker.py` changes the
single period-queue relocation and the util module's flush/destroy imports.
It uses the helper's actual exported ABI versions. The preparation command
below stages those changes, loads the helper before the util, and updates
`modules.dep` without modifying the baseline ramdisk or AOSP-generated files.

Starting with an extracted, pre-RT vendor-kernel ramdisk at an explicit path:

```sh
python3 tools/audio/prepare_frankel_d5_rt_ramdisk.py \
  work/audio-research/frankel/pre-rt-baseline/ramdisk-root \
  work/audio-research/frankel/d5-rt-prepared \
  --helper work/upstream/frankel-gki-15739706/modules/frankel_d5_period_rt.ko \
  --symvers work/upstream/frankel-gki-15739706/modules/frankel_d5_period_rt.Module.symvers

bash tools/audio/repack_frankel_vendor_kernel_boot.sh \
  artifacts/frankel/powerphone-audio192-dev/vendor_kernel_boot.img \
  work/audio-research/frankel/d5-rt-prepared/ramdisk-root \
  work/audio-research/frankel/d5-rt-image
```

The baseline directory and fresh output names in this example are explicit
choices, not automatically discovered inputs. Extract the matching baseline
image with the existing AOSP `unpack_bootimg`, then decompress its sole vendor
ramdisk with `lz4` and `cpio`. Never use an already-RT-patched module as the
preparation baseline. The September 11 playback bundle now contains this RT
addition and is not a pre-RT baseline. The complete ordered extraction/build
procedure is in
[BUILD_PLAYBACK192.md](../../../../scripts/audio/frankel/BUILD_PLAYBACK192.md).
To use the post-sanitization AOSP module instead of the
ramdisk's module, additionally pass:

```sh
--baseline-module work/aosp/vendor/google_devices/frankel/stock-kernel/aoc_alsa_dev_util.ko
```

Preparation produces `ramdisk-root/` for packing, `originals/` outside that
payload, and `preparation.json` recording paths, import changes, preserved
dependencies, and the before/after module-load counts. The packer produces
`vendor_kernel_boot.img`; neither command flashes a device. Keep the current
known bootable images until hardware playback and clean stop/restart qualify
the candidate.

The wrappers extend the original close/reset barriers: private RT work is
flushed before its original workqueue is flushed, and it is flushed and
unbound before that workqueue is destroyed. The original stream container
must never outlive those barriers. The patched util's import dependency
prevents unloading this helper while it can still receive callbacks.

## Hardware diagnostics

The task is named `pp_d5_period`; its expected policy is FIFO/95. Read-only
counters are available in `/sys/module/frankel_d5_period_rt/parameters/`:

- `queued`, `executed`, `busy`: actual private-work dispatch counts.
- `bindings`: D5 stream bindings across open/close cycles.
- `max_queue_ns`: largest observed queue-to-callback delay.
- `max_callback_ns`: largest elapsed callback time, including preemption.

These counters diagnose scheduling only. Real microphone recordings,
speaker-frequency fidelity, sustained playback, and clean lifecycle tests
remain the qualification criteria. This helper is included in the booted
September 11 playback bundle; see the bounded hardware/API results and
retained failures in [the playback report](../../../../docs/frankel-playback192-20260911.md).
