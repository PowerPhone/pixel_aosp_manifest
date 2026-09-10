# Frankel 192 kHz acoustic measurement

This directory is the host half of the Frankel acoustic-verification rig. Its
purpose is to distinguish a real wideband signal from a stream that merely has
a 192 kHz WAV header. The scripts do not attach USB devices, choose a Windows
bus ID, change interface gain, or claim transducer bandwidth.

## Present receiver and its limit

The Windows USB inventory currently identifies a Behringer UMC202HD as
`1397:0507` and describes it as `UMC202HD 192k`. It was intentionally left
unshared during preparation of this runbook. Behringer specifies 24-bit/192 kHz
conversion and the rates 44.1, 48, 88.2, 96, 176.4, and 192 kHz. The same
official specification gives the analog input response only as 10 Hz--50 kHz
(0/-3 dB), and the output/system response only through 43 kHz. See the
[official product page](https://www.behringer.com/en/products/0805-AAR) and
[official U-PHORIA quick-start specification](https://mediadl.musictribe.com/media/sys_master/he0/h50/8849765957662.pdf).

That makes this interface useful for identifying a 24 kHz brick wall and for a
carefully calibrated comparison around 48 kHz. By itself it cannot substantiate
the requested smooth phone response through 60+ kHz. Final 60--96 kHz evidence
needs an acquisition interface, preamplifier, and measurement microphone whose
*analog* response is independently calibrated over that band. A 192 kHz ADC
label is not such a calibration.

## Host setup

Install ALSA's `arecord` alongside the existing Python analysis dependencies:

```bash
sudo apt-get install alsa-utils python3-numpy python3-scipy
```

USB forwarding is a deliberate operator step and is never performed by an
audio script. First locate the current bus ID without changing it:

```bash
usbipd.exe list
```

When a phone test is ready and no Windows application owns the interface, bind
the `1397:0507` row from an elevated Windows shell if it has not been shared
before, then attach its *current* bus ID to this WSL distribution. Do not copy
the historical `9-4` value blindly; bus IDs can change after replugging.

After forwarding, identify the stable ALSA card ID and hardware capture PCM:

```bash
lsusb -d 1397:0507
arecord -l
for card_id in /proc/asound/card*/id; do
  printf '%s: %s; USB ' "$card_id" "$(<"$card_id")"
  cat "${card_id%/id}/usbid"
done
```

Use the symbolic ALSA card ID printed above. The examples assume it is
`UMC202HD` and its capture device is 0; verify both on the actual host.

## Exact host capture

[`capture-alsa-192k.sh`](capture-alsa-192k.sh) opens only a literal symbolic
`hw:CARD,DEVICE` PCM. It refuses `default`, `plughw`, and numeric card aliases,
so an ALSA plug-in cannot silently resample the stream and card renumbering
cannot redirect a run. It additionally passes all four ALSA conversion-disable
flags, verifies `/proc/asound/cardN/usbid`, snapshots the live substream
`hw_params`, and requires all of the following:

- 192000 Hz, S32_LE, RW_INTERLEAVED, and the requested channel count;
- the requested period and buffer geometry at the hardware PCM;
- exactly `duration * 192000` WAV frames and plausible wall-clock duration;
- no `arecord` XRUN, overrun, underrun, suspension, or transport error.

Start with a two-channel, 1024-frame period and eight-period buffer:

```bash
scripts/audio/host/capture-alsa-192k.sh \
  --device hw:UMC202HD,0 --expected-usb-id 1397:0507 \
  --output work/audio/frankel/external-receiver-192k.wav \
  --duration 12 --channels 2 --period-size 1024 --buffer-size 8192
```

Alongside the WAV, a successful run produces `.alsa.log`, `.hw-params`, and
`.capture.json` sidecars. Preserve all four as one evidence unit. Failed and
interrupted runs leave PID-suffixed partials rather than promoting an invalid
WAV.

## Calibrate before measuring the phone

Keep the interface sample rate at 192 kHz for every baseline and phone run.
Changing the receiver rate between comparisons defeats the control.

1. Record terminated-input noise and room noise at the exact gain used later.
2. Electrically sweep the ADC with a safe, calibrated low-level source. Do not
   connect a speaker output to a mic input or enable phantom power unless the
   source and cabling are designed for it.
3. Measure the ultrasonic microphone, preamplifier, emitter, and geometry as a
   chain. Record the usable band and a dBFS floor that is above baseline noise.
4. Repeat a continuous pilot capture to establish the normal phase-step count
   and clock-frequency offset for the independent source/ADC clocks.

The analyzer's strict energy threshold must come from that baseline. Do not
pick a threshold after looking at the phone result.

## Isolated speaker tests

Place the calibrated ultrasonic measurement microphone at a fixed distance and
angle. Test `earpiece` and `bottom` separately, at the same conservative gain.
Never use `both` as a substitute for the two physical endpoint runs.

Generate a broadband sweep once:

```bash
scripts/audio/frankel/generate-signal.py generate \
  work/audio/frankel/chirp-15k-80k-192k-s32-4ch.wav \
  --signal chirp --start-frequency 15000 --end-frequency 80000 \
  --rate 192000 --channels 4 --bits 32 --duration 10 --amplitude 0.02
```

For each speaker, start the independent host receiver before the phone stream:

```bash
scripts/audio/host/capture-alsa-192k.sh \
  --device hw:UMC202HD,0 --expected-usb-id 1397:0507 \
  --output work/audio/frankel/speaker-earpiece-external-192k.wav \
  --duration 12 --channels 2 --period-size 1024 --buffer-size 8192 &
receiver_pid=$!
sleep 1
scripts/audio/frankel/tinyplay.sh \
  --file work/audio/frankel/chirp-15k-80k-192k-s32-4ch.wav \
  --endpoint earpiece --rate 192000 --format s32 --channels 4 \
  --period-size 512 --period-count 8 --ultrasonic-mode in-band \
  --high-rate-source direct --amp-gain 0
wait "$receiver_pid"
```

Repeat with `--endpoint bottom` and a different output name. Analyze only the
receiver channel connected to the measurement microphone (channel 0 here):

```bash
scripts/audio/analyze-wideband.py \
  work/audio/frankel/speaker-earpiece-external-192k.wav \
  --expected-rate 192000 --channel 0 --require-no-cutoff \
  --spectrum-csv work/audio/frankel/speaker-earpiece-external-spectrum.csv
```

After calibration, add the preregistered floor, for example
`--min-above-48k-dbfs -90`. The number is illustrative, not a UMC202HD or
Frankel acceptance limit. A result below the supplied 52--70 kHz floor exits 5;
a candidate 24/48 kHz brick wall exits 3.

For discontinuity screening, use a low-level continuous 18 kHz pilot in a
separate run. The analyzer removes linear clock offset, then counts abrupt
residual phase steps:

```bash
scripts/audio/analyze-wideband.py \
  work/audio/frankel/speaker-earpiece-pilot-external-192k.wav \
  --expected-rate 192000 --channel 0 --pilot-tone 18000 \
  --max-phase-step-outliers 0
```

Exit 4 means the selected channel exceeded the allowed outlier count. Zero is
a conservative initial screen, not a universal metrology threshold; establish
the rig's clean baseline and inspect peak/residual phase metrics. This check
complements, but does not replace, the host `.alsa.log` and phone kernel/AoC
XRUN logs.

## Isolated microphone tests

Use an independently calibrated ultrasonic emitter driven by a 192 kHz source.
Do not use an unqualified phone speaker to prove a phone microphone: an unknown
cutoff on either side makes the result ambiguous. Run `tinycap.sh` separately
for `pdm0`, `pdm1`, and `pdm2`, then analyze each WAV with
`--require-no-cutoff` and the source-specific energy floor.

The PDM numbers are electrical IDs until physically mapped. Determine the
bottom/top/camera-hole mapping by fixed-position stimulation and gentle
occlusion, record the mapping, and only then rename evidence by enclosure
endpoint. A rising broadband floor toward 96 kHz is supportive PDM
noise-shaping evidence; it is not required on every microphone and is not a
substitute for the calibrated stimulus.

## Phone self-loop matrix

[`../frankel/self-loop-192k.sh`](../frankel/self-loop-192k.sh) is a guarded
regression test for the two phone paths in series. Run the broadband stimulus
from each physical speaker while capturing all three PDM IDs:

```bash
scripts/audio/frankel/self-loop-192k.sh \
  --stimulus work/audio/frankel/chirp-15k-80k-192k-s32-4ch.wav \
  --output work/audio/frankel/self-loop-earpiece-all-192k.wav \
  --speaker earpiece --microphone all --duration 12 --lead-seconds 1 \
  --amp-gain 0

scripts/audio/frankel/self-loop-192k.sh \
  --stimulus work/audio/frankel/chirp-15k-80k-192k-s32-4ch.wav \
  --output work/audio/frankel/self-loop-bottom-all-192k.wav \
  --speaker bottom --microphone all --duration 12 --lead-seconds 1 \
  --amp-gain 0
```

Those two three-channel recordings cover the six physical combinations:

| Speaker | Captured microphone channels |
| --- | --- |
| Earpiece | PDM0, PDM1, PDM2 |
| Bottom | PDM0, PDM1, PDM2 |

If `all` channel ordering is in doubt, repeat six single-ID runs by replacing
`--microphone all` with `pdm0`, `pdm1`, and `pdm2`. Also repeat the matrix with
a four-channel continuous 18 kHz stimulus and append
`--pilot-tone 18000 --max-phase-step-outliers 0` for the conservative initial
jitter screen.

Self-loop energy above 48 kHz proves only that the *combined* speaker-air-mic
path passed it. A self-loop cutoff does not identify which side caused it. The
isolated external-receiver speaker tests and calibrated-emitter microphone
tests remain mandatory for endpoint claims.

### Time-aligned 18--85 kHz chirp analysis

[`../analyze-chirp-loop.py`](../analyze-chirp-loop.py) is the corresponding
real-capture analyzer for the D0/D10 stereo stimulus. It validates the stimulus
as a rising linear chirp, locates it in a mono or multichannel capture from the
18--23.5 kHz ridge, and refuses to infer upper-band behavior unless that
alignment is both strong and distinct. Generate the known stimulus once if it
is not already present:

```bash
scripts/audio/frankel/generate-signal.py generate \
  work/audio-research/frankel/signals/chirp-18k-85k-192k-s32-2ch-5s-a030.wav \
  --signal chirp --start-frequency 18000 --end-frequency 85000 \
  --rate 192000 --channels 2 --bits 32 --duration 5 --amplitude 0.30
```

After a real self-loop run, analyze every capture channel by default and retain
both the summary and frame-level ridge measurements:

```bash
scripts/audio/analyze-chirp-loop.py \
  work/audio-research/frankel/signals/chirp-18k-85k-192k-s32-2ch-5s-a030.wav \
  work/audio-research/frankel/self-loop-earpiece-raw192-pdm0.wav \
  --json-output \
    work/audio-research/frankel/self-loop-earpiece-raw192-pdm0.chirp.json \
  --ridge-csv \
    work/audio-research/frankel/self-loop-earpiece-raw192-pdm0.ridge.csv \
  --require-wideband
```

The report gives ridge-versus-simultaneous-local-noise SNR in 18--24, 24--36,
36--48, 48--60, 60--72, and 72--85 kHz bands. It also compares local transfer
gain across 24 and 48 kHz, identifies bracketed low-SNR ridge gaps, and reports
large STFT ridge-timing steps after removing a robust linear drift. The latter
is a discontinuity indicator, not a direct clock-jitter measurement. One sweep
also cannot distinguish a temporal dropout from a narrow acoustic notch.

Exit 3 means the lower-band alignment was weak or ambiguous and all upper-band
claims were withheld. Exit 4 means `--require-wideband` was requested but at
least one selected channel lacked supported 72--85 kHz evidence or had a
candidate sharp cutoff. Exit 2 is an input/format error. Exit 0 means analysis
completed; without `--require-wideband`, it is not itself a bandwidth pass.
Use repeatable real captures and inspect the CSV rather than relaxing the
detection thresholds after seeing a result.

## Evidence checklist

For every physical endpoint, archive the raw WAV, spectrum CSV, tool logs,
exact mixer/PCM geometry, image/build identity, geometry and gain notes, and at
least two repeat runs. Accept a 192 kHz endpoint only when all applicable checks
agree: exact live hardware parameters, full wall-clock/frame duration, no
XRUNs, no abrupt pilot discontinuities, no 24/48 kHz brick wall, and calibrated
energy above 48 kHz. To support a 60+ kHz claim, the external analog rig must
itself be calibrated there.
