#!/usr/bin/env python3
"""Analyze an actual D10 recording of a known D5 tone, including comb sidebands.

The microphone's qualified 192 kHz clock is the reference. Preserve the loudest
two-second interval for comparison, and independently analyze the entire
detected tone interval, including internal amplitude gaps and phase changes.
--start/--duration affect only the comparison interval. Results characterize
speaker-air-microphone measurements, not isolated amplifier response.
"""
from __future__ import annotations

import argparse
import csv
import json
from pathlib import Path

import numpy as np
from scipy import signal
from scipy.io import wavfile


def db(value: float | np.ndarray) -> float | np.ndarray:
    return 10 * np.log10(np.maximum(value, 1e-30))


def full_active_analysis(samples: np.ndarray, rate: int, tone: float) -> tuple[dict, dict]:
    """Find outer tone boundaries; never discard quiet holes inside them."""
    low = max(1000, tone - 3000)
    high = min(rate / 2 - 1000, tone + 3000)
    filtered = signal.sosfiltfilt(signal.butter(4, [low, high], "bandpass", fs=rate, output="sos"), samples)
    envelope_block = round(rate * 0.01)
    envelope_count = filtered.size // envelope_block
    power = np.mean(filtered[:envelope_count * envelope_block].reshape(envelope_count, envelope_block) ** 2, axis=1)
    quiet_count = min(50, max(1, envelope_count // 10))
    quiet_power = float(np.median(power[:quiet_count]))
    loud_count = min(50, max(1, envelope_count // 20))
    active_power = float(np.median(np.sort(power)[-loud_count:]))
    contrast = float(db(active_power / max(quiet_power, 1e-30)))
    threshold = max(quiet_power * 10, active_power * 0.05)
    active = signal.medfilt((power > threshold).astype(float), kernel_size=5) > 0
    locations = np.flatnonzero(active)
    evidence = {"measurable": False, "active_over_quiet_band_db": contrast,
                "boundary_envelope_bin_seconds": envelope_block / rate,
                "boundary_threshold_dbfs": float(db(threshold)),
                "excluded_boundary_seconds_each_end": 0.05}
    if contrast < 12 or locations.size < 20:
        evidence["reason"] = "no sustained tone interval at least 12 dB above quiet lead"
        return evidence, {}
    outer_first = int(locations[0] * envelope_block)
    outer_last = int((locations[-1] + 1) * envelope_block)
    first = outer_first + round(0.05 * rate)
    last = outer_last - round(0.05 * rate)
    selected = samples[first:last]
    if selected.size < rate // 10:
        evidence["reason"] = "tone interval too short after removing onset/offset boundaries"
        return evidence, {}
    block = round(rate * 0.00025)
    count = selected.size // block
    t = (np.arange(count) + 0.5) * block / rate
    phasor = np.exp(-2j * np.pi * tone * np.arange(count * block) / rate)
    demod = ((selected[:count * block] * phasor).reshape(count, block) * signal.windows.hann(block, sym=False)).mean(axis=1)
    amplitude = np.abs(demod)
    amplitude_floor = float(np.median(amplitude) * 0.2)
    good = amplitude > amplitude_floor
    phase = np.unwrap(np.angle(demod))
    slope, offset = np.polyfit(t[good], phase[good], 1)
    residual = phase - (slope * t + offset)
    jumps = np.diff(residual)
    valid_pairs = good[1:] & good[:-1]
    jump_locations = np.flatnonzero((np.abs(jumps) > 0.35) & valid_pairs)
    edges = np.diff(np.r_[False, ~good, False].astype(int))
    gap_starts, gap_ends = np.flatnonzero(edges == 1), np.flatnonzero(edges == -1)
    gap_lengths = gap_ends - gap_starts
    frequency, psd = signal.welch(selected, rate, nperseg=min(rate, selected.size), noverlap=min(rate, selected.size) // 2, scaling="density")
    df = frequency[1] - frequency[0]
    carrier_band = np.abs(frequency - tone) <= max(3, 3 * df)
    carrier_power = float(np.sum(psd[carrier_band]) * df)
    spurious = (frequency > 1000) & (frequency < 95000) & (np.abs(frequency - tone) > 20)
    spur_index = int(np.argmax(np.where(spurious, psd, 0)))
    spur_power = float(np.sum(psd[max(0, spur_index - 3):spur_index + 4]) * df)
    near = np.abs(frequency - tone) < 20
    peak_index = int(np.argmax(np.where(near, psd, 0)))
    a, b, c = np.log(np.maximum(psd[peak_index - 1:peak_index + 2], 1e-30))
    correction = 0.5 * (a - c) / (a - 2 * b + c) if a - 2 * b + c else 0.0
    peak_hz = float(frequency[peak_index] + np.clip(correction, -0.5, 0.5) * df)
    evidence.update({
        "measurable": True, "outer_detected_start_seconds": outer_first / rate,
        "outer_detected_stop_seconds": outer_last / rate,
        "analyzed_start_seconds": first / rate, "analyzed_stop_seconds": last / rate,
        "analyzed_duration_seconds": selected.size / rate,
        "measured_carrier_peak_hz": peak_hz, "phase_fit_hz": float(tone + slope / (2 * np.pi)),
        "phase_fit_spans_dropouts": bool(gap_lengths.size),
        "requested_tone_dbfs": float(db(carrier_power)),
        "strongest_spur_hz": float(frequency[spur_index]),
        "strongest_spur_dbc": float(db(spur_power / max(carrier_power, 1e-30))),
        "phase_analysis_block_microseconds": 1e6 * block / rate,
        "analyzed_phase_pairs": int(np.sum(valid_pairs)),
        "phase_step_over_035rad_count": int(jump_locations.size),
        "phase_step_max_rad": float(np.max(np.abs(jumps[valid_pairs]))) if np.any(valid_pairs) else None,
        "phase_event_capture_seconds": (first / rate + t[jump_locations + 1]).tolist(),
        "amplitude_floor": amplitude_floor, "amplitude_dropout_blocks": int(np.sum(~good)),
        "amplitude_dropout_total_seconds": float(np.sum(~good) * block / rate),
        "amplitude_dropout_longest_seconds": float(np.max(gap_lengths) * block / rate) if gap_lengths.size else 0.0,
        "amplitude_dropout_events": [{"capture_start_seconds": first / rate + int(begin) * block / rate,
                                       "duration_seconds": int(end - begin) * block / rate}
                                      for begin, end in zip(gap_starts, gap_ends)],
        "clipped_samples": int(np.sum(np.abs(selected) > 0.999)),
        "interpretation": "All samples between outer tone boundaries are included; 50 ms at each outer boundary is excluded. Internal dropouts remain counted. Phase cannot be assessed during amplitude dropouts; a single carrier also cannot reveal sample slips by an exact whole number of carrier cycles.",
    })
    return evidence, {"time": t + first / rate, "amplitude": amplitude, "residual": residual,
                      "good": good, "frequency": frequency, "psd": psd}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("wav", type=Path)
    parser.add_argument("--tone", type=float, required=True)
    parser.add_argument("--output-dir", type=Path)
    parser.add_argument("--start", type=float)
    parser.add_argument("--duration", type=float, default=2.0)
    parser.add_argument("--channel", type=int, default=0)
    args = parser.parse_args()
    rate, pcm = wavfile.read(args.wav)
    if rate != 192000:
        raise ValueError(f"D10 clock reference must be 192000 Hz; got {rate}")
    if pcm.ndim > 1:
        pcm = pcm[:, args.channel]
    if not np.issubdtype(pcm.dtype, np.signedinteger):
        raise ValueError("expected signed integer PCM")
    scale = float(2 ** (np.iinfo(pcm.dtype).bits - 1))
    samples = pcm.astype(np.float64) / scale
    samples -= np.mean(samples)
    n = min(round(args.duration * rate), samples.size)
    if n < rate // 2:
        raise ValueError("at least 0.5 seconds of capture is required")
    if args.start is None:
        # DC/PDM noise must not select the quiet tail; use a broad expected-tone
        # region that also includes the 500/1000 Hz comb from dropped blocks.
        low = max(1000, args.tone - 3000)
        high = min(rate / 2 - 1000, args.tone + 3000)
        filtered = signal.sosfiltfilt(signal.butter(4, [low, high], "bandpass", fs=rate, output="sos"), samples)
        power_integral = np.r_[0.0, np.cumsum(filtered * filtered)]
        candidates = np.arange(0, samples.size - n + 1, max(1, rate // 20))
        energies = power_integral[candidates + n] - power_integral[candidates]
        start = int(candidates[np.argmax(energies)])
    else:
        start = round(args.start * rate)
    selected = samples[start:start + n]
    if selected.size < rate // 2:
        raise ValueError("selected interval is too short")
    frequency, psd = signal.welch(selected, rate, nperseg=min(rate, selected.size), noverlap=min(rate, selected.size) // 2, scaling="density")
    step = frequency[1] - frequency[0]
    search = (frequency > max(1000, args.tone / 2)) & (frequency < min(95000, args.tone * 2))
    candidates, _ = signal.find_peaks(psd)
    candidates = candidates[search[candidates]]
    ranked = candidates[np.argsort(psd[candidates])[::-1]]
    carrier = int(np.argmin(np.abs(frequency - args.tone)))
    tone_band = np.abs(frequency - args.tone) <= max(3, 3 * step)
    carrier_power = float(np.sum(psd[tone_band]) * step)
    peaks = []
    for index in ranked[:20]:
        # Sub-bin estimate from the peak's log-PSD parabola.
        a, b, c = np.log(np.maximum(psd[index - 1:index + 2], 1e-30))
        correction = 0.5 * (a - c) / (a - 2 * b + c) if a - 2 * b + c else 0.0
        f = float(frequency[index] + np.clip(correction, -0.5, 0.5) * step)
        integrated = float(np.sum(psd[max(0, index - 3):index + 4]) * step)
        peaks.append({"hz": f, "dbfs": float(db(integrated)), "dbc_requested_tone": float(db(integrated / max(carrier_power, 1e-30)))})
    broad = (frequency > 1000) & (frequency < 95000)
    spurious = broad & (np.abs(frequency - args.tone) > 20)
    biggest_spur = int(np.argmax(np.where(spurious, psd, 0)))
    spur_power = float(np.sum(psd[max(0, biggest_spur - 3):biggest_spur + 4]) * step)
    # 250 us windows resolve the observed 500 Hz comb. A 2 ms demodulation
    # window averages exactly one comb cycle and can hide severe distortion.
    block = round(rate * 0.00025)
    count = selected.size // block
    tone_phasor = np.exp(-2j * np.pi * args.tone * np.arange(count * block) / rate)
    demod = ((selected[:count * block] * tone_phasor).reshape(count, block) * signal.windows.hann(block, sym=False)).mean(axis=1)
    amplitude = np.abs(demod)
    good = amplitude > np.median(amplitude) * 0.2
    phase = np.unwrap(np.angle(demod))
    t = (np.arange(count) + 0.5) * block / rate
    slope, offset = np.polyfit(t[good], phase[good], 1)
    residual = phase - (slope * t + offset)
    jumps = np.diff(residual)
    good_pairs = good[1:] & good[:-1]
    baseline = samples[:min(rate // 2, samples.size)]
    bf, bp = signal.welch(baseline, rate, nperseg=baseline.size)
    baseline_carrier_power = float(np.sum(bp[np.abs(bf - args.tone) <= 4]) * (bf[1] - bf[0]))
    report = {
        "capture": str(args.wav.resolve()), "microphone_clock_hz": rate,
        "requested_tone_hz": args.tone,
        "selected_start_seconds": start / rate,
        "selected_duration_seconds": selected.size / rate,
        "requested_tone_dbfs": float(db(carrier_power)),
        "tone_over_quiet_lead_db": float(db(carrier_power / max(baseline_carrier_power, 1e-30))),
        "strongest_nearby_peak_hz": peaks[0]["hz"] if peaks else None,
        "strongest_spur_hz": float(frequency[biggest_spur]),
        "strongest_spur_dbc": float(db(spur_power / max(carrier_power, 1e-30))),
        "phase_fit_hz": float(args.tone + slope / (2 * np.pi)),
        "phase_step_over_035rad_count": int(np.sum((np.abs(jumps) > 0.35) & good_pairs)),
        "phase_step_max_rad": float(np.max(np.abs(jumps[good_pairs]))) if np.any(good_pairs) else None,
        "phase_analysis_block_microseconds": 1e6 * block / rate,
        "amplitude_dropout_blocks": int(np.sum(~good)),
        "clipped_samples": int(np.sum(np.abs(selected) > 0.999)),
        "peaks": peaks,
        "limits": "Acoustic tone fidelity only. 12 kHz alone cannot establish 192 kHz bandwidth. Repeat above 24 and 48 kHz and compare quiet baseline, aliases, and harmonics; microphone PDM noise is not speaker output proof.",
    }
    report["comparison_interval"] = {key: value for key, value in report.items() if key not in ("capture", "limits", "peaks")}
    full_report, full_arrays = full_active_analysis(samples, rate, args.tone)
    report["full_active_interval"] = full_report
    output_dir = args.output_dir or args.wav.parent
    output_dir.mkdir(parents=True, exist_ok=True)
    (output_dir / "tone-analysis.json").write_text(json.dumps(report, indent=2) + "\n")
    with (output_dir / "tone-spectrum.csv").open("w", newline="") as output:
        writer = csv.writer(output)
        writer.writerow(["frequency_hz", "psd_dbfs_per_hz"])
        writer.writerows(zip(frequency, db(psd)))
    with (output_dir / "tone-phase.csv").open("w", newline="") as output:
        writer = csv.writer(output)
        writer.writerow(["seconds_in_capture", "carrier_amplitude", "phase_residual_rad", "above_amplitude_floor"])
        writer.writerows(zip(t + start / rate, amplitude, residual, good.astype(int)))
    if full_arrays:
        with (output_dir / "tone-full-active-phase.csv").open("w", newline="") as output:
            writer = csv.writer(output)
            writer.writerow(["seconds_in_capture", "carrier_amplitude", "phase_residual_rad", "above_amplitude_floor"])
            writer.writerows(zip(full_arrays["time"], full_arrays["amplitude"], full_arrays["residual"], full_arrays["good"].astype(int)))
        with (output_dir / "tone-full-active-spectrum.csv").open("w", newline="") as output:
            writer = csv.writer(output)
            writer.writerow(["frequency_hz", "psd_dbfs_per_hz"])
            writer.writerows(zip(full_arrays["frequency"], db(full_arrays["psd"])))
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
