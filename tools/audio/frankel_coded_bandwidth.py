#!/usr/bin/env python3
"""Generate coded acoustic bandwidth stimuli and analyze real 192 kHz captures.

Each carrier plays alone. Noncommensurate carrier frequencies avoid common
harmonic/alias coincidences, while a known on/off code distinguishes acoustic
output from microphone noise. Hardware capture is performed separately by
scripts/audio/frankel/d5-d10-acoustic-measurement.sh.
"""
from __future__ import annotations

import argparse
import csv
import json
from pathlib import Path

import numpy as np
from scipy import signal
from scipy.io import wavfile

RATE = 192000
FREQUENCIES = [12000, 18173, 30419, 42761, 54283, 66547, 78829]
CODE = [1, 0, 1, 1, 0, 1, 0, 0, 1, 1]
SLOT = 0.2
STEP = SLOT * len(CODE)
GAP = 0.5
LEAD = 1.0


def db(power: float) -> float:
    return float(10 * np.log10(max(power, 1e-30)))


def generate(args: argparse.Namespace) -> None:
    manifest_path = args.wav.with_suffix(".json")
    if args.wav.exists() or manifest_path.exists():
        raise FileExistsError("output WAV or manifest exists; choose a new path")
    if not 0 < args.amplitude <= 0.1:
        raise ValueError("amplitude must be greater than zero and at most 0.1")
    duration = LEAD + len(FREQUENCIES) * (STEP + GAP) + 1
    mono = np.zeros(round(duration * RATE), dtype=np.float64)
    segments = []
    for i, frequency in enumerate(FREQUENCIES):
        start = LEAD + i * (STEP + GAP)
        t = np.arange(round(STEP * RATE)) / RATE
        envelope = np.repeat(np.asarray(CODE, dtype=np.float64), round(SLOT * RATE))
        # A 10 ms triangular smoothing kernel removes clicks at code transitions.
        kernel = signal.windows.triang(round(0.01 * RATE))
        kernel /= kernel.sum()
        envelope = signal.convolve(envelope, kernel, mode="same")
        tone = args.amplitude * envelope * np.sin(2 * np.pi * frequency * t)
        first = round(start * RATE)
        mono[first:first + tone.size] = tone
        segments.append({"frequency_hz": frequency, "start_seconds": start, "duration_seconds": STEP})
    pcm = np.round(mono * (2 ** 31 - 1)).astype(np.int32)
    args.wav.parent.mkdir(parents=True, exist_ok=True)
    wavfile.write(args.wav, RATE, np.column_stack([pcm, pcm]))
    manifest = {"sample_rate_hz": RATE, "channels": 2, "bits": 32, "duration_seconds": duration,
                "amplitude": args.amplitude, "slot_seconds": SLOT, "amplitude_code": CODE,
                "segments": segments}
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n")
    print(json.dumps({"wav": str(args.wav), "manifest": str(manifest_path), "duration_seconds": duration,
                      "recommended_capture_seconds": int(np.ceil(duration + 5))}, indent=2))


def carrier_envelope(samples: np.ndarray, frequency: float, block: int = 1920) -> np.ndarray:
    n = samples.size // block
    t = np.arange(block) / RATE
    weights = signal.windows.hann(block, sym=False) * np.exp(-2j * np.pi * frequency * t)
    # Phase reset per block leaves magnitude unchanged and avoids huge arrays.
    return np.abs(samples[:n * block].reshape(n, block) @ weights) * 2 / np.sum(np.abs(weights))


def corrcoef(a: np.ndarray, b: np.ndarray) -> float:
    if a.size < 3 or np.std(a) < 1e-20 or np.std(b) < 1e-20:
        return 0.0
    return float(np.corrcoef(a, b)[0, 1])


def folded(frequency: float, rate: float) -> float:
    return abs((frequency + rate / 2) % rate - rate / 2)


def analyze(args: argparse.Namespace) -> None:
    manifest = json.loads(args.manifest.read_text())
    rate, pcm = wavfile.read(args.wav)
    if rate != RATE:
        raise ValueError(f"the qualified microphone reference requires {RATE} Hz, got {rate}")
    if pcm.ndim == 2:
        pcm = pcm[:, args.channel]
    if np.issubdtype(pcm.dtype, np.signedinteger):
        samples = pcm.astype(np.float64) / (2 ** (np.iinfo(pcm.dtype).bits - 1))
    else:
        raise ValueError("expected signed integer PCM")
    samples -= samples.mean()
    code = np.asarray(manifest["amplitude_code"])
    slot = manifest["slot_seconds"]
    first_segment = manifest["segments"][0]
    block_seconds = 0.01
    first_env = carrier_envelope(samples, first_segment["frequency_hz"])
    template = np.repeat(code, round(slot / block_seconds)).astype(np.float64)
    template -= template.mean()
    n = template.size
    if first_env.size < n:
        raise ValueError("capture is shorter than the alignment pilot")
    sums = np.convolve(first_env, np.ones(n), mode="valid")
    sumsq = np.convolve(first_env ** 2, np.ones(n), mode="valid")
    numerator = signal.correlate(first_env, template, mode="valid")
    denominator = np.sqrt(np.maximum(sumsq - sums ** 2 / n, 1e-30) * np.sum(template ** 2))
    correlations = numerator / denominator
    best_index = int(np.argmax(correlations))
    alignment = float(correlations[best_index])
    offset = args.offset if args.offset is not None else best_index * block_seconds - first_segment["start_seconds"]
    args.output_dir.mkdir(parents=True, exist_ok=True)
    results = []
    for segment in manifest["segments"]:
        frequency = segment["frequency_hz"]
        start = offset + segment["start_seconds"]
        stop = start + segment["duration_seconds"]
        first, last = round(start * RATE), round(stop * RATE)
        if first < 0 or last > samples.size:
            results.append({"frequency_hz": frequency, "error": "segment outside capture"})
            continue
        selected = samples[first:last]
        env = carrier_envelope(selected, frequency)
        env_times = (np.arange(env.size) + 0.5) * block_seconds
        slots = np.minimum((env_times / slot).astype(int), code.size - 1)
        interior = ((env_times % slot) > 0.03) & ((env_times % slot) < slot - 0.03)
        on = interior & (code[slots] == 1)
        off = interior & (code[slots] == 0)
        on_power = float(np.median(env[on] ** 2) / 2)
        off_power = float(np.median(env[off] ** 2) / 2)
        code_correlation = corrcoef(env[interior], code[slots][interior])
        frequencies, psd = signal.periodogram(selected, RATE, window="hann", scaling="density")
        df = frequencies[1] - frequencies[0]
        near = np.abs(frequencies - frequency) <= 15
        peak_index = int(np.argmax(np.where(near, psd, 0)))
        a, b, c = np.log(np.maximum(psd[peak_index - 1:peak_index + 2], 1e-30))
        correction = 0.5 * (a - c) / (a - 2 * b + c) if a - 2 * b + c else 0
        measured = float(frequencies[peak_index] + np.clip(correction, -0.5, 0.5) * df)
        aliases = []
        for assumed_rate in (48000, 96000):
            alias = folded(frequency, assumed_rate)
            if abs(alias - frequency) < 1:
                continue
            alias_env = carrier_envelope(selected, alias)
            alias_power = float(np.median(alias_env[on] ** 2) / 2)
            aliases.append({"assumed_intermediate_rate_hz": assumed_rate, "alias_hz": alias,
                            "alias_on_dbfs": db(alias_power), "alias_relative_to_intended_db": db(alias_power / max(on_power, 1e-30)),
                            "alias_code_correlation": corrcoef(alias_env[interior], code[slots][interior])})
        # A strong subharmonic could produce the requested high tone through
        # nonlinear distortion. Explicitly report 2nd..8th-harmonic alternatives.
        subharmonics = []
        for harmonic in range(2, 9):
            lower = frequency / harmonic
            lower_env = carrier_envelope(selected, lower)
            lower_power = float(np.median(lower_env[on] ** 2) / 2)
            subharmonics.append({"harmonic": harmonic, "lower_frequency_hz": lower,
                                 "lower_relative_to_intended_db": db(lower_power / max(on_power, 1e-30)),
                                 "lower_code_correlation": corrcoef(lower_env[interior], code[slots][interior])})
        detected = (code_correlation >= 0.75 and db(on_power / max(off_power, 1e-30)) >= 15
                    and abs(measured - frequency) <= 2 and (args.offset is not None or alignment >= 0.75))
        confound = any(item["lower_relative_to_intended_db"] > 0 and item["lower_code_correlation"] > 0.75 for item in subharmonics)
        strong_alias = any(item["alias_relative_to_intended_db"] > -20 and item["alias_code_correlation"] > 0.75 for item in aliases)
        result = {"frequency_hz": frequency, "capture_start_seconds": start,
                  "measured_peak_hz": measured, "pitch_error_hz": measured - frequency,
                  "on_dbfs": db(on_power), "on_over_off_db": db(on_power / max(off_power, 1e-30)),
                  "code_correlation": code_correlation, "intended_coded_tone_detected": bool(detected),
                  "strong_coded_subharmonic_confound": bool(confound),
                  "strong_coded_alias": bool(strong_alias),
                  "clean_intended_tone_evidence": bool(detected and not confound and not strong_alias),
                  "aliases": aliases, "subharmonics": subharmonics}
        results.append(result)
        with (args.output_dir / f"{frequency}-spectrum.csv").open("w", newline="") as output:
            writer = csv.writer(output)
            writer.writerow(["frequency_hz", "psd_dbfs_per_hz"])
            writer.writerows(zip(frequencies, 10 * np.log10(np.maximum(psd, 1e-30))))
        with (args.output_dir / f"{frequency}-envelope.csv").open("w", newline="") as output:
            writer = csv.writer(output)
            writer.writerow(["capture_seconds", "intended_carrier_amplitude", "expected_on", "interior"])
            writer.writerows(zip(env_times + start, env, code[slots], interior.astype(int)))
        print(f"{frequency:6.0f} Hz: peak {measured:12.3f} Hz, on/off {result['on_over_off_db']:7.2f} dB, code {code_correlation:.3f}, detected={detected}, harmonic_confound={confound}, strong_alias={strong_alias}")
    report = {"capture": str(args.wav.resolve()), "stimulus_manifest": str(args.manifest.resolve()),
              "source_to_capture_offset_seconds": offset, "alignment_code_correlation": alignment,
              "results": results,
              "limits": "Positive results demonstrate stimulus-correlated acoustic output at listed frequencies through this speaker-air-microphone pair. They do not establish flat response or 96 kHz acoustic bandwidth. Weak high-frequency output cannot distinguish speaker rolloff, microphone response, acoustic geometry, or digital filtering. Use separate 12 kHz continuous-tone analysis and ALSA/AoC logs for continuity; code transitions are intentional."}
    (args.output_dir / "bandwidth-analysis.json").write_text(json.dumps(report, indent=2) + "\n")
    print(f"Alignment correlation {alignment:.4f}; source offset {offset:.4f} s")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    create = commands.add_parser("generate")
    create.add_argument("wav", type=Path)
    create.add_argument("--amplitude", type=float, default=0.008)
    create.set_defaults(handler=generate)
    measure = commands.add_parser("analyze")
    measure.add_argument("wav", type=Path)
    measure.add_argument("--manifest", type=Path, required=True)
    measure.add_argument("--output-dir", type=Path, required=True)
    measure.add_argument("--offset", type=float, help="known source frame 0 position in capture, seconds; otherwise match pilot code")
    measure.add_argument("--channel", type=int, default=0)
    measure.set_defaults(handler=analyze)
    args = parser.parse_args()
    args.handler(args)


if __name__ == "__main__":
    main()
