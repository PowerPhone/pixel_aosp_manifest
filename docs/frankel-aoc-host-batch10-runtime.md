# Frankel AoC D12 host-batch10 overlay

This document describes an **experimental, volatile and build-specific** F1
overlay for `CP2A.260805.005`. It has passed offline RT500 link/byte/transition
tests, but it is not hardware-qualified merely because those tests pass.

The prerequisite is the mono whole-block D12 profile in
`tools/audio/patch_frankel_aoc_d12_wholeblock_mono_192k.py` and its independent
0x3000-byte MIC_US ring. That path produces one real 192-frame S32 mono block
(0x300 bytes) per millisecond. Batch10 keeps every sample but stages ten blocks
before one 0x1e00-byte RingBufferHost cache clean, writer advance and notify:

| Property | Whole-block | Host batch10 | Batch2 overlay |
| --- | ---: | ---: | ---: |
| Physical rate | 192 kHz | 192 kHz | 192 kHz |
| Native block | 192 frames / 0x300 bytes | unchanged | unchanged |
| Input catch-up cap | 4 blocks | unchanged | unchanged |
| Ring commit | 1000/s | 100/s | 500/s |
| Commit quantum | 1 ms / 0x300 | 10 ms / 0x1e00 | 2 ms / 0x600 |
| Host wake threshold | 0x1e00 | 0x1e00 | 0x1e00 |

The callback remains the cap-four `0x403f0c44` implementation. Cap one is not
safe: MIC_US has four native 0xc00-byte blocks and must catch up after producer
notifications coalesce.

## Files and offline verification

- `tools/audio/device/frankel_aoc_d12_host_batch10_192.S` contains exact RT500
  instruction bytes and ABI commentary.
- `tools/audio/device/frankel_aoc_d12_host_batch10_192.ld` fixes every section
  address and rejects cave overflow or moved helper symbols.
- `tools/audio/patch_frankel_aoc_d12_host_batch10_192k.py` is the fail-closed
  live installer/checker.
- `tools/audio/test_patch_frankel_aoc_d12_host_batch10_192k.py` covers linked
  section bytes, decoded call/branch targets, transition cutpoints, injected
  write failures, ring guards and descriptor normalization.
- `tools/audio/patch_frankel_aoc_d12_host_batch2_192k.py` is a reversible,
  two-site overlay on an exact connected batch10 profile. It preserves the
  batch10 implementation so `revert` returns to it without reconstructing the
  whole profile.
- `tools/audio/test_patch_frankel_aoc_d12_host_batch2_192k.py` proves its exact
  aligned writes, profile classification, round trip, and post-reconnect
  requarantine/rollback path.

Run the offline suite before considering a device transaction:

```bash
repo_root=/path/to/pixel_aosp_manifest
cd "$repo_root/tools/audio"
python3 -m unittest -v \
  test_patch_frankel_aoc_d12_host_batch10_192k.py \
  test_patch_frankel_aoc_d12_host_batch2_192k.py \
  test_patch_frankel_aoc_d12_wholeblock_mono_192k.py
```

Set `RT500_TOOLCHAIN_PREFIX` to the executable prefix ending in `-` if the
qualified RT500 toolchain is not at the test's local development default. The
source/linker golden test skips when that toolchain is unavailable; every
other offline test still runs.

## Guarded device actions

These commands write volatile AoC memory. Run them only on the exact qualified
build, with every capture client stopped:

```bash
repo_root=/path/to/pixel_aosp_manifest
cd "$repo_root"
ADB=work/toolchains/platform-tools/adb

python3 tools/audio/patch_frankel_aoc_d12_host_batch10_192k.py \
  check-wholeblock --adb "$ADB" --adb-server-port 5038

python3 tools/audio/patch_frankel_aoc_d12_host_batch10_192k.py \
  apply --adb "$ADB" --adb-server-port 5038

python3 tools/audio/patch_frankel_aoc_d12_host_batch10_192k.py \
  check-batch10 --adb "$ADB" --adb-server-port 5038
```

### Reversible batch2 isolation trial

Two separate batch10 hardware trials each delivered exactly 38,400 frames
(0.2 seconds) without stale-block replay, then wedged the AoC control path.
Batch2 isolates whether the ten-millisecond commit itself causes that failure:
it keeps the same physical input, cap-four callback, output capacity and host
threshold, but commits two blocks at a time. Five 0x600 commits cross the
unchanged 0x1e00 wake threshold.

Starting from the uniformly connected batch10 profile above:

```bash
export FRANKEL_AOC_DIAG_DEVICE=/data/local/tmp/frankel_aoc_diag

python3 tools/audio/patch_frankel_aoc_d12_host_batch2_192k.py \
  check-batch10 --adb "$ADB" --adb-server-port 5038
python3 tools/audio/patch_frankel_aoc_d12_host_batch2_192k.py \
  apply --adb "$ADB" --adb-server-port 5038
python3 tools/audio/patch_frankel_aoc_d12_host_batch2_192k.py \
  check-batch2 --adb "$ADB" --adb-server-port 5038
```

The transition changes exactly two aligned 16-bit words after checking every
complete batch10-owned region:

- `0x403f64b0`: `1c ec` to `0c 6c`, notification bytes `30 << 8` to `6 << 8`.
- `0x403e88be`: `97 10` to `27 10`, the aligned changed portion of the
  instruction at `0x403e88bd`, threshold ten blocks to two.

Both apply and revert make the callback inert, prove a stable closed object,
normalize descriptor and pending state, perform guarded writes, invoke the
reviewed whole-F1 I-cache invalidator, and reconnect cap four only after exact
postflight. To return to the preserved batch10 profile:

```bash
python3 tools/audio/patch_frankel_aoc_d12_host_batch2_192k.py \
  revert --adb "$ADB" --adb-server-port 5038
python3 tools/audio/patch_frankel_aoc_d12_host_batch2_192k.py \
  check-batch10 --adb "$ADB" --adb-server-port 5038
```

On any failure after quarantine, capture-node modes remain `000`. Recovery
rolls instruction bytes back only after independently re-proving an inert,
stable callback, then synchronizes F1 I-cache again. If that proof fails, it
does not perform further instruction writes; audit or reboot before reuse.

`apply` installs A (including the inert callback) while cap four is still
connected, switches the callback table with one aligned 32-bit write, proves
inactive state is stable, installs the remaining code, and reconnects cap four
only after exact postflight. It normalizes the approved inactive 0x180/20
runtime pair to 0x300/10, resets output descriptor totals/cursors to zero, and
clears pending count/base under inert quarantine. A retained sacrificial state
such as writer `0x8a00`, reader `0x7800`, queued `0x1200` is therefore not
silently accepted as a batch boundary.

Revert in the reverse direction:

```bash
python3 tools/audio/patch_frankel_aoc_d12_host_batch10_192k.py \
  revert --adb "$ADB" --adb-server-port 5038
```

The table moves to inert first. The start hook is removed before its helper,
the output tail is removed before A/B/C, and A remains present until cap four
has been restored and another stable inactive interval has elapsed.

For a uniformly installed batch10 profile, `normalize-idle` performs only the
guarded inactive state/descriptor reset transaction. It is useful after an
aborted lab capture, but is not required before each normal reopen because the
per-open start helper clears pending count/base before publishing active state.

## Safety and lifecycle boundary

The installer changes no partition and survives no AoC/device reboot. All
mutating actions chmod every card-0 capture node to `000` before the first AoC
write. Modes are restored only after complete success; interruption or any
unknown byte/state deliberately leaves captures blocked for manual audit or a
reboot.

The per-open helper relies on exact guarded stock context: caller `a14` is
`Fullband+0x800` and caller `a15` is zero. It clears `Fullband+0x814/+0x818`,
executes `MEMW`, then publishes active at `+0x834`. A close after 1..9 ms can
discard that incomplete final batch, but the next open cannot splice it into a
new recording. Applications needing every final millisecond must keep the
stream open long enough to finish a 10 ms batch; there is no close-time flush.

Only p1920's exact `write_size=0x300`, `invocations=10`, and output threshold
`0x1e00` are qualified. A/B/C construct `0x1e00` internally rather than load a
mutable threshold, so a mismatched open cannot turn the cache clean, advance,
or notify into 0x3c00. Such an open remains unsupported and must not be used.

`GetWritePointer` is checked for null. Null drops that one input block without
copying or incrementing pending state, then retries on the next invocation.
The firmware does not have a separate requested-length free-space query: the
profile therefore still assumes the ultrasonic host reader drains normally.
A stalled reader may lose data, and hardware qualification must force a
no-drain case and confirm there is no AoC fault. This overlay is not a durable
flow-control redesign.

Hardware qualification must include more than a rate label: capture for more
than three seconds (the earlier failure froze around 0.403 s), require writer
deltas exactly 0x1e00, no lag-four plateau, no underrun/overrun jitter, and a
Nyquist spectrum with no sharp 24/48 kHz cutoff. Keep factory control
responsive throughout, and retain the tested device state until evidence is
archived.
