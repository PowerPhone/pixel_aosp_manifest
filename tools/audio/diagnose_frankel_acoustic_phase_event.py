#!/usr/bin/env python3
"""Diagnose one event in a real acoustic WAV; never change qualification.

Compare carrier phase/amplitude before and after the event, residual spectra,
and different diagnostic demodulation windows. An additive transient can bias
a short-window phase estimator; these observations do not erase its failure.
Print a JSON report to stdout. Requires NumPy and SciPy.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path

import numpy as np
from scipy import signal
from scipy.io import wavfile


def db_power(value):
    return float(10 * np.log10(max(float(value), 1e-30)))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("analysis", type=Path)
    parser.add_argument("--event-index", type=int, default=0)
    args = parser.parse_args()
    analysis = json.loads(args.analysis.read_text())
    full = analysis["full_active_interval"]
    event = full["phase_event_capture_seconds"][args.event_index]
    rate, raw = wavfile.read(analysis["capture"], mmap=True)
    if rate != 192000 or raw.ndim != 1 or raw.dtype != np.int16:
        parser.error("expected the real mono S16/192000 Hz D10 capture")
    tone = analysis["requested_tone_hz"]
    lo, hi = event - 0.01, event + 0.01
    windows = {"before": (lo - 0.12, lo - 0.02), "event": (lo, hi),
               "after": (hi + 0.02, hi + 0.12)}

    def samples(start, stop):
        indices = np.arange(round(start * rate), round(stop * rate))
        return indices, raw[indices].astype(np.float64) / 32768

    def fit(interval):
        indices, values = samples(*interval)
        angle = 2 * np.pi * tone * indices / rate
        basis = np.c_[np.cos(angle), np.sin(angle), np.ones(len(indices))]
        coefficients = np.linalg.lstsq(basis, values, rcond=None)[0]
        carrier = complex(coefficients[0], -coefficients[1])
        return coefficients, carrier

    reference, before_carrier = fit(windows["before"])
    _, after_carrier = fit(windows["after"])
    report = {
        "capture": analysis["capture"], "tone_hz": tone,
        "event_capture_seconds": event, "qualification_changed": False,
        "original_full_interval_phase_events": full["phase_step_over_035rad_count"],
        "original_full_interval_max_phase_step_rad": full["phase_step_max_rad"],
        "after_minus_before_carrier_phase_rad": float(np.angle(after_carrier / before_carrier)),
        "after_over_before_carrier_amplitude_db": db_power(abs(after_carrier / before_carrier) ** 2),
        "method": "100 ms cosine/sine/DC least-squares carrier fits before/after a20 ms event window, separated by20 ms guards. Residuals subtract the pre-event fitted carrier. Welch residual band powers use1920-sample segments. Diagnostic demodulation blocks align with the original analyzer origin; no qualification threshold changes.",
        "windows": {}, "diagnostic_demodulation": {},
        "limits": "No persistent phase step supports—but does not prove—an additive transient. A brief timing excursion may cancel. Neither the transient source nor playback-vs-capture causality is determined by this analysis alone."
    }
    bands = [(1000, 5000), (5000, 10000), (10000, 14000), (14000, 20000), (40000, 90000)]
    for name, interval in windows.items():
        indices, values = samples(*interval)
        angle = 2 * np.pi * tone * indices / rate
        residual = values - (reference[0] * np.cos(angle) +
                             reference[1] * np.sin(angle) + reference[2])
        frequency, power = signal.welch(residual, rate, nperseg=min(1920, len(residual)))
        df = frequency[1] - frequency[0]
        peaks = signal.find_peaks(power)[0]
        peaks = peaks[np.argsort(power[peaks])[-8:][::-1]]
        report["windows"][name] = {
            "capture_seconds": interval,
            "residual_rms_dbfs": db_power(np.var(residual)),
            "residual_bands_dbfs": {
                f"{a}_{b}_hz": db_power(np.sum(power[(frequency >= a) & (frequency < b)]) * df)
                for a, b in bands},
            "strongest_residual_peaks_hz": frequency[peaks].tolist(),
        }
    origin = round(full["analyzed_start_seconds"] * rate)
    for seconds in (0.00025, 0.001, 0.002):
        block = round(seconds * rate)
        first = origin + int(np.floor((lo * rate - origin) / block)) * block
        count = int(np.ceil((hi * rate - first) / block))
        indices = np.arange(first, first + count * block)
        values = raw[indices].astype(np.float64) / 32768
        window = signal.windows.hann(block, sym=False)
        baseband = (values * np.exp(-2j * np.pi * tone * indices / rate)).reshape(-1, block)
        carrier = 2 * np.sum(baseband * window, axis=1) / window.sum()
        normalized = carrier / before_carrier
        phase = np.angle(normalized)
        report["diagnostic_demodulation"][f"{seconds * 1e6:g}_us"] = {
            "amplitude_ratio_range": [float(abs(normalized).min()), float(abs(normalized).max())],
            "phase_rad_range": [float(phase.min()), float(phase.max())],
            "max_adjacent_phase_step_rad": float(abs(np.diff(np.unwrap(phase))).max()),
        }
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
