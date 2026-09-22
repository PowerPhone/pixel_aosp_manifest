#!/usr/bin/env python3
"""Analyze a real 18--85 kHz, 192 kHz phone self-loop chirp capture.

The WAV header and sample count are never treated as bandwidth proof.  This
tool first finds the known chirp from its lower-frequency STFT ridge, then
measures ridge power against simultaneous local sidebands.  If that alignment
is weak or ambiguous, upper-band, cutoff, dropout, and jitter conclusions are
withheld.
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
    (18_000.0, 24_000.0),
    (24_000.0, 36_000.0),
    (36_000.0, 48_000.0),
    (48_000.0, 60_000.0),
    (60_000.0, 72_000.0),
    (72_000.0, 85_000.0),
)


def finite_float(text: str) -> float:
    value = float(text)
    if not math.isfinite(value):
        raise argparse.ArgumentTypeError("value must be finite")
    return value


def positive_float(text: str) -> float:
    value = finite_float(text)
    if value <= 0:
        raise argparse.ArgumentTypeError("value must be positive")
    return value


def positive_int(text: str) -> int:
    value = int(text)
    if value <= 0:
        raise argparse.ArgumentTypeError("value must be positive")
    return value


def nonnegative_int(text: str) -> int:
    value = int(text)
    if value < 0:
        raise argparse.ArgumentTypeError("value must be non-negative")
    return value


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("stimulus", type=pathlib.Path)
    parser.add_argument("capture", type=pathlib.Path)
    parser.add_argument("--expected-rate", type=positive_int, default=192_000)
    parser.add_argument("--expected-start", type=positive_float, default=18_000.0)
    parser.add_argument("--expected-end", type=positive_float, default=85_000.0)
    parser.add_argument(
        "--stimulus-frequency-tolerance",
        type=positive_float,
        default=1_000.0,
        help="maximum fitted endpoint error in Hz (default 1000)",
    )
    parser.add_argument("--stimulus-channel", type=nonnegative_int, default=0)
    parser.add_argument(
        "--channel",
        action="append",
        type=nonnegative_int,
        help="capture channel to analyze; may be repeated (default: all)",
    )
    parser.add_argument("--alignment-low", type=positive_float, default=18_000.0)
    parser.add_argument("--alignment-high", type=positive_float, default=23_500.0)
    parser.add_argument("--window-frames", type=positive_int, default=4096)
    parser.add_argument("--hop-frames", type=positive_int, default=1024)
    parser.add_argument("--fft-frames", type=positive_int, default=8192)
    parser.add_argument("--ridge-half-width", type=positive_float, default=350.0)
    parser.add_argument("--ridge-search-width", type=positive_float, default=1_200.0)
    parser.add_argument("--local-noise-inner", type=positive_float, default=1_000.0)
    parser.add_argument("--local-noise-outer", type=positive_float, default=3_000.0)
    parser.add_argument("--min-ridge-snr-db", type=finite_float, default=6.0)
    parser.add_argument(
        "--min-detection-fraction", type=finite_float, default=0.60
    )
    parser.add_argument(
        "--min-alignment-margin-db", type=finite_float, default=1.5
    )
    parser.add_argument(
        "--cutoff-drop-threshold-db", type=positive_float, default=15.0
    )
    parser.add_argument(
        "--jitter-step-threshold-ms", type=positive_float, default=3.0
    )
    parser.add_argument(
        "--require-wideband",
        action="store_true",
        help=(
            "exit 4 unless every selected channel has supported 72--85 kHz "
            "ridge evidence and no candidate sharp cutoff"
        ),
    )
    parser.add_argument("--json", action="store_true", help="write JSON to stdout")
    parser.add_argument("--json-output", type=pathlib.Path)
    parser.add_argument(
        "--ridge-csv",
        type=pathlib.Path,
        help="write per-STFT-frame ridge measurements for review",
    )
    return parser.parse_args()


def normalized_pcm(samples: np.ndarray) -> np.ndarray:
    if np.issubdtype(samples.dtype, np.signedinteger):
        return samples.astype(np.float64) / float(
            1 << (np.iinfo(samples.dtype).bits - 1)
        )
    if np.issubdtype(samples.dtype, np.unsignedinteger):
        midpoint = float(np.iinfo(samples.dtype).max + 1) / 2.0
        return (samples.astype(np.float64) - midpoint) / midpoint
    if np.issubdtype(samples.dtype, np.floating):
        return samples.astype(np.float64)
    raise ValueError(f"unsupported WAV sample type: {samples.dtype}")


def load_wav(path: pathlib.Path, expected_rate: int) -> tuple[int, np.ndarray, str]:
    if path.is_symlink() or not path.is_file():
        raise ValueError(f"WAV is missing or unsafe: {path}")
    rate, raw = wavfile.read(path, mmap=True)
    if rate != expected_rate:
        raise ValueError(f"{path}: rate is {rate}, expected {expected_rate}")
    dtype = str(raw.dtype)
    pcm = normalized_pcm(np.asarray(raw))
    if pcm.ndim == 1:
        pcm = pcm[:, np.newaxis]
    if pcm.ndim != 2 or pcm.shape[0] < 8192 or pcm.shape[1] < 1:
        raise ValueError(f"{path}: unsupported or too-short PCM shape {pcm.shape}")
    if not np.all(np.isfinite(pcm)):
        raise ValueError(f"{path}: PCM contains non-finite samples")
    return int(rate), pcm, dtype


def stft_power(
    samples: np.ndarray,
    rate: int,
    window_frames: int,
    hop_frames: int,
    fft_frames: int,
) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    centered = samples - float(np.mean(samples))
    frequencies, times, values = signal.stft(
        centered,
        fs=rate,
        window="hann",
        nperseg=window_frames,
        noverlap=window_frames - hop_frames,
        nfft=fft_frames,
        detrend=False,
        boundary=None,
        padded=False,
    )
    return frequencies, times, np.square(np.abs(values))


def range_indices(
    frequencies: np.ndarray, low: float, high: float
) -> tuple[int, int]:
    begin = max(0, int(np.searchsorted(frequencies, low, side="left")))
    end = min(
        frequencies.size, int(np.searchsorted(frequencies, high, side="right"))
    )
    return begin, end


def ridge_and_noise_series(
    power: np.ndarray,
    frequencies: np.ndarray,
    center: float,
    args: argparse.Namespace,
) -> tuple[np.ndarray, np.ndarray]:
    ridge_begin, ridge_end = range_indices(
        frequencies,
        center - args.ridge_half_width,
        center + args.ridge_half_width,
    )
    left_begin, left_end = range_indices(
        frequencies,
        center - args.local_noise_outer,
        center - args.local_noise_inner,
    )
    right_begin, right_end = range_indices(
        frequencies,
        center + args.local_noise_inner,
        center + args.local_noise_outer,
    )
    ridge_bins = ridge_end - ridge_begin
    noise_bins = (left_end - left_begin) + (right_end - right_begin)
    if ridge_bins < 1 or noise_bins < 4:
        raise ValueError(f"insufficient FFT bins around {center:g} Hz")
    ridge = np.sum(power[ridge_begin:ridge_end], axis=0)
    side = np.sum(power[left_begin:left_end], axis=0)
    side += np.sum(power[right_begin:right_end], axis=0)
    local_noise = side * (ridge_bins / noise_bins)
    return ridge, local_noise


def power_db(value: np.ndarray | float) -> np.ndarray | float:
    floor = np.finfo(np.float64).tiny
    return 10.0 * np.log10(np.maximum(value, floor))


def characterize_stimulus(
    stimulus: np.ndarray, rate: int, args: argparse.Namespace
) -> dict[str, Any]:
    frequencies, times, power = stft_power(
        stimulus,
        rate,
        args.window_frames,
        args.hop_frames,
        args.fft_frames,
    )
    search = (frequencies >= args.expected_start - 2_000.0) & (
        frequencies <= args.expected_end + 2_000.0
    )
    if np.count_nonzero(search) < 64:
        raise ValueError("FFT does not resolve the requested stimulus band")
    search_indices = np.flatnonzero(search)
    ridge_indices = search_indices[np.argmax(power[search], axis=0)]
    ridge_hz = frequencies[ridge_indices]
    coefficients = np.polyfit(times, ridge_hz, 1)
    fitted = np.polyval(coefficients, times)
    denominator = float(np.sum(np.square(ridge_hz - np.mean(ridge_hz))))
    r_squared = 1.0 - float(np.sum(np.square(ridge_hz - fitted))) / max(
        denominator, np.finfo(np.float64).tiny
    )
    duration = stimulus.size / rate
    fitted_start = float(coefficients[1])
    fitted_end = float(coefficients[1] + coefficients[0] * duration)
    if coefficients[0] <= 0 or r_squared < 0.995:
        raise ValueError(
            "stimulus is not a clean rising linear chirp: "
            f"slope={coefficients[0]:.3f}, "
            f"R^2={r_squared:.6f}"
        )
    if abs(fitted_start - args.expected_start) > args.stimulus_frequency_tolerance:
        raise ValueError(
            f"fitted chirp start {fitted_start:.1f} Hz is not "
            f"{args.expected_start:.1f} Hz"
        )
    if abs(fitted_end - args.expected_end) > args.stimulus_frequency_tolerance:
        raise ValueError(
            f"fitted chirp end {fitted_end:.1f} Hz is not "
            f"{args.expected_end:.1f} Hz"
        )
    return {
        "frequencies": frequencies,
        "times": times,
        "power": power,
        "ridge_hz": ridge_hz,
        "ridge_indices": ridge_indices,
        "slope_hz_per_s": float(coefficients[0]),
        "intercept_hz": fitted_start,
        "fitted_end_hz": fitted_end,
        "r_squared": r_squared,
        "duration_seconds": duration,
    }


def channel_alignment(
    capture: np.ndarray,
    rate: int,
    stimulus: dict[str, Any],
    channel: int,
    args: argparse.Namespace,
) -> dict[str, Any]:
    frequencies, times, power = stft_power(
        capture,
        rate,
        args.window_frames,
        args.hop_frames,
        args.fft_frames,
    )
    ridge_hz = stimulus["ridge_hz"]
    lower = np.flatnonzero(
        (ridge_hz >= args.alignment_low) & (ridge_hz < args.alignment_high)
    )
    if lower.size < 24:
        raise ValueError("lower alignment band contains fewer than 24 STFT frames")
    tracks = np.empty((lower.size, times.size), dtype=np.float64)
    for row, stimulus_index in enumerate(lower):
        ridge, noise = ridge_and_noise_series(
            power, frequencies, float(ridge_hz[stimulus_index]), args
        )
        tracks[row] = power_db(ridge) - power_db(noise)

    candidates: list[dict[str, Any]] = []
    minimum_frames = max(24, int(math.ceil(lower.size * 0.70)))
    for shift in range(-int(lower[-1]), int(times.size - lower[0])):
        capture_indices = lower + shift
        valid = (capture_indices >= 0) & (capture_indices < times.size)
        if np.count_nonzero(valid) < minimum_frames:
            continue
        rows = np.flatnonzero(valid)
        values = tracks[rows, capture_indices[valid]]
        candidates.append(
            {
                "shift": shift,
                "median_snr_db": float(np.median(values)),
                "p10_snr_db": float(np.percentile(values, 10.0)),
                "detection_fraction": float(
                    np.mean(values >= args.min_ridge_snr_db)
                ),
                "frames": int(values.size),
            }
        )
    if not candidates:
        raise ValueError("capture has no usable lower-band alignment interval")
    best = max(candidates, key=lambda item: item["median_snr_db"])
    exclusion = max(1, int(math.ceil(0.15 * rate / args.hop_frames)))
    alternatives = [
        item
        for item in candidates
        if abs(item["shift"] - best["shift"]) > exclusion
    ]
    second_score = max(
        (item["median_snr_db"] for item in alternatives), default=float("-inf")
    )
    margin = (
        None
        if not math.isfinite(second_score)
        else float(best["median_snr_db"] - second_score)
    )
    conclusive = bool(
        best["median_snr_db"] >= args.min_ridge_snr_db
        and best["detection_fraction"] >= args.min_detection_fraction
        and margin is not None
        and margin >= args.min_alignment_margin_db
    )
    return {
        "channel": channel,
        "shift_stft_frames": int(best["shift"]),
        "offset_seconds": float(best["shift"] * args.hop_frames / rate),
        "median_lower_ridge_snr_db": best["median_snr_db"],
        "p10_lower_ridge_snr_db": best["p10_snr_db"],
        "lower_ridge_detection_fraction": best["detection_fraction"],
        "alignment_frames": best["frames"],
        "next_distinct_candidate_snr_db": (
            None if not math.isfinite(second_score) else float(second_score)
        ),
        "alignment_margin_db": margin,
        "conclusive": conclusive,
    }


def local_peak_frequency(
    column: np.ndarray,
    frequencies: np.ndarray,
    expected: float,
    search_width: float,
) -> float:
    begin, end = range_indices(
        frequencies, expected - search_width, expected + search_width
    )
    if end - begin < 3:
        return expected
    relative = int(np.argmax(column[begin:end]))
    index = begin + relative
    if index <= 0 or index >= column.size - 1:
        return float(frequencies[index])
    y = np.log(np.maximum(column[index - 1 : index + 2], np.finfo(float).tiny))
    denominator = y[0] - 2.0 * y[1] + y[2]
    delta = 0.0 if abs(denominator) < 1e-20 else 0.5 * (y[0] - y[2]) / denominator
    delta = float(np.clip(delta, -0.5, 0.5))
    return float(frequencies[index] + delta * (frequencies[1] - frequencies[0]))


def track_channel(
    capture: np.ndarray,
    rate: int,
    stimulus: dict[str, Any],
    shift: int,
    args: argparse.Namespace,
) -> dict[str, np.ndarray]:
    frequencies, capture_times, capture_power = stft_power(
        capture,
        rate,
        args.window_frames,
        args.hop_frames,
        args.fft_frames,
    )
    stimulus_times = stimulus["times"]
    expected_hz = stimulus["ridge_hz"]
    stimulus_power = stimulus["power"]
    stimulus_frequencies = stimulus["frequencies"]
    stimulus_indices = np.arange(stimulus_times.size, dtype=np.int64)
    capture_indices = stimulus_indices + shift
    valid = (
        (capture_indices >= 0)
        & (capture_indices < capture_times.size)
        & (expected_hz >= args.expected_start)
        & (expected_hz <= args.expected_end)
    )
    stimulus_indices = stimulus_indices[valid]
    capture_indices = capture_indices[valid]
    count = stimulus_indices.size
    if count < 32:
        raise ValueError("aligned chirp leaves fewer than 32 analysis frames")

    ridge_power = np.empty(count)
    noise_power = np.empty(count)
    stimulus_ridge_power = np.empty(count)
    observed_hz = np.empty(count)
    for output_index, (stimulus_index, capture_index) in enumerate(
        zip(stimulus_indices, capture_indices, strict=True)
    ):
        center = float(expected_hz[stimulus_index])
        ridge, noise = ridge_and_noise_series(
            capture_power[:, capture_index : capture_index + 1],
            frequencies,
            center,
            args,
        )
        source_ridge, _source_noise = ridge_and_noise_series(
            stimulus_power[:, stimulus_index : stimulus_index + 1],
            stimulus_frequencies,
            center,
            args,
        )
        ridge_power[output_index] = ridge[0]
        noise_power[output_index] = noise[0]
        stimulus_ridge_power[output_index] = source_ridge[0]
        observed_hz[output_index] = local_peak_frequency(
            capture_power[:, capture_index],
            frequencies,
            center,
            args.ridge_search_width,
        )
    snr_db = power_db(ridge_power) - power_db(noise_power)
    relative_gain_db = power_db(ridge_power) - power_db(stimulus_ridge_power)
    timing_error_s = (
        observed_hz - expected_hz[stimulus_indices]
    ) / stimulus["slope_hz_per_s"]
    return {
        "stimulus_index": stimulus_indices,
        "capture_index": capture_indices,
        "stimulus_time_s": stimulus_times[stimulus_indices],
        "capture_time_s": capture_times[capture_indices],
        "expected_hz": expected_hz[stimulus_indices],
        "observed_hz": observed_hz,
        "ridge_snr_db": snr_db,
        "relative_gain_db": relative_gain_db,
        "timing_error_s": timing_error_s,
        "detected": snr_db >= args.min_ridge_snr_db,
    }


def summarize_band(
    track: dict[str, np.ndarray], low: float, high: float, args: argparse.Namespace
) -> dict[str, Any]:
    selected = (track["expected_hz"] >= low) & (track["expected_hz"] < high)
    count = int(np.count_nonzero(selected))
    if count < 8:
        return {
            "low_hz": low,
            "high_hz": high,
            "frames": count,
            "assessment": "inconclusive",
            "reason": "fewer than eight aligned ridge frames",
        }
    covered_hz = track["expected_hz"][selected]
    ridge_step_hz = float(np.median(np.diff(track["expected_hz"])))
    coverage_slack_hz = max(500.0, 3.0 * abs(ridge_step_hz))
    coverage_low_hz = float(np.min(covered_hz))
    coverage_high_hz = float(np.max(covered_hz))
    if (
        coverage_low_hz > low + coverage_slack_hz
        or coverage_high_hz < high - coverage_slack_hz
    ):
        return {
            "low_hz": low,
            "high_hz": high,
            "frames": count,
            "coverage_low_hz": coverage_low_hz,
            "coverage_high_hz": coverage_high_hz,
            "assessment": "inconclusive",
            "reason": "aligned chirp does not cover the full requested band",
        }
    snr = track["ridge_snr_db"][selected]
    gain = track["relative_gain_db"][selected]
    detected = snr >= args.min_ridge_snr_db
    fraction = float(np.mean(detected))
    median_snr = float(np.median(snr))
    if median_snr >= args.min_ridge_snr_db and fraction >= args.min_detection_fraction:
        assessment = "supported"
    elif fraction < 0.20 and median_snr < 3.0:
        assessment = "not_detected"
    else:
        assessment = "partial_or_inconclusive"
    return {
        "low_hz": low,
        "high_hz": high,
        "frames": count,
        "coverage_low_hz": coverage_low_hz,
        "coverage_high_hz": coverage_high_hz,
        "median_ridge_vs_local_snr_db": median_snr,
        "p10_ridge_vs_local_snr_db": float(np.percentile(snr, 10.0)),
        "p90_ridge_vs_local_snr_db": float(np.percentile(snr, 90.0)),
        "detection_fraction": fraction,
        "median_relative_gain_db": float(np.median(gain)),
        "assessment": assessment,
    }


def cutoff_evidence(
    track: dict[str, np.ndarray], boundary: float, args: argparse.Namespace
) -> dict[str, Any]:
    guard = 750.0
    width = 4_000.0
    below = (track["expected_hz"] >= boundary - width) & (
        track["expected_hz"] < boundary - guard
    )
    above = (track["expected_hz"] >= boundary + guard) & (
        track["expected_hz"] < boundary + width
    )
    if np.count_nonzero(below) < 8 or np.count_nonzero(above) < 8:
        return {
            "boundary_hz": boundary,
            "assessment": "inconclusive",
            "reason": "comparison windows are not both covered",
        }
    below_snr = track["ridge_snr_db"][below]
    above_snr = track["ridge_snr_db"][above]
    below_gain = track["relative_gain_db"][below]
    above_gain = track["relative_gain_db"][above]
    below_fraction = float(np.mean(below_snr >= args.min_ridge_snr_db))
    above_fraction = float(np.mean(above_snr >= args.min_ridge_snr_db))
    below_median_snr = float(np.median(below_snr))
    above_median_snr = float(np.median(above_snr))
    drop = float(np.median(below_gain) - np.median(above_gain))
    below_strong = bool(
        below_median_snr >= args.min_ridge_snr_db
        and below_fraction >= args.min_detection_fraction
    )
    above_strong = bool(
        above_median_snr >= args.min_ridge_snr_db
        and above_fraction >= args.min_detection_fraction
    )
    if not below_strong:
        assessment = "inconclusive"
        reason = "ridge below the boundary is too weak for a cutoff comparison"
    elif drop >= args.cutoff_drop_threshold_db:
        assessment = "sharp_cutoff_candidate"
        reason = "local transfer drop exceeds threshold"
    elif above_strong:
        assessment = "no_sharp_cutoff_evidence"
        reason = "ridge is supported on both sides without a threshold-sized drop"
    else:
        assessment = "inconclusive"
        reason = "above-boundary ridge is weak but the measured drop is not decisive"
    return {
        "boundary_hz": boundary,
        "below_median_snr_db": below_median_snr,
        "above_median_snr_db": above_median_snr,
        "below_detection_fraction": below_fraction,
        "above_detection_fraction": above_fraction,
        "relative_gain_drop_db": drop,
        "threshold_db": args.cutoff_drop_threshold_db,
        "assessment": assessment,
        "reason": reason,
    }


def robust_timing(
    track: dict[str, np.ndarray], args: argparse.Namespace
) -> dict[str, Any]:
    selected = track["detected"]
    if np.count_nonzero(selected) < 30:
        return {
            "assessment": "inconclusive",
            "reason": "fewer than 30 detected ridge frames",
            "detected_frames": int(np.count_nonzero(selected)),
        }
    x = track["stimulus_time_s"][selected]
    y = track["timing_error_s"][selected]
    retained = np.ones(x.size, dtype=bool)
    coefficients = np.polyfit(x, y, 1)
    for _iteration in range(4):
        residual = y - np.polyval(coefficients, x)
        center = float(np.median(residual[retained]))
        mad = float(np.median(np.abs(residual[retained] - center)))
        limit = max(0.002, 4.0 * 1.4826 * mad)
        updated = np.abs(residual - center) <= limit
        if np.count_nonzero(updated) < 20 or np.array_equal(updated, retained):
            break
        retained = updated
        coefficients = np.polyfit(x[retained], y[retained], 1)
    residual = y - np.polyval(coefficients, x)
    retained_residual = residual[retained]
    retained_indices = track["stimulus_index"][selected][retained]
    consecutive = np.diff(retained_indices) == 1
    steps = np.diff(retained_residual)[consecutive]
    threshold_s = args.jitter_step_threshold_ms / 1_000.0
    outliers = np.abs(steps) >= threshold_s
    assessment = (
        "discontinuity_candidates"
        if np.any(outliers)
        else "no_large_ridge_timing_steps_detected"
    )
    return {
        "assessment": assessment,
        "detected_frames": int(x.size),
        "fit_retained_frames": int(np.count_nonzero(retained)),
        "ridge_time_drift_ppm": float(coefficients[0] * 1_000_000.0),
        "timing_residual_median_abs_ms": float(
            np.median(np.abs(retained_residual)) * 1_000.0
        ),
        "timing_residual_p95_abs_ms": float(
            np.percentile(np.abs(retained_residual), 95.0) * 1_000.0
        ),
        "consecutive_ridge_steps": int(steps.size),
        "step_threshold_ms": args.jitter_step_threshold_ms,
        "step_outliers": int(np.count_nonzero(outliers)),
        "step_p99_abs_ms": (
            None
            if steps.size == 0
            else float(np.percentile(np.abs(steps), 99.0) * 1_000.0)
        ),
        "caution": (
            "ridge timing includes acoustic group delay and STFT uncertainty; "
            "it is a discontinuity indicator, not a direct clock-jitter measurement"
        ),
    }


def ridge_gaps(
    track: dict[str, np.ndarray], bands: list[dict[str, Any]], args: argparse.Namespace
) -> dict[str, Any]:
    supported = [
        (band["low_hz"], band["high_hz"])
        for band in bands
        if band.get("assessment") == "supported"
    ]
    eligible = np.zeros(track["expected_hz"].size, dtype=bool)
    for low, high in supported:
        eligible |= (track["expected_hz"] >= low) & (track["expected_hz"] < high)
    indices = np.flatnonzero(eligible)
    if indices.size < 30:
        return {
            "assessment": "inconclusive",
            "reason": "fewer than 30 frames lie in supported bands",
        }
    detected = track["detected"]
    candidates: list[dict[str, Any]] = []
    cursor = 1
    while cursor < indices.size - 1:
        if detected[indices[cursor]]:
            cursor += 1
            continue
        begin = cursor
        while cursor < indices.size and not detected[indices[cursor]]:
            cursor += 1
        end = cursor
        neighborhood = indices[begin - 1 : min(end + 1, indices.size)]
        contiguous = np.all(np.diff(neighborhood) == 1)
        bracketed = begin > 0 and end < indices.size
        bracketed_by_detections = bool(
            bracketed
            and detected[indices[begin - 1]]
            and detected[indices[end]]
        )
        if contiguous and bracketed_by_detections:
            first = indices[begin]
            last = indices[end - 1]
            candidates.append(
                {
                    "start_stimulus_s": float(track["stimulus_time_s"][first]),
                    "end_stimulus_s": float(track["stimulus_time_s"][last]),
                    "start_hz": float(track["expected_hz"][first]),
                    "end_hz": float(track["expected_hz"][last]),
                    "frames": int(end - begin),
                    "span_ms": float(
                        (end - begin)
                        * args.hop_frames
                        / args.expected_rate
                        * 1_000.0
                    ),
                }
            )
    return {
        "assessment": (
            "ridge_gap_candidates" if candidates else "no_bracketed_ridge_gaps"
        ),
        "eligible_frames": int(indices.size),
        "low_snr_fraction_in_supported_bands": float(np.mean(~detected[indices])),
        "candidate_count": len(candidates),
        "candidates": candidates,
        "caution": (
            "one sweep cannot distinguish a temporal dropout from a narrow "
            "acoustic notch"
        ),
    }


def analyze_channel_track(
    channel: int, track: dict[str, np.ndarray], args: argparse.Namespace
) -> dict[str, Any]:
    bands = [summarize_band(track, low, high, args) for low, high in DEFAULT_BANDS]
    cutoffs = [
        cutoff_evidence(track, boundary, args)
        for boundary in (24_000.0, 48_000.0)
    ]
    upper_supported = bands[-1].get("assessment") == "supported"
    cutoff_flagged = any(
        item.get("assessment") == "sharp_cutoff_candidate" for item in cutoffs
    )
    if upper_supported and not cutoff_flagged:
        assessment = "ridge_evidence_through_85khz_band"
    elif cutoff_flagged:
        assessment = "sharp_cutoff_candidate"
    else:
        assessment = "limited_or_inconclusive_bandwidth"
    return {
        "channel": channel,
        "assessment": assessment,
        "bands": bands,
        "cutoffs": cutoffs,
        "timing": robust_timing(track, args),
        "dropout_indicator": ridge_gaps(track, bands, args),
        "clipped_samples": None,
    }


def serializable_stimulus(stimulus: dict[str, Any]) -> dict[str, Any]:
    return {
        "duration_seconds": stimulus["duration_seconds"],
        "fitted_start_hz": stimulus["intercept_hz"],
        "fitted_end_hz": stimulus["fitted_end_hz"],
        "slope_hz_per_s": stimulus["slope_hz_per_s"],
        "linear_fit_r_squared": stimulus["r_squared"],
        "stft_frames": int(stimulus["times"].size),
    }


def write_ridge_csv(
    path: pathlib.Path, tracks: list[tuple[int, dict[str, np.ndarray]]]
) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", newline="", encoding="utf-8") as output:
        writer = csv.writer(output)
        writer.writerow(
            (
                "channel",
                "stimulus_time_s",
                "capture_time_s",
                "expected_hz",
                "observed_hz",
                "ridge_vs_local_snr_db",
                "relative_gain_db",
                "timing_error_ms",
                "detected",
            )
        )
        for channel, track in tracks:
            for index in range(track["expected_hz"].size):
                writer.writerow(
                    (
                        channel,
                        float(track["stimulus_time_s"][index]),
                        float(track["capture_time_s"][index]),
                        float(track["expected_hz"][index]),
                        float(track["observed_hz"][index]),
                        float(track["ridge_snr_db"][index]),
                        float(track["relative_gain_db"][index]),
                        float(track["timing_error_s"][index] * 1_000.0),
                        int(track["detected"][index]),
                    )
                )


def human_report(report: dict[str, Any]) -> None:
    stimulus = report["stimulus_characterization"]
    print(
        f"stimulus: {stimulus['fitted_start_hz']/1000:.2f}--"
        f"{stimulus['fitted_end_hz']/1000:.2f} kHz, "
        f"{stimulus['duration_seconds']:.3f} s, "
        f"linear R^2={stimulus['linear_fit_r_squared']:.7f}"
    )
    alignment = report["alignment"]
    margin = alignment["alignment_margin_db"]
    margin_text = "unavailable" if margin is None else f"{margin:.2f} dB"
    print(
        f"alignment channel {alignment['channel']}: offset "
        f"{alignment['offset_seconds']:.6f} s, median lower-ridge SNR "
        f"{alignment['median_lower_ridge_snr_db']:.2f} dB, detection "
        f"{alignment['lower_ridge_detection_fraction']:.1%}, distinct-candidate "
        f"margin {margin_text}, "
        f"conclusive={str(alignment['conclusive']).lower()}"
    )
    if not alignment["conclusive"]:
        print("assessment: INCONCLUSIVE -- upper-band and timing claims withheld")
        return
    for channel in report["channel_results"]:
        print(f"channel {channel['channel']}: {channel['assessment']}")
        for band in channel["bands"]:
            if "median_ridge_vs_local_snr_db" not in band:
                print(
                    f"  {band['low_hz']/1000:g}--{band['high_hz']/1000:g} kHz: "
                    f"{band['assessment']}"
                )
                continue
            print(
                f"  {band['low_hz']/1000:g}--{band['high_hz']/1000:g} kHz: "
                f"median SNR {band['median_ridge_vs_local_snr_db']:.2f} dB, "
                f"detected {band['detection_fraction']:.1%}, {band['assessment']}"
            )
        for cutoff in channel["cutoffs"]:
            if "relative_gain_drop_db" in cutoff:
                print(
                    f"  {cutoff['boundary_hz']/1000:g} kHz cutoff: local drop "
                    f"{cutoff['relative_gain_drop_db']:.2f} dB, "
                    f"{cutoff['assessment']}"
                )
            else:
                print(
                    f"  {cutoff['boundary_hz']/1000:g} kHz cutoff: "
                    f"{cutoff['assessment']}"
                )
        timing = channel["timing"]
        print(
            f"  timing: {timing['assessment']}; step outliers="
            f"{timing.get('step_outliers', 'n/a')}"
        )
        gaps = channel["dropout_indicator"]
        print(
            f"  dropout/notch indicator: {gaps['assessment']}; candidates="
            f"{gaps.get('candidate_count', 'n/a')}"
        )
    print(
        "interpretation: a tracked ridge above 48 kHz is combined speaker-air-mic "
        "evidence only; one self-loop sweep cannot assign bandwidth to either endpoint"
    )


def emit_report(report: dict[str, Any], args: argparse.Namespace) -> None:
    encoded = json.dumps(report, indent=2, sort_keys=True)
    if args.json_output is not None:
        args.json_output.parent.mkdir(parents=True, exist_ok=True)
        args.json_output.write_text(encoded + "\n", encoding="utf-8")
    if args.json:
        print(encoded)
    else:
        human_report(report)


def main() -> int:
    args = parse_args()
    if not 0.0 < args.min_detection_fraction <= 1.0:
        raise ValueError("--min-detection-fraction must be in (0, 1]")
    if not (
        args.expected_start
        <= args.alignment_low
        < args.alignment_high
        <= args.expected_end
    ):
        raise ValueError("alignment band must lie inside the expected chirp")
    if args.expected_end >= args.expected_rate / 2.0:
        raise ValueError("expected chirp end must be below the Nyquist frequency")
    if not args.local_noise_inner > args.ridge_half_width:
        raise ValueError("local noise inner edge must exceed ridge half-width")
    if not args.local_noise_outer > args.local_noise_inner:
        raise ValueError("local noise outer edge must exceed inner edge")
    if args.hop_frames >= args.window_frames:
        raise ValueError("hop frames must be smaller than window frames")
    if args.fft_frames < args.window_frames:
        raise ValueError("FFT frames must be at least window frames")

    rate, stimulus_pcm, stimulus_dtype = load_wav(args.stimulus, args.expected_rate)
    _capture_rate, capture_pcm, capture_dtype = load_wav(
        args.capture, args.expected_rate
    )
    if args.stimulus_channel >= stimulus_pcm.shape[1]:
        raise ValueError(
            f"stimulus channel {args.stimulus_channel} is outside "
            f"0..{stimulus_pcm.shape[1] - 1}"
        )
    selected_channels = (
        list(range(capture_pcm.shape[1]))
        if args.channel is None
        else list(dict.fromkeys(args.channel))
    )
    invalid = [item for item in selected_channels if item >= capture_pcm.shape[1]]
    if invalid:
        raise ValueError(
            f"capture channel(s) outside 0..{capture_pcm.shape[1] - 1}: {invalid}"
        )

    stimulus = characterize_stimulus(
        stimulus_pcm[:, args.stimulus_channel], rate, args
    )
    alignments = [
        channel_alignment(
            capture_pcm[:, channel], rate, stimulus, channel, args
        )
        for channel in selected_channels
    ]
    alignment = max(
        alignments,
        key=lambda item: (
            item["conclusive"], item["median_lower_ridge_snr_db"]
        ),
    )
    report: dict[str, Any] = {
        "format": "powerphone-real-self-loop-chirp-v1",
        "stimulus_path": str(args.stimulus),
        "capture_path": str(args.capture),
        "sample_rate_hz": rate,
        "stimulus_dtype": stimulus_dtype,
        "capture_dtype": capture_dtype,
        "stimulus_channels": int(stimulus_pcm.shape[1]),
        "capture_channels": int(capture_pcm.shape[1]),
        "selected_capture_channels": selected_channels,
        "capture_duration_seconds": float(capture_pcm.shape[0] / rate),
        "stimulus_characterization": serializable_stimulus(stimulus),
        "alignment": alignment,
        "per_channel_alignment_candidates": alignments,
        "thresholds": {
            "minimum_ridge_snr_db": args.min_ridge_snr_db,
            "minimum_detection_fraction": args.min_detection_fraction,
            "minimum_alignment_margin_db": args.min_alignment_margin_db,
            "cutoff_drop_threshold_db": args.cutoff_drop_threshold_db,
            "jitter_step_threshold_ms": args.jitter_step_threshold_ms,
        },
        "limitations": [
            "A self-loop measures the combined speaker, air path, and microphone.",
            "A single sweep cannot distinguish a dropout from a narrow acoustic notch.",
            (
                "STFT ridge timing is not a direct phase-noise or sample-clock "
                "measurement."
            ),
        ],
    }
    if not alignment["conclusive"]:
        report["overall_assessment"] = "inconclusive_lower_band_alignment"
        report["channel_results"] = []
        emit_report(report, args)
        return 3

    tracks: list[tuple[int, dict[str, np.ndarray]]] = []
    channel_results: list[dict[str, Any]] = []
    for channel in selected_channels:
        track = track_channel(
            capture_pcm[:, channel],
            rate,
            stimulus,
            int(alignment["shift_stft_frames"]),
            args,
        )
        tracks.append((channel, track))
        result = analyze_channel_track(channel, track, args)
        result["clipped_samples"] = int(
            np.count_nonzero(np.abs(capture_pcm[:, channel]) >= 0.999)
        )
        channel_results.append(result)
    report["channel_results"] = channel_results
    if all(
        item["assessment"] == "ridge_evidence_through_85khz_band"
        for item in channel_results
    ):
        report["overall_assessment"] = "ridge_evidence_through_85khz_band"
    elif any(
        item["assessment"] == "sharp_cutoff_candidate"
        for item in channel_results
    ):
        report["overall_assessment"] = "sharp_cutoff_candidate"
    else:
        report["overall_assessment"] = "limited_or_inconclusive_bandwidth"
    if args.ridge_csv is not None:
        write_ridge_csv(args.ridge_csv, tracks)
    emit_report(report, args)
    if (
        args.require_wideband
        and report["overall_assessment"]
        != "ridge_evidence_through_85khz_band"
    ):
        return 4
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError) as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(2)
