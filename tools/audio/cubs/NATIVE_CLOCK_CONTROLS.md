# Cubs native-clock controls

These are isolated hardware experiments, not qualified images. They retain
the mono-only/quarantined RAW pipeline and cache requirements in
`MONO192_CANDIDATE.md`. Cold reboot between profiles; do not layer them on
an already patched session. No ordinary enum5 capture clients may run.

## Stock-clock control

```sh
python3 tools/audio/cubs/build_mono192_manifest.py --native96-control
```

Output: `tools/audio/manifests/cubs_d10_mono96_clock_control.json`.
Dedicated source: `tools/audio/asm/cubs_d10_mono96_clock_control.S`.
It preserves stock3.2MHz,96k timebase and38400 timestamp ticks while using
96-frame direct RAW staging. With a192k header, a physical20k tone must
appear at40k; this is intentionally not a192k qualification recipe.

Real hardware at3.2MHz produced clean20k/19.937k acoustic carriers on all
three separately selected microphones. The first mic0 control captured
476160 frames in a5s request (4.96physical seconds), versus v5's875520frames
and noisy+0.7014FS DC at6.4MHz. Thus the same direct quantization path can
carry clean audio; the clock/timing configuration is the remaining suspect.
Evidence: `work/audio-research/cubs/mono96-control-v1-20260922/`.

## Experimental lower-decimation control

```sh
python3 tools/audio/cubs/build_mono192_manifest.py --native192-rfactor2-control
```

Output: `tools/audio/manifests/cubs_d10_native192_rfactor2_control.json`.
Dedicated ASM/LD: `tools/audio/asm/cubs_d10_native192_rfactor2_control.*`.

This keeps stock3.2MHz but restores the192k software timebase/timestamp
expectation. PdmV4::ConfigRFactor at4024e318 normally maps native argument4
to a write of4 at the selected lane's MMIO+0x28. The candidate changes only
that case to write2; arguments25/6 retain their stock behavior and bounds.
The register encoding is **experimental**: firmware does not establish
that2 means half the decimation or that the hardware supports it. Real
callback cadence, sample output, spectrum and continuity must decide.

The real register2 trial produced238080frames during a5s capture and
repeated76800 timestamp ticks per96-frame block: actual48k, not192k. It
started/stopped without AoC reset. Together with the stock-register4
control's96k result, the observed rate moves in the opposite direction
from the initial decimation hypothesis. Software timebase/header changes
alone do not change the producer's physical cadence.

A separate register8 candidate preserves the same scoped branch:

```sh
python3 tools/audio/cubs/build_mono192_manifest.py --native192-rfactor8-control
```

Its manifest is `tools/audio/manifests/cubs_d10_native192_rfactor8_control.json`;
its dedicated ASM/LD use the corresponding `rfactor8_control` basename.
Only the native case's hardware write value changes2→8.192k is its target,
not a claim of supported hardware encoding or acoustic qualification.

The real register8 trial returned zero frames. AP configuration and RAW
enable returned success, with no AoC restart or coredump, but there were no
PDM timestamp callbacks. This does not prove the field width or the reason
for no output; register8 is not a working192k setting. Evidence:
`work/audio-research/cubs/native192-rfactor8-v1-20260922/`.

## Register6 and lower-clock192 controls

```sh
python3 tools/audio/cubs/build_mono192_manifest.py --native192-rfactor6-control
python3 tools/audio/cubs/build_mono192_manifest.py --native192-rfactor6-clock4266-control
```

The first writes 6 at the same scoped native register and retains the
nominal 3.2 MHz request. Real hardware produced **64 ksample/s**, not the
initially hypothesized 144 ksample/s: 322560 frames in five seconds and
57600 timestamp ticks per 96-frame block. Acoustic phase fitting independently
confirmed 64000.000785 samples/s. The separate 4,266,666 Hz/register6 candidate
was consequently **not tried**; its old 192k hypothesis is rejected.
The manifests are `cubs_d10_native192_rfactor6_control.json` and
`cubs_d10_native192_rfactor6_clock4266_control.json` under
`tools/audio/manifests/`; dedicated ASM sources are under`tools/audio/asm/`,
with the latter sharing the register6 linker layout.

The actual PdmClockV3 object in the v3 core has38,400,000Hz at+12. Its
frequency setter4024f1f0 chooses an integer divider and returns integer
base/divider; native start4025d096 requires equality to the requested
literal. Thus divider9 returns4,266,666Hz (not4,266,667), while divider12
returns3,200,000Hz. This establishes an attainable clock request, **not a
measurement of the physical PDM pad clock**, microphone bandwidth, or the
meaning of register6. ClockManager4024c398 writes that divider unchanged to
the translated register block at physical03ea1600+10; helper4024be34 applies
no N-minus-one transformation and waits for the corresponding status bit.
The actual parent frequency and hardware divider interpretation remain
unmeasured.

PdmV4::ConfigRFactor4024e318 writes native argument4 to MMIO+0x28. Its
other accepted arguments25/6 write4/8 to MMIO+0x24 instead. Those cases
remain untouched. The two neighboring factor configuration virtual
methods are no-ops for PdmV4; their upstream numeric arguments do not
establish the hardware's actual decimation chain.

The5-byte hook at4024e31b jumps to15 bytes at4025ee9a in the old enum5-only
producer body, now unreachable in this exclusive-native7 session. This is
not unused stock memory. Every original byte is guarded in the manifest;
the complete profile must be removed by cold reboot before ordinary capture.
The canonical192-v5 and stock96-control manifests remain separate.

## Register3 result

The separate `--native192-rfactor3-control` produced 161280 frames in five
seconds and 115200 timestamp ticks per 96-frame block: **32 ksample/s**.
The 19.937 kHz stimulus did not yield a strong alias; do not call its
ultrasonic recording qualified. These measured results defeat a single
linear interpretation of the register: values2/3 give48/32k, whereas4/6
give96/64k. No additional arbitrary register values are currently proposed.

## Native receiver-edge discriminator

```sh
python3 tools/audio/cubs/build_mono192_manifest.py --native192-edge0-control
```

Manifest: `tools/audio/manifests/cubs_d10_native192_edge0_control.json`.
Dedicated ASM/LD: `tools/audio/asm/cubs_d10_native192_edge0_control.*`.
This includes the canonical v5 geometry unchanged and replaces only the
native load at4025d1fc, `l8ui a12,a15,33`, with `movi a12,0`. Clock request
remains6.4 MHz, RFactor remains4, and the stock HPF polarity is preserved.
It is an unqualified, cold-boot-only hardware discriminator.

Field evidence is separate from any electrical claim:

- Native start indexes `AudioCapturePdm+0x221+physical_lane` at4025d1f7..1fc
  and passes that byte to PdmV4 virtual+24.
- The constructor at76af96e9..96f2 initializes all four lane bytes to1.
- Virtual+24 is402568f0 and modifies only bit1 of the selected lane's
  CONTROL register, preserving all other bits.
- The configuration debug printer76af9ff7..76afa018 labels its per-DMIC
  edge bytes at configuration+36..39 as `rising` for1 and `falling` for0;
  the physical pad mapping is separately read from configuration+4..16.
- These are explicit firmware edge fields, but the complete configuration
  copy into runtime+0x221 and the electrical pad waveforms have not been
  measured. The control tests whether the opposite native receive edge
  fixes corruption at the higher clock; success must come from actual
  acoustic carrier, spectrum, and continuity results.
