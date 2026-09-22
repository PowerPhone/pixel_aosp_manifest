#!/usr/bin/env python3
"""Analyze all four planned tones from an actual continuous handoff recording.

Copy exact PCM sample intervals, without resampling or changing the original
WAV. Each launch gets its predetermined -0.8..+5.7 second window. Analyze the
whole detected tone and apply the existing five-second acoustic gate; never
choose a favorable subinterval. The fixed comparison FFT starts at the launch
anchor and extends to the planned window end, not the loudest two seconds.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import subprocess
import sys
import wave


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("run_directory", type=Path)
    parser.add_argument("--output-dir", type=Path)
    args = parser.parse_args()
    run = args.run_directory.resolve()
    qualification = json.loads((run / "handoff-qualification.json").read_text())
    segments = qualification["segments"]
    if len(segments) != 4 or [segment["segment"] for segment in segments] != [1, 2, 3, 4]:
        parser.error("four ordered segments with actual launch markers are required")
    output = args.output_dir or run / "acoustic-segments"
    output.mkdir(parents=True, exist_ok=False)
    tool_directory = Path(__file__).resolve().parent
    source = run / "capture.wav"
    results = []
    with wave.open(str(source), "rb") as recorded:
        params = recorded.getparams()
        if (params.nchannels, params.sampwidth, params.framerate, params.comptype) != (1, 2, 192000, "NONE"):
            parser.error("expected actual uncompressed mono S16/192000 Hz D10 WAV")
        for segment in segments:
            number = segment["segment"]
            tone = segment["tone_hz"]
            if tone != (12037 if number in (1, 3) else 12000):
                parser.error(f"unexpected planned tone for segment{number}")
            anchor = segment["launch_from_capture_marker_seconds"]
            first = max(0, round((anchor - 0.8) * params.framerate))
            planned_stop = round((anchor + 5.7) * params.framerate)
            stop = min(params.nframes, planned_stop)
            if stop <= first:
                parser.error(f"segment{number} lies outside captured PCM")
            local = output / f"segment-{number}"
            local.mkdir()
            copied = local / "capture.wav"
            recorded.setpos(first)
            pcm = recorded.readframes(stop - first)
            with wave.open(str(copied), "wb") as sliced:
                sliced.setparams(params)
                sliced.writeframes(pcm)
            bounds = {
                "original_capture": str(source), "segment": number,
                "run_id": qualification["run_id"], "requested_tone_hz": tone,
                "requested_playback_seconds": 5,
                "original_sample_bounds_start_inclusive_stop_exclusive": [first, stop],
                "original_capture_window_seconds": [first / params.framerate, stop / params.framerate],
                "launch_from_capture_marker_seconds": anchor,
                "launch_in_copied_window_seconds": anchor - first / params.framerate,
                "planned_capture_window_complete": stop == planned_stop,
                "resampled": False, "original_modified": False,
                "selection": "Fixed recorded-launch anchor minus0.8s through plus5.7s; no acoustic-energy-based interval selection. Intentional handoff gaps are outside each required five-second active tone.",
            }
            (local / "sample-bounds.json").write_text(json.dumps(bounds, indent=2) + "\n")
            comparison_start = anchor - first / params.framerate
            comparison_duration = (stop - first) / params.framerate - comparison_start
            command = [sys.executable, str(tool_directory / "analyze_frankel_playback_tone.py"),
                       str(copied), "--tone", str(tone), "--start", str(comparison_start),
                       "--duration", str(comparison_duration), "--output-dir", str(local)]
            with (local / "analysis.log").open("w") as log:
                analysis_status = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT).returncode
            command = [sys.executable, str(tool_directory / "qualify_frankel_playback_measurement.py"),
                       str(local / "tone-analysis.json"), "--tone", str(tone), "--play-seconds", "5"]
            with (local / "qualification.log").open("w") as log:
                gate_status = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT).returncode
            passed = analysis_status == 0 and gate_status == 0 and stop == planned_stop
            results.append({"segment": number, "address": segment["address"],
                            "tone_hz": tone, "acoustic_pass": passed,
                            "analysis_exit": analysis_status, "qualification_exit": gate_status,
                            "sample_bounds": str(local / "sample-bounds.json"),
                            "tone_qualification": str(local / "tone-qualification.json")})
            print(f"segment{number} {tone}Hz acoustic_pass={passed}", flush=True)
    acoustic_pass = all(item["acoustic_pass"] for item in results)
    transport_pass = qualification["transport_and_handoff_log_pass"]
    report = {"run_id": qualification["run_id"], "original_capture": str(source),
              "transport_and_handoff_log_pass": transport_pass,
              "all_four_segments_acoustic_pass": acoustic_pass,
              "pass": transport_pass and acoustic_pass, "segments": results,
              "limits": "Windows follow execution markers, which precede actual acoustic onset; inspect all detected boundaries. A too-late app onset or prior tone intruding into the quiet lead can invalidate a window, never justify silently shortening the required tone. Existing thresholds and the original transport report are unchanged."}
    (output / "handoff-acoustic-qualification.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))
    return 0 if report["pass"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
