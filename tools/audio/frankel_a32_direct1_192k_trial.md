# Frankel A32 Direct1 acoustic-PDM trial (experimental)

Status: **reverse-engineered but currently blocked; not run on hardware**. The
instruction candidates below have no proven safe delivery mechanism. They must
not be enabled by the default Frankel build or applied by mutating the signed
`aoc.bin` in place.

The offsets below apply only to the stock Frankel `CP2A.260805.005` firmware:

```text
file: vendor/firmware/aoc.bin
size: 24791040
sha256: ac6d7d86e6aa78379bfa3db5eaea4dadebf8113dc8f46aab52d55f3987064abd
```

## What this route is, and is not

Direct1 is implemented by the A32 VD6282 flicker-sensor driver. It is not an
existing acoustic-audio service. In its stock configuration, it reads optical
PDM from controller ID 4, converts PDM in software, and transports the result
through the USF flicker FlatBuffer API.

The underlying A32 PDM manager is generic, however. Its ID table is:

| ID | physical register base | A32 virtual base | IRQ | DMA channel |
|---:|---:|---:|---:|---:|
| 0 | `0x01c0a000` | `0x81c0a000` | 183 | 12 |
| 1 | `0x01c0b000` | `0x81c0b000` | 184 | 14 |
| 2 | `0x01c0c000` | `0x81c0c000` | 185 | 16 |
| 3 | `0x01c0d000` | `0x81c0d000` | 186 | 18 |
| 4 | `0x01c0e000` | `0x81c0e000` | 187 | 20 |

Frankel's DT maps PDM0, PDM2, and PDM3 to the three built-in DMIC clock/data
pairs and exposes a separate `XAOC_PDM0_FLCKR_*` pin function for the flicker
sensor. The vendor registry selects `pdm_id=4` for VD6282. Changing that
registry value to 0, 2, or 3 therefore asks an optical-sensor software client
to consume a built-in microphone controller. That interpretation is supported
by the manager table and DT, but the reroute has not yet been demonstrated on
hardware. ID 1 should not be the first trial because Frankel's schematic data
does not identify an installed DMIC on it.

This path does not expose raw PDM to Android. A32 performs a simple software
conversion and sends signed PCM-like samples through the USF flicker service.
It is independent of tinyALSA and AudioFlinger.

## Relevant A32 data flow

- `0x780b4de2` opens the generic PDM handle while the VD6282 device is
  initialized. The `UsfPdmConfig` supplied from the registry is two signed
  32-bit values: `pdm_id`, then `pcm_rate_hz`.
- `0x780b6214..0x780b6229` turns `flicker_mode == 1` into a raw flag and calls
  `0x7808a622`. That function selects the hardware vtable's `+0x78` raw start
  instead of its `+0x74` PCM-converting start.
- `0x780ba7f8..0x780ba8d0` repeatedly reads up to 128 raw PDM bytes from the
  generic manager. It popcounts both nibbles of every byte, accumulates exactly
  `direct_mode_chunk_size_in_bits`, emits one `int16` sample, and sends blocks
  of 400 samples. A chunk size of 8 is structurally supported: the loop adds
  eight bits per input byte and the parser already requires a multiple of 8.
- `0x780b7ba6..0x780b7c78` parses `pdm_clock_khz` and
  `direct_mode_sample_rate_hz` through 16-bit temporaries. Consequently,
  192000 cannot be represented by the registry property. The chunk must be
  forced to 8 for a 1.536 MHz clock.
- `0x780b5f58..0x780b5fbb` copies the mode-specific geometry into the flicker
  capture object and computes its reported rate as `clock_hz / chunk_bits`.

The converter offers bandwidth but very little amplitude resolution at an OSR
of 8: an unfiltered sample initially has only nine possible popcount values. This
is a research bypass, not a quality-equivalent replacement for the production
audio decimator.

The PDM clock is not an arbitrary-frequency generator. The underlying clock
object at `0x4008e67e` divides a 38.4 MHz parent by an integer in the range
1..63 and returns the actual divided rate. The manager rejects the result if it
does not exactly equal the requested rate. In particular, a 3.072 MHz request
is rounded to 38.4 MHz / 13 = 2.953846 MHz and then rejected. For a 192 kHz
software output with a chunk constrained to a multiple of eight:

```text
(integer clock divider) * (PDM bits per output sample) = 200
```

The lowest-clock practical exact solution is divider 25, chunk 8, giving a
1.536 MHz PDM clock and 192 ksample/s. The resulting OSR is intentionally low
and must be evaluated for noise and usable ultrasonic bandwidth on hardware.

## Exact guarded instruction candidates

The signed-file offset includes the 0x1000 superbin header. The mapping offset
is `signed_offset - 0x1000`, matching the loaded superbin layout. Physical
addresses below assume the live Frankel AoC carveout begins at `0x8d200000`.
These addresses are for audit only: they are not AP-writable on the secure boot
path described below.

| Purpose | A32 VA | signed file | mapping | physical | original bytes | replacement bytes |
|---|---:|---:|---:|---:|---|---|
| use 1.536 MHz when deriving the manager ratio | `0x7808a370` | `0x8ccf0` | `0x8bcf0` | `0x8d28bcf0` | `4df20041c0f23001` | `47f20001c0f21701` |
| request and verify a 1.536 MHz physical PDM clock | `0x7808a4bc` | `0x8ce3c` | `0x8be3c` | `0x8d28be3c` | `4df20048c0f23008` | `47f20008c0f21708` |
| use an 8-bit Direct1 software conversion chunk | `0x780b5f6e` | `0xb88ee` | `0xb78ee` | `0x8d2b78ee` | `d4f85821` | `082200bf` |

The clock replacements decode to `movw/movt` pairs loading `0x00177000`
(1536000) into `r1` and `r8`. The chunk replacement decodes to
`movs r2,#8; nop`. Every replacement has the same length as the guarded input.

There is also an audited way to force Direct1 in code:

```text
A32 VA:       0x780b6214
signed file:  0xb8b94
mapping:      0xb7b94
original:     95f85411       ldrb.w r1,[r5,#0x154]
replacement:  012100bf       movs r1,#1; nop
```

Do not apply that fourth patch in the planned trial. Set `flicker_mode=1` in a
target-specific registry overlay instead, so the mode is visible and
reversible. Keep `pcm_rate_hz=16000`. Set `pdm_clock_khz=1536`; that property
sets the VD6282 object's rate metadata, while the two clock instructions above
configure the generic PDM manager itself.

The first clock literal changes the normal 16 kHz conversion ratio from 25 to
12. The raw-start vtable path sets the controller's raw-bypass bit, so that
normal conversion ratio should not decimate Direct1 data. The second literal
is the actual hardware clock request, whose return value is compared against
1536000. Divider 25 is exact for the 38.4 MHz parent. This has not yet been
tested on Frankel hardware.

## Write-path constraints

The production debug command nominally accepts core 1 for A32, but access to
these VAs has not yet been confirmed on the attached Frankel. The only safe
first operation is a read guard:

```sh
python3 tools/audio/aoc_factory_diag.py --core 1 dump 0x7808a370 8
# expected: 4df20041c0f23001

python3 tools/audio/aoc_factory_diag.py --core 1 dump 0x7808a4bc 8
# expected: 4df20048c0f23008

python3 tools/audio/aoc_factory_diag.py --core 1 dump 0x780b5f6e 4
# expected: d4f85821
```

Do not issue the corresponding debug writes after boot. Both clock literals
execute when the PDM handle is opened during A32 device initialization. USF
enable/disable starts and stops the existing handle; it does not reopen it.
Cross-core writes also provide no demonstrated A32 instruction-cache
invalidation. A successful read would prove only the address mapping, not a
safe or effective live-patch procedure.

The kernel post-authentication DRAM writer is also unavailable. Its first real
hardware trial panicked with an asynchronous SError immediately after
`AOC secure booting enabled`; the secure SEM log reported `NS_WR_EN=0`. That is
direct evidence that the non-secure AP mapping is write-forbidden at this
point. The earlier log-string canary was not proof of a successful write.

Therefore the instruction table above is not an executable trial manifest.
Persistent code mutation can resume only after one of these is independently
established:

- a GSA-approved way to modify the authenticated backing before the firewall
  becomes read-only while preserving the authenticated image contract;
- a firmware-owned A32 service that performs guarded code/data writes and an
  explicit device teardown/re-probe with instruction-cache maintenance; or
- a separately signed research AoC firmware accepted by the production boot
  chain.

## Firmware-owned data/MMIO route (read guards not yet run)

There is a narrower runtime possibility that does not modify authenticated
instructions. `CMD_DBG_MEM_DUMP` and `CMD_DBG_MEM_SET` nominally route a request
to core 1. If a read-only hardware trial proves that core 1 performs the access
itself, it may be able to update A32 heap data and the A32-visible clock divider
without violating the AP `NS_WR_EN=0` firewall. This is not yet proven and is
not a reason to issue a write.

The generic PDM-handle list head is at A32 address `0x40130e88`. For each
64-byte handle `H`, the audited fields are:

| Field | Meaning | Expected VD6282 value |
|---:|---|---:|
| `H + 0x05` | PDM controller ID | `4`, or the explicitly rerouted ID |
| `H + 0x08` | normal PCM rate | `16000` |
| `H + 0x0c` | main PDM hardware object `M` | non-null pointer |
| `H + 0x14` | callback | `0x400ad01d` |
| `H + 0x18` | VD6282 client object `C` | non-null pointer |
| `H + 0x3c` | next handle | pointer or zero |

The client must cross-reference the handle at `C + 0x6c`. Its relevant
configuration is `pdm_clock_hz` at `C + 0x14c`, `flicker_mode` at
`C + 0x154`, and Direct1 chunk bits at `C + 0x158`. The capture-configure
routine at `0x780b5f58` copies those values to its working object on the next
enable, sets the raw flag, and computes the callback rate as clock/chunk.

The main hardware object must have vtable `0x400f99f4`. `M + 0x14` points to
the clock object `K`, and `M + 0x70` caches the current PDM clock. The clock
object must have vtable `0x400f9ac4`, index 2 at `K + 0x08`, and 38.4 MHz at
`K + 0x0c`. A live-object dump corrected the index-2 clock mapping. The
clock object's base and stride fields resolve to three separate register
groups in the A32 address space; the earlier `0x824d2de0/3000/4760`
calculation used incorrect strides.

| Register group | Addresses | Known field |
|---|---|---|
| divider | `0x824d1020`, `0x824d1024`, `0x824d1028` | divider is in bits 5:0 of `0x824d1024` |
| source mux | `0x824d0e00`, `0x824d0e04`, `0x824d0e08` | preserve all fields during a divider-only trial |
| gate | `0x824d07a0`, `0x824d07a4`, `0x824d07bc` | gate status is bit 8 of `0x824d07bc` |

Source/divider status bit 0 is a transient write acknowledgement. On the real
device it rose after a value-preserving store and later returned to zero while
the selected source, divider 12, cached 3.2 MHz rate, and AoC health remained
unchanged. Idle validation must accept exact status words zero or one; a rate
setter still polls for the acknowledgement immediately after its store.

Stock 3.2 MHz uses divider 12. The exact 1.536 MHz rate uses divider 25. The
vendor SetRate routine at `0x4008e67e` performs a read/modify/write of only the
low six divider bits. A future trial must reproduce the complete traced
divider/source/gate sequence and verify gate status bit 8; it must not use the
invalid `0x824d2de0/3000/4760` mapping or overwrite unrelated register bits.

The first trial is read-only. Resolve and validate each dynamic pointer before
following it:

```sh
python3 tools/audio/probe_frankel_a32_direct1.py --pdm-id 4
```

That probe contains no memory-set command. It starts at `0x40130e88`, limits
pointer traversal to aligned A32 address windows, validates every
cross-reference and vtable above, and reads the clock register triplet last.

If every guard succeeds, a later explicitly acknowledged, data-only trial can
use a target registry overlay with `flicker_mode=1`, `pdm_clock_khz=1536`, and
the selected `pdm_id`. With the flicker sensor disabled and F1 quiesced for the
same PDM controller, it would:

1. preserve all non-divider bits and change only divider bits 5:0 from 12 to
   25 at `0x824d1024`, then require the complete divider/source/gate status
   transitions used by SetRate, including gate status bit 8 at `0x824d07bc`;
2. update the cached clock `M + 0x70` from 3200000 to 1536000;
3. update `C + 0x158` from its parsed value to 8 before the next sensor enable;
4. enable Direct1, which copies clock/chunk to the working capture object and
   selects raw CONTROL bit 22 in the PDM controller.

This route still needs a successful core-1 read probe and an exact register
snapshot before a guarded writer can be implemented. It would be a per-boot
runtime setup, not a persistent AoC firmware patch. A reproducible image would
need an explicit opt-in init service after the trial is proven.

## Staged real-device experiment after a delivery path exists

Use a separately named trial artifact at every stage and retain a known-good
boot image. A failure to initialize the sensor path is a reason to revert, not
to add unguarded writes.

1. Boot stock firmware and run `usf_flicker_capture --probe`, followed by a
   short stock PDM4 optical capture. This validates the private libusf ABI and
   permissions without rerouting a microphone.
2. Run only the core-1 handle/object/MMIO read guards above. Stop if any vtable,
   cross-reference, parent clock, or divider value differs.
3. After a separately reviewed guarded data/MMIO helper exists, select
   `flicker_mode=1`, `pdm_clock_khz=1536`, divider 25, and chunk 8, still on
   optical PDM4. Capture for two seconds. The
   harness should report `reported_rate=192000`, approximately 384000 samples,
   no invalid blocks, no sequence gaps, and no local drops. This proves the raw
   transport and software-conversion cadence without competing for a DMIC.
4. In a new trial image, change only `pdm_id=4` to `pdm_id=0`. Do not run a
   normal F1/tinyALSA microphone capture concurrently. Before starting USF,
   determine whether the DMIC rail and pad mux are already active. The A32
   manager table proves controller selection but does not prove that it powers
   the microphone. If power is absent, use only the matching F1 manual `MIC0`
   power control, without enabling an EP1/EP5 capture route or F1 DMA, and
   restore it to zero after the test. Start USF explicitly with
   `--ack-pdm-reroute 0`, record two seconds, and verify that the samples react
   to acoustic stimulus rather than optical modulation. Repeat in separate
   boots for IDs 2 and 3 only after ID 0 succeeds.
5. For a genuine bandwidth result, stimulate and measure above 48 and 96 kHz
   with suitable external lab hardware. Sample counts and the reported format
   are transport checks only; they do not establish Nyquist bandwidth.

The expected A32 log strings are:

```text
USF: VD6282: flicker_capture_mode_:%d.
USF: VD6282: pdm_clock_hz_:%d.
USF: VD6282: direct_mode_chunk_size_in_bits_:%d (Hz:%d).
USF: Failed to configure PDM clock freq: %d instead of %d
```

The chunk-size log is emitted by the registry parser before the later guarded
data-only chunk override, so it will not by itself report the effective chunk.
The USF format callback's `reported_rate` is computed when the capture object
is configured and is the better transport-rate check.

## Stop conditions

- Stop immediately if the clock object is not using a 38.4 MHz parent, index 2,
  stock divider 12, and the exact register triplet documented above.
- Do not attempt an AP post-authentication DRAM write while secure SEM reports
  `NS_WR_EN=0`; the observed result is an asynchronous SError and host panic.
- Revert if VD6282/PDM initialization errors appear or AoC becomes unhealthy.
- Never let F1 audio and the A32 trial own the same PDM controller
  concurrently until an ownership handoff is found.
- Treat DMIC regulator and pad muxing as separate from controller selection.
  A zero or constant capture may mean the mic is unpowered or the pins remain
  in their sleep function; it is not evidence that the raw converter failed.
- Do not infer that F1's `0x40487xxx` PdmV3 pointers are AP-accessible MMIO.
  They fall inside the loaded F1 image/RAM and are software/config pointers
  unless a later hardware-bus dereference is independently demonstrated.
