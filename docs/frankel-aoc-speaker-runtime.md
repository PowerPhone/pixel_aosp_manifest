# Frankel volatile AoC speaker runtime contract

Status: the boot-integrated source is aligned with the live-hardware native
q192 path: stock signed AoC firmware, one-period-lag D0 kernel transport, one
dynamic four-bank F1 speaker allocation, H0 192/1536 geometry, F1 source-0
two-S32-slot profile, in-place AudioEntrypoint getters, and stock-priority
`UsfDefaultWorker`. The exact integrated image booted to both readiness
certificates. Both individual speakers passed direct tinyALSA plus Java
`AudioTrack` and native AAudio at 192 kHz with zero xruns; only bounded
first-boundary WRITEI retries are accepted. Acoustic bandwidth remains a
separate external-instrument qualification.

## Selected profile

The selected profile is
`experimental-enum7-q192-tdm12288-192-2xs32-dma-source0`, plus both guarded
in-place AudioEntrypoint getter replacements used by source 0:

- PCM0,D0, stereo S32_LE with a declared 192 kHz frontend,
  `period_size=1920`, `period_count=2`;
- start threshold 1920 frames, so the first complete physical-ring period
  triggers START;
- AoC source 0, two physical S32 slots, 192-frame firmware quantum, and a
  12.288 MHz TDM clock;
- H0 AMixSPKR geometry of 192 frames / 1536 bytes only for enum-7,
  one-millisecond Configure; enum-5/ten-millisecond DeepBuffer retains stock
  480-frame / 3840-byte geometry;
- F1 source-pull getter of 1920 frames on the slow arm;
- 24 code-cave words followed by 22 hooks, including eight words that replace
  the two existing getters in place with `a3 ? 192 : 1920`; and
- exact stock A32 allocator on the final qualified boot; an optional guarded
  branch `0x400a114e: 70d0 -> 25d0` is permitted only when its early
  cache-sync window is proven, and the global `UsfTimer` assertion remains
  stock; and
- A32 `UsfDefaultWorker` current/base priority remains stock at 7/7.

The helper also requires 32 unselected mapper, S16 DMA, 16-bit slot-width, and
other-profile words to remain exactly stock. PCM0,D28, q48, and four-S16 paths
are historical experiments, not image configuration.

### Native q192 two-S32-slot geometry

The direct PCM0,D0 wrapper defaults to `--pipeline q192-s32-2slot` and maps
only to the selected profile. With EP1, ultrasonic mode, and both amplifiers
off, it programs and reads back:

- `TDM_0_RX Sample Rate=SR_192K`;
- `TDM_0_RX Format=S32_LE` and `TDM_0_RX SlotFmt=S32_LE`; and
- `TDM_0_RX Chan=Two` and `TDM_0_RX nSlot=Two`.

Two 32-bit slots at 192 kHz imply a 12.288 MHz bit clock. The userspace
frontend remains PCM0,D0 stereo S32_LE/192000. The qualified target uses
1920x2 and 15,360-byte raw-WRITEI calls, exactly one observed D0 physical-ring
quantum per submission. The one-period-lag kernel profile makes the
1,920-frame start threshold stable without reporting progress ahead of AoC.
For physical output, the direct wrapper snapshots and sets only the selected
codec's stock-route `Digital PCM Volume` to 817: the unprefixed control for
earpiece or `R Digital PCM Volume` for bottom. The inactive codec volume is
never read or written. Cleanup first forces EP1 and both amp-enable controls
off, then restores the selected volume snapshot.

The physical `speaker+0x28c=2` write in the Start cave is early enough for the
TDM and DMA setup, but the later speaker worker never reads that field. Its
two alternative format-copy paths independently load the native frame count
from `speaker+0x298` and multiply it by four words. The profile therefore
keeps `+0x298=192` and changes only those two multipliers:

- `0x403d3c84: 1b22e066 -> 1b22f066`; and
- `0x403d3d70: 1b33e066 -> 1b33f066`.

These are x4-to-x2 shifts, not a frame-quantum clamp. CPU copy and two-S32 DMA
are both `192 * 2 * 4 = 0x600` bytes, matching the native stereo source block
and avoiding the prior `0xc00` walk into the following DMA objects and
`AHWSinkSPKR` stack.
Only after all backend and codec controls are verified may the wrapper enable
ultrasonic mode and one amplifier; `TDM_0_RX Mixer EP1=1` remains the final
activation immediately adjacent to `tinyplay`. Existing `q48-s32` and
`q192-s16` behavior is unchanged.

The named volatile profile must pass its guarded boot apply/readback
transaction. Transport qualification requires declared frames to consume at
nominal wall time, zero xruns, no retry beyond the first physical-period
boundary, stable AoC generation, and individual
physical-endpoint output. Independent wideband response remains unqualified.

### Native q192 four-S16 CPU-Q96 candidate

The host patcher additionally exposes
`experimental-enum7-q192-tdm12288-192-4xs16-dma-source0`. This source-0
variant corrects the overflow observed in the otherwise-equivalent source-14
trial by changing only the two alternative CPU format-copy loop loads:

- `0x403d3c80: 04622da6 -> 0462a060`; and
- `0x403d3d6c: 08622da6 -> 0862a060`.

The encoded 96 is not the producer quantum. Each local path immediately
multiplies it by four 32-bit words, so it copies `96 * 4 * 4 = 0x600` bytes.
That is exactly one native-q192 stereo-S32 source block
(`192 * 2 * 4`) and exactly one four-S16 physical DMA block
(`192 * 4 * 2`). The guarded producer remains 192 frames per millisecond,
the TDM clock remains 12.288 MHz/192 kHz, and the descriptor-frame load at
`0x403d4150` remains stock 192. The profile includes the paired S16 slot-width,
DMA byte-count, CCR, and descriptor-length edits. It includes none of the
early/generic q48 clamps or the q48 descriptor-frame override.

Both format-copy alternatives are an indivisible patch pair. The previous
unclamped source-14 crash copied 0xc00 bytes across 0x600-byte banks and into
the following DMA objects and `AHWSinkSPKR` stack. The corrected composition
is geometry-consistent but remains a live candidate: route survival and byte
counts alone do not qualify its slot ordering or acoustic bandwidth.

## Boot transaction

System-ext init stops `audioserver` before class startup. Vendor post-fs-data
arms a typed boot-local attempted latch; once stock `aocd` and the AoC audio
HAL are running, the system-ext gate claims the latch and starts the root,
oneshot `vendor.powerphone-d10-bootstrap` service. After claiming the latch,
the gate stops and waits for both audioserver and
`vendor.audio-hal-powerphone`, starts attempt one asynchronously, and returns
control to init; the bootstrap then:

1. clears and reads back the speaker and D10 readiness properties;
2. establishes the strict raw-capture mixer state using per-index INTEGER
   access and quarantines unadvertised capture PCMs;
3. runs `frankel_aoc_speaker_patch apply --allow-incomplete-boot
   --skip-zero-validation`, requires
   exact stock allocator/object provenance, installs and cache-synchronizes the
   live fallback, allocates/rebases four speaker banks, installs H0/F1 native
   q192 geometry without changing worker priority, and requires its certificate.
   The boot-only flag skips the 192-command full-allocation zero scan, while
   retaining allocation range/alignment, first/last accessibility, geometry,
   and commit readback guards;
4. runs `frankel_aoc_d10_patch apply --allow-incomplete-boot` and requires its
   certificate; and
5. lets exact service-state/phase triggers run at most two retries and then the
   certificate-aware finalizer, all as asynchronous oneshot services.

The state machine advances through `armed`, three attempt phases,
`finalizing`, `releasing`, and `complete`. Each transition publishes its phase
immediately before starting the service in the same short action. Init consumes
that queued phase edge only after the start, so either a later stop or an
immediate start failure advances exactly once. Long AoC work never occupies init's
action queue or delays unrelated HAL property actions. On both success and
fail-open, finalizer completion starts a fresh PowerPhone sidecar and only then
releases `audioserver`.
Init service stops are asynchronous, so both `stopped` waits are mandatory.
This lifecycle prevents an AIDL Module instance from retaining startup stream
configs owned by a dead audioserver.

Speaker runs first because real Frankel boots showed that its factory-mailbox
transaction cannot complete reliably after D10's resident diagnostic profile
has been installed. D10 runs last, and its final whole-F1 cache synchronization
covers the already-installed speaker edits. A later bounded attempt may
re-certify the already-selected speaker state idempotently before retrying D10.

The claim is the gate's first command and remains one for the rest of the
boot. Later deliberate audioserver/HAL stops therefore cannot replay the
bootstrap action or force audioserver back up during tinyALSA qualification.
An asynchronous 60-second watchdog starts when vendor init arms the latch. The
main transaction stops it after claiming the latch. Its trigger also requires
the watchdog service to be running and expiration to remain zero, so a
published timeout or stopped watchdog wins init's all-property sweep. If the
compound aocd/HAL prerequisites never converge, the watchdog asks the platform
gate to claim the same latch and start the asynchronous finalizer; its stopped
event reaches the common ordinary-audio release. An unexpected watchdog-service
stop while both latch and expiration remain zero enters that same fail-open path.
Both watchdog exits use the same audioserver/sidecar reap-and-restart sequence;
the fail-open path therefore cannot reintroduce stale sidecar stream state.

Each mutation attempt fails closed. After the bounded attempts, the finalizer
revokes both readiness properties and restores stock PCM modes; the gate then
restarts the sidecar and releases ordinary audio so a certification failure
does not hold the boot indefinitely.
`--allow-incomplete-boot` bypasses only the `sys.boot_completed` check, not
hardware, build, PCM, generation, memory, or readback guards.
`--skip-zero-validation` is also apply-only and bypasses only
`RequireZeroAllocation`; the boot path uses the same early-return, two-second
absolute dump reader as the D10 helper. The full scan remains the standalone
default.

The D0 kernel transport is also a paired-module contract. The selected
`aoc_alsa_dev_util.ko`
(`398eaca28da2d97431b1398b5df93e34e594389fa691616416354b4705bde4e3`,
including EP6 192 kHz admission; normalized D0 profile
`37cc7ff81bf9804677699d612621ed75a177597e773709ec54924916811818e6`)
must be installed with the zero-write-pointer-reset `aoc_core.ko`
(`f4b7c9daad2fb3cb2ddc9fa8f80381629b3ffe048194348924e9f7a0ead1024c`).
Stock `aoc_core.ko` advances an already-zero producer write pointer by a full
ring during reset, so the patched ALSA module alone is not a valid candidate.

## A32 allocator, priority, and F1 guards

The image-time firmware profile is exact stock. At runtime the native helper
reads aligned A32 word `0x400a114c`, accepts only stock `002870d0` or live
destination `002825d0`, and separately requires
`0x4009e0cc=8efd90bb`, proving the old global timer-assertion NOP is absent.
On the final qualified boot the early timer window was unavailable, so the
helper deliberately retained `002870d0`. After the Android audio warm-up,
the ordinary F1 allocation and complete speaker rebase succeeded. The
boot-local A32 allocator readiness property therefore correctly remained
zero.

If the optional A32 fallback is eligible, its I-cache path validates the fixed
work-pool pointer and bounded live
state, then resolves the exact five-second TMD3743 OUTPUTTER timer. Its vtable,
worker, callback, context, address range, and alignment must all match. The
helper temporarily points that callback at AoC's own whole-cache invalidator,
verifies the armed timer, waits seven seconds, then restores and re-reads the
stock callback. Every attempted callback write enters the restoration path.
The invocation is timing-inferred, while object/readback/generation guards are
exact. Before and after this transaction, the reviewed 0x50-byte TCB at
`0x401658f8` must retain current/base priority 7/7; no scheduler field is
written. Reboot is the supported A32 rollback.

Before profile hooks, the helper issues exactly one aligned 0x3000 F1 heap
allocation, verifies it is zero, and divides it into two 0xc00 CPU banks and
two 0xc00 DMA banks. It validates the complete idle speaker and RingBuffer
objects, publishes capacities before backing pointers, and preserves the
allocation in scratch across an interrupted pre-commit retry. A partial commit
or a second allocation is forbidden and requires reboot.

The H0 cave at `0x403f0c44` keeps the stock `3 * period` multiplier unless
`config[18] == 1` and `config[1].bits[4:2] == 7`; only that q192 profile scales
the multiplier by four before returning to the untouched frame/byte shifts at
`0x403ea946`. Thus D0 obtains 192/1536 while a 48 kHz ten-millisecond
DeepBuffer request remains 480/3840 and fits its stock shared ring. The helper
requires the legacy shift words at `0x403ea948` and `0x403ea954` to remain
stock. Because H0 has no proven live I-cache invalidator, it fills all five
cave words before atomically connecting `0x403ea940`, while the exact
pre-Configure idle speaker object proves no speaker activation has occurred.

Every F1 read/write requires exact Frankel/build/card identity, closed and
unowned PCM0,D0, stable `restart_count`/`coredump_count`, exact source bytes,
and destination readback. Mixed state is never repaired. After installing all
46 words, the helper invokes the reviewed F1 whole-I-cache invalidator through
a temporary `HD Mic gain (cB)` dispatch redirect, restores that pointer, and
rechecks selected and unselected words before publishing readiness. `revert`
restores F1/H0 code only; reboot restores the A32 allocator, allocation, and
all other volatile state.

## Android output contract

`IModule/powerphone` exposes exactly two explicit stereo I32/192 kHz BUS
devices. Each uses a 7,680-frame (40 ms) framework/FMQ queue backed by exact
PCM0,D0 1920x2 ALSA geometry:

- `POWERPHONE_C0_D0_EARPIECE`;
- `POWERPHONE_C0_D0_BOTTOM` (bottom-speaker candidate).

The route layer enables exactly one amplifier. There is no composite `BOTH`
device: simultaneous amps watchdoged F1 `mainTask`, so the HAL, app suite, and
tinyALSA wrappers reject that combination. Google's default module remains
responsible for ordinary media/policy routes; research clients explicitly
select a PowerPhone BUS device.

The selected HAL patch stack requires the playback worker to enter the
hardware-stable `SCHED_FIFO/90` policy and fails start before route binding
if promotion is unavailable. It then waits until the first complete nonzero
client burst before binding EP1 or opening D0 and uses a version-scripted
scalar facade over statically embedded legacy
tinyALSA and submits one 1,920-frame period per raw WRITEI. Its explicit
1,920-frame threshold starts after one complete physical-ring quantum. It deliberately bypasses
generic playback `SYNC_PTR` position refinement because interleaving that
control ioctl with the RW sequence made the following `WRITEI`
fail. The facade exposes the cumulative xrun count, including internally
recovered EPIPEs; every observed xrun or nonzero write status fails the client
stream closed.

Immediately before final EP1 activation, the HAL snapshots and temporarily
sets `PCM Stream Wait Time in MSec=200`. The vendor driver copies that
card-wide value into D0 during `hw_params`; the HAL restores the prior card
value immediately after `pcm_open` returns and retries restoration on every
setup/open cleanup path. This closes the first-ring stability difference seen
on hardware without treating the wait as a software pacer.

## Selected one-allocation buffer rebase

Native q192 needs four 0xc00-byte banks: CPU TX/source staging at speaker
`+0x2c4/+0x2c8`, plus the `SPKR_TX_DMA`/`SPKR_RX_DMA` RingBufferStatic
backings. One guarded `aligned_alloc(64, 0x3000)` succeeded. A second identical
invocation exhausted `HeapMicroAllocGenericInternal` and restarted AoC.
Consequently the boot helper makes exactly one allocation and derives all four
backings at offsets 0, 0xc00, 0x1800, and 0x2400. Allocation addresses are
runtime values and must never be hard-coded. The Python helper remains the
reference implementation; the installed native helper owns boot mutation.

## Qualification status

The exact boot-integrated image completed the allocation, H0/F1 transition,
cache synchronization, D10 certification, and both readiness publications on
real hardware. Direct 192 kHz playback passed independently on bottom and
earpiece with full 4608000-byte transfers and zero xruns. Java `AudioTrack`
and native AAudio also passed both exact BUS routes with active
S32_LE/stereo/192000/1920x2 hardware geometry, complete frame transfers, zero
framework underrun or HAL xrun, and stable AoC counters.

The remaining physical speaker gate requires an independently characterized
wideband microphone/analyzer and evidence of no 24/48 kHz brick-wall cutoff;
the phone's own D10 microphones cannot independently assign a self-loop
rolloff to the speaker. See
`docs/frankel-powerphone-final-qualification.md` for the exact endpoint
matrix and evidence paths.

Implementation paths:

- `tools/audio/device/frankel_aoc_speaker_patch/`;
- `tools/audio/device/frankel_powerphone_d10_bootstrap/`;
- `work/aosp/hardware/interfaces/audio/aidl/default/powerphone/`;
- `scripts/audio/frankel/`; and
- `../csr460-powerphone/`.
