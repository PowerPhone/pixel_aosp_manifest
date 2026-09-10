# Frankel CS35L43: coordinated 192 kHz constraints

The Cirrus driver has a normal 192 kHz PCM setting and a 24.576 MHz PLL
reference-clock entry. This is **codec-side configuration support**, not proof
that Frankel's AoC generates that clock or that its speakers emit ultrasound.
This investigation made no device changes and produced no qualified image.

## Source and hardware identity

The inspected public source is CirrusLogic/linux-drivers commit
`f48875b27bcca8be7a80cdefdeb1c8a8dc745d93`, locally under
`work/upstream/cirrus-linux-cs35l43/sound/soc/codecs/`:

- [cs35l43.c](https://github.com/CirrusLogic/linux-drivers/blob/f48875b27bcca8be7a80cdefdeb1c8a8dc745d93/sound/soc/codecs/cs35l43.c)
- [cs35l43-tables.c](https://github.com/CirrusLogic/linux-drivers/blob/f48875b27bcca8be7a80cdefdeb1c8a8dc745d93/sound/soc/codecs/cs35l43-tables.c)

Saved device tree `work/audio-research/frankel/baseline/live-frankel.dts`
identifies two CS35L43s at lines 14040 and 14062. Both TDM0 playback and capture
reference them and use DSP_A framing (lines 1947–1997). Their system-clock
definitions select BCLK, clock ID 0, and multiplier 1 (lines 2278–2294).
The right codec has the `R` control prefix. These are saved-device observations;
the public source is not claimed byte-identical to the currently loaded driver.

## Normal PCM route: coordinated requirements

| Layer | Required setting for the proposed native bus | Evidence |
| --- | --- | --- |
| Physical serial bus | 192,000 frames/s, four 32-bit slots; BCLK 24,576,000 Hz | Arithmetic; matching AoC production of that bus remains unproved |
| Codec framing | Preserve DSP_A, codec clock consumer, existing clock polarity and endpoint slot assignment | `cs35l43_set_dai_fmt`, lines 1922–1997; saved DT |
| Codec PCM rate | 192,000; `GLOBAL_FS=0x05` | `cs35l43_fs_rates` and `pcm_hw_params`, lines 2005–2051 |
| Codec mode | `Ultrasonic Mode=Disabled` | This selects the normal rate-table branch |
| Input route | Selected endpoint's `PCM Source=ASPRX1`; `High Rate PCM Source=Zero` | DAPM routes, lines 1646–1663 |
| Codec reference clock | BCLK input, frequency code `0x3b` for 24.576 MHz | PLL table line 505; component clock setter lines 2123–2177 |
| Width and power | 32-bit slot; appropriate PCM word length; selected ASPRX and Main AMP actually powered | `pcm_hw_params`, DAPM widgets and amp event |

PCM channel count is not TDM slot count. The codec DAI advertises one or two
playback channels while the shared serial frame can contain four slots.
`set_tdm_slot` only records slot width in this driver; receiver slot placement
uses separate `ASPRXn Slot Position` controls. Existing endpoint placement must
be preserved, not inferred from a WAV's channel count.

The public Google machine driver
`work/upstream/google-modules-aoc/alsa/aoc_alsa_card.c:553` computes BCLK as
backend rate × slot width × slot count, then calls each codec's clock setters.
CS35L43's **DAI** `set_sysclk` is a no-op; its **component** `set_sysclk` performs
PLL configuration. That component path must run with the matching frequency.
It uses the existing open-loop/reconfigure/close-loop sequence and programs
the frame-clock monitor; no hand-written register sequence is required here.
A successful setter or PLL status is not a physical bus-frequency measurement.

Playback and codec-feedback capture share this bus. The codec declares
`symmetric_rate=1`; running a 48 kHz TDM0 feedback stream alongside genuine
192 kHz playback cannot be assumed valid. PDM microphone capture is a separate
path and does not establish the TDM feedback clock.
Here the shared-rate requirement concerns the physical codec/backend bus,
not necessarily a host capture frontend: DPCM fixup can retain a 48 kHz
frontend if AoC supplies a real conversion stage. The
[startup/duplex note](frankel-speaker-192-coordination-20260905.md) distinguishes
physical feedback, internal AEC processing and frontend rates.

## Ultrasonic mode is a different path

Public `cs35l43_ultrasonic_mode_put` (lines 265–378) gives In Band and Out of
Band identical register programming: high-rate DSP RX/TX selections, base-rate
monitor selections, `AMP_PCM_FSX2_EN`, dual-rate monitoring, and AUDIO_REINIT.
Public `pcm_hw_params` nevertheless fixes `GLOBAL_FS=0x03` (48 kHz) whenever
either ultrasonic mode is selected. There is no public 192 kHz-specific
ultrasonic branch in this revision.

The earlier experimental source under
`work/upstream/frankel-gki-15739706/cs35l43-powerphone-build/module/cs35l43.c`
changes that branch to `GLOBAL_FS=0x04` for a 192 kHz request, intending a
96 kHz base with FSx2. This is a local, acoustically unqualified modification,
not evidence of stock support. The public callback also lacks a DAPM mux
power-update call. Earlier live evidence indeed showed its Ultrasonic Mode
widget Off even when the control read In Band. These findings do not justify
repeating the previously failed high-rate/dual-route trials.

## DSP, protection, and what bypass means

Selecting ASPRX1 directly as normal PCM routes samples around the Cirrus DSP
audio output; choosing `DSP` or `DSP FS2` routes through it. This does **not**
turn off AoC or change the AoC output scheduler. The AoC `ASP_BYPASS` mixer
setting is likewise a separate processing choice, not a clock generator.

Cirrus DSP initialization selects speaker-protection firmware (`fw=9`, source
line 2511), and its DAPM path includes current, voltage, supply and temperature
monitoring. Amp startup applies delta tuning when DSP firmware is running.
Direct PCM is therefore not equivalent to retaining the calibrated protection
algorithm, even though hardware fault handling remains present. Keep existing
fault protection and bounded low-level diagnostics; do not increase gain or
disable DC/thermal/boost protections to compensate for a silent path.
The source alone does not establish protection-firmware 192 kHz compatibility,
analog output bandwidth, or the loudspeaker's ultrasonic response.

## Historical evidence and present limit

The **September 4 historical** snapshot
`work/audio-research/frankel/codec-route-live-20260904/active-dual-bypass-codec.txt`
has `REFCLK_INPUT=0x670`: frequency bits decode to `0x33`, the 12.288 MHz PLL
reference setting, not 24.576 MHz. It also has `GLOBAL_FS=4`, FSx2 enabled,
ASPRX1 and Main AMP powered, and Ultrasonic Mode DAPM Off. These are old
configuration readbacks, not a measurement of the current bus or present
kernel. No identifiable acoustic tone was established in those trials.

The newer [rate-only hardware log](frankel-speaker-rate-only-20260905.md)
establishes that permitting a 192 kHz frontend alone still consumes samples at
the stock 48 kHz cadence. The
[AoC analysis](frankel-native-ultrasound-decomp-20260905.md) identifies 48/96 kHz
speaker constructor branches, not a working normal 192 kHz selection.
Codec settings cannot repair that upstream cadence by themselves.

The remaining prerequisite is a supported, coordinated AoC 192 kHz producer
and physical TDM clock. Only after that exists can simultaneous clock/route
observations and actual acoustic bandwidth/continuity measurements qualify
the amplifier path. There is currently no verified 192 kHz speaker result.
