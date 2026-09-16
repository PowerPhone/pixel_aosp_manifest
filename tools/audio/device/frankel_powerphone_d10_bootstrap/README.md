# Frankel D5/D10 audio boot orchestrator

`frankel_powerphone_d10_bootstrap` coordinates the reboot-volatile speaker
and microphone profiles after Google's signed AoC firmware loads. The current
speaker path is **D5/source 5, coherent 192-frame processing, stereo S32 and
two physical TDM slots**. It retains the stock A32 allocator and timer
assertion; former q48/source-0 D0 and OUTPUTTER-fallback recipes are historical.

The no-fixed-delay flow and presentation gate below are **qualified within
the tested boot/first-launch/UI/API scope on two consecutive boots of the
same images**. Boots7–8 completed native setup at about 19.8 s and Android
boot at about 21 s; immediate non-root first-launch recordings reproduced
the requested 20 kHz tone with no detected phase/dropout/clipping events.
Boot7 additionally passed eight physical UI-click checks and all ten endpoint
API transport cases, preserving six microphone WAVs without an AoC reset.
Boot8 also passed ordinary 48 kHz Java playback with independent D10 capture.
Earlier failed trials remain retained; this does not requalify every
endpoint's acoustic bandwidth or long-run research continuity. See the
[dated candidate report](../../../../docs/frankel-boot-streamline-20260912.md)
for firmware evidence and the hardware-results status.

## Boot sequence and prerequisites

The companion RC belongs in `/system_ext/etc/init`, where platform init may
observe the private `init.svc.audioserver` property; a vendor RC cannot take
that role. Early init disables audioserver's automatic start and publishes
`sys.powerphone.audio_boot=pending`.

Vendor `post-fs-data` sets phase `armed`, clears watchdog expiration, arms
`vendor.powerphone.bootstrap.attempted=0`, and starts the asynchronous
sixty-second prerequisite watchdog. The normal trigger requires stock
`aocd` and primary HAL running, audioserver stopped, watchdog running and
expiration zero. Its first command claims the latch. Later audio-service
stops cannot replay bootstrap or restart audioserver during host-owned tests.

In the same action, the gate stops the watchdog, reaps the research HAL,
starts a fresh research HAL and audioserver, and publishes `attempt1`
immediately before starting the bounded bootstrap. The selected flow retains the
early audioserver start so AudioService can initialize policy volume ranges;
boot3–5 held it stopped until finalization. The final release action still
restarts audioserver/research HAL after finalization on success or failure.
There is no separate
`starting` phase or startup service-stopped finalization edge. Helpers run
asynchronously: no long `exec_start` blocks init's action queue.

The superseded first hardware trial used a `starting` branch. A queued
research-HAL-stopped action launched finalization just before the queued
all-services-running action launched the first attempt. This advanced the
phase concurrently and suppressed the attempt's normal retry edge. Its first
speaker preflight debug read timed out before mutation; both readiness flags
remained zero, and the display gate correctly failed open without audio
certification. Removing that branch preserves the native bounded
prerequisite wait and existing retries. Boot2 ran those retries correctly,
but its second attempt timed out on the allocator result cookie and the third
rejected retained temporary scaffolding. Boot3 repeated that failure with
audioserver kept stopped until finalization. Both ended with readiness `0/0`
and a failed bridge. Boot4's DHI-only wrapper also failed the allocator cookie.
Boot5 added DHU and completed native setup at 19.622 s; a non-root API launch
at 22.65 s and the later ten-case endpoint API matrix passed transport, but
speaker tone/UI output was absent. AudioPolicy volume ranges remained
`-1/-1` despite valid AudioService cached ranges. See the dated report for
these distinct outcomes and the separate late diagnostic incident.

The former early `prepare-a32` service, blind thirty-second warm-up and
ten-second stability delay are removed. The selected early A32 action already
retained stock without using the timer patch. This audit does not prove the
thirty-second interval redundant for all other boot dependencies: boot5
passed native setup but was silent. Boots7–8 now supply repeatable physical
first-launch results, with UI and endpoint API evidence on boot7. The native
prerequisite wait checks immediately, polling every 100 ms for at most sixty
seconds until:

- Card 0 control, D5 playback, D10 capture, factory diagnostic/debug nodes and
  all four quarantined PCM nodes exist as character devices.
- Both helpers are executable and the primary HAL is running.

These are device/service prerequisites, not an allocator-ready certificate.
Init process state is not complete audio-policy initialization. Neither the
bootstrap nor the init trigger may wait for `sys.boot_completed`: it follows
boot-animation completion and would create a circular dependency.

## Guarded speaker and microphone transaction

The bootstrap clears both readiness flags, establishes idle
RAW/S16_LE/mono/SR_192K microphone state, quarantines unadvertised D8/D9/D12
capture and D31 playback, and invokes:

```text
frankel_aoc_speaker_patch apply --allow-incomplete-boot --skip-zero-validation
frankel_aoc_d10_patch apply --allow-incomplete-boot
```

Speaker runs first because historical inverse ordering could not reliably
finish its factory-mailbox transaction after D10's resident diagnostic
profile. Strict microphone state is reapplied at that boundary: stock HAL
defaults may have changed while speaker patching ran. The zero HD Mic gain
requirement is checked without issuing a redundant write when already zero.
After speaker readiness, a nonzero HD Mic gain fails the handoff instead of
issuing a command that could refill the F1 dispatch cache line. Before
speaker readiness it may still be corrected and read back.

The speaker helper retains stock A32 allocation and `UsfDefaultWorker`
priority 7. It makes one aligned `0x3000` F1 allocation for enlarged speaker
banks and applies the source-5/192-frame profile. Target/build, shared
transaction lock, AoC generation, closed-D5 ownership, instruction/object/ring
provenance, allocation range/alignment/accessibility, cache synchronization
and post-commit guards remain. The 250-ms generation preflight remains.
`--skip-zero-validation` omits only the 192-read full zero scan. An ambiguous
allocation or mixed profile must not become a retryable readiness probe.

The current speaker cache barrier uses a resident wrapper which calls the
existing whole-F1 I-cache invalidator, then `DHU`/`DHI`/`MEMW` on the HD Mic dispatch
line before the host restores its stock pointer. The guarded one-shot
allocator claims a nonzero cookie sentinel before allocation, publishes its
result with `DHWB`/`MEMW`, and uses `DHU`/`DHI`/`MEMW` on that dispatch line
before return.
Zero/sentinel results do not qualify an allocation or permit a second one.
Resident code/literals occupy exact guarded stock padding; mixed/unknown
bytes or changed live boundary words require reboot. This native sequence
completed in boot5; it did not by itself establish working physical audio.

When speaker readiness is `1`, D10 checks the resident wrapper's exact bytes
and uses the same I-cache/dispatch-line barrier; it refuses a mismatch rather
than silently using its former I-only path. With speaker readiness missing
or zero, standalone D10 retains its stock-speaker path. Rebuild all three
matching helpers using
[BUILD_BOOT192.md](../../../../scripts/audio/frankel/BUILD_BOOT192.md);
do not deploy the orchestrator alone with incompatible helper revisions.
Candidate 6 restored only early audioserver startup and still failed native
allocation. Candidate 7 additionally uses the live-verified A32 noncacheable
factory alias for shared RAM MB1–9. Both helpers first require paired live
section descriptors through ordinary core1 reads. F1/H0 shared accesses at
`0x40100000..0x409fffff` use wire addresses `0x80100000..0x809fffff`;
DSP pointers and patch-model addresses remain unchanged. A32/core1 runtime
state retains its cached view. MB0's second-level mappings, private memory
and other unreviewed ranges are excluded. Unknown table descriptors fail
rather than silently selecting a new mapping.

Boot7 completed native setup at about 19.856 s, published the ready bridge at
19.908 s and completed Android boot at 21.157 s. A non-root app launched at
22.58 s; independent capture measured the five-second 20 kHz request with
correct pitch, zero detected phase/dropout events and zero clipped samples.
All eight UI clicks are source-correlated, and policy MUSIC ranges are
initialized at `0..25`. Native flags were `1/1`, AoC counters `0/0`, and
SELinux Enforcing. Boot8 reproduced native setup at 19.786 s and first app
launch at 22.75 s on unchanged images; its full 20 kHz tone again had correct
pitch and zero detected phase/dropout/clipping events. The subsequent
ordinary 48 kHz Java/12 kHz tone control also passed. These qualify the tested
boot and immediate-use behavior, not every endpoint's acoustic response,
96 kHz acoustic bandwidth, long-run research continuity or every possible
sample-slip pattern. Simultaneous primary/research playback remains
unsupported. Timing is measured rather than guaranteed. The matched
[boot-ready bundle](../../../../artifacts/frankel/powerphone-playback192-bootready-20260912/README.md)
contains the tested system, system_ext and vendor images.

After D10 activation, with capture routes still off, the bootstrap primes
logical microphone selections `1, 2, 0`, verifies each four-element list and
leaves microphone 0 selected. Selection materializes PdmV3 state; selecting
only before activation is insufficient. Never use an all-`-1` list because
firmware requires a nonzero PDM mask. Values are programmed/read back one
element at a time to avoid an array ABI assumption. Priming/readback failure
revokes microphone readiness and enters retry/finalization.

Each helper publishes its own readiness flag after its guarded final state
passes; the bootstrap checks both and can revoke them on failure. These
internal flags are written in the confined bootstrap domain, not vendor init.
Direct/standalone helper commands retain their normal
`sys.boot_completed=1` requirement. The boot's explicit
`apply --allow-incomplete-boot` exception bypasses only that property check,
not target, PCM, mixer, instruction, transport, readback or cache guards.

## Retry, quarantine and failure handling

The state machine is:

```text
armed -> attempt1 -> attempt2 -> attempt3
      -> finalizing -> releasing -> complete
```

Failure/timeout edges may finalize earlier. Unique phase/service-state
transitions provide at most three attempts; each next phase is published
immediately before its service starts. Later attempts return without mutation
if both profiles are already ready. The pre-trigger watchdog claims the same
latch and finalizes if prerequisites never converge or the watchdog
unexpectedly stops before latch/expiration publication. After latch claim,
native device/I/O waits provide their own bounds. Do not SIGKILL a helper
mid-transaction: temporary HD Mic dispatch/code/allocator scaffolding may
still require guarded disconnection and restoration.

The separate finalizer preserves mode `0000` on D8/D9/D12/D31p after success.
Otherwise it revokes both readiness flags and restores `0660`. A node that
never registered has no changed inode to restore; ueventd supplies its normal
mode later. Non-character replacements or failed mode readbacks are errors.
D31p is quarantined because AoC Capture Injection can replace physical PDM data.

The sole release action waits for audioserver and the old research HAL to
stop, then starts a fresh research HAL and audioserver. Stale client-owned
AIDL stream configurations cannot cross that audioserver lifetime.
`complete` means the state machine ended, not that research audio passed.
The sidecar refuses research starts/transfers without required readiness.
An interrupted or unknown firmware mutation still requires reboot before
another research qualification attempt.

Init creates `/data/vendor/powerphone` as `0700 root:root`; its dedicated
`powerphone_vendor_data_file` label confines `.aoc-patch.lock` access.
Both helpers must use that lock because the factory diagnostic response
stream is global. A separate helper must not bypass this ownership.

## Boot animation and API publication

After finalization, init publishes `sys.powerphone.audio_boot=ready` only
with both real profile flags and all three audio services running. A completed
bootstrap missing either flag publishes `failed`. An opt-in WindowManager
gate holds boot-animation exit/input enablement without blocking
SystemServer or init initialization.

Even with `ready`, WindowManager requires current live Binder registrations
for `media.audio_policy` and `media.audio_flinger` after the deliberate
audioserver restart. Non-waiting `ServiceManager.checkService` lookups and
Binder-liveness checks retry every 250 ms, not through blocking service waits
or PCM opens. The independent 180-second presentation deadline and failed-state
path allow UI/recovery access without certifying audio. Safe mode, recovery
and boot messages retain their escape paths; an absent opt-in property keeps
normal behavior on other targets.

Use the passive
[boot observer](../../../../scripts/audio/frankel/observe-boot-readiness.sh)
for real timing. Property/API publication is boot evidence, not a substitute
for cold UI clicks and independent microphone-reference tests of ordinary and
research AudioTrack, AAudio, microphone selections and endpoint handoffs.
