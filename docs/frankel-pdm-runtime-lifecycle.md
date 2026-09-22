# Frankel raw-PDM runtime lifecycle design

> **Retired card-1 design.** The AP-PDM module and card-1 S32 routes described
> below are not part of the current PowerPhone image. Live hardware qualified
> PCM0,D10 mono S16_LE/192000 instead; see
> [`frankel-powerphone-image-integration.md`](frankel-powerphone-image-integration.md).
> This file remains only as historical design evidence.

Status: **design only; deliberately not enabled**. The first guarded PDM0 AP
permission trial has not supplied the live evidence required by this design.
Nothing in this document changes PDM hardware, enables FIFO polling, or claims
working `AudioRecord`/AAudio capture.

This document defines the smallest fail-closed bridge from the existing inert
Frankel pieces to an application-usable capture path:

- `frankel_pdm_alsa.ko` maps physical PDM0/PDM2/PDM3 and exposes card 1,
  devices 0/2/3, but performs no read until the synchronous `status_probe=1`;
  that operation reads only FIFO status `+0x10`, and destructive polling is
  impossible until its single-use proof is consumed;
- `powerphone_pdm_loader` currently proves only the module/card topology,
  leaves polling at zero, and publishes only
  `vendor.powerphone.pdm.topology_ready`; and
- the always-registered sidecar advertises three addressed `IN_BUS` mono
  S32_LE/192000 routes but has no ownership,
  microphone-power, A32-handoff, or polling lifecycle.

The current image therefore has a valid *inert topology*, not a source of
samples. Do not work around that gap with an init property race, an unattended
shell command, or an unconditional MMIO sequence.

## Safety invariants

The runtime implementation must preserve all of these invariants.

1. The only selected physical controllers are PDM0, PDM2, and PDM3. They use
   one shared clock and must be applied and reverted as the exact coordinated
   set `0,2,3`; a second controller must never be added to a live transaction.
2. The A32 factory-diagnostic path is the only writer of clock, reset, and PDM
   configuration. The AP kernel module remains read-only MMIO. Neither side
   maps the out-of-DT clock range.
3. A32 apply cannot begin until the AP consumer is mapped and waiting with
   polling exactly zero. AP polling cannot become one until A32 apply and its
   exact active-state verification finish.
4. Cleanup is ordered: close/reap every card-1 PCM, synchronously set and prove
   polling zero, verify the exact active A32 snapshot, revert A32, then power
   off the three scalar microphone controls. The mapped module remains loaded
   for the sidecar topology; it must not be unloaded as an error shortcut.
5. Any uncertainty stops dependent cleanup. In particular, unproven polling
   stop forbids A32 writes; an A32 snapshot mismatch forbids A32 revert and
   microphone power-off. The system instead latches a fault with the sidecar
   stopped and the module's suspend veto still active.
6. The daemon never accesses `MIC3`, `BUILDIN MIC POWER STATE`, or
   `BUILDIN_MIC_POWER_INIT`. It uses only the independent scalar controls
   `MIC0`, `MIC1`, and `MIC2`, with scalar type/count validation and readback.
7. Card-0 capture, an active A32 PDM handle, a changed shared gate/divider, a
   nonzero controller IRQ-enable register, or an unknown journal owner is a
   competing owner. Acquisition fails rather than preempting it.
8. A stream open, a 192000 client format, and a nominal frame count are not
   physical-bandwidth or continuity evidence. Promotion still requires the
   acoustic and pilot tests in `frankel-audio-api.md`.

## Canonical implementation inputs

Do not independently rediscover or silently simplify the hardware sequence.
The native broker must be checked against these tracked sources as part of
every build:

- `tools/audio/frankel_a32_raw_pdm.py` owns A32 identity, ownership, clock,
  reset, controller, snapshot, transaction, apply, and revert rules;
- `tools/audio/aoc_factory_diag.py` owns the factory-diagnostic packet and
  response transport;
- `scripts/audio/frankel/raw-pdm-capture.sh` owns the cross-component ordering,
  scalar-power constraints, polling stop proof, and cleanup dependency rules;
  and
- `tools/audio/kernel/frankel_pdm_alsa/frankel_pdm_alsa.c` owns the only AP
  MMIO reads, PCM contract, CIC implementation, counters, and synchronous
  polling stop.

At minimum, a compile-time/generated-constant audit must match: device
`frankel`, vendor build `CP2A.260805.005`, A32 core 1, handle-list head
`0x40130e88`, controller base `0x81c0a000` with stride `0x1000`, controller
set 0/2/3, AP projection `0x0ac0a000`, parent 38.4 MHz, divider 12 to 8,
PDM 4.8 MHz, RFactor/CIC decimation 25, controller watermark 150, and card 1
devices 0/2/3 at mono S32_LE/192000. The qualified runtime PCM geometry starts
from the wrapper's 19200-frame periods and four-period buffer; changing it is
a measured scheduling experiment, not a lifecycle fix.

The A32 address/offset allowlists, bit masks, and exact full-word guards remain
canonical in the Python helper. In particular, the broker must retain the
helper's inspection of all five controller idle states, selected-controller
full active map, and complete original word map. Unit tests should compare a
machine-readable native manifest with the Python constants so review cannot
miss drift. The runtime design does not make a third editable copy of every
address.

## One owner and one synchronous lease API

Evolve the current root loader into one boot-scoped **PDM lifecycle broker**.
It remains the sole module loader and readiness-property owner and adds a
small vendor Binder interface used only by the PowerPhone HAL. Do not grant
the audioserver-domain HAL direct access to factory diagnostic devices,
microphone mixer controls, or writable module parameters.

The interface needs only these concepts:

- `acquire(endpoint, clientToken)`: idempotently acquire PDM0, PDM2, or PDM3.
  The first lease performs the global activation transaction and returns only
  after polling reads back one. Later leases join the already active group.
- `release(clientToken)`: release after that stream's ALSA PCM has been closed.
  The last lease performs the global cleanup transaction and returns only
  after the exact idle state and all three scalar controls read back off.
- `getState()`: read-only diagnostics containing the state, fault reason,
  lease endpoints, journal generation, and counter deltas.

The server must accept only UID `audioserver` in the expected HAL SELinux
domain. A caller-owned Binder token gives the broker a death recipient; token
reuse for another endpoint is rejected. All transitions are serialized.

The HAL calls `acquire` before it makes an ALSA device profile available to
the stream worker. It holds the lease for the whole stream-object lifetime.
On close it must first stop and close tinyalsa through the normal stream
teardown, prove the matching `/proc/asound/card1/pcmNc/sub0/status` is
`closed`, and only then call `release`. Repeated `setConnectedDevices` calls
must not create duplicate leases. A route change after acquisition is rejected
instead of silently moving one token between physical controllers.

The exact `StreamAlsa` close ordering must be confirmed in the pinned AOSP
source and with instrumentation before this hook is implemented. If
`defaultOnClose()` does not guarantee that the PCM file descriptor is closed
before it returns, add an explicit post-close callback at the owning worker;
do not approximate ordering with a delay.

Properties remain boot/service gates, not a stream-control protocol.
`vendor.powerphone.pdm.ready=1` means the broker, inert module topology, and
lease RPC are healthy enough for the sidecar to run. A Binder transaction
returns stream activation success or failure synchronously. A second
read-only property may expose a coarse runtime state for diagnostics, but it
must not trigger hardware writes.

## Why activation is a three-controller group

The 38.4 MHz parent, divider, gate, and reset block are shared. Adding PDM2 or
PDM3 after PDM0 is already producing would require changing shared state under
an active stream. Instead, the first lease:

- powers all three proven scalar microphone controls;
- applies A32 controllers `0,2,3` in one transaction;
- enables one polling worker over immutable mask `0x0d`; and
- continuously drains and decimates all three FIFOs.

Only leased PCMs receive frames. Frames for the other two closed PCMs remain
deliberately discarded, as the current module already specifies. This costs
the full three-controller polling load, but it permits any later combination
of PDM0/PDM2/PDM3 without perturbing an existing stream. It also makes one
global first-lease/last-release transaction sufficient.

Powering or applying only the first requested controller is not an acceptable
optimization until there is a separately reviewed, non-disruptive shared
clock transition. A single-PDM0 pass therefore does not authorize this group
mode; all-controller qualification is a later mandatory gate.

## State machine

```text
BOOTSTRAP
   | exact kernel/card/module validation; polling=0; A32 idle; scalars off
   v
TOPOLOGY_IDLE <----------------------------+
   | first acquire                         | successful last-release cleanup
   v                                       |
ACTIVATING ------------------------------> ACTIVE
   | journal/power/apply/polling failure      | additional acquire/release
   |                                          | last release after PCM close
   +--> FAULT_QUIESCED <--- synchronous ------+
             |              polling-off proved
             | exact same-boot journal recovery succeeds
             +-------------------------------> TOPOLOGY_IDLE
             |
             | polling stop, ownership, journal, or restore cannot be proved
             v
        FAULT_LATCHED -- manual audited recovery or reboot only
```

`QUIESCING` is a serialized transition between `ACTIVE` and
`TOPOLOGY_IDLE`; no acquire is accepted during it. `RECOVERING` is a
boot-scoped transition entered after a broker crash when an exact journal and
kernel owner cookie are present. They are represented separately in logs even
though the diagram folds them into the fault path.

### BOOTSTRAP to TOPOLOGY_IDLE

Retain the current loader's exact gates:

- kernel release
  `6.6.118-android15-8-g1831c2a45d9b-ab15739706-4k`;
- card 0 ID `googleaocsndcar`, no preexisting card 1, and no preexisting raw
  module without a same-boot ownership record;
- module parameters `map_controllers=1`,
  `projection_ack=0x0ac0a000`, `controller_mask=0x0d`, CIC3, provisional
  chronology bits all zero, `status_probe=0`, and `polling_enabled=0`;
- exact card-1 devices 0/2/3 and exact mono S32_LE/192000 constraints; and
- zero stats on a newly loaded module.

Then run the native read-only equivalent of A32 `check-idle --controllers
0,2,3` and prove scalar `MIC0`, `MIC1`, and `MIC2` all read off. Only then set
readiness to one. The sidecar process is already registered from the HAL boot
class; the property only unblocks new capture streams. The existing mapped
module vetoes system suspend even in `TOPOLOGY_IDLE`; that is an explicit cost
of this research image, not a readiness failure.

### TOPOLOGY_IDLE to ACTIVE

For the first lease, perform this exact ordered transaction:

1. Revalidate immutable module/card topology and `polling_enabled=0`. Record
   the lifetime module-stat baseline without touching MMIO.
2. Require all card-0 capture status files and all three card-1 capture status
   files to say exactly `closed`.
3. Run the full native `check-idle` guard for controllers `0,2,3`, including
   the A32 handle list, all five controller idle/IRQ/FIFO guards, stock divider
   12, shared clock gate off, reset agreement, and exact target/build identity.
4. Validate all three microphone controls are scalar, independently addressable,
   and off. Atomically create the write-ahead journal before the first change.
5. Set `MIC0`, `MIC1`, and `MIC2` to one individually. After each write, read
   back the selected control and verify the other scalar states. If any write
   fails, turn off only the controls whose on-state was proved, in reverse
   order, and return to idle.
6. Rerun the complete A32 idle/ownership guard after microphone power-on. A
   scalar command that activated an AoC handle or controller is a stop.
7. Execute the exact `frankel_a32_raw_pdm.py apply` transformation for the
   group: shared clock on; reset pulse 0/2/3; clock off; divider 12 to 8;
   RFactor25 value 4, `+0x30 |= 0x211`, watermark 150, selection bit 2; shared
   clock on; raw start; `+0x2c` HPF-bypass bit 1. Never write controller
   `+0x04` and never read FIFO `+0x0c` from the lifecycle process.
8. Run the exact active-state checks and save the controlled active word map.
   The shared parent/divider now supplies 4.8 MHz and CIC `/25` supplies
   192000 frames/s.
9. With polling still zero, synchronously write `status_probe=1`. Require one
   selected `+0x10` read per controller, `status_polls` and `probe_reads` deltas
   of exactly one, and no change in FIFO words, bits, PCM frames, delivery,
   periods, overrun, or clip counters. Re-prove A32 active state.
10. Through the kernel control lease, enable polling and read back one. The
    kernel must consume `status_probe` back to zero before waking the worker.
    Snapshot stats again and require evidence that each selected controller
    begins polling without an AP fault. Mark the journal `active`, then return
    the successful lease to the HAL.

Polling starts before the HAL opens its first PCM. The worker therefore drains
the FIFO and advances each CIC while the HAL opens/prepares/triggers; those
initial unleased frames are expected in `discarded`. This is preferable to
starting a PCM with no producer and risking an immediate XRUN. The activation
latency and initial discarded-frame count must be measured in the coordinated
hardware trial.

### ACTIVE

The broker accepts additional unique endpoint leases without changing
hardware. It monitors, at a bounded interval:

- exact module identity, owner cookie, immutable parameters, and card topology;
- its kernel polling-control lease and the expected `polling_enabled=1`;
- the exact active A32 controlled-word map and inactive A32 handle list;
- all three microphone scalar readbacks;
- card-0 capture status, which must remain closed; and
- per-controller stats deltas, ALSA XRUNs, impossible counter relationships,
  and kernel/AoC health signals established by qualification.

No monitor may read FIFO data. A changed A32 word or a new card-0 capture owner
first clears readiness so new starts and the next transfer fail closed, then
enters the same fail-closed quiesce path. The registered HAL process remains
available. It must not write a guessed correction over the competing owner.

### ACTIVE to TOPOLOGY_IDLE

Normal last-release cleanup is:

1. Reject new acquires and require all three card-1 PCM statuses exactly
   `closed`. A non-last release merely removes that lease and leaves the group
   active.
2. Set polling to zero through the kernel lease. The write must return only
   after the polling thread's final MMIO read and ALSA callback. Read back zero.
3. Capture stats/dmesg/AoC diagnostic deltas. Require no unexplained ALSA
   overrun; hardware FIFO-loss proof remains a separate qualification item.
4. Run exact `check-active` against this boot's journal. Then execute the exact
   group revert: clear the raw start bits, pulse reset 0/2/3, gate the shared
   clock, restore all snapshotted controller words and divider 12, and validate
   the full idle state. Never write `+0x04`.
5. Set `MIC2`, `MIC1`, and `MIC0` off, each with readback. Validate all remain
   off and all card-0 capture statuses remain closed.
6. Mark and fsync the journal `reverted`, publish the session counter deltas,
   erase its recoverable-active marker, and accept a future first lease.

If PCM closure is not proved, the broker may still synchronously force
polling off to stop AP reads, but it retains the lease, A32 active state, and
powered microphones. It does not revert until the PCM file descriptors are
proved closed.

## Crash-safe polling lease and journal

The current writable sysfs Boolean is insufficient for a process-crash
guarantee: if the loader/broker dies while it is one, polling continues. Before
runtime is enabled, add a narrowly scoped kernel control endpoint with these
semantics:

- one broker opens it with an immutable boot-random owner cookie;
- an authenticated ioctl changes polling using the existing
  `poll_control_lock` and synchronous `force_polling_off_locked()` path;
- the file's final `release` synchronously forces polling off; and
- a new broker instance can claim the endpoint only with the same module
  cookie and a matching same-boot journal.

The endpoint does not write PDM MMIO, clocks, reset, or microphone controls.
Its sole crash action is the already-reviewed synchronous polling stop. A
plain writable sysfs parameter may remain for the manual qualification image,
but integrated runtime uses the lease endpoint exclusively.

The module load receives a random `owner_cookie` read-only parameter. Before
insertion, the broker stores that cookie and `/proc/sys/kernel/random/boot_id`
in a write-ahead journal under a dedicated `/data/vendor/powerphone/pdm/`
label. It then proves the live module cookie equals the journal. A restarted
broker never adopts a preexisting module from parameter similarity alone.

The native journal contains at least:

- version, boot ID, device/serial, vendor build, kernel, module cookie, and
  controllers `[0,2,3]`;
- topology phase, lease endpoints/tokens represented by nonsecret IDs, and
  original scalar states;
- every original A32 word read by the Python helper, the exact active word map,
  capture statuses, and A32 handle inventory;
- module-stat baselines/deltas; and
- a write-ahead record for every A32 store: address, guarded before value,
  intended after value, label, and verified/not-verified phase.

Write the intent and fsync the file and parent directory before sending each
factory-diagnostic store. After exact readback, mark it verified and fsync
again. On recovery, an unverified record is accepted only if the live word is
exactly its before or after value; any third value latches the fault. This is a
stronger crash guarantee than the host helper's in-process transaction list,
while preserving its exact guards and reverse-order rollback logic.

On broker death, init immediately clears readiness; the always-registered HAL
rejects new starts and an active capture fails its next transfer. The kernel
control-file release makes polling zero before the restarted broker does
anything. The restarted broker:

1. proves the same boot ID, module owner cookie, polling zero, exact topology,
   and closed card-1 PCMs after the dead HAL's descriptors are reaped;
2. resolves any write-ahead intent using exact before/after reads;
3. validates the journal's exact active or partially applied state; and
4. recovers toward *idle*, never toward resumed application capture: guarded
   reverse/restore, then scalar power-off.

A stale journal from another boot is archived as evidence and never replayed;
hardware reset is not inferred to have preserved its state. A missing journal,
cookie mismatch, unproven polling stop, unexpected A32 word, or incomplete
restore enters `FAULT_LATCHED`. In that state readiness remains zero, the
module stays mapped, its suspend veto remains active, and only an audited
manual recovery or reboot is allowed.

## Failure matrix

| Failure | Mandatory response |
| --- | --- |
| HAL/AudioFlinger client dies | Binder death drops all leases from that client; clear readiness, reject new capture streams, wait for kernel-reaped PCM FDs, stop polling, then perform exact group cleanup. Keep the VINTF module process registered. |
| Broker dies while active | Init clears readiness; the HAL rejects new capture streams while remaining registered. Kernel control-file release synchronously stops polling; the restarted broker uses the same-boot cookie/journal only to recover to idle. |
| Broker dies during one A32 store | Polling is zero unless activation had completed; restart resolves the fsynced intent only from exact before/after readback, then rolls back. Any third value latches. |
| PCM fails to close | Stop polling if possible, but retain active A32 state, rail power, journal, module, and suspend veto; retry closure after killing the owning sidecar. |
| Polling-off write/readback fails | No A32, rail, or module cleanup. Readiness zero and fault latched. |
| Active A32 word/handle changes | Treat as a competing AoC owner; stop clients and polling, but do not overwrite or revert the changed state. Fault latched. |
| Scalar power readback fails | Before apply, reverse only proved-on scalars. After apply, first stop polling and restore A32; if either is unproved, leave rails unchanged. |
| Module/card topology changes | Clear readiness and reject new capture streams without unregistering the HAL. Do not adopt/reload while an active journal exists. |
| Device reboots | Never replay the old journal. Start a new boot transaction only after all fresh idle/topology gates pass. |
| Suspend requested | The mapped module returns `NOTIFY_BAD`. Do not weaken the veto while any topology mapping or recoverable fault remains. |

## SELinux and privilege boundary

Keep the broker in a dedicated vendor domain. Its eventual policy needs only:

- load and validate the one staged module, plus the new polling-control device;
- read exact card/module procfs and sysfs state;
- read/write card-0 ALSA control for the three named scalar controls, not
  capture/playback PCMs;
- read/write the exact factory-diagnostic and debug character-device types
  discovered from live `ls -Z`/policy inspection;
- create and atomically update only the dedicated journal directory;
- register the private lifecycle Binder service, accept calls only from the
  PowerPhone HAL, and set only the dedicated readiness/diagnostic properties.

Give the immutable module-parameter subtree a read-only type and the new
polling-control node its own writable type. Do not broaden the existing whole
module sysfs label to generic write access. Do not give `hal_audio_default`
factory-diagnostic, sys_module, journal, or mixer-control privileges.

The factory-diagnostic transport must be ported, not replaced with shelling
out. Preserve core 1, command IDs `0x25`/`0x26`, packet counter/length/reply
validation, maximum dump size, debug-output address continuity checks, and
exact pre/post reads from `aoc_factory_diag.py`. Serialize it against any
manual research tool; concurrent users of `/dev/acd-debug` make response
attribution unsafe.

## Live gates before implementation may be enabled

### What the first PDM0 trial must supply

The first run of `raw-pdm-capture.sh` is the AP-permission and single-path
safety gate. Retain one evidence directory containing all of the following:

1. Exact target, vendor build, userdebug type, kernel release, card IDs,
   module vermagic/parameters, scalar preflight, and pre-trial card-0 PCM
   statuses.
2. A successful read-only A32 `check-idle`, the atomic original/active/reverted
   JSON snapshot for controller 0, and complete apply/check-active/revert logs.
3. Proof that the first AP status/FIFO access neither hangs nor causes an
   external abort, SError, AoC watchdog, kernel oops, USB loss, or reboot.
   Save before/after dmesg and AoC logs and prove the device remains responsive.
4. Exact status/polling transitions `status_probe 0 -> 1 -> 0` followed by
   `polling 0 -> 1 -> 0`. Preserve the status-only counter deltas and zero data
   deltas before polling, the synchronous polling-stop return, and zero
   readback before A32 revert. Record apply-to-probe, probe-to-polling, and
   polling-stop latency.
5. Raw module stats showing PDM0 `words > 0`, `bits == words * 24`, decimated
   and delivered progress consistent with 192000 frames/s, no ALSA overrun,
   and zero MMIO/stat activity on unselected PDM2/PDM3. Preserve all observed
   raw `last_status` bits; bit 0 alone cannot prove absence of FIFO overflow.
6. The captured mono S32_LE/192000 data and external pilot/spectral analysis,
   not merely its WAV header. Determine byte order, bit chronology, and
   polarity sufficiently to rule out periodic phase discontinuity. Account
   for CIC3/R25 droop (about -11.8 dB at 96 kHz).
7. The exact scalar `MIC0`, `MIC1`, or `MIC2` used, its on/off readbacks, the
   other two controls remaining off, and stimulus coherence that associates
   that logical control with physical PDM0. Noise or RMS alone is insufficient.
8. Complete cleanup proof: tinycap reaped and PCM closed, polling zero, A32
   snapshot `reverted` with exact idle validation, scalar off, module unloaded,
   card 1 absent, card-0 captures still closed, and device/AoC health intact.

Any missing item keeps the runtime design disabled. An AP read hang/abort,
unknown status bit indicating loss, nonzero overrun, snapshot mismatch,
failed cleanup, or unexplained discontinuity is a hard stop rather than a
reason to relax a guard.

### What PDM0 alone cannot authorize

Even a complete PDM0 pass leaves these blockers before the integrated broker
may activate all three endpoints:

- repeat guarded individual permission/capture trials for PDM2 and PDM3;
- resolve the full `MIC0/MIC1/MIC2 -> PDM0/PDM2/PDM3` matrix by coherence;
- run one coordinated `controllers=0,2,3`, mask `0x0d` trial with all three
  PCMs captured concurrently, proving no controller starvation, scheduling
  XRUN, phase discontinuity, or ownership conflict;
- identify or otherwise bound hardware FIFO overflow/loss, because the current
  module decodes only the empty bit;
- choose and pin the qualified byte/bit-order/polarity module parameters;
- confirm the exact HAL acquire-before-open and close-before-release hooks;
- implement and fault-inject the polling control lease and write-ahead recovery
  path; and
- pass Java `AudioRecord` and AAudio routing/format/continuity tests plus the
  required Nyquist acoustic measurement for each physical opening.

Until every item passes, keep the current loader's behavior: card topology may
be validated, but microphone power, A32 apply, and polling remain disabled.
