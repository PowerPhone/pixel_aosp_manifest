# Frankel speaker startup and duplex-rate coordination

Offline analysis only; no firmware, kernel, image, or phone state was changed.
This describes requirements for a future supported mode, not a working
192 kHz implementation. Constructor/resource analysis is in the
[design note](frankel-speaker-192-design-20260905.md); codec details are in
the [CS35L43 note](frankel-cs35l43-192k-constraints-20260905.md).

## Normal startup chain

Evidence is the unchanged container's valid `regions-complete/shared.elf`
and `dsp-external.elf`, decoded at known instruction boundaries with the
recovered Sky1 decoder. Addresses identify this firmware version only.

| Stage | Exact evidence | Requirement |
| --- | --- | --- |
| Speaker construction | `0x78972b24`; speaker `+0x298` is rate in kHz; `+0x28c=4`; `+0x288=128*rate_kHz` | Rate, slots, clock, resources and processing topology must describe the same mode. |
| Clock source selection | Startup `0x403d4026..0x403d4033` calls clock object `+0x284`, vtable `+0`, with arguments 1 and 0 | Preserve the valid clock-source topology; a desired frequency is not itself a source selector. |
| TDM slot setup | `0x403d4042..0x403d404b` calls `0x403a915c` with the low byte of `+0x28c` | Four-slot geometry must match both codecs and DMA. Callee stores the count at controller `+0x74` and programs slot fields. |
| Clock divider | `0x403d404e..0x403d4058` calls clock vtable `+8`, identified as `0x4039d5c8`, using speaker `+0x288` | A 192 kHz four-slot S32 bus requires 24,576 kHz here and a source supporting the exact divider. |
| Serial word configuration | `0x403d405b..0x403d4070`: two TDM-controller virtual calls, offsets 24 and 28, each argument 32 | Keep both serial directions' 32-bit geometry coherent. The exact C++ method names are not recovered. |
| Two-direction DMA setup | `0x403d4150..0x403d41a1`, alternative branch `0x403d41ea..0x403d420d`, calls `0x403aa43c` | The same call receives both allocated buffer bases, speaker rate `+0x298`, half-allocation size, and both half-state structures `+0x2cc/+0x2d0`. |
| DMA channel bookkeeping | Two calls to `0x403ab914` populate `+0x300/+0x304`; startup logs both with clock, rate and slots at `0x403d4252` | Do not update output bookkeeping while leaving feedback on old geometry. |

The two calls to `0x403aa43c` are alternative startup branches, not two
independent rates: each supplies both directional buffers. Constructor
members `+0x200/+0x204` hold those DMA buffer objects; startup obtains their
bases through virtual offset 72 and allocation sizes through offset 76.
The size passed to setup is half of a double-buffer allocation. At the
proposed 192 frames/ms and four S32 slots this is 3,072 bytes per half and
6,144 bytes per direction, as derived in the design note. Both directions
therefore follow the same speaker rate even when no host feedback recording
is open.

The observed setup guards accept eight-frame granularity, at most 256
iterations, four/eight enabled slots and 64-byte-aligned state structures.
192 frames imply 24 iterations and satisfy those numeric conditions; this
does not qualify execution deadlines, throughput or clock generation.
The divider routine additionally requires an exact integer source/target
ratio and an encodable divider. Its existing source must be established,
not inferred from the desired target or from CPU/DSP DVFS frequency.

## Three rates must not be conflated

| Domain | Can remain 48 kHz with a native 192 kHz speaker bus? |
| --- | --- |
| Physical codec ASP/TDM0 feedback bus | No independent 48 kHz frame clock is established. Playback and capture refer to the same CS35L43 DAI and shared framing/PLL/global-rate state. |
| Internal feedback/AEC processing | Potentially yes, with a validated 192-to-48 converter and matching blocks. The existing 96 kHz branch already uses a 96-to-48 boundary. |
| Host ALSA capture frontend | Potentially yes, if the selected AoC capture route truly produces 48 kHz from the 192 kHz backend. Acceptance by ALSA is insufficient. |
| PDM microphone capture | A separate signal path. Its chosen rate is not forced to equal the codec feedback rate by this codec DAI. |

The existing feedback routine `0x403d370c` reads physical feedback using
`+0x2a4`, calls the converter at `+0x2b0` when the high-rate topology is
enabled, and publishes a fixed `0x300`-byte block at `0x403d3839`.
For four S32 channels that is 48 frames, consistent with its retained
48 kHz processing domain. That fixed count is not evidence that physical
feedback must remain 48 kHz, nor a reason to enlarge all feedback objects.
A new 192-to-48 converter configuration has not been qualified.

Public CS35L43 declares `symmetric_rate=1` (`cs35l43.c:2601`), but that does
not force every DPCM frontend to use the physical rate. Public
`sound/soc/soc-pcm.c:1827` skips propagating backend symmetry to the frontend
when the link has `be_hw_params_fixup`. Frankel's saved TDM0 playback and
capture links both have `usefixup`, and public Google
`alsa/aoc_alsa_card.c:344` sets backend parameters from independent port
caches. Thus a 48 kHz frontend and a 192 kHz backend can be represented.
Neither the fixup nor the symmetry declaration implements resampling.

In contrast, leaving the **TDM0 capture backend** at 48 kHz is not a valid
way to retain 48 kHz AEC: its normal clock/codec callbacks can program the
same shared codec PLL and `GLOBAL_FS` with the wrong rate. Any active
TDM0 capture backend needs matching physical rate and slot geometry.
This is a source-backed integration constraint, not a claim that the
current binary will reject every mismatched open.

## Suggested release-manifest fields

Keep these semantic requirements separate from binary edit sites and from
qualification results. A future target manifest should record:

- `status: design_only`, exact firmware/kernel/codec provenance, and no
  `verified_192k` flag until acoustic evidence exists.
- `tdm0.frame_rate_hz`, `slot_count`, `slot_width_bits`, `bclk_hz`, framing,
  clock-source identity and achieved divider; 192000/4/32/24576000 describe
  the proposed physical geometry, not the current device.
- Independent `frontend_rate_hz`, `backend_rate_hz`, and
  `processing_rate_hz` for playback and feedback. Do not collapse them into
  one sample-rate field.
- TX/RX DMA frame counts, half-buffer and total capacities; high-rate
  staging capacities; converter input/output counts and actual supported
  rate pairs. Link the separate constructor/SRC analysis instead of
  multiplying every existing 48-frame constant.
- Codec mode, `GLOBAL_FS`, BCLK reference setting, endpoint slot mapping,
  and whether feedback/AEC retains its protected 48 kHz processing domain.
- A separate native high-rate content route. Upsampling a 48 kHz playback
  processing stream cannot restore acoustic content above 24 kHz.
- Qualification evidence for physical cadence, acoustic bandwidth and
  continuity, explicitly distinguishing measured data from arithmetic.

No supported mechanism that constructs and runs this complete 192 kHz mode
has been established. These dependencies are not deployment instructions.
