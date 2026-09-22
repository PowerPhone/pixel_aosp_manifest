#!/usr/bin/env python3
"""Analyze real Frankel 16--85 kHz D0/D10 self-loop evidence.

The capture must be standard mono PCM16 at 192 kHz.  A supplied stimulus is
validated as a rising 16--85 kHz chirp, then located from its lower-band ridge
before any ultrasonic conclusion is made.  A WAV header or non-correlated
upper-band noise is never treated as bandwidth proof.
"""

from __future__ import annotations

import argparse
import json
import math
import pathlib
import sys
import types
import wave
from typing import Any

import numpy as np
from scipy import signal


RATE_HZ = 192_000
CHIRP_START_HZ = 16_000.0
CHIRP_END_HZ = 85_000.0
BANDS = (
    ("16_24khz", 16_000.0, 24_000.0),
    ("24_36khz", 24_000.0, 36_000.0),
    ("36_48khz", 36_000.0, 48_000.0),
    ("48_60khz", 48_000.0, 60_000.0),
    ("60_72khz", 60_000.0, 72_000.0),
    ("72_85khz", 72_000.0, 85_000.0),
)


def finite_float(text: str) -> float:
    value = float(text)
    if not math.isfinite(value):
        raise argparse.ArgumentTypeError("value must be finite")
    return value


def positive_float(text: str) -> float:
    value = finite_float(text)
    if value <= 0.0:
        raise argparse.ArgumentTypeError("value must be positive")
    return value


def nonnegative_int(text: str) -> int:
    value = int(text)
    if value < 0:
        raise argparse.ArgumentTypeError("value must be non-negative")
    return value


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("stimulus", type=pathlib.Path, help="known 16--85 kHz chirp WAV")
    parser.add_argument("capture", type=pathlib.Path, help="mono PCM16/192000 loopback WAV")
    parser.add_argument("--stimulus-channel", type=nonnegative_int, default=0)
    parser.add_argument(
        "--min-ridge-snr-db",
        type=finite_float,
        default=6.0,
        help="minimum ridge-to-simultaneous-sideband SNR (default: 6 dB)",
    )
    parser.add_argument(
        "--min-detection-fraction",
        type=finite_float,
        default=0.60,
        help="minimum fraction of band frames above the SNR floor (default: 0.60)",
    )
    parser.add_argument(
        "--cutoff-drop-db",
        type=positive_float,
        default=15.0,
        help="source-normalized local drop that flags a sharp cutoff (default: 15 dB)",
    )
    parser.add_argument(
        "--max-clipped-samples",
        type=nonnegative_int,
        default=0,
        help="allowed rail-valued samples during the aligned chirp (default: 0)",
    )
    parser.add_argument(
        "--max-dc-fraction",
        type=positive_float,
        default=0.01,
        help="DC warning threshold as a fraction of full scale (default: 0.01)",
    )
    parser.add_argument(
        "--constant-run-ms",
        type=positive_float,
        default=1.0,
        help="exact repeated/zero run that flags a dropout (default: 1 ms)",
    )
    parser.add_argument(
        "--low-rms-dbfs",
        type=finite_float,
        default=-90.0,
        help="10 ms aligned-chirp block floor used as a dropout indicator",
    )
    parser.add_argument(
        "--require-above-48k",
        action="store_true",
        help="exit 4 unless qualifying correlated evidence extends above 48 kHz",
    )
    parser.add_argument("--json", action="store_true", help="emit JSON on stdout")
    parser.add_argument("--json-output", type=pathlib.Path, help="also write JSON here")
    return parser.parse_args()


def load_chirp_core() -> types.ModuleType:
    core_path = (
        pathlib.Path(__file__).resolve().parents[2]
        / "scripts"
        / "audio"
        / "analyze-chirp-loop.py"
    )
    if not core_path.is_file() or core_path.is_symlink():
        raise ValueError(f"required chirp-analysis core is missing or unsafe: {core_path}")
    module = types.ModuleType("_frankel_chirp_core")
    module.__file__ = str(core_path)
    module.__dict__["__name__"] = module.__name__
    source = core_path.read_bytes()
    exec(compile(source, str(core_path), "exec"), module.__dict__)
    return module


def load_capture(path: pathlib.Path) -> tuple[np.ndarray, np.ndarray]:
    if path.is_symlink() or not path.is_file():
        raise ValueError(f"capture WAV is missing or unsafe: {path}")
    try:
        with wave.open(str(path), "rb") as wav:
            channels = wav.getnchannels()
            width = wav.getsampwidth()
            rate = wav.getframerate()
            frames = wav.getnframes()
            compression = wav.getcomptype()
            payload = wav.readframes(frames)
            trailing = wav.readframes(1)
    except (EOFError, wave.Error) as error:
        raise ValueError(f"invalid standard PCM WAV: {path}: {error}") from error
    if channels != 1 or width != 2 or rate != RATE_HZ or compression != "NONE":
        raise ValueError(
            f"capture must be mono PCM16/{RATE_HZ}; got channels={channels}, "
            f"sample_width={width}, rate={rate}, compression={compression}"
        )
    if frames < RATE_HZ or len(payload) != frames * 2 or trailing:
        raise ValueError(
            f"capture has an invalid or too-short data chunk: header_frames={frames}, "
            f"payload_bytes={len(payload)}"
        )
    raw = np.frombuffer(payload, dtype="<i2").copy()
    normalized = raw.astype(np.float64) / 32768.0
    return raw, normalized


def core_args(args: argparse.Namespace) -> types.SimpleNamespace:
    return types.SimpleNamespace(
        expected_rate=RATE_HZ,
        expected_start=CHIRP_START_HZ,
        expected_end=CHIRP_END_HZ,
        stimulus_frequency_tolerance=1_000.0,
        alignment_low=16_000.0,
        alignment_high=23_500.0,
        window_frames=4096,
        hop_frames=1024,
        fft_frames=8192,
        ridge_half_width=350.0,
        ridge_search_width=1_200.0,
        local_noise_inner=1_000.0,
        local_noise_outer=3_000.0,
        min_ridge_snr_db=args.min_ridge_snr_db,
        min_detection_fraction=args.min_detection_fraction,
        min_alignment_margin_db=1.5,
        cutoff_drop_threshold_db=args.cutoff_drop_db,
        jitter_step_threshold_ms=3.0,
    )


def longest_true_run(mask: np.ndarray) -> int:
    if mask.size == 0 or not np.any(mask):
        return 0
    padded = np.concatenate((np.array([False]), mask, np.array([False])))
    edges = np.flatnonzero(padded[1:] != padded[:-1])
    return int(np.max(edges[1::2] - edges[::2]))


def longest_constant_run(samples: np.ndarray) -> tuple[int, int | None]:
    if samples.size == 0:
        return 0, None
    edges = np.flatnonzero(
        np.concatenate((np.array([True]), samples[1:] != samples[:-1], np.array([True])))
    )
    lengths = np.diff(edges)
    index = int(np.argmax(lengths))
    return int(lengths[index]), int(samples[int(edges[index])])


def dbfs_amplitude(value: float) -> float | None:
    if value <= 0.0:
        return None
    return float(20.0 * math.log10(value))


def aligned_bounds(
    alignment: dict[str, Any] | None, stimulus_duration: float, sample_count: int
) -> tuple[int, int] | None:
    if alignment is None or not alignment.get("conclusive"):
        return None
    start = int(round(float(alignment["offset_seconds"]) * RATE_HZ))
    stop = int(round((float(alignment["offset_seconds"]) + stimulus_duration) * RATE_HZ))
    start = max(0, min(sample_count, start))
    stop = max(0, min(sample_count, stop))
    if stop - start < RATE_HZ // 2:
        return None
    return start, stop


def low_rms_blocks(samples: np.ndarray, threshold_dbfs: float) -> dict[str, Any]:
    block_frames = RATE_HZ // 100
    count = samples.size // block_frames
    if count < 4:
        return {"measurable": False, "reason": "fewer than four 10 ms blocks"}
    blocks = samples[: count * block_frames].reshape(count, block_frames)
    rms = np.sqrt(np.mean(np.square(blocks.astype(np.float64) / 32768.0), axis=1))
    rms_dbfs = 20.0 * np.log10(np.maximum(rms, np.finfo(np.float64).tiny))
    low = rms_dbfs <= threshold_dbfs
    return {
        "measurable": True,
        "block_duration_ms": 10.0,
        "threshold_dbfs": threshold_dbfs,
        "block_count": int(count),
        "low_block_count": int(np.count_nonzero(low)),
        "longest_low_run_blocks": longest_true_run(low),
        "longest_low_run_ms": float(longest_true_run(low) * 10.0),
        "minimum_block_rms_dbfs": float(np.min(rms_dbfs)),
        "median_block_rms_dbfs": float(np.median(rms_dbfs)),
        "caution": "a swept-frequency acoustic notch can resemble a temporal low-RMS interval",
    }


def quality_metrics(
    raw: np.ndarray,
    normalized: np.ndarray,
    bounds: tuple[int, int] | None,
    args: argparse.Namespace,
) -> dict[str, Any]:
    region = raw if bounds is None else raw[bounds[0] : bounds[1]]
    normalized_region = (
        normalized if bounds is None else normalized[bounds[0] : bounds[1]]
    )
    region_name = "whole-capture" if bounds is None else "aligned-chirp"
    positive_clip = int(np.count_nonzero(region == 32767))
    negative_clip = int(np.count_nonzero(region == -32768))
    clipped = positive_clip + negative_clip
    constant_frames, constant_value = longest_constant_run(region)
    zero_frames = longest_true_run(region == 0)
    dropout_frames = int(math.ceil(args.constant_run_ms * RATE_HZ / 1_000.0))
    dc = float(np.mean(normalized_region))
    peak = float(np.max(np.abs(normalized_region)))
    low_rms = low_rms_blocks(region, args.low_rms_dbfs)
    blockers: list[str] = []
    warnings: list[str] = []
    if clipped > args.max_clipped_samples:
        blockers.append("clipping")
    if constant_frames >= dropout_frames:
        blockers.append("exact-constant-run")
    if zero_frames >= dropout_frames:
        blockers.append("exact-zero-run")
    if abs(dc) >= args.max_dc_fraction:
        warnings.append("dc-offset")
    if low_rms.get("longest_low_run_blocks", 0) > 0:
        warnings.append("low-rms-blocks")
    return {
        "assessment_region": region_name,
        "assessment_frames": int(region.size),
        "capture_frames": int(raw.size),
        "capture_duration_seconds": float(raw.size / RATE_HZ),
        "peak_fraction_full_scale": peak,
        "peak_dbfs": dbfs_amplitude(peak),
        "positive_rail_samples": positive_clip,
        "negative_rail_samples": negative_clip,
        "clipped_samples": clipped,
        "clipped_fraction": float(clipped / max(1, region.size)),
        "max_allowed_clipped_samples": args.max_clipped_samples,
        "dc_offset_fraction_full_scale": dc,
        "dc_offset_dbfs": dbfs_amplitude(abs(dc)),
        "dc_warning_threshold_fraction": args.max_dc_fraction,
        "longest_exact_constant_run_frames": constant_frames,
        "longest_exact_constant_run_ms": float(constant_frames * 1_000.0 / RATE_HZ),
        "longest_exact_constant_value": constant_value,
        "longest_exact_zero_run_frames": zero_frames,
        "longest_exact_zero_run_ms": float(zero_frames * 1_000.0 / RATE_HZ),
        "dropout_run_threshold_frames": dropout_frames,
        "dropout_run_threshold_ms": args.constant_run_ms,
        "low_rms_blocks": low_rms,
        "blocking_indicators": blockers,
        "warnings": warnings,
        "qualifying_integrity": not blockers,
    }


def median_psd_db(
    frequencies: np.ndarray, psd: np.ndarray, low: float, high: float
) -> float | None:
    selected = (frequencies >= low) & (frequencies < high)
    if np.count_nonzero(selected) < 8:
        return None
    values = 10.0 * np.log10(np.maximum(psd[selected], np.finfo(np.float64).tiny))
    return float(np.median(values))


def noise_shape_metrics(
    normalized: np.ndarray,
    bounds: tuple[int, int] | None,
) -> dict[str, Any]:
    minimum_segment = 16_384
    segments: list[np.ndarray] = []
    if bounds is not None:
        guard = RATE_HZ // 10
        before = normalized[: max(0, bounds[0] - guard)]
        after = normalized[min(normalized.size, bounds[1] + guard) :]
        segments = [part for part in (before, after) if part.size >= minimum_segment]
    if not segments:
        segments = [normalized]
        source = "whole-capture-median-welch"
        caveat = "no sufficiently long off-chirp interval; chirp rejection relies on median Welch"
    else:
        source = "off-chirp-intervals"
        caveat = None

    spectra: list[np.ndarray] = []
    weights: list[int] = []
    frequencies: np.ndarray | None = None
    for part in segments:
        centered = part - float(np.mean(part))
        current_frequencies, current_psd = signal.welch(
            centered,
            fs=RATE_HZ,
            window="hann",
            nperseg=8192,
            noverlap=4096,
            nfft=16_384,
            detrend=False,
            scaling="density",
            average="median",
        )
        frequencies = current_frequencies
        spectra.append(current_psd)
        weights.append(int(part.size))
    if frequencies is None:
        raise ValueError("no samples are available for upper-band noise analysis")
    psd = np.average(np.stack(spectra), axis=0, weights=np.asarray(weights))

    centers: list[float] = []
    levels: list[float] = []
    for low in np.arange(55_000.0, 94_000.0, 1_000.0):
        value = median_psd_db(frequencies, psd, float(low), float(low + 1_000.0))
        if value is not None:
            centers.append(float((low + 500.0) / 1_000.0))
            levels.append(value)
    if len(centers) < 20:
        return {"measurable": False, "reason": "upper band has too few PSD bins"}
    x = np.asarray(centers)
    y = np.asarray(levels)
    slope, intercept = np.polyfit(x, y, 1)
    fitted = slope * x + intercept
    denominator = float(np.sum(np.square(y - np.mean(y))))
    r_squared = 1.0 - float(np.sum(np.square(y - fitted))) / max(
        denominator, np.finfo(np.float64).tiny
    )
    lower = median_psd_db(frequencies, psd, 55_000.0, 65_000.0)
    middle = median_psd_db(frequencies, psd, 70_000.0, 80_000.0)
    upper = median_psd_db(frequencies, psd, 88_000.0, 94_000.0)
    if lower is None or middle is None or upper is None:
        raise ValueError("upper-band PSD windows are unexpectedly unresolved")
    rise = upper - lower
    if rise >= 3.0 and slope >= 0.08 and r_squared >= 0.35:
        assessment = "rising-upper-band-noise-candidate"
    elif rise <= -3.0 and slope <= -0.08:
        assessment = "falling-upper-band-noise"
    else:
        assessment = "no-clear-upper-band-noise-rise"
    return {
        "measurable": True,
        "assessment": assessment,
        "assessment_thresholds": {
            "minimum_near_nyquist_rise_db": 3.0,
            "minimum_fit_slope_db_per_khz": 0.08,
            "minimum_fit_r_squared": 0.35,
        },
        "spectrum_source": source,
        "analyzed_samples": int(sum(weights)),
        "lower_55_65khz_median_dbfs_per_hz": lower,
        "middle_70_80khz_median_dbfs_per_hz": middle,
        "near_nyquist_88_94khz_median_dbfs_per_hz": upper,
        "near_nyquist_rise_over_55_65khz_db": rise,
        "fit_slope_db_per_khz_55_94khz": float(slope),
        "fit_r_squared": r_squared,
        "supportive_only": True,
        "caution": (
            "a rising floor is compatible with delta-sigma/PDM noise shaping but is not "
            "proof of acoustic bandwidth"
        ),
        "source_caveat": caveat,
    }


def extension_assessment(
    upper: dict[str, Any], lower: dict[str, Any]
) -> dict[str, Any]:
    if upper.get("assessment") == "supported":
        value: bool | None = True
        assessment = "supported"
    elif (
        upper.get("assessment") == "not_detected"
        and lower.get("assessment") == "supported"
    ):
        value = False
        assessment = "not-detected-after-supported-lower-band"
    else:
        value = None
        assessment = "inconclusive"
    return {
        "detected": value,
        "assessment": assessment,
        "median_ridge_vs_local_snr_db": upper.get("median_ridge_vs_local_snr_db"),
        "detection_fraction": upper.get("detection_fraction"),
    }


def cutoff_boolean(cutoff: dict[str, Any]) -> bool | None:
    assessment = cutoff.get("assessment")
    if assessment == "sharp_cutoff_candidate":
        return True
    if assessment == "no_sharp_cutoff_evidence":
        return False
    return None


def human_report(report: dict[str, Any]) -> None:
    stimulus = report["stimulus"]
    print(
        f"stimulus: {stimulus['fitted_start_hz']/1000:.2f}--"
        f"{stimulus['fitted_end_hz']/1000:.2f} kHz; "
        f"linear R^2={stimulus['linear_fit_r_squared']:.7f}"
    )
    alignment = report["alignment"]
    print(
        f"alignment: conclusive={str(alignment['conclusive']).lower()}, "
        f"offset={alignment['offset_seconds']:.6f} s, "
        f"lower-ridge SNR={alignment['median_lower_ridge_snr_db']:.2f} dB, "
        f"detected={alignment['lower_ridge_detection_fraction']:.1%}"
    )
    for name, band in report.get("correlated_energy", {}).get("bands", {}).items():
        snr = band.get("median_ridge_vs_local_snr_db")
        detail = "" if snr is None else f", median SNR={snr:.2f} dB"
        print(f"band {name}: {band['assessment']}{detail}")
    conclusions = report["conclusions"]
    print(
        "correlated energy above 48 kHz: "
        f"{conclusions['above_48khz']['assessment']}"
    )
    print(
        "correlated energy above 60 kHz: "
        f"{conclusions['above_60khz']['assessment']}"
    )
    for name, cutoff in report.get("cutoffs", {}).items():
        drop = cutoff.get("relative_gain_drop_db")
        detail = "" if drop is None else f", local drop={drop:.2f} dB"
        print(f"{name}: {cutoff['assessment']}{detail}")
    noise = report["upper_band_noise"]
    if noise.get("measurable"):
        print(
            f"upper-band noise: {noise['assessment']}, "
            f"88--94 vs 55--65 kHz={noise['near_nyquist_rise_over_55_65khz_db']:.2f} dB"
        )
    else:
        print(f"upper-band noise: inconclusive ({noise.get('reason', 'unknown')})")
    quality = report["signal_quality"]
    low_rms = quality["low_rms_blocks"]
    print(
        f"quality: clipped={quality['clipped_samples']}, "
        f"DC={quality['dc_offset_fraction_full_scale']:.6f} FS, "
        f"constant-run={quality['longest_exact_constant_run_ms']:.3f} ms, "
        f"zero-run={quality['longest_exact_zero_run_ms']:.3f} ms, "
        f"low-RMS-blocks={low_rms.get('low_block_count', 'inconclusive')}, "
        f"blockers={quality['blocking_indicators'] or 'none'}"
    )
    continuity = report.get("continuity", {})
    if "ridge_timing" in continuity:
        print(
            "continuity: timing="
            f"{continuity['ridge_timing']['assessment']}, ridge-gaps="
            f"{continuity['ridge_gap_or_notch']['assessment']}"
        )
    else:
        print(f"continuity: {continuity.get('assessment', 'inconclusive')}")
    print(f"overall: {report['overall_assessment']}")
    print(
        "interpretation: this is combined speaker-air-microphone evidence; "
        "it cannot assign bandwidth to either endpoint alone"
    )


def emit(report: dict[str, Any], args: argparse.Namespace) -> None:
    encoded = json.dumps(report, indent=2, sort_keys=True, allow_nan=False)
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
    if args.max_dc_fraction > 1.0:
        raise ValueError("--max-dc-fraction must be at most 1")

    core = load_chirp_core()
    analysis_args = core_args(args)
    raw_capture, capture = load_capture(args.capture)
    rate, stimulus_pcm, stimulus_dtype = core.load_wav(args.stimulus, RATE_HZ)
    if args.stimulus_channel >= stimulus_pcm.shape[1]:
        raise ValueError(
            f"stimulus channel {args.stimulus_channel} is outside "
            f"0..{stimulus_pcm.shape[1] - 1}"
        )
    stimulus = core.characterize_stimulus(
        stimulus_pcm[:, args.stimulus_channel], rate, analysis_args
    )
    alignment = core.channel_alignment(capture, rate, stimulus, 0, analysis_args)
    bounds = aligned_bounds(
        alignment, float(stimulus["duration_seconds"]), raw_capture.size
    )
    quality = quality_metrics(raw_capture, capture, bounds, args)
    noise = noise_shape_metrics(capture, bounds)
    report: dict[str, Any] = {
        "format": "frankel-ultrasonic-loopback-evidence-v1",
        "stimulus_path": str(args.stimulus),
        "capture_path": str(args.capture),
        "capture_format": "mono-pcm16-le-192000",
        "stimulus_dtype": stimulus_dtype,
        "stimulus": core.serializable_stimulus(stimulus),
        "alignment": alignment,
        "thresholds": {
            "minimum_ridge_snr_db": args.min_ridge_snr_db,
            "minimum_detection_fraction": args.min_detection_fraction,
            "minimum_alignment_margin_db": analysis_args.min_alignment_margin_db,
            "sharp_cutoff_drop_db": args.cutoff_drop_db,
            "maximum_clipped_samples": args.max_clipped_samples,
            "maximum_dc_fraction": args.max_dc_fraction,
            "constant_run_dropout_ms": args.constant_run_ms,
            "low_rms_block_dbfs": args.low_rms_dbfs,
        },
        "signal_quality": quality,
        "upper_band_noise": noise,
        "limitations": [
            "Self-loop evidence covers the combined speaker, air path, and microphone.",
            (
                "A single chirp maps time to frequency, so a ridge gap can also be "
                "an acoustic notch."
            ),
            "Rising near-Nyquist noise is supportive PDM evidence, not bandwidth proof.",
            (
                "Ridge timing is a discontinuity screen, not a direct sample-clock "
                "jitter measurement."
            ),
        ],
    }
    if not alignment["conclusive"]:
        report["correlated_energy"] = {"assessment": "withheld"}
        report["cutoffs"] = {}
        report["continuity"] = {"assessment": "withheld"}
        report["conclusions"] = {
            "above_48khz": {"detected": None, "assessment": "inconclusive"},
            "above_60khz": {"detected": None, "assessment": "inconclusive"},
            "qualifying_above_48khz": False,
        }
        report["overall_assessment"] = "inconclusive-lower-band-alignment"
        emit(report, args)
        return 3

    track = core.track_channel(
        capture,
        rate,
        stimulus,
        int(alignment["shift_stft_frames"]),
        analysis_args,
    )
    bands = {
        name: core.summarize_band(track, low, high, analysis_args)
        for name, low, high in BANDS
    }
    cutoff_list = [
        core.cutoff_evidence(track, boundary, analysis_args)
        for boundary in (24_000.0, 48_000.0)
    ]
    cutoffs = {
        f"near_{int(item['boundary_hz']/1000)}khz": item for item in cutoff_list
    }
    above_48 = extension_assessment(bands["48_60khz"], bands["36_48khz"])
    above_60 = extension_assessment(bands["60_72khz"], bands["48_60khz"])
    cutoff_48 = cutoff_boolean(cutoffs["near_48khz"])
    qualifying = bool(
        above_48["detected"] is True
        and cutoff_48 is not True
        and quality["qualifying_integrity"]
    )
    if qualifying and above_60["detected"] is True:
        overall = "qualifying-correlated-evidence-above-60khz"
    elif qualifying:
        overall = "qualifying-correlated-evidence-above-48khz"
    elif cutoff_48 is True:
        overall = "sharp-48khz-rolloff-candidate"
    elif above_48["detected"] is False:
        overall = "correlated-energy-not-detected-above-48khz"
    elif not quality["qualifying_integrity"]:
        overall = "quality-blocked"
    else:
        overall = "limited-or-inconclusive"

    report["correlated_energy"] = {
        "assessment": "time-aligned-ridge-versus-simultaneous-sidebands",
        "bands": bands,
    }
    report["cutoffs"] = cutoffs
    report["continuity"] = {
        "ridge_timing": core.robust_timing(track, analysis_args),
        "ridge_gap_or_notch": core.ridge_gaps(track, list(bands.values()), analysis_args),
    }
    report["conclusions"] = {
        "above_48khz": above_48,
        "above_60khz": above_60,
        "sharp_rolloff_near_24khz": cutoff_boolean(cutoffs["near_24khz"]),
        "sharp_rolloff_near_48khz": cutoff_48,
        "qualifying_above_48khz": qualifying,
    }
    report["overall_assessment"] = overall
    emit(report, args)
    if args.require_above_48k and not qualifying:
        return 4
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError) as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(2)
