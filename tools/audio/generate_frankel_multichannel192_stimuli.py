#!/usr/bin/env python3
"""Create the exact physical-test stimuli; no device calls or capture simulation.

Unlike the general generator, this dedicated experiment intentionally permits
a sweep's mathematical limits of DC and Nyquist. Its last sampled frequency is
below Nyquist. Existing generator guards are not modified.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import wave

import numpy as np

RATE = 192000
PEAK = 0.08
FADE_FRAMES = 960


def fade(samples):
    ramp = 0.5 - 0.5 * np.cos(np.pi * np.arange(FADE_FRAMES) / (FADE_FRAMES - 1))
    samples[:FADE_FRAMES] *= ramp
    samples[-FADE_FRAMES:] *= ramp[::-1]
    return samples


def save_stereo(path, mono, repetitions):
    pcm = np.rint(mono * PEAK * 2147483647).astype('<i4')
    with wave.open(str(path), 'wb') as output:
        output.setnchannels(2)
        output.setsampwidth(4)
        output.setframerate(RATE)
        for _ in range(repetitions):
            for start in range(0, len(pcm), RATE):
                # Channels share exactly the same integer samples and phase.
                stereo = np.repeat(pcm[start:start + RATE, None], 2, axis=1)
                output.writeframesraw(stereo.tobytes())


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output-dir', type=Path, required=True)
    args = parser.parse_args()
    if args.output_dir.exists():
        parser.error('choose a new output directory; existing stimuli are never overwritten')
    args.output_dir.mkdir(parents=True)

    cw_frames = RATE * 30
    t = np.arange(cw_frames, dtype=np.float64) / RATE
    cw = fade(np.sin(2 * np.pi * 50000 * t))
    cw_name = 'cw-50000Hz-30s-stereo-s32-192k.wav'
    save_stereo(args.output_dir / cw_name, cw, 1)

    sweep_frames = RATE * 10
    t = np.arange(sweep_frames, dtype=np.float64) / RATE
    slope = 96000 / 10
    sweep = fade(np.sin(2 * np.pi * (0.5 * slope * t * t)))
    sweep_name = 'sweep-0-to-96000Hz-10s-x3-stereo-s32-192k.wav'
    save_stereo(args.output_dir / sweep_name, sweep, 3)

    parameters = {
        'generator': str(Path(__file__).resolve()),
        'numpy_version': np.__version__,
        'rate_hz': RATE, 'channels': 2, 'format': 'signed PCM32 little-endian RIFF/WAVE',
        'channel_relationship': 'sample-identical, same phase, no channel-dependent delay',
        'peak_scale': PEAK, 'integer_scale': 2147483647, 'quantizer': 'numpy.rint, no dither',
        'frame_count_each_file': cw_frames, 'seconds_each_file': 30,
        'fade_frames_each_edge': FADE_FRAMES, 'fade_seconds': FADE_FRAMES / RATE,
        'fade': 'half-cosine, inclusive 0 to 1 over first960 frames; reversed at final960',
        'cw': {'file': cw_name, 'frequency_hz': 50000,
               'phase_radians': '2*pi*50000*n/192000', 'fades': 'start/end of entire30s'},
        'sweep': {'file': sweep_name, 'repetitions': 3, 'identical_integer_repetitions': True,
                  'frames_each_repetition': sweep_frames, 'seconds_each_repetition': 10,
                  'start_hz': 0, 'mathematical_endpoint_hz': 96000,
                  'slope_hz_per_second': slope, 'phase_radians': '2*pi*0.5*9600*(n/192000)^2',
                  'sample_time_seconds': 'n/192000, n=0..1919999; restart n=0 for each repetition',
                  'last_sample_instantaneous_frequency_hz': slope * (sweep_frames - 1) / RATE,
                  'fades': 'start/end of every10s repetition; no extra gap frames'},
        'limits': '96kHz is the mathematical Nyquist endpoint at t=10s, not an above-limit sampled tone. The endpoint is faded and not an independently measurable bandwidth proof. No resampling, DSP calibration, or physical endpoint support is asserted by generating these files.'}
    (args.output_dir / 'stimulus-parameters.json').write_text(json.dumps(parameters, indent=2) + '\n')
    print(json.dumps(parameters, indent=2))


if __name__ == '__main__':
    main()
