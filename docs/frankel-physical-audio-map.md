# Frankel physical audio map

> The static amplifier, pin, rail, and logical-ID evidence in this document is
> still useful. Its later AP-PDM/card-1 module procedure is a superseded
> experiment and must not be used for the current image. Current capture uses
> card 0, PCM 10 (D10/EP3), mono S16_LE/192000 with logical IDs 0, 1, and 2;
> see [`frankel-audio-api.md`](frankel-audio-api.md). Logical IDs still do not
> prove enclosure-hole assignment; that requires controlled acoustic trials.

This document records what the extracted Pixel 10 (`frankel`) stock files prove
about the physical speakers and microphones. It deliberately separates a proven
electrical route from an enclosure-hole assignment that still needs an acoustic
test. It is a routing map, not evidence that any route has 192 kHz acoustic
bandwidth.

## Physical inventory and scope

Google's [Pixel 10 specifications](https://store.google.com/product/pixel_10_specs?hl=en-US)
list stereo speakers and three microphones. Google's
[Pixel 10 hardware diagram](https://support.google.com/pixelphone/answer/7157629)
locates the two speaker openings at the top and bottom and the three microphone
openings at the top, rear, and bottom. The extracted files agree on the endpoint
counts:

| Physical class in scope | Count | Local evidence |
| --- | ---: | --- |
| Built-in acoustic outputs | 2 | Two CS35L43 nodes are at `work/audio-research/frankel/baseline/live-frankel.dts:14040-14080`; the vendor configuration declares `SpeakerNum=2` at `work/aosp/vendor/google_devices/frankel/proprietary/vendor/etc/audio/config/audio_platform_configuration.xml:59-62`. |
| Built-in acoustic inputs | 3 | Three separately supplied DMICs are wired to PDM0, PDM2, and PDM3 as shown below. |

USB, Bluetooth, DisplayPort, and other virtual endpoints are outside this
inventory. The CS40L26 codec at `live-frankel.dts:12930-12959` belongs to the
haptic actuator, not a speaker or microphone; it is also excluded by the stated
acoustic-endpoint scope. Thus the PowerPhone target must qualify exactly five
physical endpoints: top receiver, bottom speaker, top mic, rear mic, and bottom
mic.

## Speaker route

Frankel does not expose separate AoC sinks for its earpiece and lower speaker.
The current 192 kHz qualification path uses:

```text
PCM 0,0 (`audio_playback0`)
  -> EP1 / AoC playback source 0
  -> `TDM_0_RX Mixer EP1`
  -> TDM0 hardware port
  -> `SINK_SPEAKER` (0)
  -> one or both CS35L43 amplifier enable controls
```

The stock DT names the PCM 0,0 frontend `audio_playback0`, EP1 playback, at
`work/audio-research/frankel/baseline/live-frankel.dts:1181-1191`. The stock
mixer route enables `TDM_0_RX Mixer EP1` at
`work/aosp/vendor/google_devices/frankel/proprietary/vendor/etc/audio/config/mixer_paths.xml:769-783`.
For an ordinary entrypoint, the AoC driver maps the EP index directly to the
source at `work/audio-research/upstream-aoc/alsa/aoc_alsa_hw.c:58-72`; it maps
`PORT_TDM_0_RX` to `SINK_SPEAKER` at
`work/audio-research/upstream-aoc/alsa/aoc_alsa_hw.c:33-47`, and defines the
speaker sink as 0 at
`work/audio-research/upstream-aoc/aoc-interface-zuma.h:2161-2168`. The route
binding converts the frontend and hardware-port IDs to that source/sink pair at
`work/audio-research/upstream-aoc/alsa/aoc_alsa_hw.c:1635-1659`.

PCM 0,28 (`audio_ultrasonic`) through `SPEAKER_US` and `TDM_0_RX Mixer US` was
an earlier experiment. It remains useful as historical routing evidence, but it
is not the current D0 transport and must not be cited as its tested route.

Physical selection happens after this common AoC sink:

| Requested endpoint | Amplifier control | Static confidence | Evidence |
| --- | --- | --- | --- |
| Earpiece | `Main AMP Enable Switch` | Proven | Stock `speaker-earpiece` enables only the unprefixed amplifier: `work/aosp/vendor/google_devices/frankel/proprietary/vendor/etc/audio/config/mixer_paths.xml:1402-1408`; voice/HAC variants agree at `:1410-1424`. |
| Lower-speaker candidate | `R Main AMP Enable Switch` | Proven non-earpiece amplifier; lower-hole location needs one acoustic confirmation | Stock `speaker-safe` enables only `R`: `mixer_paths.xml:1455-1457`. The full `speaker` path enables both at `:1426-1431`. |
| Both | Both controls | Unsafe | Simultaneous enable watchdogs FF1 `mainTask`; no API or wrapper exposes this combination. |

The DT's unprefixed `cs35l43@0` is at
`work/audio-research/frankel/baseline/live-frankel.dts:14040-14060`; the second
codec, `cs35l43@1`, supplies `sound-name-prefix = "R"` at `:14062-14080`.
The stock adapted routes contain both amplifiers, `R` only, and
unprefixed only at `mixer_paths.xml:1629-1654`.

Do not use `SINK_IDS` to select earpiece versus lower speaker. The extracted
mixer defaults write `-1 -1` at `mixer_paths.xml:163-164`, while the driver
initializes the default sink to 0 at
`work/audio-research/upstream-aoc/alsa/aoc_alsa_card.c:1846-1849`. More
importantly, opening the TDM0 path itself maps the hardware port to speaker sink
0. The two CS35L43 enable controls, not two AoC sink IDs, perform the physical
split. The research image deliberately permits only one amplifier at a time.

## Microphone electrical map

The DT proves three built-in DMIC rails and three physical PDM controllers:

| Schematic mic | Physical controller pins | 1.8 V rail | Evidence |
| --- | --- | --- | --- |
| DMIC1 | PDM0: `XAOC_PDM0_MIC_CLK`, `XAOC_PDM0_MIC_IN` | `L20M_DMIC1` | Pinmux: `work/audio-research/frankel/baseline/live-frankel.dts:25984-26000`; rail: `:16081-16088`. |
| DMIC2 | PDM2: `XAOC_PDM2_MIC_CLK`, `XAOC_PDM2_MIC_IN` | `L20S_DMIC2` | Pinmux: `live-frankel.dts:26012-26028`; rail: `:16522-16529`. |
| DMIC3 | PDM3: `XAOC_PDM3_MIC_CLK`, `XAOC_PDM3_MIC_IN` | `L19S_DMIC3` | Pinmux: `live-frankel.dts:26040-26056`; rail: `:16512-16519`. |

The AoC GPIO names independently list DMIC2, DMIC3, and DMIC1 clock/data pairs
at `live-frankel.dts:25149-25155`. No Frankel built-in mic is identified on
PDM1; the raw-handoff address inventory is at
`tools/audio/frankel_a32_raw_pdm_ap_handoff.md:45-63`.

### Logical IDs are not physical controller numbers

The stock mixer capture list is `0 1 2 -1` at
`work/aosp/vendor/google_devices/frankel/proprietary/vendor/etc/audio/config/mixer_paths.xml:251-256`.
The driver copies those logical IDs into the interleaving list and PDM mask at
`work/audio-research/upstream-aoc/alsa/aoc_alsa_hw.c:1879-1899`. However, the
reviewed firmware contains these diagnostic strings:

```text
DMICs re-mapped to PDM pads based on physical map:
  DMIC %d -> PDM pad %d (%s edge)
```

They occur at file offsets `0x26c0fa` and `0x26c130` in
`work/audio-research/frankel/ghidra-input/aoc-hifi.bin`. No captured runtime dump
records the actual Frankel remap. Therefore none of these correspondences may
be assumed from static evidence:

- logical `MIC0`, `MIC1`, or `MIC2` to physical PDM0, PDM2, or PDM3;
- physical PDM0, PDM2, or PDM3 to the bottom, top/front, or rear-camera hole.

Likewise, `tinycap.sh --endpoint pdm0`, `pdm1`, and `pdm2` currently select AoC
logical capture IDs 0, 1, and 2. Those option names do not prove physical
controller numbers. The framework configuration exposes only a bottom input
and a back input at
`work/aosp/vendor/google_devices/frankel/proprietary/vendor/etc/audio/config/audio_platform_configuration.xml:134-140`
and `:237-242`; it does not connect those descriptors to an AoC logical ID or a
PDM controller. The stock front/back mixer routes both inherit the same generic
mic path at `mixer_paths.xml:1461-1516`.

## Capture-free microphone power control

Only use the three scalar controls, and only while all capture paths and raw
PDM controllers are idle:

```sh
# Snapshot/read back one scalar at a time.
tinymix -D 0 -v -- MIC0
tinymix -D 0 -v -- MIC1
tinymix -D 0 -v -- MIC2

# Example isolated trial; repeat separately for MIC1 and MIC2.
tinymix -D 0 -- MIC0 1
tinymix -D 0 -v -- MIC0
tinymix -D 0 -- MIC0 0
tinymix -D 0 -v -- MIC0
```

Each scalar addresses exactly one logical mic index at
`work/audio-research/upstream-aoc/alsa/aoc_alsa_ctl.c:335-369` and
`:2713-2720`. Its implementation sends `CMD_AUDIO_INPUT_MIC_POWER_ON` or
`CMD_AUDIO_INPUT_MIC_POWER_OFF` without opening a capture PCM at
`work/audio-research/upstream-aoc/alsa/aoc_alsa_hw.c:498-521`. The scalar setter
does not propagate the lower-level return value, so verify the scalar readback
and inspect AoC logs after every write.

This is **capture-free, not F1-control-free**: the power command still travels
through the AoC audio-input control service. The three named DT regulators are
all `google,monitor-only`; the extracted files provide no evidence for a safe
direct AP rail-control alternative.

Do not use any of the following:

- `BUILDIN MIC POWER STATE`: its getter and setter loop over all four indices,
  including unsupported index 3, at `aoc_alsa_ctl.c:65-104` and `:131-165`.
- `MIC3`: a recorded Frankel trial produced `Cannot get DMIC power state for
  mic index 3` at
  `work/audio-research/frankel/live-d12-patch/decimator6-logcat.txt:32-37`.
- `BUILDIN_MIC_POWER_INIT`: it reads or writes five block-139 `PDM_POWER`
  configuration parameters rather than toggling one rail; see
  `aoc_alsa_ctl.c:2298-2327` and `aoc_alsa_hw.c:4156-4193`.
- `MIC Clock Rate` while capture is active: its getter caused a tested AoC
  watchdog reset, as recorded in `scripts/audio/frankel/README.md` under
  "Capture physical microphones."

`tinycap.sh` and `reset-routes.sh` now restrict their power preflight and
cleanup to scalar `MIC0`, `MIC1`, and `MIC2`; neither script accesses the
unsupported logical `MIC3` control. The physical `DMIC3`/PDM3 endpoint in the
table above is distinct from that invalid fourth AoC logical-control index.

## Live endpoint identification

Run these trials only on the exact reviewed Frankel build, with root ADB, after
stopping media, calls, camera, hotword, and other audio clients.

### Confirm the two speaker openings

Use the current D0 wrapper with a low-level 18 kHz stimulus, first with only the
unprefixed amplifier and then with only `R`. A conservative raw gain of 6 is the
stock earpiece value; increase only if the measurement setup requires it.

```bash
for endpoint in earpiece bottom; do
  scripts/audio/frankel/d0-speaker-192k.sh \
    --file work/audio-research/frankel/signals/tone-18k-192k-s32-2ch-15s.wav \
    --endpoint "$endpoint" --amp-gain 6 \
    --player-bin /data/local/tmp/tinyplay1-xrun
done
```

Measure close to each opening or use enclosure vibration. The unprefixed trial
must energize only the top receiver. The `R` trial should energize only the
lower opening; if it does not, correct the endpoint label rather than changing
`SINK_IDS`. Retain each wrapper log and require the complete expected byte count,
zero xruns, zero remaining bytes, successful drain, and its final hard-off
readback. Do not use `--skip-live-patch-check` for final evidence. This listening
or near-field trial establishes the opening assignment, not ultrasonic acoustic
bandwidth.

### Resolve current D10 logical IDs to microphone openings

Capture every current D10 selector separately. For each 15-second capture,
apply the same repeatable near-field 15--20 kHz source or gentle occlusion at
the bottom opening during seconds 2--4, the top opening during seconds 6--8,
and the rear opening during seconds 10--12. Start the timed sequence only after
the wrapper reports that PCM 0,10 is capturing. Repeat in reverse opening order
to reject gain and time drift.

```bash
scripts/audio/frankel/d10-raw192-capture.sh \
  --output work/audio-research/frankel/endpoint-map/mic0.wav \
  --endpoint raw192-pdm0 --duration 15 \
  --period-size 1920 --period-count 16 --soft-gain-db 0

# Repeat with raw192-pdm1/mic1.wav and raw192-pdm2/mic2.wav.
```

Assign each logical selector to the opening with the greatest stimulus
coherence or occlusion attenuation. Do not assign it using absolute RMS alone:
all three microphones can hear the same source, and an inactive/floating input
can be noisy. Record the result as:

```text
logical D10 MIC0/MIC1/MIC2 -> bottom/top/rear opening
```

This current D10 experiment cannot reveal whether a logical selector maps to
physical PDM0, PDM2, or PDM3 inside AoC. That separate mapping requires a
firmware runtime remap trace or direct physical-controller observation; do not
infer it from the `raw192-pdmN` option spelling.

### Historical AP-PDM controller-mapping procedure

> **Historical procedure below.** It describes the retired card-1 AP-PDM
> consumer. Do not load `frankel_pdm_alsa` or perform the A32 ownership handoff
> on a D10 PowerPhone image.

The raw AP consumer is still a guarded prototype. Complete its documented
single-PDM0 permission trial before any PDM2/PDM3 or coordinated
three-controller trial; see
`tools/audio/kernel/frankel_pdm_alsa/README.md:44-86` and `:180-230`.
The host-side implementation for one physical controller per invocation is
`scripts/audio/frankel/raw-pdm-capture.sh`. Thereafter use this order:

1. Require every `/proc/asound/card0/pcm*/sub*/status` to be `closed`. Run
   `python3 tools/audio/frankel_a32_raw_pdm.py check-idle --controllers 0,2,3
   --snapshot /tmp/frankel-pdm023-MICN.json`. Snapshot scalar `MIC0`, `MIC1`,
   and `MIC2` individually; never query the four-element vector or `MIC3`.
2. While the controllers remain idle, power exactly one logical scalar and
   leave the other two off. Read it back, inspect the AoC log, and rerun
   `check-idle`. If the controllers are no longer idle, restore power and stop.
3. Run `raw-pdm-capture.sh` for PDM0 first. It loads/maps its raw module in the
   waiting state, rechecks A32 idle state after powering the selected scalar,
   applies only controller 0, and enables polling only after apply succeeds.
   PDM2/PDM3 require its explicit `--ack-pdm0-permission-proven` gate. The
   wrapper does not support `all`; a future simultaneous run must use the
   coordinated `apply --controllers 0,2,3` and matching revert documented at
   `tools/audio/frankel_a32_raw_pdm_ap_handoff.md:136-169`.
4. Card 1 devices 0, 2, and 3 map to physical PDM0, PDM2, and PDM3 in
   `tools/audio/kernel/frankel_pdm_alsa/README.md:1-15`. Present a low-level
   15--20 kHz near-field broadband signal or chirp and repeat separate wrapper
   trials across the logical-scalar/controller matrix. A controller coherent
   with the stimulus identifies the physical controller powered by that
   logical `MICN`. Use coherence with the known stimulus rather than raw RMS,
   because an unpowered input can float noisily.
5. Let the wrapper perform the cleanup below, then repeat separately for the
   other logical IDs/controllers. Do not change a mic power control while the
   AP owns a PDM controller.
6. After resolving logical-ID-to-controller mapping, power all three scalars
   while idle and capture all three controllers together. Use time-coded
   near-field or gentle-occlusion windows, for example bottom at 0--3 seconds,
   top/front at 4--7 seconds, and rear-camera at 8--11 seconds, with one-second
   gaps. Repeat in reverse order to reject gain and time drift. Assign holes by
   stimulus coherence and occlusion attenuation, not sign; raw bit order,
   polarity, and decimator phase remain calibration variables.

Record the resulting two mappings explicitly:

```text
logical MIC0/MIC1/MIC2 -> physical PDM0/PDM2/PDM3
physical PDM0/PDM2/PDM3 -> enclosure opening
```

### Mandatory cleanup order

For every raw-PDM trial:

1. Stop and reap every `tinycap` process started by the trial.
2. Write `0` to
   `/sys/module/frankel_pdm_alsa/parameters/polling_enabled` and wait for the
   write to return. Read the module statistics and collect dmesg now.
3. Run the matching A32 `revert` with the exact selected controller set,
   `--ack-hardware-write`, `--ack-polling-stopped`, and the exact trial
   snapshot.
4. Power off every scalar selected by the trial using only `MIC0`, `MIC1`, or
   `MIC2`; the current wrapper selects exactly one.
5. Only after polling is off, A32 state is reverted, and scalar power is off,
   unload the raw module. Pull and validate the WAV afterward, then recheck all
   PCM status files and inspect the saved kernel/AoC logs.

Never revert A32 ownership while AP polling is enabled. The module's synchronous
polling stop requirement is documented at
`tools/audio/kernel/frankel_pdm_alsa/README.md:66-86`. The wrapper refuses
dependent cleanup if it cannot prove polling-off or the matching A32 restore;
this intentionally leaves evidence and state for manual guarded recovery.
