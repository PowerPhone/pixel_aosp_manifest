# Frankel D10 boot orchestrator

`frankel_powerphone_d10_bootstrap` is the only component allowed to set
`vendor.powerphone.pdm.ready=1` in the PowerPhone research image. A companion
RC installed in `/system_ext/etc/init` holds the system-owned `audioserver`
stopped and starts this vendor service only after the stock `aocd` firmware
daemon and AoC audio HAL are both running, init reports audioserver stopped,
watchdog expiration remains zero, and the watchdog service is running.
Vendor `post-fs-data` arms the typed boot-local
`vendor.powerphone.bootstrap.attempted=0` latch and initializes the typed phase
to `armed`. The platform gate changes the latch to one as its first command and
requires both values in its trigger. Thus the bounded transaction runs at most
once per boot; stopping audioserver or cycling its stock HAL later cannot
replay the gate or restart audioserver during a host-owned tinyALSA session.
An asynchronous vendor watchdog starts at `post-fs-data` and bounds the wait
for that compound prerequisite trigger to 60 seconds. The main action stops it
immediately after claiming the same latch. Requiring expiration to remain zero
on the normal trigger gives a published timeout precedence during init's
all-property sweep. If `aocd` or the HAL never reaches
running, the watchdog publishes a typed expiration property; a platform-context
action claims the still-zero latch and starts the certificate-aware finalizer
asynchronously. Its stopped transition reaches the common audio-release
action. The same guarded fail-open runs if the
watchdog service stops before either the latch or expiration is set, covering
an executable, policy, crash, or property-publication failure. A failed AoC load
therefore cannot leave the early-init stop in force indefinitely.
This watchdog bounds only the wait before the transaction claims its latch.
Once asynchronous helper execution begins, the helpers' own factory-I/O and
device waits provide the deadlines. Init deliberately does not SIGKILL a
helper mid-transaction: the speaker helper may be inside the mandatory restore
window for its temporary AoC timer callback. Crucially, the helper is a normal
oneshot service, not an `exec_start`: init continues processing unrelated
property actions, including vendor-module readiness and HAL startup, throughout
the long AoC transaction.
The `aocd` condition ensures AoC firmware, card 0, and its mixer exist before
the first asynchronous attempt. The gate deliberately does not wait for
`sys.boot_completed`: system_server audio initialization can require
audioserver, which would make that gate circular. The partition split is
required by Treble: a vendor RC cannot consume the private
`init.svc.audioserver` property. The bootstrap then
establishes the exact idle RAW/S16_LE/mono/SR_192K mixer state and quarantines
unadvertised D8/D9/D12/D31p. It first invokes
`frankel_aoc_speaker_patch apply --allow-incomplete-boot
--skip-zero-validation`, which guardedly retains the exact stock A32 allocator
when the early cache-sync window is unavailable (or installs its certified
fallback only when that window is proven), requires `UsfDefaultWorker` to
remain at stock priority 7, and
retains allocation range/alignment, edge-accessibility, object/ring, and
post-commit guards while omitting only the watchdog-prohibitive 192-dump full
zero scan. It installs the qualified F1 q48/source-0 D0 speaker profile, then invokes
`frankel_aoc_d10_patch apply --allow-incomplete-boot`. Real-device boots
showed that the speaker factory-mailbox transaction cannot complete reliably
after D10's resident diagnostic profile is installed. D10 therefore runs last
and its final whole-F1 cache synchronization covers both installed profiles.
A real-device inverse-order test established that `BUILDIN MIC ID CAPTURE
LIST` materializes the selected logical microphone's PdmV3 state when the
control is written: selecting logical microphone 1 before D10 activation
produced only 96,000 frames/s, whereas selecting the same microphone after
activation produced exactly 192,000 frames/s. Consequently, while every
capture route is still off and the PCM quarantine is still active, the
bootstrap rewrites the capture list in the non-empty sequence 1, 2, 0 after
D10 activation. Each four-element value is read back exactly, and the sequence
leaves logical microphone 0 as the boot default. It never writes an all-`-1`
list because the firmware requires a nonzero PDM mask. A priming or readback
failure revokes `vendor.powerphone.pdm.ready` and enters the bounded
retry/fail-open path rather than certifying a partially materialized profile.
A bounded retry may re-certify the already-selected speaker state idempotently
before retrying D10. The explicit flag is
the helper's only early-boot exception and is accepted only for `apply`.
Direct/standalone helper commands still require `sys.boot_completed=1`; the
exception bypasses only that property check, leaving every target, mixer,
closed-PCM, byte, transport, readback, and I-cache guard intact. The patch
helper owns the readiness property: it raises it only after all guarded
writes, I-cache synchronization, and final uniform readback pass.

Only after both helpers publish and the bootstrap re-reads their readiness
properties does an attempt return. Exact service-state/phase triggers launch
at most two further attempts and then the asynchronous finalizer. The confined
bootstrap domain, not `vendor_init`, initializes both
`vendor.powerphone.pdm.ready` and
`vendor.powerphone.aoc_speaker_192k.ready` to zero. The certificate-aware
native finalizer consumes both readiness values before its stopped event lets
the system-ext gate release audioserver. The four-value microphone selection is
programmed and read back one element at a time to avoid depending on an array
representation across the userspace/kernel mixer ABI.

The persistent device-node quarantine also includes
`/dev/snd/pcmC0D31p`, AoC's Capture Injection playback frontend. That frontend
can replace PDM microphone data and must not coexist with the resident D10
profile.

During `post-fs-data`, init creates `/data/vendor/powerphone` as `0700
root:root`. Its dedicated `powerphone_vendor_data_file` label lets only the
bootstrap domain create, open, read, write, and lock
`.aoc-patch.lock`. The D10 helper and any separately qualified AoC helper must
use that same lock because the factory diagnostic response stream is global.

The services remain one-shot. A typed state machine advances through
`armed -> attempt1 -> attempt2 -> attempt3 -> finalizing -> releasing ->
complete`, for a strict maximum of three certification attempts. Every short
transition publishes its next phase immediately before starting the service.
Because init cannot consume that queued phase event until the action finishes,
it observes either a running service or a genuine immediate failure; the later
stopped event advances exactly once. No long-running command executes in
init's action queue.
Each later invocation exits without mutation when an earlier attempt already
certified both profiles. A separately named finalizer then checks both
certificates. It preserves mode `0000` on D8/D9/D12/D31p after success, or
revokes both readiness properties and restores their normal `0660` modes after
failure. When that finalizer stops, including after a start or SELinux failure,
the sole release action reaps audioserver and the old sidecar, starts a fresh
`vendor.audio-hal-powerphone`, then starts stock `audioserver`. A transient
certification problem therefore cannot trap the phone in boot animation, and
no client-owned AIDL stream configuration can cross the audioserver lifetime.
If card 0 never registered, an absent PCM has no inode or changed mode to
restore; the finalizer treats it as already fail-open and ueventd supplies the
stock mode when the node is eventually created. An existing non-character path
or a failed mode readback remains a hard restoration error.
Both readiness properties remain zero in the fallback, and the PowerPhone AIDL
sidecar independently rejects every research stream start and transfer. The
fallback does not claim that an interrupted, unknown AoC F1 mutation is safe
for research; reboot before another qualification attempt.
