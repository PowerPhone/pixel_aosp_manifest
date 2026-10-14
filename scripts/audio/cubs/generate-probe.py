#!/usr/bin/env python3
"""Generate a real stereo S32 PCM probe; no resampling or bandwidth claims."""
import argparse
import json
import math
import struct
import wave
from pathlib import Path

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--output', type=Path, required=True)
p.add_argument('--rate', type=int, choices=(48000, 96000, 192000), required=True)
p.add_argument('--tone', type=float, default=20000)
p.add_argument('--end-tone', type=float, help='Optional linear-chirp end frequency; omitted means CW.')
p.add_argument('--duration', type=float, default=2)
p.add_argument('--peak', type=float, default=.02)
a = p.parse_args()
if not (0 < a.tone < a.rate / 2 and .02 <= a.duration <= 30 and 0 < a.peak <= .08):
    p.error('Require a sub-Nyquist tone, duration .02..30 s, peak (0,.08].')
if a.end_tone is not None and not (0 < a.end_tone < a.rate / 2 and a.end_tone != a.tone):
    p.error('Chirp end must differ from the start and lie strictly below Nyquist.')
if a.output.exists() or a.output.with_suffix('.json').exists():
    p.error('Refusing to overwrite an existing stimulus or parameter record.')
a.output.parent.mkdir(parents=True, exist_ok=True)
frames = round(a.duration * a.rate)
fade = min(round(.005 * a.rate), frames // 2)
with wave.open(str(a.output), 'wb') as w:
    w.setnchannels(2)
    w.setsampwidth(4)
    w.setframerate(a.rate)
    for start in range(0, frames, 4096):
        data = bytearray()
        for n in range(start, min(start + 4096, frames)):
            envelope = min(1., n / fade, (frames - 1 - n) / fade)
            t = n / a.rate
            slope = 0. if a.end_tone is None else (a.end_tone - a.tone) / a.duration
            phase = 2 * math.pi * (a.tone * t + .5 * slope * t * t)
            sample = round((2**31 - 1) * a.peak * envelope * math.sin(phase))
            data.extend(struct.pack('<ii', sample, sample))
        w.writeframesraw(data)
metadata = dict(rate=a.rate, channels=2, bits=32, frames=frames,
                duration_seconds=frames/a.rate, tone_hz=a.tone, peak=a.peak,
                linear_fade_seconds=fade/a.rate, identical_channels=True,
                signal='cw' if a.end_tone is None else 'linear_chirp', end_tone_hz=a.end_tone,
                purpose='Physical playback probe; digital generation alone is not acoustic evidence.')
a.output.with_suffix('.json').write_text(json.dumps(metadata, indent=2) + '\n')
print(json.dumps(metadata))
