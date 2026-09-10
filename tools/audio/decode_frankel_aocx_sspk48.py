#!/usr/bin/env python3
"""Analyze the lossy stock-48-kHz Frankel AoCx sspk WAV recorder format.

This is an evidence-specific decoder, not a generic WAV conversion utility.
Each packet's missing second half remains a gap. No continuous WAV is emitted.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import sys
import wave

import numpy as np


RATE = 48000
PACKET_FRAMES = 1920
OBSERVED_FRAMES = 960
PACKET_BYTES = 15360
TONE_HZ = 15000


def decode(path: Path) -> tuple[np.ndarray, int]:
    with wave.open(str(path), "rb") as source:
        if (source.getframerate(), source.getnchannels(), source.getsampwidth(),
                source.getcomptype()) != (RATE, 2, 4, "NONE"):
            raise ValueError("requires the known PCM32/stereo/48000 tap header")
        header_frames = source.getnframes()
        payload = source.readframes(header_frames)
    if not payload or len(payload) != header_frames * 8:
        raise ValueError("empty or truncated tap payload")
    if len(payload) % PACKET_BYTES:
        raise ValueError("payload does not contain complete 15360-byte packets")

    packets = np.frombuffer(payload, dtype="<u2").reshape(-1, 7680)
    if np.count_nonzero(packets[:, 3840:]):
        raise ValueError("packet second halves are not all zero; unsupported layout")

    # The stock recorder uses 16-bit planar-to-interleaved conversion in
    # 480-sample/10-ms units even when the packet says four bytes per sample.
    # Undo that conversion only for the first 7680 bytes that it retained.
    chunks = packets[:, :3840].reshape(-1, 960)
    restored = np.concatenate((chunks[:, 0::2], chunks[:, 1::2]), axis=1)
    observed = restored.copy().view("<i4").reshape(-1, OBSERVED_FRAMES, 2)
    return observed, header_frames


def analyze(observed: np.ndarray, header_frames: int, path: Path) -> dict:
    phase = np.exp(-2j * np.pi * TONE_HZ * np.arange(OBSERVED_FRAMES) / RATE)
    frequencies = np.fft.rfftfreq(OBSERVED_FRAMES, 1 / RATE)
    window = np.hanning(OBSERVED_FRAMES)
    channels = []
    for channel in range(2):
        samples = observed[:, :, channel].astype(np.float64)
        rms = np.sqrt(np.mean(samples * samples, axis=1))
        tone_amplitudes = np.abs(samples @ phase) * (2 / OBSERVED_FRAMES)
        max_amplitude = float(np.max(tone_amplitudes))
        # Describe explicitly selected tone-bearing packets, not silent gaps.
        tone_packets = tone_amplitudes >= max_amplitude * 0.5
        tone_packets &= tone_amplitudes > 0
        power = np.mean(np.abs(np.fft.rfft(samples * window, axis=1)) ** 2, axis=0)
        dominant = float(frequencies[1 + np.argmax(power[1:])]) if np.any(power) else None
        selected_fraction = (tone_amplitudes[tone_packets] ** 2 /
                             (2 * rms[tone_packets] ** 2))
        channels.append({
            "channel": channel,
            "observed_nonzero_samples": int(np.count_nonzero(samples)),
            "observed_peak_abs_s32_units": float(np.max(np.abs(samples))),
            "observed_rms_s32_units": float(np.sqrt(np.mean(samples * samples))),
            "dominant_bin_hz": dominant,
            "bin_width_hz": RATE / OBSERVED_FRAMES,
            "tone_hz": TONE_HZ,
            "tone_amplitude_max_s32_units": max_amplitude,
            "tone_packet_selection": "amplitude >= half maximum, excluding zero",
            "tone_selected_packets": int(np.count_nonzero(tone_packets)),
            "tone_amplitude_median_selected_s32_units": (
                float(np.median(tone_amplitudes[tone_packets])) if np.any(tone_packets) else None),
            "tone_energy_fraction_median_selected": (
                float(np.median(selected_fraction)) if np.any(tone_packets) else None),
        })
    return {
        "input": str(path),
        "profile": "frankel-stock48-sspk-cp2a.260805.005",
        "sample_units": "signed 32-bit integers; full-scale convention not inferred",
        "nominal_rate_hz": RATE,
        "packet_count": len(observed),
        "header_frames": header_frames,
        "observed_frames_per_channel": len(observed) * OBSERVED_FRAMES,
        "missing_frames_per_channel": len(observed) * OBSERVED_FRAMES,
        "gap_layout": {
            "packet_stride_frames": PACKET_FRAMES,
            "observed_range_within_each_packet": [0, OBSERVED_FRAMES],
            "missing_range_within_each_packet": [OBSERVED_FRAMES, PACKET_FRAMES],
            "ranges_are_half_open": True,
            "omitted_source_samples_cannot_be_recovered": True,
        },
        "spectrum_method": "average spectra of individual observed 20-ms pieces; no gap concatenation",
        "timeline": "nominal packet order only; original packet timestamps are absent from WAV",
        "continuous_stream_recovered": False,
        "jitter_qualified": False,
        "acoustic_output_qualified_by_this_tap": False,
        "channels": channels,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("capture", type=Path)
    parser.add_argument("--confirm-stock-48k", action="store_true", required=True,
                        help="confirm stock 48-kHz sspk evidence, not a stale-header 192-kHz experiment")
    parser.add_argument("--json-output", type=Path)
    parser.add_argument("--npz-output", type=Path,
                        help="optional nominal packet timeline with NaN missing samples; never a continuous WAV")
    args = parser.parse_args()
    for output in (args.json_output, args.npz_output):
        if output is not None and output.exists():
            parser.error(f"refusing to overwrite existing output: {output}")
    try:
        observed, header_frames = decode(args.capture)
        report = analyze(observed, header_frames, args.capture)
        text = json.dumps(report, indent=2, allow_nan=False) + "\n"
        if args.npz_output:
            timeline = np.full((len(observed), PACKET_FRAMES, 2), np.nan)
            timeline[:, :OBSERVED_FRAMES, :] = observed
            present = np.zeros((len(observed), PACKET_FRAMES), dtype=bool)
            present[:, :OBSERVED_FRAMES] = True
            # Open explicitly so numpy does not silently alter the filename.
            with args.npz_output.open("xb") as output:
                np.savez_compressed(output, pcm_s32_units=timeline.reshape(-1, 2),
                                    observed=present.reshape(-1), nominal_rate_hz=RATE,
                                    packet_frames=PACKET_FRAMES)
        if args.json_output:
            with args.json_output.open("x") as output:
                output.write(text)
        sys.stdout.write(text)
        return 0
    except (OSError, ValueError, wave.Error) as error:
        print(f"Cannot decode stock sspk capture: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
