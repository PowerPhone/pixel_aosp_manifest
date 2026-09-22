# Frankel speaker routing diagnostics — 2026-09-04

The native 192 kHz D0 transport completes, but these trials did **not** establish
acoustic emission. An eight-second 15 kHz tone was played through the bottom
speaker while D10 recorded PDM0 at 192 kHz. Each of the three route trials below
wrote the complete 12,288,000-byte payload with zero reported xruns. None
produced an identifiable 15 kHz tone in the capture.

| D0 options | Normal PCM | High Rate PCM | Ultrasonic mode | AoC ASP |
| --- | --- | --- | --- | --- |
| `--codec-route normal-asprx1` | ASPRX1 | Zero | Disabled | Preserved |
| `--codec-route dual-asprx1` | ASPRX1 | ASPRX1 | In Band | Preserved |
| `--codec-route dual-asprx1 --asp-mode bypass` | ASPRX1 | ASPRX1 | In Band | ASP_BYPASS |

The default `high-rate` route remains unchanged: normal PCM Zero, High Rate
ASPRX1, ultrasonic In Band. `--asp-mode keep` preserves the existing processing
mode; explicit `on` and `bypass` values are restored during cleanup. The normal,
dual, and bypass options are diagnostic controls, not acoustically qualified
routes. Normal mode uses the CS35L43 driver's 192 kHz `GLOBAL_FS=0x05` entry;
In Band uses the patched 96 kHz base for its doubled high-rate input.

The active dual/bypass codec snapshot showed Main AMP and ASPRX1 DAPM widgets
On, while the Ultrasonic Mode DAPM widget remained Off. The same active sample
reported:

| Register/state | Value |
| --- | --- |
| GLOBAL_ENABLES | `0x1` |
| BLOCK_ENABLES | `0x21` |
| GLOBAL_FS | `0x4` |
| ASPRX1 enable | `0x10000` |
| ASP word length / slot | 32 bits / slot 1 |
| DACPCM1 / DACPCM2 selectors | `0x8` / `0x8` |
| FSx2 register | `0xd0580011` |

This confirms that the dual route can power the normal ASP/amp path; it does
not establish that the expected samples reach the physical output. A DAPM
widget label, mixer readback, successful ALSA write, or the microphone's own
shaped noise floor is insufficient evidence of transmitted sound.

Local evidence is under
`work/audio-research/frankel/codec-route-live-20260904/`:

- `tone15-normal-bottom-pdm0.wav`
- `tone15-dual-bottom-pdm0.wav`
- `tone15-dual-bypass-bottom-pdm0.wav`
- `active-dual-bypass-codec.txt`

The WAVs have analysis and spectrum sidecars. The directory also contains
48 kHz positive-control attempts from `d0-speaker-control-48k.sh`. The first
tinyplay attempt wrote no audio because of EFAULT. The staged attempt initially
selected its default US route; the wrapper now passes EP1 explicitly with
`--prepare-route bound` and bounded first-boundary retries. These are ongoing
hardware diagnostics, not final playback qualification. The next evidence
needed is a clearly identifiable acoustic stimulus before testing ultrasonic
response and continuity.

## Speaker-output tap and clean-reboot follow-up — 2026-09-05

The standard stock AoCx diagnostic service successfully recorded its
`core 2 / sspk.0` speaker tap through output buffer `tapout20`. Only that
buffer's IO was enabled; injection remained disabled and unbound. The two
initial source-0 recordings in the evidence directory above contained:

| Playback request | Tap file | Stereo S32 frames | Sample contents |
| --- | --- | --- | --- |
| 192 kHz, 15 kHz tone | `sspk192_tapout20.wav` | 1,547,520 | All zero |
| 48 kHz, 15 kHz tone | `sspk48_tapout20.wav` | 391,680 | All zero |

The staged 48 kHz EP1 player had completed its 3,072,000-byte payload with
zero reported xruns. Thus silence was not specific to requesting 192 kHz,
and successful transfer to ALSA was not proof that nonzero samples reached
the tapped processing point. The normal, bounded source-0 tuning GET
reported gain 1000; no gain change was needed for that check. This helper
supports only the known block-16/component-0/key-0 parameter.

The tap metadata advertises 48 kHz, two channels, four bytes per sample,
and block length 1920. Its WAV header stayed at 48 kHz during the 192 kHz
experiment despite the observed increased frame cadence. The retained
files are not rewritten. Header values, counts, and cadence do not
establish the physical converter rate or acoustic bandwidth. Likewise,
all-zero data at `sspk.0` does not by itself prove that this tap is the
final amplifier input or identify which upstream stage suppressed sound.

After a clean reboot with stock AoC firmware, the ordinary 48 kHz direct
playback control still produced an all-zero speaker tap. This weakens the
explanation that silence was solely residual state from an experimental
192 kHz run. It does not establish that every other software component or
route was stock, or that the ordinary Android speaker path is defective.

The next positive control is ordinary Android playback through its normal
audio HAL and policy, paired with the same standard output tap and an
identifiable acoustic stimulus. A nonzero normal-path reference is needed
before attributing the direct-route failure to the codec, the AoC source,
or an omitted routing/processing setup. Ultrasonic frequency-response and
continuity qualification remain pending; there is no verified acoustic
192 kHz speaker result or newly qualified flash-all image from these trials.

The reproducible tap wrapper is
[`aocx-speaker-tap.sh`](../scripts/audio/frankel/aocx-speaker-tap.sh).
Its [normal-control README](../tools/audio/device/frankel_aoc_source_gain/README.md#standard-aocx-speaker-output-tap)
documents the exact stock V3 Binder calls, recorder parser bug, original
SELinux-state restoration, and output-file interpretation. The stock
recorder opens files for all buffers but does not enable their IO; the
wrapper checks an idle/unbound initial state and activates only tapout20.

## Stock 48 kHz reference and frontend-only 192 kHz trial

Subsequent ordinary Android playback on the stock-kernel reference supplied
a positive 15 kHz acoustic control. Its nonzero stock speaker tap initially
looked malformed because the stock WAV recorder applies a 16-bit conversion
to four-byte samples. The [stock-48-kHz decoding note](frankel-aocx-stock48-tap-decoding.md)
documents the supported partial inverse and unavoidable missing packet
halves. After decoding, both that Android reference and Source-5/EP6 direct
S16 playback contain a clean digital 15 kHz tone. The tap alone does not
acoustically qualify the direct route.

The next trial changed only the EP6 frontend's allowed-rate mask in the
kernel, retaining stock AoC firmware and explicitly configuring the backend
at 48 kHz. Its source WAV was stereo S16, 192 kHz, eight seconds, containing
a 15 kHz tone. Actual evidence is under
`work/audio-research/frankel/stock-kernel-reference-20260905/ep6-frontend192-backend48/`:

| Observation | Actual result |
| --- | --- |
| Frontend / backend request | 192,000 / 48,000 Hz |
| Confirmed WRITEI result totals | 1,536,000 frames / 6,144,000 bytes |
| Full successful ioctls / EFAULT retries / reported xruns | 800 / 0 / 0 |
| Wall-time behavior | Approximately 32 seconds for the eight-second source |
| Tap packet count / nominal duration | 799 / 31.96 seconds |
| Decoded dominant frequency, both channels | 3,750 Hz |
| Median 3,750 Hz amplitude, both channels | Approximately 214,745,813 S32 units |
| Median tone-energy fraction | 0.999999987 |

The quarter-frequency tone and fourfold duration are consistent with
`15000 * 48000 / 192000 = 3750`: the stream was consumed at the active
48 kHz pipeline cadence despite the frontend accepting a 192 kHz request.
It was not sample-rate converted to preserve the original 15 kHz pitch.
This rules out treating the frontend rate-mask change alone as 192 kHz
support. This trial deliberately held the backend at 48 kHz, so it does
not yet establish how consumption behaves with a 192 kHz backend or which
component determines that cadence.

The trial's `sspk-decoded48.json` and `sspk-decoded48-with-gaps.npz` preserve
767,040 observed and 767,040 missing frames per channel. Each channel has
741,210 nonzero retained samples. Analysis fits 3,750 Hz separately within
the observed 20 ms pieces; the decoder report also retains its usual
15 kHz coefficient, which is effectively zero here. Missing samples are
not synthesized, and these artifacts do not qualify continuity, jitter,
or physical ultrasonic output. The next isolated diagnostic is the same
frontend with the backend explicitly set to 192 kHz.
