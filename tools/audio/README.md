# Frankel audio source boundary

This tree contains source code for Pixel 10 (`frankel`) audio bring-up. It is
not an image-output directory. Generated binaries, captures, spectra, device
dumps, and live-run logs belong below ignored `work/` paths, normally
`work/audio-research/frankel/`; none is a tracked release input.

## Current speaker qualification and offline inspection

192 kHz physical speaker output is not qualified. The later real-device
rate-only trials and complete firmware inspection supersede any older
transport-only interpretation below. See
[the current findings](../../docs/frankel-speaker-firmware-findings-20260905.md).

`extract_frankel_aoc_analysis.py` extracts the reviewed stock container's
shared and external code regions into local analysis files. It performs no
firmware rewrite or device operation. Its new-output-directory requirement
and exact layout guards prevent accidental substitution of another image.
The matching Sky1 disassembler is required; the installed Ghidra FLIX
pseudocode remains unreliable. `ghidra/DecompileAudioEntries.java` is an
analysis diagnostic, not proof that those instructions decompiled correctly.

`patch_frankel_aoc_offline_manifest.py` is a separate, fail-closed workflow
for producing an **unsigned, non-flashable offline analysis copy** from a
review-complete semantic manifest. It accepts only the exact reviewed stock
Frankel container, never edits in place, validates every stock byte and the
final whole-file digest, and contains no device or firmware-loading support.
The placeholder and constructor draft remain deliberately incomplete and
cannot emit a binary. A separate reviewed manifest,
`manifests/frankel-aoc-speaker-192k-offline-analysis.json`, records seven exact
guarded edits whose instruction bytes and SRC heap bounds passed independent
offline review. `asm/frankel_aoc_speaker_192k_analysis.S` provides their
decodable Sky1 instruction source. The generated copy remains below ignored
`work/` as `candidate-aoc-speaker192.UNSIGNED-NOT-FLASHABLE.bin`; it is not a
release artifact, authenticated firmware, or hardware qualification. The
separate `--validate-incomplete-design` mode
checks a populated incomplete manifest's mapping and byte guards and prints
an in-memory preview digest without writing; it does not confer review or
hardware qualification. See
[the workflow and manifest contract](../../docs/frankel-aoc-offline-patching.md).

## Image-selected source

Only the following source is selected by the current
`POWERPHONE_AUDIO_SIDECAR=true` image workflow:

- `device/frankel_aoc_d10_patch/`: guarded volatile F1 D10 patch helper;
- `device/frankel_aoc_speaker_patch/`: guarded A32/F1 D0 speaker helper;
- `device/frankel_powerphone_d10_bootstrap/`: boot orchestration and its
  target-scoped policy; and
- `../../patches/hardware-interfaces/`: the PowerPhone AIDL audio module
  patches.

The Frankel generated-vendor sanitizer copies and attests those exact sources.
The release packager consumes only the resulting attested AOSP images; it does
not copy host tools or live-run artifacts into the flash bundle.

Separately, `POWERPHONE_AOC_ALSA_192K=true` makes that sanitizer run
`patch_frankel_aoc_192k.py` and
`patch_frankel_aoc_core_zero_wp_reset.py` against two generated stock-kernel
modules. The selected `aoc_alsa_dev_util.ko` state is the exact D10-capture plus
D0/EP1 source-0-playback closure: general 192 kHz allowances, EP3 and EP1
masks, 500 us capture-ring polling, and D0 progress bounded by its real mailbox
ISR. It has SHA-256
`fc990edad9b77b2bb96cd222f6a07503dc12247804c498a769d0436b5cb61cd0`.
The paired `aoc_core.ko` has SHA-256
`f4b7c9daad2fb3cb2ddc9fa8f80381629b3ffe048194348924e9f7a0ead1024c`;
its one changed comparison makes ring reset a no-op when the loaded write
pointer is already zero. Without it, stock core advances Tx by one complete
ring before the first PCM copy, so the ALSA-only state is not selectable.
Both helpers accept only exact stock or qualified whole-file identities and
write atomically. The narrower timer/EP3 helpers are retained only to explain
historical trial derivation; finished images do not chain them.

`POWERPHONE_CS35L43_192K=true` independently selects
`patch_frankel_cs35l43_global_fs96.py`, the exact-stock one-instruction
ultrasonic GLOBAL_FS 48-to-96 kHz transform. Its selected module SHA-256 is
`fc631fc227ab2e7e8cfa2d664e97ac7cca4c14324fb2a39479fc8e79aa358a3a`.
A publishable PowerPhone bundle requires all three opt-ins; any partial
selection is isolated as an experimental bundle.

## Live hardware qualification

These are operator tools, not shipped executables:

- `patch_frankel_aoc_live_d10_raw_192k.py` and
  `validate_frankel_d10_raw192.py` support the qualified D10 capture trial;
- `patch_frankel_aoc_live_speaker_192k.py` and
  `device/frankel_aoc_speaker_patch/` implement the exact guarded EP1/source-0
  192 kHz, q48, four-S32, 24.576 MHz volatile profile; the native helper also
  attests the exact cold A32 allocator fallback and stock timer assertion; and
- `../../scripts/audio/frankel/` owns the target-guarded tinyALSA wrappers and
  route cleanup.

The selected bootstrap certifies the speaker profile first and D10 last.
Real-device boots showed that D10's resident diagnostic profile can prevent a
later speaker factory-mailbox transaction from completing. D10's final
whole-F1 cache synchronization covers the already-installed speaker edits;
later bounded attempts re-certify the selected speaker state idempotently
before retrying D10. Direct D0 and D10 transport has live evidence, but source
presence, successful compilation, or a boot readiness property is not an
acoustic-bandwidth qualification claim.

The host live patcher also exposes the deliberately unselected experimental
profile
`experimental-enum7-q192-tdm12288-192-2xs32-dma-source0`. It combines the
native 192-frame source-0 quantum with a 192 kHz, 12.288 MHz, two-S32-slot TDM
bus and the paired two-slot DMA admission, group-divisor, and unused-slot
edits. The speaker worker ignores that slot field and otherwise retains its
hard-coded four-word-per-frame copy bound, so this profile also changes both
local word-count shifts from x4 to x2. Consequently the source, CPU copy, and
DMA geometry all remain `192 * 2 * sizeof(S32) = 0x600` bytes. It contains no
q48 allocation, frame-count, or DMA descriptor-frame clamp.
This name describes source composition only: it is not image-selected or
hardware-qualified until a guarded live run proves real five-second
consumption, stable AoC generation, and physical endpoint behavior.

The same patcher exposes the source-0 native-q192 four-S16 candidate
`experimental-enum7-q192-tdm12288-192-4xs16-dma-source0`. Its two CPU
format-copy sites deliberately use the local scalar 96 before their fixed x4
word multiplier. This is byte geometry, not a 96-frame producer quantum:
`96 * 4 * sizeof(S32)`, `192 stereo frames * sizeof(S32)`, and
`192 * 4 S16 slots` are all exactly `0x600` bytes. The AoC producer, TDM
frame rate, and DMA descriptor therefore remain native 192 frames per
millisecond. This profile includes the complete S16 DMA byte-count/CCR/length
set, but excludes the early/generic q48 geometry clamps and the q48 DMA-frame
override. It remains a guarded live candidate until real hardware proves
restart-free route binding, nominal wall time, and physical wideband output.

The current HAL stack ends at
`0015-require-clocked-speaker-prime.patch`, with the companion
tinyALSA xrun-counter patch. Both directions expose a 1,920-frame framework
queue; D10 retains a 1920-by-four ALSA ring and D0 a 480-by-four ALSA ring.
D0 is written one hardware period at a time, silently primed before client
audio, and may reopen on a negative EIO only during that startup phase. It
rejects faster-than-clock write streaks until a 1.6-second warm-up has elapsed
and 32 clean periods span at least 60 ms of their nominal 80 ms. The
cumulative xrun count includes internally recovered EPIPEs, and every new xrun
after startup fails the stream closed. This candidate still needs exact-image
Java and AAudio qualification on hardware.

The paired-kernel transport evidence is retained in
`../../work/audio-research/frankel/speaker-d0-mailbox-4xs32-192k-hardware-attestation-20260902.md`:
the amps-muted 15-second D0 run completed all 23,040,000 expected bytes with
matching Tx/Rx counters and no restart/coredump during the interval. The exact
known-good kernel image is under
`../../work/audio-research/frankel/speaker-d0-mailbox-cs35l43-stock-global-fs96-pair/trial-1/`.
Any root `vbmeta.img` retained in a historical trial directory is bound to the
full partition set from that trial and is not a portable companion image.
These ignored artifacts are evidence, not tracked release inputs.

## Experimental root-vbmeta safety

Active mailbox kernel builders omit root `vbmeta.img` by default. A paired
root image can only be generated from an explicitly supplied complete image
set after all AVB descriptors are checked. Use
`verify_frankel_vbmeta_image_set.py` and the guarded
`flash_frankel_experimental_vendor_kernel_boot.sh`; do not manually combine a
VKB and root vbmeta from different trial directories. The failure analysis,
builder audit, and exact commands are in
[`../../docs/frankel-experimental-vbmeta-safety.md`](../../docs/frankel-experimental-vbmeta-safety.md).

## Historical and exploratory source

The root-level D12, AP-PDM, GSA/cold-firmware, MMIO, ring-resize, and timer
patchers and the stand-alone assembly/linker fragments under `device/` are
retained as research history. `device/frankel_pdm_loader/` is likewise the
retired card-1 AP-PDM experiment. They are not selected by the current D10
image and must not be cited as evidence for it. The AP-MMIO capture trial
faulted and rebooted the phone, so that path is rejected rather than merely
awaiting another static check.

Before promoting any experiment into an image, give it a target-scoped source
directory, an explicit default-off build selection, generated-tree and final
image attestation, fail-closed boot/runtime ownership, and real-device
qualification. Do not make a packager consume a file merely because it exists
somewhere in this research tree.
