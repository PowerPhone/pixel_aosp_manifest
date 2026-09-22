# Frankel native volatile AoC speaker patch helper

`frankel_aoc_speaker_patch` is an opt-in, fail-closed Android vendor-native
translation of
[`patch_frankel_aoc_live_speaker_192k.py`](../../patch_frankel_aoc_live_speaker_192k.py).
The native model selects Python profile
`experimental-enum7-q192-tdm12288-192-2xs32-dma-source5`, then replaces both
existing `AudioEntrypoint` quantum getters in place. It selects
EP6/source bitmap bit 5, 192-frame firmware jobs, a 12.288 MHz two-slot S32 TDM
bus, and 1920-frame source pulls. Before connecting those F1 hooks, it creates
one aligned 0x3000-byte live allocation, splits it into four guarded 0xc00-byte
speaker banks, and installs a conditional H0 AMixSPKR geometry hook. The hook
selects 192/1536 only for rate enum 7 with a one-millisecond period; stock
48 kHz/ten-millisecond DeepBuffer remains 480/3840. It
also validates the A32 allocator state, optionally installs its fallback only
through a proven early cache-sync window, and invokes firmware cache
invalidators without changing scheduler state. It is usable only on this
exact target:

- `ro.product.device=frankel`
- `ro.vendor.build.id=CP2A.260805.005`
- `sys.boot_completed=1` (except the bootstrap-only apply flag below)

The source is Apache-2.0 licensed under the repository's top-level `LICENSE`.
This directory contains the complete public source and build description; no
prebuilt binary is authoritative.

## Safety contract

The executable requires real and effective UID 0 and proves the exact ALSA
identity `00-05: EP6 playback (*) :  : playback 1` in
`/proc/asound/pcm`. `/dev/snd/pcmC0D5p` must be a direct character-device
node with the reviewed dynamic device number `116:7`. It then walks every numeric
`/proc/<pid>/fd` directory as root, follows every numeric fd with `fstatat`,
and refuses any fd whose `st_rdev` equals that playback node. A vanished PID
or fd is accepted only when the operation reports `ENOENT`; permission,
directory-read, stat, unexpected-entry, and close errors are fatal because
they make the ownership scan incomplete.

Frankel removes `/proc/asound/card0/pcm5p/sub0/status` while PCM5 is closed.
If the status file exists, its trimmed content must be exactly `closed`; an
`ENOENT` is accepted only together with the exact inventory/node checks and
the complete root fd scan. Those checks are repeated across the 250 ms
preflight and around every
diagnostic operation. The helper has no option to waive any guard. Patch-state
actions also require readable and writable `/dev/acd-factory_diag`, readable
`/dev/acd-debug`, and strict unsigned decimal `restart_count` and
`coredump_count` from
`/sys/devices/platform/9000000.aoc/`. Both counters and PCM closure must remain
stable through a 250 ms preflight and around every diagnostic read and write.

Factory requests use a nonblocking open/write loop with one absolute
two-second deadline. Only a negative `EINTR`, `EAGAIN`, or `EWOULDBLOCK`
result is retried; a positive short write is fatal and is never continued or
resent. Response assembly keeps the same owned nonblocking descriptor for one
absolute five-second deadline, treating `EAGAIN` and a zero-byte read as a
pending reply. A memory dump opens and drains one nonblocking `acd-debug`
descriptor before submitting the command, retains that descriptor across the
correlated acknowledgement, and tests the accumulated text after every new
chunk. It therefore returns as soon as the exact address and length parse,
while an absolute two-second failure deadline tolerates delayed output without
letting continuous unrelated debug traffic extend boot-time patching. A rolling
64 KiB tail bounds noisy output. Packet size bounds and response correlation
remain mandatory, and the command is never resent while waiting.

Before any live mutation, the helper accepts only the aligned allocator word
at `0x400a114c` in exact stock (`002870d0`) or destination (`002825d0`) state.
The optional branch halfword at `0x400a114e` changes `70d0` to `25d0`, redirecting a
failed dynamic 40-byte work-item allocation to the allocator's existing
static-freelist path. It also requires `0x4009e0cc=8efd90bb`, retaining the
stock `UsfTimer` assertion instead of the historical global callback-drop NOP.
The final hardware-proven boot retains this word in its exact stock state:
after Android audio warms AoC, the ordinary F1 allocation succeeds and the
complete four-bank rebase verifies. The fallback may be installed only when
the exact early OUTPUTTER timer/cache-sync transaction is available. An
already-patched allocator is accepted only with this boot's cache-sync
certificate.

For A32 instruction-cache synchronization, the helper requires the exact work
pool pointer `0x40131094 -> 0x40164110`, a nonempty freelist, and no more than
eight current users. Real CP2A.260805.005 boots with the same signed AoC image
have produced two mutually exclusive TMD3743 runtime construction layouts:
owner/context `0x4016df48/0x4016df08` or
`0x4016e048/0x4016e008`. The helper probes both and accepts exactly one
complete match; it does not infer arbitrary shifted addresses. It constrains
the timer address and alignment, then checks its vtable, five-second period,
worker, callback, and layout-specific context fields. It replaces only the
callback with the firmware-native whole-cache invalidator, verifies that the
same owner and timer remain armed, waits seven seconds, and restores and
re-reads the stock callback. Every attempted callback write enters this
inspect-and-restore path; no match, two matches, an unknown object or callback,
or failed restoration is fatal and requires a reboot.

The helper snapshots the exact `UsfDefaultWorker` TCB at `0x401658f8` before
and after the A32 operation. Both current and base priority must be exactly 7.
Raised or mixed priority state is rejected, and neither priority field is ever
written. The timer callback invocation is necessarily timing-inferred; the
seven-second window plus the already hardware-qualified, restart-free speaker
path is the behavioral basis for this boot profile.

The F1 heap transaction temporarily quarantines D12's callback, installs a
reviewed allocator body in its now-unreachable code, flushes F1 I-cache,
redirects exactly one `HD Mic gain (cB)` command, and disconnects that command
before reading its result. The helper accepts exactly one 64-byte-aligned
0x3000 allocation in the reviewed heap range. Standalone apply verifies all
bytes are zero. Boot integration explicitly passes `--skip-zero-validation`
to avoid 192 individual mailbox dumps before the platform watchdog; this skips
only that full scan. Address range/alignment, first and last word
accessibility, exact idle object/ring geometry, and post-commit readback remain
mandatory.
It then publishes capacities before pointers for the two CPU banks and the
SPKR_TX_DMA/SPKR_RX_DMA rings. A second allocation is forbidden because it
restarted F1 on hardware. The allocation pointer in scratch makes an
interrupted pre-commit retry reusable; a partially published object is
reboot-only. Revert cannot free interior bank pointers, so only a cold AoC
reset restores the original allocation/layout.

It reads and classifies all 46 four-byte selected F1 sites. It also proves 32
reachable alternative-profile sites remain stock. An
apply proceeds only from uniformly stock words; a revert proceeds only from
uniformly patched words. An already-uniform destination is a verified no-op.
Mixed state and any unrecognized word are fatal. Every write has an immediate
source pre-read and destination read-back, and the entire table is read again
at the end. A changed or unreadable AoC generation stops the transaction before
another word can be attempted.

Apply fills all 24 code-cave words before it connects any of the 22 hook
words. Eight hook words replace the two existing `AudioEntrypoint` getter
functions in place at `0x403f03ac` and `0x403f03bc`, each implementing
`a3 ? 192 : 1920`. No getter vtable slot or zero cave is selected. Revert
restores every hook in reverse order before it erases caves in reverse order.
If a
process/device failure interrupts a transaction, do not try to resume it:
reboot AoC/the device to restore stock volatile memory, then run `check-stock`.

After an apply or revert reaches and re-reads its complete destination table,
the helper temporarily redirects the `HD Mic gain (cB)` dispatch word to the
reviewed whole-F1 instruction-cache invalidator, invokes that control directly
through `libtinyalsa`, and restores and re-reads the exact stock dispatch word.
Mutation starts by clearing
`vendor.powerphone.aoc_speaker_192k.ready`; only a fully verified apply raises
it to `1`. Revert and every detected mutation failure leave it at `0`.

H0 has no proven diagnostic I-cache invalidator. Its five-word zero cave and
single-word activation hook are therefore written only while the exact idle
q48 speaker object proves that the first speaker Configure has not run in this
boot. The cave preserves the stock multiplier unless `config[18] == 1` and the
rate enum in `config[1].bits[4:2]` is 7. The stock downstream multiplier words
are separately guarded, so a stale legacy unconditional-x4 state is rejected.
Boot integration must call this helper before audioserver or any speaker route
can activate.

Neither the sysfs counter check nor the process-wide PCM ownership scan can be
atomic with a factory-diag memory command. There remains a narrow interval in
which an AoC reset or a new playback open can occur after the last guard and
before a word write. Any detected reset/playback transition, mixed state,
helper failure after the first write, or lost ADB transport therefore requires
a hard AoC/device reboot; never attempt to continue or repair that transaction.

With `POWERPHONE_AUDIO_SIDECAR=true`, this source is copied into generated
vendor and installed as a required dependency of the boot orchestrator. The
orchestrator runs `apply --allow-incomplete-boot --skip-zero-validation` for
the speaker before D10 certification. Real-device boots showed that the full
0x3000 zero scan exceeded the boot watchdog even though AoC stayed healthy, so
this one explicit apply-only exception is required at boot. The factory-mailbox
transaction cannot complete reliably after D10's resident diagnostic profile
is installed.
D10 therefore runs last and its final whole-F1 cache synchronization covers
both profiles. A bounded retry may re-certify the already-selected speaker
state idempotently before retrying D10. `--allow-incomplete-boot` bypasses only
`sys.boot_completed`, and `--skip-zero-validation` bypasses only the full
allocation zero scan. Both are rejected for every other action.

## Build

Place or symlink this directory beneath an AOSP source tree (for example,
`vendor/csr460/tools/frankel_aoc_speaker_patch`), then initialize the target
environment and build the named Soong module:

```bash
source build/envsetup.sh
source vendor/google_devices/frankel/cmds-for-envsetup.sh
export USE_STOCK_KERNEL=true
export OUT_DIR=out_pixel/frankel
lunch frankel-aosp_current-userdebug
m frankel_aoc_speaker_patch frankel_aoc_speaker_patch_host_test
```

The resulting target binary is normally under
`out_pixel/frankel/target/product/frankel/vendor/bin/`. The target module links
`libtinyalsa`; it does not execute `/system/bin/tinymix`. The pure packet,
parser, and state model has a host module too:

```bash
out_pixel/frankel/host/linux-x86/bin/frankel_aoc_speaker_patch_host_test
```

It can also be tested without Soong using any C++20 host compiler:

```bash
clang++ -std=c++20 -Wall -Wextra -Werror \
  patch_model.cpp patch_model_test.cpp -o /tmp/frankel_aoc_speaker_patch_test
/tmp/frankel_aoc_speaker_patch_test
```

The device-only translation unit can also be warning-clean syntax-checked
from the AOSP checkout without linking Android runtime symbols:

```bash
clang++ -std=c++20 -Wall -Wextra -Werror -fsyntax-only \
  -I../../../../external/tinyalsa/include \
  frankel_aoc_speaker_patch.cpp patch_model.cpp
```

## Manual use

Restart adbd as root on the reviewed userdebug build, push the target binary
to a transient path, and invoke it directly while all PCM 0,5/EP6 speaker
playback is stopped. `apply` additionally requires the installed firmware to
be the exact stock CP2A.260805.005 image; it installs the F1 profile and any
eligible guarded allocator change only in reboot-volatile SRAM. This workflow does not
assume that the AOSP image ships a `su` executable:

```bash
adb root
adb wait-for-device
adb push frankel_aoc_speaker_patch /data/local/tmp/
adb shell 'mkdir -p /data/vendor/powerphone && chmod 0700 /data/vendor/powerphone'
adb shell /data/local/tmp/frankel_aoc_speaker_patch check-playback-closed
adb shell /data/local/tmp/frankel_aoc_speaker_patch apply
adb shell /data/local/tmp/frankel_aoc_speaker_patch check-patched
adb shell /data/local/tmp/frankel_aoc_speaker_patch revert  # F1/H0 code only
adb shell /data/local/tmp/frankel_aoc_speaker_patch check-stock
```

`check-playback-closed` is hardware-read-only and does not open either AoC
diagnostic device or inspect AoC memory; like every action it takes the shared
`/data/vendor/powerphone/.aoc-patch.lock`. Boot integration must create the
parent as `0700 root root` during `post-fs-data` and provide its vendor data
label/SELinux access before invoking either native patch helper.
The host runtime uses it as its speaker-closure certifier. Other actions return
zero only after their required uniform state has been proven. `revert` restores
the selected F1 words and the H0 conditional hook/cave, but leaves the current
A32 allocator state and dynamically rebased banks in place. The A32 worker remains at
stock priority 7.
Reboot restores all volatile code, data, and allocation state from the required
stock `aoc.bin`.
Usage errors return 64; guard, transport, state, and verification failures
return 2. Applied changes remain RAM-only and disappear when AoC/the device
reboots.
