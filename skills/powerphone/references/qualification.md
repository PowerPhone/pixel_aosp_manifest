# Acoustic bandwidth, endpoint mapping, and continuity qualification

Use this procedure to separate metadata, transport, electrical bandwidth, and
physical acoustic bandwidth. A maximum stable transport rate and the highest
measured usable acoustic frequency are different results; do not collapse them
into one pass claim.

## Evidence ladder

| Observation | What it establishes | What it does not establish |
| --- | --- | --- |
| Driver advertises/accepts a rate | ALSA constraint permits it | Actual clocks, cadence, or bandwidth |
| Correct active `hw_params` or equivalent direct observer | Frontend PCM geometry | Backend rate or absence of resampling |
| Expected bytes over wall time | Nominal producer/consumer cadence | Fresh samples or acoustic bandwidth |
| Fresh non-repeating blocks | New data reaches the frontend | Correct spectrum or physical endpoint |
| Backend clock/DSP log | Selected hardware/firmware profile | Transducer acoustic response |
| Java/AAudio plus active ALSA state | Intended API route reaches the PCM | Ultrasonic acoustic response |
| Calibrated spectrum and pilot continuity | Physical passband and sample-slip continuity within rig limits | Sample-clock phase noise or performance beyond the rig's calibration |

Retain evidence from every rung. The highest rung does not excuse an XRUN or
wrong route at a lower rung.

## Map endpoints before naming them

Static DT and mixer files can prove rails, pads, codec channels, or amplifier
controls without proving an enclosure opening. Firmware can remap logical
microphones to physical PDM controllers.

For speakers, play a short low-level 15--22 kHz chirp through one amplifier at
a time and measure close to each opening or use enclosure vibration. Do not use
a combined amp route to infer the split.

For microphones, capture each logical selector separately while applying
time-coded near-field stimuli or gentle occlusion to bottom, top/front, and
camera openings. Repeat in reverse order. Use coherence with the known signal
and occlusion attenuation rather than raw RMS or polarity. Maintain two maps:

```text
logical microphone selector -> physical controller/pad
physical controller/pad -> enclosure opening
```

If controller isolation is unavailable, report only the mapping actually
measured; do not fill the missing link from similar phones.

## Design a bandwidth measurement

Use low output gain and short trials. Avoid 1 kHz; a low-level tone above
15 kHz, deterministic broadband noise, or a swept chirp is more useful and less
annoying. Monitor amplifier/codec temperature and stop on distortion, thermal
events, watchdogs, or unexpected audible artifacts.

### Microphone

Drive the phone with an independently characterized wideband ultrasonic source
and capture raw/unprocessed data at the target rate. Inspect each endpoint
separately. For a target rate `Fs`, Nyquist is `Fs/2`; show usable evidence
above the previous 24 or 48 kHz boundary and no unexplained brick-wall cutoff
there.

PDM delta-sigma microphones commonly show a rising noise-shaped floor toward
Nyquist. That is supporting evidence that a high-rate stream contains the
expected converter noise, especially when it appears across fresh blocks, but
it neither proves acoustic sensitivity nor excludes upsampling or injected DSP
noise. Require a coherent above-legacy-band stimulus for an acoustic claim.

### Speaker

Use a measurement microphone and interface whose calibrated response extends
beyond the frequency being claimed. Play a low-level broadband signal or sweep
through each transducer separately. Look for a gradual physical rolloff rather
than a sharp 24 or 48 kHz boundary. A receiver rated only to 50 kHz can expose a
48 kHz brick wall but cannot substantiate smooth response above 60 kHz.

Phone speaker-to-phone microphone self-loop testing is useful combined-path
evidence: energy above a legacy cutoff implies both active paths passed that
content during the run. It does not independently assign the rolloff or maximum
bandwidth to the speaker versus the microphone. Use an external characterized
source/receiver to qualify them separately.

Guard against spectral-analysis artifacts. Use raw PCM/WAV with known integer
format, analyze channels separately, choose windows deliberately, and ensure
the generator, player, recorder, pull/conversion step, and analysis library did
not resample. Record the external rig model, its configured hardware rate, and
its calibrated bandwidth. With carefully selected tones or a sweep, also check
for folded aliases at the frequencies predicted by any suspected 48 or 96 kHz
intermediate stage.

## Detect drops, stale data, and clock discontinuity

Check all of these together:

- ALSA/kernel/DSP XRUN, underrun, overrun, watchdog, and restart logs;
- actual frames and bytes versus monotonic wall-clock duration;
- callback/read/write sizes and timestamp deltas;
- zero, duplicated, or repeated half-block patterns at DSP quantum boundaries;
- discontinuous phase increments of a continuous pilot above 15 kHz; and
- consistency across repeated chirps and teardown/reopen cycles.

A valid file length can contain duplicated or zero-filled data. A clean log can
still miss an application callback gap. Fit and remove the steady phase slope
caused by independent source and capture clocks before treating a pilot-phase
step as a dropped or repeated sample.

These checks establish transport continuity, callback scheduling, and coarse
clock drift. They do not measure sample-clock jitter or phase noise; reserve
that term for a calibrated timebase or spectral method with a stated bandwidth
and uncertainty.

If scheduling causes XRUNs, first increase period count within ring limits.
Change period frames only with an explicit DSP cadence model; preserve period
time where possible and recompute byte geometry. Repeat the full endpoint and
spectrum test after every buffer change.

## Qualification matrix

Maintain one row per independently selectable built-in endpoint and require:

```text
physical/logical identity and route
direct tinyALSA rate/format/channels/periods and observation mechanism
backend clock or DSP profile evidence
freshness, duration, XRUN/restart result
Java AudioTrack or AudioRecord result
native AAudio result
UNPROCESSED/effect state for inputs
spectral response and instrument limit
pilot/timestamp continuity and clock-drift result
image/build identity and evidence paths
```

For output, test each individual transducer; simultaneous playback is not a
separate physical endpoint unless the research requirement explicitly needs it
and hardware testing proves it safe. For input, do not call logical IDs
bottom/top/camera until the mapping experiment passes.

Classify results precisely: configured, transport-qualified, combined-path
wideband, or independently acoustic-qualified. Record the transport rate and
measured acoustic band separately. Mark missing calibration, instrument
bandwidth, physical mapping, Java API, AAudio, lifecycle coverage, or endpoint
coverage as a gap rather than converting it into a pass.
