# Frankel audio boot streamlining — 2026-09-12

Status: **qualified within the tested boot/first-launch/UI/API scope on two
consecutive boots of the same images**. Boots7–8 completed native setup in
about 19.8 s and Android boot in about 21 s; immediate non-root first-launch
recordings reproduced the requested five-second 20 kHz tone with correct
pitch and no detected phase/dropout/clipping events. Boot7 also passed eight
physical UI-click checks and all ten endpoint API transport cases. The
[boot-ready bundle](../artifacts/frankel/powerphone-playback192-bootready-20260912/README.md)
contains the matched images. This does not requalify long-run research
continuity or high-frequency acoustic bandwidth. Boots1–6 and their distinct
failures remain documented below.

Final handoff: [device state](../work/audio-research/frankel/boot-streamline-20260912/boot8/final-device-state.txt)
shows Settings launching in 188 ms, a successful UI hierarchy dump, the public
bridge `ready`, both profile flags `1`, all three audio services running,
AoC restart/coredump counts `0/0`, and Enforcing SELinux. The phone remains on
the tested repeat boot; userdata was retained.

## Removed delays and their actual purpose

The previous bootstrap performed an early `prepare-a32` invocation, a blind
30-second Android-audio warm-up, and a further ten-second card-stability wait.
The warm-up only slept. The stability wait checked character-device presence,
helper executability, and the primary HAL's init process state; it did not
observe F1 heap readiness, successful allocator execution, or completion of
Android's audio initialization.

The selected speaker helper's `prepare-a32` branch calls
`EnsureA32AllocatorFallbackApplied(..., false)`. With the factory A32 word,
that path reads the reviewed state, retains the stock allocator, and publishes
`vendor.powerphone.aoc_a32_allocator.ready=0`. It never enters the optional
OUTPUTTER timer rewrite/cache-synchronization path. The late speaker apply
uses the same `false` argument. Therefore the former requirement to preserve
the short-lived OUTPUTTER timer while audioserver was stopped no longer
describes the selected profile. The timer machinery remains historical code;
this candidate does not enable it. This source audit does **not** establish
that the former thirty-second interval was redundant for every other boot
dependency. The failed trials below remain failed. Boots7–8 now supply two
successful native/first-launch trials without those fixed delays, plus
boot7 UI and endpoint API evidence. The qualification is bounded to those
tests, not an unconditional guarantee for every future boot state.

Relevant canonical sources:

- [Bootstrap and prerequisite predicate](../tools/audio/device/frankel_powerphone_d10_bootstrap/frankel_powerphone_d10_bootstrap.cpp).
- [Asynchronous init gate](../tools/audio/device/frankel_powerphone_d10_bootstrap/frankel_powerphone_audioserver_gate.rc).
- [Speaker preflight, allocator and mutation guards](../tools/audio/device/frankel_aoc_speaker_patch/frankel_aoc_speaker_patch.cpp).

## Firmware and historical evidence

The actual F1 aligned allocation wrapper at `0x4040bf40` loads its heap pointer
through literal `0x4040bc84`, whose value is `0x410052c4`. If the heap pointer
is zero, the wrapper itself calls heap initialization at `0x4040c220`, using
backing `0x404c3d80` and the size read through `0x40461f00`; it publishes the
heap pointer at `0x4040bf5c`. It then calls the allocator at `0x4040cee8`.
There is no thirty-second timing condition in this wrapper. This rejects a
literal timer requirement in that function, but does **not** prove that an
earlier allocation has sufficient capacity, executes coherently after code
injection, or can run amid all boot traffic. It is not hardware proof that
the old wait can safely be removed.

The unchanged decoded input is
[regions-complete/shared.elf](../work/audio-research/frankel/speaker-firmware-decomp-20260905/regions-complete/shared.elf).
The relevant wrapper range is `0x4040bf40..0x4040bf72`; its three literals are
at `0x4040bc84..0x4040bc90`.

The retained
[readiness-gate cold log](../work/audio-research/frankel/readiness-gate-cold-logcat.txt)
shows failed attempts at `12:41:25.383`, `12:41:36.305`, and `12:41:47.238`,
each after the ten-second wait. Their explicit failure was
`implausible A32 OUTPUTTER timer pointer 0x00000000`, not proof that the F1
allocator needed another fixed delay. Those attempts belonged to the older
timer-dependent path.

The previous successful
[four-slot trial boot log](../work/audio-research/frankel/pitch-validation/four-slot-trial-boot-log.txt)
records stock A32 retention at `05:56:58.322`, completion of the thirty-second
warm-up at `05:57:28.475`, the ten-second wait at `05:57:38.608`, and both
profile flags at `05:57:52.556`. These timestamps document the old sequence;
they are not timing results for this candidate or qualification of that
historical four-slot playback profile.

## Candidate sequence and retained safeguards

After the existing once-per-boot aocd/primary-HAL trigger, the same init action
stops the watchdog, reaps the old research HAL, and starts a fresh research HAL
and audioserver. Candidate 6 restores this early audioserver start so that
AudioService can initialize volume ranges against the policy service; boot3–5
had held audioserver stopped until finalization. The final release action
still restarts audioserver/research HAL after finalization on success or
failure. The initial action publishes `attempt1` immediately before launching
the bounded native bootstrap. There is no separate `starting` phase or
`starting`/service-stopped failure trigger. The early A32 service and warm-up
service are removed.
The native prerequisite loop checks immediately and retries every 100 ms for
at most sixty seconds:

- `controlC0`, D5 playback, D10 capture, and factory diagnostic/debug nodes exist.
- Both native patch helpers are executable and the primary HAL is running.
- The four PCM nodes that must be quarantined exist.

This predicate is intentionally described as device/service availability,
not a firmware allocator-ready certificate. The native loop checks primary
HAL state; unavailable device prerequisites and helper failures remain subject
to the bounded wait and normal attempt/retry machinery. All three audio
services must report `running` for the final success bridge, not for a separate
pre-attempt init transition. Init's `running` state still does not prove
AIDL/audio-policy initialization has finished.

The existing helpers still enforce the target/build, serialized diagnostic
transaction, unchanged AoC restart/coredump generation, and closed D5 ownership.
Speaker preflight still samples the generation and ownership across 250 ms.
The exact cold speaker-object fields, DMA identities/empty-ring state,
recognized instruction words, one-shot allocation result, and cache
synchronization remain prerequisites to publishing readiness. An ambiguous
allocation is not retried as a readiness probe. The selected A32 word and
timer assertion remain stock.

Speaker mutation still precedes D10. Strict microphone state is restored at
the boundary, and logical microphones are primed only after the PdmV3 patch.
The existing bounded retry/finalizer structure and pre-trigger watchdog are
retained. Finalization revokes incomplete readiness before restoring ordinary
PCM access; it does not relabel a failed patch as ready.

## Presentation gate

The candidate also adds an opt-in WindowManager presentation/input gate using
the platform property `sys.powerphone.audio_boot`. This is a framework boot
presentation change, not an AudioFlinger or audio-framework signal-path patch.
An absent property leaves other targets' behavior unchanged.

Init publishes `pending` at early init. It publishes `ready` only after the
bootstrap's final phase, both actual profile flags, and all three audio
services are running. A completed bootstrap with a missing profile publishes
`failed`. Even with the bridge at `ready`, WindowManager requires current
`media.audio_policy` and `media.audio_flinger` Binder registrations, with
both Binder objects alive. It uses non-waiting `ServiceManager.checkService`
lookups rather than a blocking service wait or an AudioSystem/PCM operation;
neither name is in the Java startup service cache, so a prior audioserver's
cached handle is not used to qualify its replacement.

WindowManager polls at 250 ms before requesting boot-animation exit or
enabling input, and fails open after an independent 180-second deadline.
This same deadline covers pending bootstrap and pending API publication.
Safe-mode/recovery/boot-message paths retain their escape behavior. A failed
or timed-out gate permits recovery/UI access without certifying audio. The
Binder checks establish service publication/liveness, not acoustic quality.

Neither the bootstrap nor its prerequisites may wait for
`sys.boot_completed`: that property follows boot-animation completion, which
the new presentation gate is deliberately holding. Init's action queue and
SystemServer initialization must continue while the native transaction runs.

## First hardware boot: FAIL — superseded `starting`-branch candidate

The first streamlined boot did not certify either audio profile. Its
[init/kernel log](../work/audio-research/frankel/boot-streamline-20260912/boot1/dmesg-root.txt)
records a `starting`/research-HAL-stopped action at uptime 4.704151 s that
launched finalization. The all-services-running action was also already
queued: it ran at 4.713993 s and started the bootstrap at 4.714504 s. Thus
finalization and the first attempt ran concurrently. The finalizer revoked
readiness and advanced the state machine, so the eventual attempt failure
could no longer take its normal `attempt1` retry edge. This was an init action
queue/state race, not exhaustion of the three bounded attempts.

The native prerequisite loop first passed at 5.662846 s. The first speaker
preflight then timed out waiting for the debug read of `0x403aa7c4+4`; the
retained error at 8.075063 s says the AoC dump did not contain that response.
This happened before firmware mutation. Stock A32 state was retained, and
the helper exited with status 2. The missing debug response is separate from
the erroneous concurrent finalizer; neither is evidence that an allocation
or partially applied 192 kHz firmware profile failed.

The retained
[root properties](../work/audio-research/frankel/boot-streamline-20260912/boot1/getprop-root.txt)
show `phase=complete`, both readiness flags `0`, and
`sys.powerphone.audio_boot=failed`. The
[observer](../work/audio-research/frankel/boot-streamline-20260912/boot1/observer.txt)
returned `complete_not_ready`/exit 2. The
[WindowManager log](../work/audio-research/frankel/boot-streamline-20260912/boot1-window-manager.txt)
explicitly released the display without audio certification after bootstrap
failure. UI access through this fail-open path is not a successful audio boot.

The boot2 correction removed the entire `starting` branch and launched the
bounded bootstrap directly in the initial action. Unavailable prerequisites
and preflight failures could then use the
ordinary bounded wait/retries without a competing startup finalizer. Boot1
also exposed a non-root observer denial for the new platform bridge;
the scoped platform-policy correction grants shell read access to that one
property, without exposing the private vendor readiness properties. Boot2/3
exercised these corrections but still failed for the separate reason below;
successful timing and immediate-API claims remained pending at that stage.

## Boot2 and boot3: FAIL — retries run, allocation never certifies

Boot2 removed the competing init `starting` branch while still starting
audioserver before bootstrap. Boot3 additionally kept audioserver stopped
until finalization, matching the current canonical RC. Both reached native
prerequisites promptly and then failed in the same sequence:

| Monotonic event | Boot2 | Boot3 |
| --- | ---: | ---: |
| Device/primary-HAL prerequisites available | 5.758729 s | 5.507720 s |
| First preflight debug read missing; first attempt fails before mutation | 8.155392 s (`0x403d3e44+4`) | 7.903364 s (`0x403c89a0+4`) |
| Second attempt's one-shot allocator result cookie times out | 13.376679 s | 12.880415 s |
| Third attempt refuses retained temporary allocator state | 14.384500 s | 13.851636 s |
| Completed phase publishes failed bridge | 14.428408 s | 13.883976 s |

Sources: [boot2 dmesg](../work/audio-research/frankel/boot-streamline-20260912/boot2/dmesg-root.txt)
and [boot3 dmesg](../work/audio-research/frankel/boot-streamline-20260912/boot3/dmesg-root.txt).
The retries now launch through the intended `attempt1` → `attempt2` →
`attempt3` edges. This is progress on the init race, not successful DSP setup.

Unlike each first preflight failure, the second attempt had installed
temporary allocator/cache-maintenance scaffolding. On the missing result
cookie it disconnected the allocator dispatch, deliberately retained the
temporary body/literals, and required a cold reboot. The third attempt did
not repeat an ambiguous allocation: it rejected the non-stock D12 callback
at `0x4027c768` (`e06d4840` versus stock `d0873e40`). Both finalizers revoked
readiness and restored ordinary PCM permissions. Root snapshots for
[boot2](../work/audio-research/frankel/boot-streamline-20260912/boot2/getprop-root.txt)
and [boot3](../work/audio-research/frankel/boot-streamline-20260912/boot3/getprop-root.txt)
show `phase=complete`, speaker/microphone readiness `0/0`, and the bridge
`failed`. The first-API harness correctly did not run audio on either boot:
[boot2 qualification](../work/audio-research/frankel/boot-streamline-20260912/boot2-first-api/qualification.json),
[boot3 qualification](../work/audio-research/frankel/boot-streamline-20260912/boot3-first-api/qualification.json).

Follow-up dispatch diagnostics found the HD Mic command returning `rc: 64`
instead of producing the allocator result, with the result cookie still zero.
That motivates the next cache-coherence candidate; it is not yet a proven
root cause or a hardware-qualified fix. Boot3's failure with audioserver
stopped also means that excluding framework clients alone did not fix the
allocator path. No successful early-boot allocation or 192 kHz readiness is
claimed from these trials.

### Separate late boot2 diagnostic-induced AoC restart

After boot2 had already failed at about 14.4 s, a manual root diagnostic at
about 119 s attempted a factory dump using core selector 2 at `0x410052c4`.
That address was not mapped for this A32 diagnostic read. The
[post-read kernel log](../work/audio-research/frankel/boot-streamline-20260912/boot2/dmesg-after-invalid-heap-read.txt)
records the resulting SSR request at 119.214793 s and an A32 `CNTRL` data
abort with `DFAR=0x410052c4`, `DFSR=0x00000005`, followed by subsystem restart.
This diagnostic caused the later restart; it was **not** a bootstrap crash
and must not be attributed to the earlier cookie timeout. The F1 address in
the disassembly is not permission to dereference it through another core's
address space. This unsafe read must not be repeated as a readiness probe.

## Candidate 4: explicit F1 cache coherence — boot4 FAIL

Candidate 4 kept audioserver stopped until final release. It changed the
firmware-injection/cache handoff, not the selected playback/PDM geometry or
audio gains. Its hypothesis is that a host-visible dispatch-word readback
does not establish what F1 sees through its data cache, and an F1 cookie store
does not necessarily publish the result to the factory diagnostic reader.
The changes below are source-level mechanisms, not proof that this explains
every previous failure or fixes early boot.

The speaker helper now installs a small reboot-resident wrapper at
`0x403f64a4`. It calls the existing whole-F1 I-cache invalidator at
`0x40486de0`, then executes `DHI` on the HD Mic dispatch-word cache line
(`0x4038ea50`) and `MEMW` before returning 64. The transient HD Mic command
dispatch is still restored and read back as stock after invocation. No
generic firmware cache primitive is overwritten.

The one-shot allocator's temporary D12 entry now tail-jumps to an extension
at `0x40371590`. Before the aligned `0x3000` allocation, the F1 routine checks
its cookie at `0x403f64a0` and claims a nonzero sentinel (`0xffffffff`). A
subsequent invocation with any nonzero cookie cannot allocate again, including
after a null allocation result. The allocator publishes its result with
`DHWB` plus `MEMW`, then invalidates the HD Mic dispatch line with `DHI` plus
`MEMW`. Host polling treats zero and the sentinel as pending/failed, never as
a heap address or permission to allocate again. Existing plausible-range,
64-byte alignment, stable repeated-read, disconnect and ambiguous-state
reboot guards remain.

These resident words occupy exact reviewed zero padding:
`0x40371580..0x403715cf` and the retired D12 padding around
`0x403f6490..0x403f64bf`; the cookie is data, not executable wrapper bytes.
The native helper requires surrounding live words to remain stock, accepts
only entirely stock or entirely installed scaffold states, and refuses mixed
or unknown content. The linker asserts each section's precise extent. The
resident wrapper/extension remain after temporary allocator restoration so
later synchronization uses the same mechanism. Sources:
[assembly](../tools/audio/device/frankel_aoc_speaker_patch/frankel_aoc_speaker_coherence.S),
[linker bounds](../tools/audio/device/frankel_aoc_speaker_patch/frankel_aoc_speaker_coherence.ld),
[speaker installation/publication guards](../tools/audio/device/frankel_aoc_speaker_patch/frankel_aoc_speaker_patch.cpp).

The [D10 helper](../tools/audio/device/frankel_aoc_d10_patch/frankel_aoc_d10_patch.cpp)
selects that same resident I-cache/dispatch-line wrapper when speaker
readiness is `1`, after checking its exact literal/code bytes. A ready-speaker
guard mismatch fails rather than falling back to the old I-only route.
Missing/zero speaker readiness retains standalone D10's stock-speaker
behavior. Unexpected readiness values are rejected.

The [bootstrap](../tools/audio/device/frankel_powerphone_d10_bootstrap/frankel_powerphone_d10_bootstrap.cpp)
also stops issuing a redundant `HD Mic gain (cB)=0` command when the mixer
already reads zero. An unchanged write still sends an AoC command and could
refill the dispatch cache line between speaker and D10 barriers. Before
speaker readiness, a genuinely nonzero value can still be corrected and
read back. After speaker readiness, a nonzero value fails the handoff instead
of sending that command. This retains the zero-gain requirement; it is not a
relaxation of microphone configuration.

Reproduction now copies/builds the matching speaker, D10 and bootstrap
helpers together, as documented in
[BUILD_BOOT192.md](../scripts/audio/frankel/BUILD_BOOT192.md).
The [boot4 kernel log](../work/audio-research/frankel/boot-streamline-20260912/boot4/dmesg-root.txt)
records a first diagnostic-read failure at 9.131503 s, an allocator-cookie
timeout at 14.775228 s, third-attempt refusal of retained temporary state at
15.849380 s, and failed finalization at about 15.879 s. The DHI-only candidate
did not certify readiness. The assembly links above now contain the later
DHU addition; the description in this section records the tested boot4
revision. Boot1–4 failures remain failures.

## Boot5: native/API transport PASS, physical playback FAIL

Candidate 5 added `DHU` immediately before `DHI` on the HD Mic dispatch cache
line in both the resident cache wrapper and the one-shot allocator return
path. It retained result-cookie `DHWB`/`MEMW`, the one-shot sentinel, exact
code/boundary guards, D10's matching wrapper and the redundant-zero-write
avoidance. Audioserver was still held until finalization. This trial completed
the guarded speaker/D10 transaction, but did **not** produce a working audio
system.

In the [boot5 kernel log](../work/audio-research/frankel/boot-streamline-20260912/boot5/dmesg-root.txt),
the second attempt reports primed microphones and native profiles ready at
19.622545 s; the next attempt recognizes the completed profiles without
another allocation. The success bridge action runs at about 19.662 s.
The [passive observer](../work/audio-research/frankel/boot-streamline-20260912/boot5/samples.tsv)
observed boot completion at about 22.19 s. These are native/property timing
results for this boot, not proof that audio was usable.

The non-root first-API harness
[launched at uptime 22.65 s](../work/audio-research/frankel/boot-streamline-20260912/boot5-first-api/launch.txt)
without changing volume, mixer, services, permissions or readiness. Its
[transport qualification](../work/audio-research/frankel/boot-streamline-20260912/boot5-first-api/qualification.json)
passed: AAudio transferred all 960,000 frames with zero reported XRUNs and
a 191,993.488 Hz full-run timestamp regression; concurrent Java MIC0 capture
returned 1,357,183 frames. A later
[API matrix](../work/audio-research/frankel/boot-streamline-20260912/boot5-api-matrix/run-status.tsv)
also passed all ten transport cases: Java/AAudio playback to two speaker
endpoints and Java/AAudio recording from three logical microphone endpoints.
Those results establish API operations, not emitted sound or acoustic
continuity.

The unchanged [first-launch recording](../work/audio-research/frankel/boot-streamline-20260912/boot5-first-api/capture.wav)
contains no measurable full five-second 20 kHz stimulus. The existing analyzer
found only 2.72 dB active-versus-quiet contrast, below its 12 dB requirement.
Noise-derived frequency/phase values are not a playback measurement. The
[interpretation and fixed-window noise comparison](../work/audio-research/frankel/boot-streamline-20260912/boot5-first-api/acoustic-tone20000/INTERPRETATION.md)
shows upper-band microphone noise agreeing with previous good raw MIC0
captures within 0.11 dB. That supports preservation of the previously observed
D10 wideband/noise-shaping behavior, but neither qualifies the speaker nor
calibrates microphone bandwidth. The independent
[UI-click capture](../work/audio-research/frankel/boot-streamline-20260912/boot5-ui/capture.wav)
and [analysis](../work/audio-research/frankel/boot-streamline-20260912/boot5-ui/ui-clicks-analysis.json)
likewise found noise rather than the expected source-shaped click responses.

The [AudioPolicy dump](../work/audio-research/frankel/boot-streamline-20260912/boot5/policy-after-first.txt)
shows every stream volume group's minimum/maximum still `-1/-1`, including
SYSTEM and MUSIC. These invalid ranges persisted beyond the first launch.
By contrast, [AudioService's cached ranges](../work/audio-research/frankel/boot-streamline-20260912/boot5/audio-after-first.txt)
look valid, including MUSIC `0..25`. Client-reported volume/rate, live Binder
registration and successful frame transfer therefore were not sufficient
readiness checks for this boot.

## Candidate 6: restore early volume initialization — boot6 FAIL

The only candidate 6 change from candidate 5 is restoring `start audioserver`
in the initial once-per-boot action, before the bounded bootstrap starts.
The aim is to let AudioService initialize stream volume ranges against a
live policy service during SystemServer startup. The presentation gate still
holds normal display/input release, and native helpers retain their exact
idle-PCM ownership and mutation guards. The finalizer still restarts the
control plane before the final readiness bridge.

DHU/cache-wrapper bytes, allocator behavior, D10, PDM geometry, playback
geometry and audio gains were unchanged from candidate 5. The separate A32
uncached-alias investigation had **not** been implemented in candidate 6.
Its [kernel log](../work/audio-research/frankel/boot-streamline-20260912/boot6/dmesg-root.txt)
records first preflight failure at 8.105323 s, allocator-cookie timeout at
13.983959 s, guarded third-attempt refusal at 15.089770 s, and failed bridge
publication at about 15.134 s. Restoring early audioserver startup alone
did not fix native readiness. Boot6 is retained as FAIL.

## Boot6 live mapping evidence and candidate 7 transport

Local A32 disassembly showed ordinary cached loads/stores in the factory
memory handlers without an explicit target cache clean/invalidate. The
[live table read](../work/audio-research/frankel/boot-streamline-20260912/boot6/live-a32-table.txt)
confirmed the reviewed dispatch section's paired A32 mappings:
`0x00301c0e` for VA `0x40300000` and `0x00301c12` for VA `0x80300000`.
Both map PA `0x00300000`; the former is write-back/write-allocate and the
latter normal noncacheable, execute-never. These are runtime 1 MiB sections,
not the firmware image's initial 16 MiB supersection descriptors.

The [complete nine-section/read-alias evidence](../work/audio-research/frankel/boot-streamline-20260912/boot6/live-a32-alias-read.txt)
showed matching section pairs for MB1–9: logical
`0x40100000..0x409fffff` and factory noncacheable
`0x80100000..0x809fffff`. Cached and noncacheable dispatch reads both returned
the stock word; AoC counters remained `0/0`. MB0 has distinct coarse
second-level tables and was deliberately excluded. The low VA
`0x0038ea50` is not an alternative alias; its reviewed first-level entry is
unmapped.

Candidate 7 implements the scoped mapping in both native helpers. Before
the first translated access, each helper reads the actual paired MB1–9
descriptors through unmodified A32/core1 access and requires all expected
section words. The speaker helper translates only F1/H0 factory accesses
within that range; D10 translates its matching F1 shared-memory transactions.
Only wire addresses change: DSP pointers, patch-model addresses and guard
values remain logical `0x40...`. A32-owned runtime/TCB reads keep their
cached core1 view. MB0, private memory and unreviewed mappings are not
translated; mismatched descriptors or an out-of-range translated request
fail the guard. This replaces the earlier unimplemented alias investigation
with an actual candidate transport change, not a global cache-disable patch.

## Boot7: first real first-launch/UI PASS

Boot UUID: `b843a1e0-8577-417c-9cfb-0792d1058854`.
The [kernel log](../work/audio-research/frankel/boot-streamline-20260912/boot7/dmesg-root.txt)
records microphone priming at 19.855875 s, native profile success at
19.855930 s, bridge publication at 19.908309 s, and boot completion at
21.156778 s. The non-root first-API harness
[launched at 22.58 s](../work/audio-research/frankel/boot-streamline-20260912/boot7-first-api/launch.txt).
Its [transport result](../work/audio-research/frankel/boot-streamline-20260912/boot7-first-api/qualification.json)
passed with all 960,000 requested AAudio frames and zero reported XRUNs;
concurrent Java MIC0 capture returned 1,355,520 frames. That JSON correctly
keeps its acoustic field separate; the following measurements provide the
independent physical-path evidence.

| Full first-launch 20 kHz tone measurement | Result |
| --- | ---: |
| Detected request interval | 4.96 s of the requested 5 s |
| Analyzed interior after fixed 50 ms boundary exclusions | 4.86 s |
| Carrier peak / full-interior phase-fit frequency | 19,999.999274 / 19,999.999396 Hz |
| Phase steps above 0.35 rad / dropout blocks | 0 / 0 |
| Maximum adjacent phase step | 0.033675 rad |
| Clipped samples, entire original recording | 0 |
| Active/quiet contrast | 43.52 dB |

Sources: [unchanged WAV](../work/audio-research/frankel/boot-streamline-20260912/boot7-first-api/capture.wav),
[full analysis](../work/audio-research/frankel/boot-streamline-20260912/boot7-first-api/acoustic-tone20000/tone-analysis.json),
[interpretation and limits](../work/audio-research/frankel/boot-streamline-20260912/boot7-first-api/acoustic-tone20000/INTERPRETATION.md).
The full detected tone, not a favorable two-second subset, supports correct
pitch and no detected discontinuities under the stated thresholds. A single
periodic tone cannot exclude slips by exact whole carrier cycles, and this
test does not establish 96 kHz acoustic bandwidth or isolate airborne from
all possible electrical coupling.

The [eight-click UI recording](../work/audio-research/frankel/boot-streamline-20260912/boot7-ui/capture.wav)
now contains the expected source-shaped responses, unlike boot5.
[UI analysis](../work/audio-research/frankel/boot-streamline-20260912/boot7-ui/ui-clicks-analysis.json)
finds all eight normalized source correlations `0.759..0.810` versus quiet's
maximum `0.225`, with click peaks `13.46..13.87 dB` above quiet.
The [policy dump](../work/audio-research/frankel/boot-streamline-20260912/boot7/policy-after-first.txt)
has initialized MUSIC ranges `0..25`, rather than boot5's `-1/-1`.
Root checks show native readiness `1/1`, completed phase, ready bridge,
AoC counters `0/0`, and SELinux Enforcing.

The completed [endpoint API matrix](../work/audio-research/frankel/boot-streamline-20260912/boot7-api-matrix/run-status.tsv)
passed all ten transport cases: Java/AAudio playback on both speakers and
Java/AAudio capture on all three logical microphones. All six microphone
WAVs are preserved, and no AoC reset occurred during the matrix. These remain
API transport results, not independent acoustic qualification of every case.
Boot7 supplies the first positive combined evidence. The independent repeat
below extends the boot/first-launch qualification, without retroactively
qualifying boots1–6.

## Boot8 repeat: PASS on the same images

An ordinary reboot, with no image change, produced boot UUID
`91b4d3e3-e5d9-41fc-a803-865d44410479`. Its
[kernel log](../work/audio-research/frankel/boot-streamline-20260912/boot8/dmesg-root.txt)
records native profile completion at 19.786186 s, bridge action at
19.830890 s, and the first boot-completed action at 21.050808 s; the passive
observer sampled boot completion at about 21.11 s. The non-root app
[launched at 22.75 s](../work/audio-research/frankel/boot-streamline-20260912/boot8-first-api/launch.txt).

| Repeated first-launch measurement | Boot7 | Boot8 |
| --- | ---: | ---: |
| Native profile completion, uptime | 19.855930 s | 19.786186 s |
| First app launch, uptime | 22.58 s | 22.75 s |
| Detected tone duration / analyzed interior | 4.96 / 4.86 s | 4.96 / 4.86 s |
| Recorded carrier peak | 19,999.999274 Hz | 19,999.999742 Hz |
| Phase / dropout / clipped-sample events | 0 / 0 / 0 | 0 / 0 / 0 |
| Native transferred frames / requested | 960,000 / 960,000 | 960,000 / 960,000 |
| Native reported XRUNs | 0 | 0 |

Boot8's [unchanged WAV](../work/audio-research/frankel/boot-streamline-20260912/boot8-first-api/capture.wav),
[full analysis](../work/audio-research/frankel/boot-streamline-20260912/boot8-first-api/acoustic-tone20000/tone-analysis.json),
and [interpretation](../work/audio-research/frankel/boot-streamline-20260912/boot8-first-api/acoustic-tone20000/INTERPRETATION.md)
retain the entire detected-tone interior with the same fixed 50 ms boundary
exclusions. Maximum adjacent phase step was 0.036210 rad; the entire original
WAV has zero clipped samples. Java MIC0 capture returned 1,357,183 frames;
the native full-run timestamp regression was 192,006.742 Hz. The first-launch
capture source remained `MIC`, not an advertised `UNPROCESSED` source.
The [root properties](../work/audio-research/frankel/boot-streamline-20260912/boot8/getprop-root.txt)
confirm ready flags `1/1`, completed phase and ready bridge;
[device health](../work/audio-research/frankel/boot-streamline-20260912/boot8/device-health.txt)
confirms AoC counters `0/0` and SELinux Enforcing.

The subsequent ordinary 48 kHz Java playback control also passed:
[measurement](../work/audio-research/frankel/boot-streamline-20260912/boot8-java48k/measurement.txt)
reports session status zero, and its independent
[D10 acoustic gate](../work/audio-research/frankel/boot-streamline-20260912/boot8-java48k/tone-qualification.json)
passed the full five-second 12 kHz request (4.9 s interior,
12,000.001288 Hz full-interior carrier, zero phase/dropout/clipping events).
This checks ordinary-rate playback after the reboot-ready 192 kHz setup,
not only a research API stream.

The matched bundle combines the tested system, system_ext and vendor images;
boot8 reproduced boot7 without another flash. The qualified claim is automatic
setup and immediate post-boot use within these first-launch, UI, ordinary
playback and endpoint API tests. Timing is measured, not a guaranteed deadline.
Prior long-run research continuity limitations, unsupported concurrent
primary/research playback, single-tone whole-cycle-slip ambiguity, and the
lack of calibrated or separately isolated high-frequency acoustic response
remain. Do not replace those boundaries with a blanket "all audio verified"
claim.

## Reproducing boot observation and qualification

Use the passive
[boot observer](../scripts/audio/frankel/observe-boot-readiness.sh) during a
real flash/reboot. It does not reboot, root, change a property, open a PCM, or
issue AoC diagnostic commands. Launch after USB disconnect, or pass the old
boot UUID with `--after-boot-id` when arming before reboot:

```bash
scripts/audio/frankel/observe-boot-readiness.sh \
  --output-dir work/audio-research/frankel/boot-streamline-NEW \
  --serial DEVICE_SERIAL --adb-server-port 5038 \
  --timeout-seconds 240 --interval-ms 100
```

The TSV records boot UUID/uptime, both profile flags, the platform bridge,
bootstrap phase, audio-service states, boot-animation state/exit flag, and
AoC restart/coredump counters where readable. Missing/private data stays
`NA`. ADB may not exist early enough to observe every transition; use retained
init/WindowManager logs to fill that gap, not inferred timestamps. The script
collects passive logs only after observation. Its success exit indicates
observed final properties, not acoustic success.

For each reproduced boot, retain:

1. Actual cold-boot attempt count and direct `attempt1` launch,
   first both-ready/bridge-ready time, WindowManager's live Binder release
   log, boot-animation exit/stopped time, and UI availability. Compare by
   monotonic uptime, not wall-clock dates that may change during boot.
2. Evidence that readiness precedes normal UI/input release, with no new AoC
   restart, coredump, allocator ambiguity, or helper failure.
3. Cold ordinary UI clicks and ordinary AudioTrack playback with independent
   D10 recording; correct pitch, expected duration, and the existing
   phase/dropout/clipping gates.
4. Research Java/AAudio playback and all microphone selections; repeat the
   ordinary/research handoff to catch boot-local HAL ownership regressions.

Do not qualify a new revision solely because the launcher appears sooner,
properties become `1`, or a sample-rate header says 192000. The results above
qualify the tested image revision and intervals; changed revisions require
new timing and independent post-boot audio evidence.
