#!/usr/bin/env python3
"""Measure wideband evidence and pilot-tone continuity in a PCM WAV capture.

The tool deliberately does not treat a 192 kHz WAV header as proof of a
192 kHz acoustic path.  It reports spectral power on both sides of the common
24/48 kHz conversion boundaries and, when given a pilot tone, phase-step
outliers that are consistent with dropped/repeated samples or clock glitches.
"""

from __future__ import annotations

import argparse
import csv
import json
import math
import pathlib
import sys
from typing import Any

import numpy as np
from scipy import signal
from scipy.io import wavfile


DEFAULT_BANDS = (
    ("audible_high", 15_000.0, 22_000.0),
    ("above_24k", 26_000.0, 44_000.0),
    ("above_48k", 52_000.0, 70_000.0),
    ("near_96k", 76_000.0, 92_000.0),
)


def finite_float(value: str) -> float:
    result = float(value)
    if not math.isfinite(result):
        raise argparse.ArgumentTypeError("value must be finite")
    return result


def positive_float(value: str) -> float:
    result = finite_float(value)
    if result <= 0:
        raise argparse.ArgumentTypeError("value must be positive")
    return result


def nonnegative_int(value: str) -> int:
    result = int(value)
    if result < 0:
        raise argparse.ArgumentTypeError("value must be non-negative")
    return result


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Report spectral evidence across 24/48 kHz boundaries and optional "
            "pilot-tone phase continuity; a WAV rate alone is never called proof"
        )
    )
    parser.add_argument("wav", type=pathlib.Path)
    parser.add_argument("--expected-rate", type=int, default=192_000)
    parser.add_argument("--skip-start", type=finite_float, default=0.25)
    parser.add_argument("--skip-end", type=finite_float, default=0.25)
    parser.add_argument(
        "--pilot-tone",
        type=positive_float,
        help="known continuous tone in Hz used for phase/jitter analysis",
    )
    parser.add_argument(
        "--pilot-bandwidth",
        type=positive_float,
        default=1_000.0,
        help="total zero-phase band-pass width around --pilot-tone (default 1000)",
    )
    parser.add_argument(
        "--phase-step-threshold",
        type=positive_float,
        default=0.35,
        help="outlier threshold in radians after removing local trend (default 0.35)",
    )
    parser.add_argument(
        "--cutoff-drop-threshold-db",
        type=positive_float,
        default=18.0,
        help="flag a candidate brick-wall boundary above this local PSD drop",
    )
    parser.add_argument(
        "--require-no-cutoff",
        action="store_true",
        help="exit 3 if a measurable 24 or 48 kHz cutoff candidate is flagged",
    )
    parser.add_argument(
        "--max-phase-step-outliers",
        type=nonnegative_int,
        help=(
            "with --pilot-tone, exit 4 if any selected channel exceeds this "
            "phase-step outlier count"
        ),
    )
    parser.add_argument(
        "--min-above-48k-dbfs",
        type=finite_float,
        help=(
            "exit 5 if the integrated 52..70 kHz power of any selected channel "
            "is below this calibrated dBFS floor"
        ),
    )
    parser.add_argument(
        "--channel",
        action="append",
        type=nonnegative_int,
        help="analyze only this zero-based WAV channel; may be repeated",
    )
    parser.add_argument("--json", action="store_true")
    parser.add_argument(
        "--spectrum-csv",
        type=pathlib.Path,
        help="write frequency plus per-channel Welch PSD columns",
    )
    return parser.parse_args()


def normalized_pcm(samples: np.ndarray) -> np.ndarray:
    if np.issubdtype(samples.dtype, np.signedinteger):
        scale = float(1 << (np.iinfo(samples.dtype).bits - 1))
        return samples.astype(np.float64) / scale
    if np.issubdtype(samples.dtype, np.unsignedinteger):
        info = np.iinfo(samples.dtype)
        midpoint = float(info.max + 1) / 2.0
        return (samples.astype(np.float64) - midpoint) / midpoint
    if np.issubdtype(samples.dtype, np.floating):
        return samples.astype(np.float64)
    raise ValueError(f"unsupported WAV sample type: {samples.dtype}")


def db(value: float) -> float:
    return 10.0 * math.log10(max(value, np.finfo(np.float64).tiny))


def band_power(frequencies: np.ndarray, psd: np.ndarray, low: float, high: float) -> float | None:
    selected = (frequencies >= low) & (frequencies < high)
    if np.count_nonzero(selected) < 2:
        return None
    return float(np.trapezoid(psd[selected], frequencies[selected]))


def median_psd_db(
    frequencies: np.ndarray, psd: np.ndarray, low: float, high: float
) -> float | None:
    selected = (frequencies >= low) & (frequencies < high)
    if np.count_nonzero(selected) < 4:
        return None
    floor = np.finfo(np.float64).tiny
    return float(np.median(10.0 * np.log10(np.maximum(psd[selected], floor))))


def cutoff_metric(
    frequencies: np.ndarray,
    psd: np.ndarray,
    boundary: float,
    threshold_db: float,
) -> dict[str, Any]:
    # Leave a 1 kHz guard on each side so a normal transition band does not
    # dominate either local median.  Five-kHz windows remain narrow enough to
    # distinguish a boundary from gradual acoustic roll-off.
    below = median_psd_db(frequencies, psd, boundary - 6_000.0, boundary - 1_000.0)
    above = median_psd_db(frequencies, psd, boundary + 1_000.0, boundary + 6_000.0)
    if below is None or above is None:
        return {
            "boundary_hz": boundary,
            "measurable": False,
            "reason": "capture Nyquist does not span both comparison windows",
        }
    drop = below - above
    return {
        "boundary_hz": boundary,
        "measurable": True,
        "below_db_per_hz": below,
        "above_db_per_hz": above,
        "drop_db": drop,
        "brick_wall_candidate": bool(drop >= threshold_db),
    }


def noise_shape_metric(frequencies: np.ndarray, psd: np.ndarray) -> dict[str, Any]:
    selected = (frequencies >= 55_000.0) & (frequencies <= 90_000.0)
    if np.count_nonzero(selected) < 32:
        return {"measurable": False}
    x = frequencies[selected] / 1_000.0
    y = 10.0 * np.log10(np.maximum(psd[selected], np.finfo(np.float64).tiny))
    # Regress bin medians rather than every FFT point so narrow tones do not
    # masquerade as the broadband rise expected from delta-sigma noise shaping.
    edges = np.linspace(float(x[0]), float(x[-1]), 36)
    centers: list[float] = []
    medians: list[float] = []
    for low, high in zip(edges[:-1], edges[1:], strict=True):
        in_bin = (x >= low) & (x < high)
        if np.any(in_bin):
            centers.append((low + high) / 2.0)
            medians.append(float(np.median(y[in_bin])))
    if len(centers) < 8:
        return {"measurable": False}
    slope, intercept = np.polyfit(np.asarray(centers), np.asarray(medians), 1)
    return {
        "measurable": True,
        "slope_db_per_khz": float(slope),
        "fitted_55khz_db_per_hz": float(intercept + slope * 55.0),
        "fitted_90khz_db_per_hz": float(intercept + slope * 90.0),
        "rising_toward_nyquist": bool(slope > 0.05),
    }


def pilot_metric(
    samples: np.ndarray,
    sample_rate: int,
    frequency: float,
    bandwidth: float,
    threshold: float,
) -> dict[str, Any]:
    nyquist = sample_rate / 2.0
    low = frequency - bandwidth / 2.0
    high = frequency + bandwidth / 2.0
    if low <= 0 or high >= nyquist:
        raise ValueError(
            f"pilot pass band {low:g}..{high:g} Hz is outside 0..{nyquist:g} Hz"
        )
    if samples.size < sample_rate // 4:
        return {"measurable": False, "reason": "less than 250 ms of samples"}
    sos = signal.butter(6, [low, high], btype="bandpass", fs=sample_rate, output="sos")
    filtered = signal.sosfiltfilt(sos, samples)
    analytic = signal.hilbert(filtered)
    phase = np.unwrap(np.angle(analytic))

    # Ignore filter transients, then remove a least-squares frequency/phase
    # model.  A sample insertion/deletion produces a discrete residual-phase
    # step; oscillator mismatch produces a fitted linear slope instead.
    margin = min(max(sample_rate // 20, 256), phase.size // 5)
    core = phase[margin:-margin]
    index = np.arange(core.size, dtype=np.float64)
    slope, intercept = np.polyfit(index, core, 1)
    residual = core - (slope * index + intercept)
    steps = np.diff(residual)
    local = signal.medfilt(steps, kernel_size=9)
    detrended_steps = steps - local
    abs_steps = np.abs(detrended_steps)
    median = float(np.median(abs_steps))
    mad = float(np.median(np.abs(abs_steps - median)))
    robust_sigma = 1.4826 * mad
    outliers = abs_steps >= threshold
    fitted_hz = float(slope * sample_rate / (2.0 * math.pi))
    rms_residual = float(np.sqrt(np.mean(np.square(residual))))
    return {
        "measurable": True,
        "expected_hz": frequency,
        "fitted_hz": fitted_hz,
        "frequency_error_hz": fitted_hz - frequency,
        "phase_residual_rms_rad": rms_residual,
        "phase_step_median_abs_rad": median,
        "phase_step_robust_sigma_rad": robust_sigma,
        "phase_step_peak_abs_rad": float(np.max(abs_steps)),
        "phase_step_threshold_rad": threshold,
        "phase_step_outliers": int(np.count_nonzero(outliers)),
        "analyzed_phase_steps": int(abs_steps.size),
    }


def analyze_channel(
    samples: np.ndarray, sample_rate: int, args: argparse.Namespace
) -> tuple[dict[str, Any], np.ndarray, np.ndarray]:
    centered = samples - float(np.mean(samples))
    peak = float(np.max(np.abs(centered)))
    rms = float(np.sqrt(np.mean(np.square(centered))))
    clipped = int(np.count_nonzero(np.abs(samples) >= 0.999))
    nperseg = min(65_536, 1 << int(math.floor(math.log2(centered.size))))
    if nperseg < 2_048:
        raise ValueError("capture is too short for wideband analysis")
    frequencies, psd = signal.welch(
        centered,
        fs=sample_rate,
        window="hann",
        nperseg=nperseg,
        noverlap=nperseg // 2,
        detrend=False,
        scaling="density",
    )
    bands: dict[str, Any] = {}
    for name, low, high in DEFAULT_BANDS:
        power = band_power(frequencies, psd, low, high)
        bands[name] = {
            "low_hz": low,
            "high_hz": high,
            "measurable": power is not None,
            "power_dbfs": None if power is None else db(power),
        }
    cutoffs = [
        cutoff_metric(frequencies, psd, boundary, args.cutoff_drop_threshold_db)
        for boundary in (24_000.0, 48_000.0)
    ]
    result: dict[str, Any] = {
        "peak_dbfs": 20.0 * math.log10(max(peak, np.finfo(np.float64).tiny)),
        "rms_dbfs": 20.0 * math.log10(max(rms, np.finfo(np.float64).tiny)),
        "clipped_samples": clipped,
        "bands": bands,
        "cutoffs": cutoffs,
        "high_frequency_noise_shape": noise_shape_metric(frequencies, psd),
    }
    if args.pilot_tone is not None:
        result["pilot"] = pilot_metric(
            centered,
            sample_rate,
            args.pilot_tone,
            args.pilot_bandwidth,
            args.phase_step_threshold,
        )
    return result, frequencies, psd


def human_report(report: dict[str, Any]) -> None:
    selected = report["selected_channels"]
    print(
        f"{report['path']}: {report['sample_rate_hz']} Hz, "
        f"{report['channels']} WAV channel(s), selected={selected}, "
        f"{report['analyzed_seconds']:.3f} s analyzed"
    )
    for channel in report["channel_results"]:
        print(
            f"channel {channel['channel']}: peak {channel['peak_dbfs']:.2f} dBFS, "
            f"RMS {channel['rms_dbfs']:.2f} dBFS, clipped={channel['clipped_samples']}"
        )
        for name, band in channel["bands"].items():
            if band["measurable"]:
                print(
                    f"  {name:12s} {band['low_hz']/1000:g}..{band['high_hz']/1000:g} kHz: "
                    f"{band['power_dbfs']:.2f} dBFS"
                )
            else:
                print(f"  {name:12s}: outside capture Nyquist")
        for cutoff in channel["cutoffs"]:
            if cutoff["measurable"]:
                label = "BRICK-WALL CANDIDATE" if cutoff["brick_wall_candidate"] else "no sharp local drop"
                print(
                    f"  {cutoff['boundary_hz']/1000:g} kHz boundary: "
                    f"drop {cutoff['drop_db']:.2f} dB ({label})"
                )
        shape = channel["high_frequency_noise_shape"]
        if shape["measurable"]:
            print(
                f"  55..90 kHz median PSD slope: {shape['slope_db_per_khz']:.3f} "
                f"dB/kHz (rising={str(shape['rising_toward_nyquist']).lower()})"
            )
        pilot = channel.get("pilot")
        if pilot and pilot["measurable"]:
            print(
                f"  pilot fitted {pilot['fitted_hz']:.4f} Hz; phase-step outliers "
                f"{pilot['phase_step_outliers']}/{pilot['analyzed_phase_steps']}, "
                f"peak {pilot['phase_step_peak_abs_rad']:.4f} rad"
            )
    print(
        "interpretation: energy above 48 kHz and no sharp 24/48 kHz boundary are "
        "necessary evidence, not sufficient proof; confirm with a calibrated wideband stimulus"
    )


def main() -> int:
    args = parse_args()
    if args.max_phase_step_outliers is not None and args.pilot_tone is None:
        raise ValueError("--max-phase-step-outliers requires --pilot-tone")
    sample_rate, raw = wavfile.read(args.wav, mmap=True)
    if args.expected_rate and sample_rate != args.expected_rate:
        raise ValueError(
            f"WAV rate is {sample_rate}, expected {args.expected_rate}; refusing mislabeled run"
        )
    pcm = normalized_pcm(np.asarray(raw))
    if pcm.ndim == 1:
        pcm = pcm[:, np.newaxis]
    elif pcm.ndim != 2:
        raise ValueError(f"expected mono/multichannel PCM, got shape {pcm.shape}")
    start = int(round(args.skip_start * sample_rate))
    end_trim = int(round(args.skip_end * sample_rate))
    stop = pcm.shape[0] - end_trim
    if start < 0 or end_trim < 0 or stop - start < 2_048:
        raise ValueError("skip interval leaves too few samples")
    pcm = pcm[start:stop]

    if args.channel is None:
        selected_channels = list(range(pcm.shape[1]))
    else:
        selected_channels = list(dict.fromkeys(args.channel))
        invalid_channels = [
            channel for channel in selected_channels if channel >= pcm.shape[1]
        ]
        if invalid_channels:
            raise ValueError(
                f"selected channel(s) outside 0..{pcm.shape[1] - 1}: "
                + ", ".join(map(str, invalid_channels))
            )

    channel_results: list[dict[str, Any]] = []
    spectra: list[np.ndarray] = []
    frequencies: np.ndarray | None = None
    for channel_index in selected_channels:
        result, channel_frequencies, psd = analyze_channel(
            pcm[:, channel_index], sample_rate, args
        )
        result["channel"] = channel_index
        channel_results.append(result)
        spectra.append(psd)
        if frequencies is None:
            frequencies = channel_frequencies

    report = {
        "path": str(args.wav),
        "sample_rate_hz": int(sample_rate),
        "channels": int(pcm.shape[1]),
        "selected_channels": selected_channels,
        "analyzed_frames": int(pcm.shape[0]),
        "analyzed_seconds": float(pcm.shape[0] / sample_rate),
        "cutoff_drop_threshold_db": args.cutoff_drop_threshold_db,
        "maximum_phase_step_outliers": args.max_phase_step_outliers,
        "minimum_above_48k_dbfs": args.min_above_48k_dbfs,
        "channel_results": channel_results,
    }
    if args.spectrum_csv is not None:
        assert frequencies is not None
        args.spectrum_csv.parent.mkdir(parents=True, exist_ok=True)
        with args.spectrum_csv.open("w", newline="", encoding="utf-8") as output:
            writer = csv.writer(output)
            writer.writerow(
                ["frequency_hz"]
                + [f"channel_{index}_db_per_hz" for index in selected_channels]
            )
            for row_index, frequency in enumerate(frequencies):
                writer.writerow(
                    [float(frequency)]
                    + [db(float(channel[row_index])) for channel in spectra]
                )
    if args.json:
        print(json.dumps(report, indent=2, sort_keys=True))
    else:
        human_report(report)

    flagged = any(
        cutoff.get("brick_wall_candidate", False)
        for channel in channel_results
        for cutoff in channel["cutoffs"]
    )
    if args.require_no_cutoff and flagged:
        return 3
    excessive_phase_steps = False
    if args.max_phase_step_outliers is not None:
        excessive_phase_steps = any(
            channel.get("pilot", {}).get("phase_step_outliers", 0)
            > args.max_phase_step_outliers
            for channel in channel_results
        )
    if excessive_phase_steps:
        return 4
    insufficient_wideband_energy = False
    if args.min_above_48k_dbfs is not None:
        insufficient_wideband_energy = any(
            channel["bands"]["above_48k"]["power_dbfs"] is None
            or channel["bands"]["above_48k"]["power_dbfs"]
            < args.min_above_48k_dbfs
            for channel in channel_results
        )
    if insufficient_wideband_energy:
        return 5
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError) as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(2)
