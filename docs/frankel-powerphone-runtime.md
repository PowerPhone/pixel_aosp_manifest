# Frankel PowerPhone runtime activation

> **Retired card-1 experiment.** This manual AP-PDM/card-1 activation path is
> preserved only as an experimental record. The supported integration uses
> PCM0,D10 mono S16_LE/192000 with logical mic selectors 0/1/2 and the
> pre-audioserver boot flow in
> [`frankel-powerphone-image-integration.md`](frankel-powerphone-image-integration.md).
> Do not use this runbook to build or qualify the current image.

This runbook controls the raw-PDM 192 kHz research path in an **already booted
integrated Frankel image** and keeps the unqualified speaker path fail-closed.
It does not install a module, start a service, patch a persistent partition,
or enable anything at boot.
[`../scripts/audio/frankel/powerphone-runtime.sh`](../scripts/audio/frankel/powerphone-runtime.sh)
is the executable contract.

The tool is intentionally narrower than a general Android audio debugger. It
accepts only the reviewed AOSP 17 `userdebug` build and exact stock donor:

- product `frankel`, Android 17/API 37, build/incremental
  `CP2A.260805.005/pixel_aosp17_r1`, and the pinned product/system
  fingerprints;
- kernel
  `6.6.118-android15-8-g1831c2a45d9b-ab15739706-4k`;
- AoC card 0 `googleaocsndcar` and loader-owned card 1 `FrankelPDM`;
- the one resident `powerphone_pdm_loader`, the always-registered PowerPhone
  HAL, the exact three card-1 capture nodes 0/2/3, and every immutable raw-PDM
  module parameter; and
- `vendor.powerphone.pdm.topology_ready=1`, with both data-ready properties
  present as exact Boolean `0` or `1`.

It also proves that `frankel_pdm_alsa.ko` is absent from every
`modules.load` file. That distinguishes the research loader's deliberately
resident topology from a normal vendor-DLKM autoload. Runtime provenance still
depends on the integrated image's AVB boundary; this workflow deliberately
does not duplicate the image/package hash attestation.

## Property permission boundary

UID 0 does not bypass Android SELinux property permissions. Every action first
requests root adbd with `adb root`, requires `ro.build.type=userdebug` and
`ro.debuggable=1`, and proves that `su 0 id -Z` enters `u:r:su:s0`. Property,
sysfs, and AoC helper operations then run through `su 0`. AOSP declares this
userdebug-only domain permissive; the script nevertheless reads each property
back and treats a mismatch as failure. It never changes global enforcing mode.

The production design still needs confined resident brokers before either
ready gate can be enabled automatically. This host workflow is only the manual
qualification bridge.

## Create one activation epoch

Stop media, calls, assistants, camera clients, ordinary microphone clients,
and prior tinyALSA probes. Use a new output directory for each PDM activation
epoch. Do not delete it until the matching deactivation has completed: its
JSON file is the write-ahead A32 snapshot required for a guarded revert.

```bash
repo_root=/path/to/pixel_aosp_manifest
cd "$repo_root"

EPOCH=work/audio-research/frankel/runtime-epochs/$(date -u +%Y%m%dT%H%M%SZ)
ADB=work/toolchains/platform-tools/adb

scripts/audio/frankel/powerphone-runtime.sh status \
  --output-dir "$EPOCH" --adb "$ADB" --adb-server-port 5038
```

`status` evaluates PDM and speaker state independently and reports both even
if one fails. `pdm-status` and `speaker-status` are available when a caller
wants only one diagnostic. Status is coherent only in these state pairs:

| Path | Inactive | Active |
| --- | --- | --- |
| PDM | ready `0`, polling/status token `0`, MIC0/1/2 off, guarded A32 idle | ready `1`, polling `1`, consumed status token `0`, MIC0/1/2 on, snapshots `active`/`powered`, exact A32 active proof |
| Speaker | ready `0`; this broker deliberately does not inspect or mutate AoC words | unavailable until the native certifier is live-qualified |

Speaker status requires readiness zero and the transient native helper at
`/data/local/tmp/frankel_aoc_speaker_patch`. Its hardware-read-only
`check-playback-closed` action proves the exact PCM inventory and character
node plus a complete root fd-owner scan without touching AoC memory. The
kernel normally omits the substream-status file while closed; if present, it
must say exactly `closed`. PDM status records all card-1 PCM states. Activation
and deactivation have the stricter closed-PCM guards described below.

## Activate and deactivate raw PDM

Activation coordinates PDM0, PDM2, and PDM3 as one transaction. It never
accepts a subset:

```bash
scripts/audio/frankel/powerphone-runtime.sh pdm-activate \
  --output-dir "$EPOCH" --adb "$ADB" --adb-server-port 5038 \
  --ack-hardware-write
```

The exact dependency order is:

1. require data-ready `0`, polling/status token `0`, MIC0/MIC1/MIC2 all exactly
   scalar-off, and all three card-1 PCMs closed;
2. use the existing guarded A32 helper to prove stock/idle state for
   controllers `0,2,3`;
3. atomically create `$EPOCH/pdm-mic-scalars.json` before the first mixer
   change, power MIC0 then MIC1 then MIC2 with complete readback after each
   write, mark that journal `powered`, and re-prove A32 idle ownership;
4. create `$EPOCH/pdm-a32-0-2-3.json`, perform the coordinated 4.8 MHz A32
   handoff, and prove the exact recorded active state;
5. while polling remains zero, write the one-shot `status_probe=1`. The kernel
   performs exactly one synchronous, non-destructive `+0x10` read per selected
   controller without waking its worker. The script requires
   `status_polls/probe_reads +1/+1` and no change to any FIFO/data counter;
6. re-prove A32 active state and card-1 closure, then set
   `polling_enabled=1`. The kernel consumes the status token back to zero before
   waking the destructive FIFO poller;
7. re-prove card-1 closure and all three scalar-on states once more; and only
   then
8. set and read back `vendor.powerphone.pdm.ready=1`; then, while rollback is
   still armed, re-prove topology/service state, exact A32 active words,
   polling, and readiness. A client that was waiting for the gate may already
   have opened its explicitly addressed card-1 PCM at this point.

The resident kernel poller is the AP FIFO consumer acknowledged to the A32
helper. Before an AudioRecord/AAudio client opens, it discards decimated
frames; after the ready gate opens, the additive HAL can start the selected
card-1 PCM.

Deactivate with the **same** epoch directory after every sidecar capture has
stopped:

```bash
scripts/audio/frankel/powerphone-runtime.sh pdm-deactivate \
  --output-dir "$EPOCH" --adb "$ADB" --adb-server-port 5038 \
  --ack-hardware-write
```

Deactivation first clears and reads back `vendor.powerphone.pdm.ready=0`.
Only then does it wait up to ten seconds for the exact three card-1 PCMs to
close at the HAL's next transfer boundary,
synchronously stop/read back polling, re-prove closure, verify the live A32
state against the epoch snapshot, and guarded-revert all three controllers.
After the final A32 idle proof it clears any unused status token, powers
MIC2/MIC1/MIC0 off in reverse order, verifies all three off, and atomically
marks the scalar journal `reverted`. It never removes microphone power while a
controller or poller may still consume that input.
The loader, module, and card 1 remain resident with polling zero; topology
readiness remains one. A later activation must use a new epoch directory
rather than overwrite the retained audit snapshot.

If the snapshot is absent or already records a clean rollback/revert,
deactivation performs only an A32 idle proof. A mixed, `applying`,
`rollback_failed`, `revert_failed`, malformed, or identity-mismatched snapshot
never authorizes a revert.

## Speaker path is intentionally fail-closed

`speaker-activate` always fails before a property or AoC-memory write. The
older Python writer lacks per-write AoC restart/coredump generation guards and
must not be used as an integrated readiness publisher. Use the native-only
one-shot transaction in
[`frankel-live-qualification.md`](frankel-live-qualification.md) for the first
hardware trial; it leaves the integrated property at zero.

Build and push that reviewed native helper before `speaker-status` or
`speaker-deactivate`, then prove the non-mutating closure guard directly:

```bash
adb push frankel_aoc_speaker_patch /data/local/tmp/
adb shell su 0 /data/local/tmp/frankel_aoc_speaker_patch \
  check-playback-closed
```

The proof requires the exact `audio_ultrasonic` PCM 0,28 inventory identity,
the direct `116:29` character node, and a complete root `/proc/<pid>/fd` scan
with no matching `st_rdev`. Only vanished PID/fd `ENOENT` races are accepted;
an incomplete permission or I/O scan fails closed. The optional procfs
substream-status file, when present, must read exactly `closed`.

```bash
scripts/audio/frankel/powerphone-runtime.sh speaker-activate \
  --output-dir "$EPOCH" --adb "$ADB" --adb-server-port 5038 \
  --ack-hardware-write
```

`speaker-deactivate` is a one-way emergency gate clear. It writes and reads
back readiness zero and proves PCM 0,28 closed, then exits nonzero without
claiming or changing the AoC word state. Reboot, or use the same native helper
that owns a still-live manual transaction, to restore volatile stock words.

```bash
scripts/audio/frankel/powerphone-runtime.sh speaker-deactivate \
  --output-dir "$EPOCH" --adb "$ADB" --adb-server-port 5038 \
  --ack-hardware-write
```

## Failure handling and audit output

The output root has mode-sensitive contents and should not be published. The
A32 snapshot records the attached device identity so that another phone cannot
consume it. Each invocation creates a unique directory like:

```text
EPOCH/
├── .powerphone-runtime.lock
├── pdm-a32-0-2-3.json
├── pdm-mic-scalars.json
└── runs/
    └── 20260830T120000Z-pdm-activate-12345/
        ├── transaction.log
        ├── pre-state.txt
        ├── pre-dmesg.txt
        ├── pdm-apply.txt
        ├── pdm-status-probe-before.txt
        ├── pdm-status-probe-after.txt
        ├── pdm-check-active-after-polling.txt
        ├── post-state.txt
        └── post-dmesg.txt
```

The process holds both a checkout-global host lock and an epoch-local lock for
the full invocation. The global lock prevents different `--output-dir` values
from bypassing serialization; the local lock protects the retained snapshot
and audit tree. These locks do not serialize Android's stock audio HAL, apps,
or someone invoking the low-level helpers directly.

On an interrupted PDM activation it first attempts to prove the ready property
zero, waits for all card-1 PCMs to close, synchronously stops
polling, re-proves closure, and uses only an `active` snapshot for guarded
revert. Only after A32 idle is proved does recovery clear the one-shot status
token, turn all three journal-owned scalar rails off, verify the complete
off-state, and mark their journal reverted. An absent, malformed, or unexpected
scalar journal never authorizes guessing ownership. Speaker actions have no
AoC cleanup branch because this broker never owns a speaker mutation. Cleanup
evidence is in `recovery.txt`. If ready-zero, polling-zero, PCM closure, or
snapshot state cannot be proven, cleanup stops at that dependency boundary and
requests a reboot/manual audit instead of guessing. The top-level transaction
log writer is joined and its failure changes an otherwise successful invocation
into failure.

## Qualification boundary

Successful PDM activation proves the selected software, kernel, ALSA, property,
and A32 state at the script's final bounded observation only. The host process
is not a resident lease broker. Stop clients and clear the PDM gate after any
reset or ownership change; do not treat the manual activation as a durable
certification service. Speaker readiness remains zero. This also does **not**
prove that a microphone records
content above 48 kHz, that either speaker radiates above 48 kHz, or that a
stream is jitter-free. Continue with the endpoint-specific Java/AAudio tests
in [`frankel-audio-api.md`](frankel-audio-api.md), the physical route map in
[`frankel-physical-audio-map.md`](frankel-physical-audio-map.md), and the
calibrated Nyquist/jitter procedure in
[`../scripts/audio/host/README.md`](../scripts/audio/host/README.md). Keep both
paths exactly as tested until their evidence is archived; deactivate PDM and
restore/reboot any manual speaker transaction before changing images.
