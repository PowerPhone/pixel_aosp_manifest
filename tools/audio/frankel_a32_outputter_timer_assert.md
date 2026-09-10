# Frankel A32 `OUTPUTTER` timer assertion

This note applies to the stock Frankel `CP2A.260805.005` AoC firmware:

```text
vendor/firmware/aoc.bin
sha256 ac6d7d86e6aa78379bfa3db5eaea4dadebf8113dc8f46aab52d55f3987064abd
```

The recurring log is:

```text
A32 (task=OUTPUTTER): Assertion failed: err == kErrNone,
usf_timer.cc, 243 [InvokeCallback]
```

## Decoded failure

The A32 image begins at signed-file offset `0x00a6fdc0` and is mapped at
`0x40000000`. `UsfTimer::InvokeCallback` is at `0x4009e05c`. When the timer has
a worker, it calls `0x400a0bea` with an eight-byte callback object. That helper
allocates a 0x28-byte work item from the global pool reached through
`0x40131094`, installs the callback, and enqueues it. A nonzero allocation
result takes the assertion at `0x4009e0ce`.

The allocator at `0x400a111e` returns error 6 when its freelist is empty. More
importantly, once static current reaches 97 it normally tries a 40-byte dynamic
allocation and, if that allocation fails, returns error 6 immediately without
trying the remaining 31 entries of its 128-entry static pool. Its pool object tracks the
current/peak static allocations at `+0x3c/+0x40`, allocation failures at
`+0x48/+0x4c`, dynamic current/peak at `+0x50/+0x54`, and dynamic failures at
`+0x58/+0x5c`. The static-to-dynamic threshold is 96 work items. Therefore the
assertion is work-pool exhaustion, not an error returned by the timer's user
callback and not direct evidence that either F1 speaker profile is invalid.

Retained coredumps and current hardware show two mutually exclusive runtime
construction layouts for this timer under the same Android build, AoC firmware
version `15070001-polygon`, and signed firmware image: owner/context
`0x4016df48/0x4016df08` or `0x4016e048/0x4016e008`. This is not a firmware-build
signature difference. In either layout the object has callback `0x400a7a2d`,
worker `0x40165730`, vtable `0x4010a330`, and a fixed 5,000,000,000 ns period.
The callback is the TMD3743 ambient-light/proximity sensor watchdog in
`tmd3743_device.cc`: it reads status/enable registers, may reset that optical
chip, and reschedules itself. It is not the q48 speaker service cadence; q48 at
192 kHz is a separate 250 us/4 kHz F1 data-path cadence.

The decisive instructions are:

```text
runtime 0x4009e0ca: bl    0x400a0bea
runtime 0x4009e0ce: cbnz  r0,0x4009e136
signed file 0x00b0de8e: 90 bb
```

Replacing `90 bb` with Thumb NOP `00 bf` silently drops any USF timer callback
whose enqueue fails. It is a global behavior change, not an `OUTPUTTER`-only
fix, and is retained only for historical reproduction. It is not part of the
PowerPhone image.

## Selected allocator fix

The narrow fix preserves the assertion for genuine exhaustion. At A32
`0x400a114e`, signed-file offset `0x00b10f0e`, it changes `70 d0` to `25 d0`:
the dynamic-allocation-failure branch targets the existing locked static
freelist path at `0x400a119c` instead of the immediate error-6 path at
`0x400a1232`. If the static freelist is also empty, unchanged firmware still
increments its failure counter and returns error 6.

The historical cold profile is `source0-4s32-allocator-fallback`; its offline
patcher requires exact whole-file stock and patched SHA-256 provenance. The
production device still boots Google's exact signed firmware because GSA
rejects the modified image. The native helper instead writes only the aligned
word `0x400a114c=002825d0` into reboot-volatile SRAM after exact guards, invokes
the firmware-native whole-cache invalidator through the uniquely validated
OUTPUTTER layout, restores the callback, and separately proves the old
assertion remains stock. No arbitrary timer-address scan or global assertion
bypass is part of that live path.

## Diagnostic traffic mitigation

The original live speaker patch loop performs repeated nested guards. With the
native helper enabled, one changed word can still cause an outer pre-read, a
Python-side pre-read, the helper's dump/set/dump, and an outer verification
read. A 31-word profile consequently generates about 250 AoC diagnostic
commands; a 35-word profile generates about 280. This traffic can create a
large transient allocation peak and should not overlap playback, although the
retained evidence does not identify one permanent leaking producer.

Use the patcher's explicit `--minimal-traffic` mode with the updated native
helper. It validates one grouped snapshot, emits exactly one `write-raw` SET
per changed word in safe cave/hook order, verifies one grouped snapshot, and
performs the bounded F1 cache flush. The 31-word four-S32 profile requires 14
before dumps, 31 SETs, and 9 after dumps, plus the cache-flush transactions (58
total instead of roughly 250). Let the helper's pre-drain/grouped-read logic
own `/dev/acd-debug`; do not start a competing reader that could steal guard
output. Observe AoC restart/coredump counters for at least 30 seconds afterward
before beginning playback.

If the allocator fallback still reaches the assertion after a fresh reboot,
the next read-only proof is a single core-1 dump of the pointer at `0x40131094`
and the allocator counters above before and after the profile operation. A
static failure then proves the complete 128-item pool was exhausted; a dynamic
failure records heap pressure before fallback. Do not add repeated polling,
because polling the diagnostic service would recreate the workload being
measured.
