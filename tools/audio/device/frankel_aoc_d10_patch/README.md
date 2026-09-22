# Frankel native D10 192 kHz patch helper

`frankel_aoc_d10_patch` is the device-native, boot-orchestration form of the
qualified volatile patch in
[`patch_frankel_aoc_live_d10_raw_192k.py`](../../patch_frankel_aoc_live_d10_raw_192k.py).
It removes the Python/ADB dependency without changing the 22 reviewed F1 sites,
three incompatible-profile guards, or HD Mic whole-I-cache dispatch. It is
deliberately locked to:

- `ro.product.device=frankel`
- `ro.vendor.build.id=CP2A.260805.005`
- `sys.boot_completed=1` for every ordinary/standalone invocation; the
  init-owned D10 bootstrap may invoke only `apply` with the explicit
  `--allow-incomplete-boot` exception described below
- the caller/init service holds `audioserver` stopped before invoking the
  helper (a vendor domain cannot read the platform-private
  `init.svc.audioserver` property directly)
- ALSA card 0 ID `googleaocsndcar`

The patch is for PCM `0,10` / EP3 strict mono RAW `S16_LE` capture at 192 kHz,
with logical microphone 0, 1, or 2 selected. Changes live only in AoC F1 RAM
and disappear on AoC/device reset.

## Boot contract

Ordinary `apply`, `revert`, `check-stock`, and `check-patched` commands remain
guarded by `sys.boot_completed=1`. The sole early-boot form is
`apply --allow-incomplete-boot`, which exists for
`frankel_powerphone_d10_bootstrap` because that orchestrator deliberately
holds `audioserver` stopped before framework boot can finish. The flag is
rejected for every other action. It bypasses only the boot-completion property
check: root identity, exact device/build identity, card ID, diagnostic nodes,
mixer profile, closed-PCMs quarantine, byte guards, readback, and I-cache
synchronization remain mandatory.

Factory requests use a nonblocking open/write loop with one absolute
two-second deadline. Only a negative `EINTR`, `EAGAIN`, or `EWOULDBLOCK`
result is retried; a positive short write is fatal and is never continued or
resent. Response assembly keeps the same owned nonblocking descriptor for one
absolute five-second deadline, treating `EAGAIN` and a zero-byte read as a
pending reply. Packet size bounds and response correlation remain mandatory,
and the command is never resent while waiting.

The caller must first stop `audioserver`, power down `MIC0`, `MIC1`, `MIC2`
and `US Record Enable`, disconnect every TX input on EP1/EP2/EP3/EP5, and set:

```text
BUILDIN MIC ID CAPTURE LIST = 0|1|2 -1 -1 -1
                            or exact dormant firmware list 0 1 2 -1
BUILTIN MIC Process Mode = Raw
Audio Capture Mic Source = Builtin_MIC
Mic Spatial Module Enable = 0
MIC DC Blocker = 0
HD Mic gain (cB) = 0
INTERNAL_MIC_TX Sample Rate = SR_192K
INTERNAL_MIC_TX Format = S16_LE
INTERNAL_MIC_TX Chan = One
```

The executable reads these controls directly through `libtinyalsa`; it neither
depends on nor executes `tinymix`. During every action it snapshots and chmods
PCM capture nodes D8/D9/D10/D12 to mode `000`, scans every numeric
`/proc/<pid>/fd` as root for existing owners of those exact character devices,
and restores the original modes before exit. Existing mode `000` therefore
remains `000`, which allows an init orchestrator to maintain a wider quarantine.

`apply` sets `vendor.powerphone.pdm.ready=0` before classifying any F1 patch
site. It raises the property to `1` only after all of the following succeed:

1. all patch sites classify uniformly stock or already patched;
2. the reload/frame-count cave is filled before live support sites and the
   Stream-2 enum activation is written last;
3. every 8/16/32-bit naturally aligned write passes an exact source pre-read
   and immediate destination readback;
4. all sites are uniformly patched;
5. the whole F1 I-cache invalidator runs through HD Mic CMD `0x016c`, and its
   temporary dispatch word is restored and read back exactly;
6. the uniform state, stock guards, routes, power state, and closed PCM set are
   re-read; and
7. card 0 is closed and the PCM node modes are restored.

Any `apply` failure leaves readiness at `0`. The init rule that starts the
audio service should therefore depend on
`vendor.powerphone.pdm.ready=1`, not merely helper process exit. `revert`
clears readiness, disconnects activation first, unwinds support in reverse,
and erases the cave last. A failed in-process transition attempts a complete
reverse-order rollback and synchronizes the I-cache again. If the helper
reports an incomplete rollback, lost device, AoC reset, or unknown bytes,
reboot instead of attempting to resume a mixed volatile state.

## Build

Stage this directory beneath the Frankel AOSP source tree (the repository's
generated-device sanitizer normally does this), then build the named vendor
module:

```bash
source build/envsetup.sh
source vendor/google_devices/frankel/cmds-for-envsetup.sh
export USE_STOCK_KERNEL=true
lunch frankel-aosp_current-userdebug
OUT_DIR=out_pixel/frankel m frankel_aoc_d10_patch
```

The module is named `frankel_aoc_d10_patch`, links only `libtinyalsa` in
addition to the platform defaults, and installs as a vendor binary. The source
can be warning-checked outside Soong with an available AOSP host Clang:

```bash
prebuilts/clang/host/linux-x86/clang-r584948b/bin/clang++ \
  -std=c++20 -Wall -Wextra -Werror \
  -Iexternal/tinyalsa/include -fsyntax-only \
  /path/to/frankel_aoc_d10_patch.cpp
```

## Actions and exit status

```bash
frankel_aoc_d10_patch check-stock
frankel_aoc_d10_patch apply
frankel_aoc_d10_patch check-patched
frankel_aoc_d10_patch revert
```

The init bootstrap uses this additional, deliberately narrow form:

```bash
frankel_aoc_d10_patch apply --allow-incomplete-boot
```

Do not use that form for an interactive or post-boot invocation. Omitting the
flag preserves the standalone `sys.boot_completed=1` guard, and supplying it
to `revert` or either check action is a syntax error.

- `0`: requested state was proved; for `apply`, readiness was also read back
  as `1`.
- `2`: identity, runtime guard, transport, classification, write, readback,
  I-cache, cleanup, or readiness failure.
- `64`: invalid command syntax.

The native helper shares `/data/vendor/powerphone/.aoc-patch.lock` with the
speaker helper so their response/debug streams cannot be interleaved. Boot
integration must create `/data/vendor/powerphone` as `0700 root root` during
`post-fs-data`, label it with a vendor PowerPhone data type, and allow the
helper domain to create/open/read/write/lock that one file.

Each dump owns one nonblocking `acd-debug` descriptor from the immediate stale
drain through the correlated factory acknowledgement. The reader tests the
accumulated text after every chunk and returns as soon as the requested address
and length parse, so successful requests pay no fixed quiet-period delay. A
two-second absolute failure deadline and rolling 64 KiB tail tolerate late or
continuous unrelated output without unbounded boot latency; response
correlation and fail-closed parsing remain unchanged.
