# Cubs direct D5→TDM96 prototype

Unqualified, reboot-volatile hardware experiment. All ordinary audio clients
must remain stopped until a cold reboot. This does not modify a flash bundle.
Use low-level stimuli: the new path bypasses speaker post-processing/protection.
The original TAS2572 bandwidth limitation still applies.

The accepted D5/96 kernel request did **not** change physical playback:
[actual trial](../../../work/audio-research/cubs/mono192-v5-20260922/duplex30k-d5-96-bottom/logcat-live.txt)
reported TDM6144kHz, four32-bit slots and48kHz. Native firmware96 construction
also upsamples48-frame mixer output; it is not itself a true96-bandwidth path.

This candidate instead keeps every stock allocation and 48-frame/768-byte DMA
half, doubles BCLK to12.288MHz, and reads48 chronological stereoS32 frames per
0.5ms callback. It writes `[L,R,0,0]` in the four TDM slots. Low8 bits are cleared
exactly as in the stock24-bit transport. H0 and SRC output are not read.

| Hook | Meaning |
| --- | --- |
| `0x40274404` | Replace stock active speaker worker; payload/literals fit entirely inside its old body |
| `0x40265c08` | D5-only worker no-op prevents double AP-ring consumption; other entrypoints replay original ENTRY64/body |
| `0x40274219` | Silence-dispatch call also uses the direct worker and retains dispatcher DMA ACK |
| `0x40274260` | Callback sanity range changed from1ms to0.5ms, same±0.1ms tolerance |
| `0x40274a78` | Set F1-owned clock field to12288kHz, retaining slots4 and frame geometry48 |

Source ring uses its actual live vtable`0x4021d118`: available+68, base+76,
capacity+80, read-pointer+84, advance+60. Advance at`0x402981e4` calls
`0x402e7258` to update AP read counters, then tests **ring+0xd8** and sends the
host IRQ at`0x40298245..0x402982b8`. Do not call derived SonicProcessor notify:
the actual base D5 vtable`0x401fdb24` has a no-op atvirtual+68.
The reader handle must be ring+0xe4. The worker checks the actual source class,
8-byte stereo frames, DMA geometry, ring boundaries and alignment. Empty input
emits zeros without consuming data. Wrapped input is copied in chronological
order. Source DHI and destination DHWB use the original Cubs cache routines.

Read-only observations for one boot (not permanent addresses):
`AudioInCtrl403cd5e0 +2c4 → AudioOutCtrl4037b588 +1f4 → D5 EP4039a200`;
EP+250→ring40367a88 and EP+254→reader40367b6c. Re-read and guard on every boot.
The builder adds exact object/vtable/chain/name guards; no whole-file hashing.

Build a **new** combined manifest with the currently selected capture candidate:

```bash
python3 tools/audio/cubs/build_direct96_manifest.py \
  --capture-manifest tools/audio/manifests/cubs_d10_mono192_candidate.json \
  --input-controller 0x403cd5e0 --output-controller 0x4037b588 \
  --endpoint 0x4039a200 --source-ring 0x40367a88 \
  --output-dir work/audio-research/cubs/direct96-BOOT-SPECIFIC
```

For the dynamic resolver in `apply_mono192_candidate.py`, prefer a zero-pointer
speaker-only template instead:

```bash
python3 tools/audio/cubs/build_direct96_manifest.py --speaker-only \
  --output-dir work/audio-research/cubs/direct96-TEMPLATE-NEW
```

Pass its `combined-manifest.json` as `--speaker-manifest` alongside the chosen
capture `--manifest`. In speaker-only mode the filename is generic: it contains
only the five playback patches. The applier resolves the current object chain,
checks both controller vtables, the D5 endpoint vtable, S32/stereo frame shape,
host-service ring vtable/reader/name, then injects the endpoint literal. It
stages the replacement body before the hooks and flushes F1 I-cache after the
combined transaction. The payload has no fixed runtime pointer in this mode.

The v2 worker checks **both** source kind4 and8 bytes/frame before reading.
On a fresh boot the pair can be exactly `(0,0)` before PCM setup; the dynamic
preflight may accept that exact unconfigured pair as well as `(4,8)`, but no
other pair. Runtime `(0,0)` produces silence/geometry-refusal counts until
the96kHz S32/stereo PCM request initializes both fields. These startup counts
must not be mistaken for an active-stream underrun.

V3 records the additional fresh-boot observation: the source ring and reader
may both be zero before EP_SETUP. Preflight can admit exactly this unbound
pair **only together with format `(0,0)`**; a bound pair must still pass its
vtable/name/reader checks. The runtime worker already sends either null source
pointer to silence, and checks ring vtable`0x4021d118` and reader=ring+0xe4
before any source-ring virtual call. V3 does not weaken or change those
existing assembly checks; it documents the newly observed preflight state.

The builder assembles the target-specific code and combines copies of manifests;
it neither edits the capture manifest nor touches the device. Do not use the
example addresses without the fresh guarded reads. Apply only through the
parent's exclusive cold-boot/coherent-cache workflow, leaving services stopped.
No hot restore: cold reboot after the test or any mutation failure.

Stats at`0x40274440` are explicitly written back each callback: callbacks,
consumed48-frame blocks, empty blocks, geometry refusals, last available bytes.
Startup/teardown can legitimately add empty blocks. The existing FS48 log field
still reports the retained48-frame block number; BCLK/slot geometry and real
microphone frequency measurements must establish the physical rate. No rate,
continuity, SPL or high-frequency acoustic claim follows from assembly alone.
