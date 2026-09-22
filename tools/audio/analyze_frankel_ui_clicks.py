#!/usr/bin/env python3
"""Measure real UI-click sound, not merely API dispatch, in an untouched D10 WAV.

Input: --session with `capture_begin <epoch seconds>`, and --events containing
PowerPhoneEffects PLAY_SOUND_EFFECT_CALL lines with run_id, epoch_ms and index.
Use separate cold/warm recordings or select --run-id. Reports band energy and
optional correlation against the actual installed Effect_Tick.ogg. It never
labels requested clicks or these metrics alone as audible playback PASS.
Use the actual tick's dominant100–2000 Hz band, with independent100–18000 Hz
metrics. Earlier2–18 kHz reports excluded99.77% of this asset's source energy.
Requires NumPy/SciPy; optional OGG decoding uses installed libsndfile1.
"""
from __future__ import annotations

import argparse
import ctypes
import ctypes.util
from decimal import Decimal
import json
from pathlib import Path
import re

import numpy as np
from scipy import signal
from scipy.io import wavfile


def db(value):
    return float(10 * np.log10(max(float(value), 1e-30)))


def decode_source(path):
    class Info(ctypes.Structure):
        _fields_ = [("frames", ctypes.c_longlong), ("samplerate", ctypes.c_int),
                    ("channels", ctypes.c_int), ("format", ctypes.c_int),
                    ("sections", ctypes.c_int), ("seekable", ctypes.c_int)]
    library = ctypes.util.find_library("sndfile")
    if library is None:
        raise RuntimeError("source correlation requires the libsndfile1 package")
    decoder = ctypes.CDLL(library)
    decoder.sf_open.argtypes = [ctypes.c_char_p, ctypes.c_int, ctypes.POINTER(Info)]
    decoder.sf_open.restype = ctypes.c_void_p
    decoder.sf_readf_double.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_double), ctypes.c_longlong]
    decoder.sf_readf_double.restype = ctypes.c_longlong
    decoder.sf_close.argtypes = [ctypes.c_void_p]
    info = Info()
    handle = decoder.sf_open(str(path).encode(), 0x10, ctypes.byref(info))
    if not handle:
        raise RuntimeError(f"cannot decode actual source {path}")
    try:
        values = np.empty((info.frames, info.channels), dtype=np.float64)
        read = decoder.sf_readf_double(handle, values.ctypes.data_as(ctypes.POINTER(ctypes.c_double)), info.frames)
        if read != info.frames:
            raise RuntimeError("incomplete source decode")
        return info.samplerate, values.mean(axis=1)
    finally:
        decoder.sf_close(handle)


def matched_metrics(values, template):
    if template is None or values.size < template.size:
        return None
    dots = signal.correlate(values, template, mode="valid", method="fft")
    index = int(np.argmax(abs(dots)))
    cumulative = np.r_[0., np.cumsum(values * values)]
    energies = np.maximum(cumulative[template.size:] - cumulative[:-template.size], 1e-30)
    source_energy = float(template @ template)
    normalized = dots / np.sqrt(energies * source_energy)
    return {"best_projection_start_sample": index,
            "signed_normalized_correlation_at_best_projection": float(normalized[index]),
            "maximum_absolute_normalized_correlation": float(abs(normalized).max()),
            "source_projection_coefficient": float(dots[index] / source_energy)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("wav", type=Path)
    parser.add_argument("--session", type=Path, required=True)
    parser.add_argument("--events", type=Path, required=True)
    parser.add_argument("--source", type=Path)
    parser.add_argument("--run-id")
    parser.add_argument("--label", default="unspecified")
    parser.add_argument("--expected-clicks", type=int, default=8)
    parser.add_argument("--response-seconds", type=float, default=1.5)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    output = args.output or args.wav.with_suffix(".ui-clicks.json")
    if output.exists():
        parser.error("choose a new output path; prior measurements are never overwritten")
    session = args.session.read_text()
    begin = re.search(r"^capture_begin ([0-9.]+)$", session, re.M)
    if not begin:
        parser.error("missing capture_begin epoch marker")
    capture_epoch = Decimal(begin[1])
    rows = {}
    for line in args.events.read_text(errors="replace").splitlines():
        if "PLAY_SOUND_EFFECT_CALL " not in line:
            continue
        fields = dict(re.findall(r"(run_id|epoch_ms|index|elapsed_ns)=([^\s]+)", line))
        if all(key in fields for key in ("run_id", "epoch_ms", "index")):
            rows[(fields["run_id"], int(fields["index"]), fields["epoch_ms"])] = fields
    run_ids = sorted({key[0] for key in rows})
    run_id = args.run_id or (run_ids[0] if len(run_ids) == 1 else None)
    if run_id is None or run_id not in run_ids:
        parser.error("select one actual run with --run-id; found " + repr(run_ids))
    events = sorted((row for row in rows.values() if row["run_id"] == run_id), key=lambda r: int(r["epoch_ms"]))
    for event in events:
        event["capture_seconds"] = float(Decimal(event["epoch_ms"]) / 1000 - capture_epoch)
    rate, pcm = wavfile.read(args.wav, mmap=True)
    if rate != 192000 or pcm.dtype != np.int16 or pcm.ndim != 1:
        parser.error("expected actual mono S16/192000 Hz D10 capture")
    samples = pcm.astype(np.float64) / 32768
    end = re.search(r"^capture_end ([0-9.]+)$", session, re.M)
    # The foreground marker precedes PCM open. Bound its unknown startup
    # offset from actual elapsed time minus recorded sample duration, without
    # shifting any window to fit acoustic peaks. Include a50ms extra margin.
    capture_timing_excess = max(0., float(Decimal(end[1]) - capture_epoch) - len(samples) / rate) if end else 0.
    sos = signal.butter(4, [100, 2000], btype="bandpass", fs=rate, output="sos")
    wide_sos = signal.butter(4, [100, 18000], btype="bandpass", fs=rate, output="sos")
    filtered = signal.sosfiltfilt(sos, samples)
    wide_filtered = signal.sosfiltfilt(wide_sos, samples)
    quiet_start = round(.1 * rate)
    quiet_stop = round(min(1.1, events[0]["capture_seconds"] - .15) * rate)
    if quiet_stop - quiet_start < .2 * rate:
        parser.error("insufficient quiet lead before first click")
    quiet = filtered[quiet_start:quiet_stop]
    quiet_power = float(np.mean(quiet * quiet))
    wide_quiet = wide_filtered[quiet_start:quiet_stop]
    wide_quiet_power = float(np.mean(wide_quiet * wide_quiet))
    template = None
    wide_template = None
    source_info = None
    if args.source:
        source_rate, decoded = decode_source(args.source)
        divisor = int(np.gcd(source_rate, rate))
        # Resample only the known source template, never the recorded WAV.
        converted = signal.resample_poly(decoded, rate // divisor, source_rate // divisor)
        template = signal.sosfiltfilt(sos, converted)
        wide_template = signal.sosfiltfilt(wide_sos, converted)
        source_info = {"path": str(args.source.resolve()), "original_rate": source_rate,
                       "original_frames": len(decoded), "template_rate": rate,
                       "template_frames": len(template), "channel_operation": "stereo mean"}
    results = []
    block = round(.02 * rate)
    hop = round(.005 * rate)
    for i, event in enumerate(events):
        at = event["capture_seconds"]
        requested_end = at + args.response_seconds
        next_call = events[i + 1]["capture_seconds"] if i + 1 < len(events) else len(samples) / rate
        first = max(0, round((at - capture_timing_excess - .05) * rate))
        last = min(len(samples), round(min(requested_end, next_call - capture_timing_excess - .01) * rate))
        if last - first < block:
            parser.error("click response window is outside capture or overlaps its next request")
        values = filtered[first:last]
        starts = np.arange(0, len(values) - block + 1, hop)
        cumulative = np.r_[0., np.cumsum(values * values)]
        powers = (cumulative[starts + block] - cumulative[starts]) / block
        best = int(np.argmax(powers))
        correlation = matched_metrics(values, template)
        if correlation is not None:
            correlation["best_projection_delay_from_request_ms"] = 1000 * ((first + correlation["best_projection_start_sample"]) / rate - at)
            correlation["capture_start_uncertainty_adjusted_delay_range_ms"] = [correlation["best_projection_delay_from_request_ms"], correlation["best_projection_delay_from_request_ms"] + 1000 * capture_timing_excess]
        wide_values = wide_filtered[first:last]
        wide_cumulative = np.r_[0., np.cumsum(wide_values * wide_values)]
        wide_powers = (wide_cumulative[starts + block] - wide_cumulative[starts]) / block
        wide_best = int(np.argmax(wide_powers))
        wide_correlation = matched_metrics(wide_values, wide_template)
        if wide_correlation is not None:
            wide_correlation["best_projection_delay_from_request_ms"] = 1000 * ((first + wide_correlation["best_projection_start_sample"]) / rate - at)
        results.append({"index": int(event["index"]), "request_epoch_ms": event["epoch_ms"],
                        "request_capture_seconds": at,
                        "sample_bounds_start_inclusive_stop_exclusive": [first, last],
                        "response_window_seconds": [first / rate, last / rate],
                        "limited_by_next_click_or_capture_end": last / rate < requested_end,
                        "analysis_band_rms_dbfs": db(np.mean(values * values)),
                        "peak_20ms_band_rms_dbfs": db(powers[best]),
                        "peak_20ms_band_above_quiet_db": db(powers[best] / max(quiet_power, 1e-30)),
                        "peak_20ms_center_delay_from_request_ms": 1000 * ((first + starts[best] + block / 2) / rate - at),
                        "clipped_samples": int(np.sum(abs(samples[first:last]) > .999)),
                        "source_correlation": correlation,
                        "wideband_100_18000": {
                            "rms_dbfs": db(np.mean(wide_values * wide_values)),
                            "peak_20ms_rms_dbfs": db(wide_powers[wide_best]),
                            "peak_20ms_above_quiet_db": db(wide_powers[wide_best] / max(wide_quiet_power, 1e-30)),
                            "peak_20ms_center_delay_from_request_ms": 1000 * ((first + starts[wide_best] + block / 2) / rate - at),
                            "source_correlation": wide_correlation}})
    report = {"label": args.label, "run_id": run_id, "original_capture": str(args.wav.resolve()),
              "sample_rate": rate, "capture_epoch_marker": str(capture_epoch),
              "capture_end_minus_begin_minus_recorded_seconds": capture_timing_excess,
              "window_timing_rule": "Precursor includes measured marker elapsed minus WAV sample duration plus50ms; adjacent-request guard uses the same conservative bound. No waveform-based realignment. These markers cannot establish precise physical playback latency.",
              "events_path": str(args.events.resolve()), "session_path": str(args.session.resolve()),
              "requested_event_count": len(events), "expected_event_count": args.expected_clicks,
              "event_sequence_complete": [int(e["index"]) for e in events] == list(range(1, args.expected_clicks + 1)),
              "analysis_band_hz": [100, 2000], "quiet_sample_bounds": [quiet_start, quiet_stop],
              "quiet_analysis_band_rms_dbfs": db(quiet_power),
              "quiet_wideband_100_18000_rms_dbfs": db(wide_quiet_power),
              "source_template": source_info, "quiet_source_correlation": matched_metrics(quiet, template),
              "quiet_wideband_source_correlation": matched_metrics(wide_quiet, wide_template),
              "clicks": results, "audible_playback_pass": None,
              "limits": "Evidence metrics only, not PASS from API requests. Capture epoch precedes actual PCM sampling, so absolute delays include unknown capture-start offset and millisecond click timestamp quantization. Nearby acoustic noise can raise band energy; speaker/acoustic filtering can reduce source correlation. A response delayed beyond the next click is ambiguous and is explicitly window-limited. Original capture is never modified or resampled."}
    output.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
