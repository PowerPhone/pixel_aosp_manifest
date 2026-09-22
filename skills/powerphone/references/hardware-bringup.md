# Hardware, kernel, DSP, and tinyALSA bring-up

Use this procedure to locate and remove the actual sample-rate bottleneck. The
names and commands are examples; derive every target-specific value from the
booted build and its sources or extracted files.

## 1. Freeze the baseline

Record the exact product, vendor build, kernel release, boot image pair, active
slot, audio card names, module identities, and stock behavior. Preserve known
good boot/rollback images before a live write. Keep serials and proprietary
artifacts in ignored work directories.

With all media, call, assistant, camera, hotword, and recording clients idle,
collect at least:

- `/proc/asound/cards`, `/proc/asound/pcm`, each relevant PCM `info`, `status`,
  and active `hw_params`;
- a complete `tinymix` dump and the stock route-specific mixer XML;
- audio policy/platform/effects XML, HAL service declarations, VINTF fragments,
  init RC, and `dumpsys media.audio_flinger` / `media.audio_policy`;
- DT/DTBO audio nodes, clocks, pinctrl, regulators, IOMMU/firewall ownership,
  codec compatibles, and DAI links;
- kernel modules, symbols, strings, rate tables, DAI masks, ring limits, and
  logs from one known-good stock playback and capture; and
- DSP or audio-coprocessor firmware identity, services, mixer controls,
  crash/restart counters, block-size messages, and signed-loading boundary.

Exercise a stock-supported rate first. A failed higher-rate `tinyplay` or
`tinycap` is useful baseline evidence only if the exact rejecting layer is
captured.

## 2. Draw one chain per endpoint

Trace both control and data flow. A useful worksheet is:

```text
Android device/profile/address
  -> policy mix port and route
  -> audio HAL module/stream
  -> ALSA card, PCM frontend, format, channels, period geometry
  -> DAPM/mixer connection and DSP service
  -> backend DAI, slot format, clocks, DMA/ring geometry
  -> speaker codec/amplifier/transducer

physical microphone/hole
  -> rail and PDM pad/controller
  -> PDM clock, edge/polarity, decimator and DSP block
  -> DSP service and ALSA frontend
  -> HAL/policy/API client
```

For every edge record: owner, accepted rates, actual running rate, format,
channels/slots, frame quantum, buffer capacity, and evidence source. The
maximum end-to-end rate is the minimum usable capability across this graph.
Keep separate maxima for each endpoint and direction. Probe a justified
descending set from the hardware's advertised families rather than forcing all
paths to share 192 or 384 kHz; preserve both 44.1-kHz-family and 48-kHz-family
rates when the clocks genuinely support them.

Do not assume that an upstream codec driver matches an OEM backport. Compare
the exact compatible, revision, register programming, firmware, and module
identity before rebuilding or transplanting source.

## 3. Reconcile clocks and geometry

For a conventional TDM/I2S backend, check at least:

```text
bit_clock = sample_rate * physical_slot_count * slot_width_bits
period_bytes = period_frames * userspace_channels * container_bytes
buffer_bytes = period_bytes * period_count
```

The physical slot count may exceed userspace channels. Container width may
also differ from valid sample bits. Confirm codec sysclk/PLL constraints and
the actual programmed BCLK rather than relying on the equation alone.

For each PDM microphone, establish:

```text
PDM clock -> modulator limit -> CIC/FIR decimation stages -> PCM output rate
OSR = PDM clock / PCM rate             # only when that ratio describes the
                                       # actual selected decimation chain
```

Find the microphone's justified maximum PDM clock from exact part data when
available. Otherwise combine board evidence, controller limits, vendor
profiles, bounded live trials, spectrum, and stability; do not turn a generic
MEMS range into a device guarantee. A firmware field named divisor, mode, or
rate can encode a profile rather than a literal clock. Record microphone rail
voltage, clock duty cycle/mode, and temperature because a part's clock limit can
depend on all three.

When raising rate, preserve the intended period duration unless a DSP contract
requires another quantum. Recompute every frame-count, byte-count, ring,
watermark, timeout, producer/consumer step, and timestamp conversion. Verify
that the new period fits all driver and firmware limits. A clean open followed
by repeated halves, zeros, stalls, or a watchdog usually indicates a geometry
or scheduling failure, not a working high-rate path.

When changing a ring or its reset path, audit initialization and first-write
behavior separately from steady-state cadence. For an empty ring, prove what
equal read/write pointers mean and whether reset must advance either side. Test
zero, nonzero, and wrap cases against the actual producer/consumer convention.

## 4. Change the lowest layer first

Prefer the least invasive layer that removes a proven bottleneck:

1. Exposed mixer/DT/clock/profile configuration.
2. Kernel constraint, DAI mask, rate-code map, ring geometry, or codec driver.
3. DSP service/profile/block geometry or scheduling.
4. A target-scoped alternate HAL route.
5. A carefully reviewed firmware or binary-module patch when source is absent.

Changing only an ALSA rate mask is never sufficient evidence. Confirm that the
backend and producer/consumer actually run at the selected rate.

If source is unavailable, make binary changes reproducible: pin the exact
input identity, use expected original bytes at every site, explain each site,
write an output atomically, and reject unknown or already-mixed states. Keep
narrow derivation experiments separate from the one whole-file state selected
by the image build.

Treat interdependent binary modules as a single selected state. If a frontend
depends on core ring reset, mailbox, allocator, or cache semantics, use one
selection to patch/restore the complete pair, attest each installed and
target-files copy, and reject a mixed stock/patched combination.

For a rebuilt or replaced kernel module, also close the Android GKI boundary:
match the running kernel release and KMI/symbol versions, toolchain, module
signature and compression, destination (`vendor_dlkm`, `system_dlkm`, or the
boot ramdisk), dependency/load order, and the AVB chain containing that
partition. A module that compiles but cannot load into the packaged kernel is
not a candidate.

Persistent DSP firmware replacement may fail an OEM secure-loader
authentication path even when its bytes are correct. A boot-volatile patch
after authenticated firmware starts is an option only when a guarded access and
cache-synchronization mechanism is proven. Integrate either method only after
live qualification and with fail-closed research-route ordering.

An apparent application-processor-accessible PDM MMIO address is not proof that
the current audio coprocessor can be bypassed. Direct ownership also needs known
clocks, reset, power, security, IOMMU/firewall, DMA/interrupt, FIFO semantics,
and a coordinated handoff from the current owner. Treat an access abort or
watchdog as a failed ownership hypothesis, not permission to probe blindly.

Pin the exact tinyALSA implementation used by each test and production process.
Different Android tinyALSA variants can export the same unversioned `pcm_*`
symbols while using incompatible public/private layouts and different byte- or
frame-oriented write and XRUN-recovery semantics. Match headers to libraries,
keep opaque handles within one ABI, and inspect final ELF dependencies and
exports when more than one implementation must coexist.

## 5. Make live trials transactional

Use one fresh evidence directory per boot/trial. Before mutation:

- identify the exact device/build and root-userdebug state;
- stop or quarantine Android audio owners;
- prove all conflicting PCMs closed by both ALSA state and fd-owner scan;
- snapshot every mixer value and live patch word to be changed;
- snapshot DSP restart/coredump counters and relevant logs; and
- install host and device-side cleanup traps before enabling an amp, mic rail,
  polling loop, or route.

For volatile firmware writes, require a uniformly known entry state. Guard
each write with expected bytes, target readback, and stable restart generation.
Install data/code first and the activation hook last; revert activation first.
If executable memory changes, use the target's proven instruction-cache
synchronization rather than assuming data readback updates execution.

Enable output amplifiers last, one physical endpoint at a time, at low gain.
For capture, enable one logical selector at a time until geometry and mapping
are proven. Never probe a control known to block while its stream is active.

On error, turn off amps/routes, stop and reap tinyALSA, stop polling/DMA, return
ownership, restore mixer state, and revert live patches in the dependency order
proved for that target. If any prerequisite cannot be proven, preserve logs and
reboot instead of guessing.

## 6. Direct tinyALSA pass gate

For each candidate rate and physical endpoint require:

- the intended PCM opens with exact rate, format, channels, period, and buffer;
- the active backend clock/profile and intended route are independently seen;
- bytes and wall-clock duration agree within the endpoint's final-buffer rule;
- capture blocks are fresh, nonzero, and non-repeating;
- playback/capture completes without XRUN, short transfer, callback stall,
  DSP restart, coredump, watchdog, or cleanup failure; and
- repeated runs remain stable after route teardown.

Tune buffers from measured scheduling behavior. Increasing period count can
absorb latency; changing period frames can violate DSP cadence, so keep period
time and firmware quantum explicit. Only after this gate should the route be
made visible to Android clients.

Define the required run duration, repeat count, and allowed final-buffer
difference before testing. Do not shorten or weaken them after a failure; retain
shorter successful runs as diagnostic evidence rather than promotion evidence.

Some drivers remove or never publish per-substream procfs `hw_params`. Absence
of that file is not itself a stream failure and a fabricated substitute is not
evidence. Use a truthful alternative such as a guarded driver trace, HAL-side
`pcm_get_config`, an exact open contract plus backend profile readback, or a
target-specific observer, and record the limitation.
