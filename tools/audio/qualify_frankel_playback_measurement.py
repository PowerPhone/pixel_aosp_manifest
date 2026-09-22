#!/usr/bin/env python3
"""Gate real D10 acoustic evidence; a clean short prefix is not a full run.

Consumes analyze_frankel_playback_tone.py output. At 4/12/12.037 kHz the entire
requested interval must be present and free of measured discontinuities.
Above 48 kHz, broadband microphone noise can prevent envelope/phase analysis;
the narrower gate proves only a recorded intended-frequency component, not
its airborne origin versus electrical coupling in an on-device self-loop.
"""
from __future__ import annotations

import argparse
import json
import math
from pathlib import Path


def finite_number(value):
    return isinstance(value, (int, float)) and math.isfinite(value)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("analysis", type=Path)
    parser.add_argument("--tone", type=int, choices=(4000, 12000, 12037, 54283, 66547), required=True)
    parser.add_argument("--play-seconds", type=float, required=True)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    if not math.isfinite(args.play_seconds) or args.play_seconds <= 0:
        parser.error("--play-seconds must be finite and positive")
    checks = []

    def check(name, passed, observed, required):
        checks.append({"name": name, "pass": bool(passed),
                       "observed": observed, "required": required})

    try:
        analysis = json.loads(args.analysis.read_text())
        check("analysis_tone", analysis.get("requested_tone_hz") == args.tone,
              analysis.get("requested_tone_hz"), args.tone)
        contrast = analysis.get("tone_over_quiet_lead_db")
        check("intended_tone_over_quiet", finite_number(contrast) and contrast >= 10,
              contrast, ">=10 dB in intended-frequency band")
        intended_peaks = [peak["hz"] for peak in analysis.get("peaks", [])
                          if finite_number(peak.get("hz"))
                          and abs(peak["hz"] - args.tone) <= 2]
        check("intended_peak", bool(intended_peaks), intended_peaks,
              "a measured spectral peak within2 Hz of requested tone")
        if args.tone in (4000, 12000, 12037):
            full = analysis.get("full_active_interval", {})
            check("full_interval_measurable", full.get("measurable") is True,
                  full.get("measurable"), True)
            measured = full.get("analyzed_duration_seconds")
            minimum, maximum = args.play_seconds - 0.25, args.play_seconds + 0.25
            check("full_requested_duration", finite_number(measured)
                  and minimum <= measured <= maximum, measured,
                  {"minimum_seconds": minimum, "maximum_seconds": maximum,
                   "boundary_allowance_seconds": 0.25})
            for name in ("phase_step_over_035rad_count", "amplitude_dropout_blocks",
                         "clipped_samples"):
                check(name, full.get(name) == 0, full.get(name), 0)
            carrier = full.get("measured_carrier_peak_hz")
            check("full_interval_pitch", finite_number(carrier)
                  and abs(carrier - args.tone) <= 2, carrier,
                  "within2 Hz of requested tone")
    except (OSError, ValueError, TypeError, KeyError, AttributeError) as error:
        check("analysis_available", False, str(error), "readable complete tone analysis")

    report = {
        "pass": all(item["pass"] for item in checks),
        "analysis": str(args.analysis.resolve()),
        "requested_tone_hz": args.tone,
        "requested_playback_seconds": args.play_seconds,
        "qualification_scope": ("full-duration low-frequency acoustic continuity"
                                if args.tone < 48000 else
                                "intended high-frequency tone only; duration and jitter unqualified"),
        "checks": checks,
        "limits": "Does not replace HAL error checks or isolate airborne sound from electrical coupling. A single carrier cannot reveal slips by exact whole carrier cycles. High-frequency microphone noise is not speaker evidence.",
    }
    output = args.output or args.analysis.with_name("tone-qualification.json")
    output.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))
    return 0 if report["pass"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
