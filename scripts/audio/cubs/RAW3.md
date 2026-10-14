# Cubs simultaneous RAW3 capture

This is a volatile research-firmware mode, not an ordinary Android audio route.
It is not admitted until the firmware applier finishes its postguards and
publishes `/dev/powerphone-cubs-raw3-192` with exactly these four lines:

```text
channels=3
rate=192000
format=S16_LE
logical_mics=0,1,2
```

The existing `/dev/powerphone-cubs-mono192` quarantine marker must also exist.
The wrappers require initial AoC restart/coredump counters0/0: the RAW3 marker
alone can survive an AoC-only restart and therefore is not generation proof.
Generation changes during the experiment still prevent stale mixer restoration.

After the hardware owner applies that profile, these host commands select the
simultaneous stream without changing firmware themselves:

```bash
scripts/audio/cubs/direct-mic-capture.sh \
  --output-dir NEW_CAPTURE_DIRECTORY --rate 192000 --mic all --duration 5

scripts/audio/cubs/duplex-baseline.sh \
  --output-dir NEW_DUPLEX_DIRECTORY --wav EXISTING_S32_STEREO_PROBE.wav \
  --capture-rate 192000 --mic all --pcm deep --endpoint bottom --asp bypass
```

Existing ADB options apply. Both use card0/D10, S16_LE, three channels and
`BUILDIN MIC ID CAPTURE LIST = 0 1 2 -1`. The backend channel enum is`Three`.
Wrong-rate requests, mono requests under RAW3, and `all` requests without the
exact marker are rejected before mixer changes. Mono behavior remains unchanged
when no RAW3 marker is present. Ordinary services stay stopped afterward; a
fresh boot is required to leave the research profile.

## Duration and evidence limits

Direct capture retains its1–120s bound. Duplex defaults remain5s capture and
at most2s playback after its quiet lead. Explicit long-run options are
`--capture-duration 5..60` and`--max-playback-duration 1..30`: the actual WAV
must fit both its stated maximum and capture duration minus3s. For a30s
stimulus use`--capture-duration 35 --max-playback-duration 30`. The probe
generator permits at most30s and retains its0.08peak ceiling and5ms fades.
The standalone speaker wrapper's10s bound is unchanged. Both capture wrappers
retain the existing absolute0.25s captured-duration tolerance and report the
actual sample count, requested duration and deficit. Existing mono192 trials
often contain875520frames (4.56s) for a5s request: that0.44s startup deficit
still causes the final format/duration gate to fail, even if device commands
and cleanup succeeded. The original partial WAV and logs remain available;
they must not be described as a complete5s acquisition.

For RAW3, neither three-channel headers nor sufficient frames establish three
independent physical signals. Analyze all original channels for nonzero and
distinct data, freshness, intended-tone frequency and whole-interval continuity.
Noise near Nyquist is supporting evidence, not independent acoustic bandwidth
qualification. Any higher-frequency speaker limitation remains separate.
