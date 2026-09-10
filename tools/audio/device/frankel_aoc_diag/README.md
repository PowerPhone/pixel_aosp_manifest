# Frankel native AoC diagnostic transport

`frankel_aoc_diag` performs direct AoC memory transactions without spawning a
device-side `dd` reader. It opens `/dev/acd-factory_diag` nonblocking, retries
reads against a monotonic deadline (Frankel's production driver does not
report useful `poll(2)` readiness), bounds and correlates every reply, and
closes the file descriptor on every exit path. This avoids the orphan-reader
failure mode of host scripts built from `adb shell timeout ... dd`.

The helper defaults to core 2 (F1), checks that its real and effective UIDs are
root on `frankel`, and serializes with both native profile helpers through
`/data/vendor/powerphone/.aoc-patch.lock`. The PowerPhone boot integration must
be present: its `post-fs-data` rule creates the `0700 root:root` parent with the
dedicated vendor-data label. The diagnostic helper fails closed if that shared
lock cannot be opened or acquired. It does not stop audio services or decide
whether a memory site is safe to modify. Stop `audioserver` and any other AoC
audio client before using it. Live changes are volatile and normally disappear
when AoC or the phone reboots.

## Build

Stage this directory below an AOSP tree and build the Soong module:

```bash
mkdir -p vendor/csr460/tools/frankel_aoc_diag
rsync -a --delete \
  /path/to/pixel_aosp_manifest/tools/audio/device/frankel_aoc_diag/ \
  vendor/csr460/tools/frankel_aoc_diag/
source build/envsetup.sh
source vendor/google_devices/frankel/cmds-for-envsetup.sh
export USE_STOCK_KERNEL=true
lunch frankel-aosp_current-userdebug
OUT_DIR=out_pixel/frankel m frankel_aoc_diag
```

The binary is written to:

```text
out_pixel/frankel/target/product/frankel/vendor/bin/frankel_aoc_diag
```

## Use

The dump result is printed as one unadorned hexadecimal line so a host script
can parse it directly. Requests up to 64 KiB are accepted and split into
bounded 256-byte AoC commands.

```bash
adb push frankel_aoc_diag /data/local/tmp/
adb shell su 0 /data/local/tmp/frankel_aoc_diag dump 0x403dbc40 32
adb shell su 0 /data/local/tmp/frankel_aoc_diag --core 2 dump 0x403dbc40 32
```

Writes are one-shot 8-, 16-, or 32-bit `CMD_DBG_MEM_SET` operations. Each
write must be naturally aligned and performs an exact guarded pre-read and an
immediate read-back:

```bash
adb shell su 0 /data/local/tmp/frankel_aoc_diag \
  write 8 0x403b75c9 0xbf 0xbf
adb shell su 0 /data/local/tmp/frankel_aoc_diag \
  write 16 0x403dbce2 0x2fb0 0x2fa0
adb shell su 0 /data/local/tmp/frankel_aoc_diag \
  write 32 0x403b84b0 0x0030d400 0x0061a800
```

`write-raw` deliberately sends exactly one `CMD_DBG_MEM_SET` without a
pre-read or read-back. Do not use it as a standalone manual patch command. It
is the low-traffic primitive used by
`patch_frankel_aoc_live_speaker_192k.py --minimal-traffic`, which first guards
the complete profile in grouped reads, writes caves before hooks (and hooks
before caves while reverting), then verifies the complete result in grouped
reads. This avoids exhausting A32's global diagnostic work pool with hundreds
of redundant per-word dump commands while preserving a coherent before/after
guard boundary:

```bash
export FRANKEL_AOC_DIAG_DEVICE=/data/local/tmp/frankel_aoc_diag
python3 tools/audio/patch_frankel_aoc_live_speaker_192k.py apply \
  --profile experimental-enum7-early-q48-tdm24576-192-4xs32-source0 \
  --minimal-traffic
```

Exit status is `0` for success, `64` for invalid command syntax, and `2` for
target, transport, guard, or verification failure.
