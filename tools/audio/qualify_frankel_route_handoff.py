#!/usr/bin/env python3
"""Gate fresh real-device route-handoff logs; retain planned acoustic segments.

This is NOT an acoustic qualification. The continuous WAV intentionally has
three handoff gaps; do not run a single-tone/full-interval dropout gate on it.
"""
import argparse
from decimal import Decimal
import json
from pathlib import Path
import re


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path)
    args = parser.parse_args()
    folder = args.directory
    run_id = (folder / "run-id.txt").read_text().strip()
    session = (folder / "session.txt").read_text()
    live = (folder / "aoc-app-live.log").read_text(errors="replace")
    archived = (folder / "logcat.txt").read_text(errors="replace")
    marker = re.compile(r"PowerPhoneHandoff: BEGIN run=" + re.escape(run_id) +
                        r" segment=(\d) rate=(\d+) tone=(\d+) address=(\S*) launch_ns=(\d+)")
    # Prefer a fully bookended single log; never count duplicated completions
    # from concatenated live and archived copies.
    end_marker = "PowerPhoneHandoff: END run=" + run_id
    logs = archived if len(list(marker.finditer(archived))) == 4 and end_marker in archived else live
    markers = list(marker.finditer(logs))
    errors = []
    live_markers = list(marker.finditer(live))
    if [m[1] for m in live_markers] != ["1", "2", "3", "4"]:
        errors.append("live log reader did not retain four ordered current-run BEGIN markers")
    if re.search(r"Invalid filter expression|logcat:.*(?:error|failed)", live, re.I):
        errors.append("live logcat reported a reader/filter error")
    if len(markers) != 4 or [m[1] for m in markers] != ["1", "2", "3", "4"]:
        errors.append("four ordered current-run markers missing or duplicated")
    if end_marker not in logs:
        errors.append("current-run END log marker missing")
    if "app_launch_status=0 capture_status=0" not in session:
        errors.append("remote foreground session did not complete successfully")
    capture_match = re.search(r"^capture_begin ([0-9.]+)$", session, re.M)
    capture_ns = int(Decimal(capture_match[1]) * 1000000000) if capture_match else None
    if capture_ns is None:
        errors.append("capture start marker missing")
    segments = []
    previous_launch_ns = None
    for index, match in enumerate(markers):
        end = markers[index + 1].start() if index + 1 < len(markers) else len(logs)
        text = logs[match.start():end]
        number, rate, tone = map(int, match.group(1, 2, 3))
        launch_ns = int(match[5])
        interval = (launch_ns - previous_launch_ns) / 1e9 if previous_launch_ns else None
        previous_launch_ns = launch_ns
        local_errors = []
        begins = [line for line in text.splitlines() if "STOCK_PLAYBACK_BEGIN " in line]
        complete = [line for line in text.splitlines() if "STOCK_PLAYBACK_COMPLETE " in line]
        results = [line for line in text.splitlines() if "STOCK_PLAYBACK_RESULT " in line]
        if len(begins) != 1 or f"rate={rate} " not in begins[0] or f"tone_hz={tone} " not in begins[0]:
            local_errors.append("one matching playback start required")
        if match[4] and (not begins or "address=" + match[4] not in begins[0]):
            local_errors.append("requested BUS address not confirmed")
        if len(complete) != 1 or len(results) != 1:
            local_errors.append("one result and one fresh completion required")
        if results and (f"written_frames={rate * 5} " not in results[0] or
                        f"played_frames={rate * 5} " not in results[0]):
            local_errors.append("five-second submitted/presented frame target not reached")
        if re.search(r"STOCK_PLAYBACK_FAILED|STOCK_REFERENCE_BEGIN|underruns=[1-9]", text):
            local_errors.append("application failure, underrun, or unexpected reference capture")
        if interval is not None and not 5.9 <= interval <= 6.75:
            local_errors.append("launch spacing outside6s target plus bounded force-stop overhead")
        offset = (launch_ns - capture_ns) / 1e9 if capture_ns is not None else None
        segments.append({"segment": number, "rate": rate, "tone_hz": tone,
                         "address": match[4] or "ordinary-speaker", "launch_ns": launch_ns,
                         "launch_from_capture_marker_seconds": offset,
                         "previous_launch_interval_seconds": interval,
                         "requested_tone_seconds": 5, "transport_log_pass": not local_errors,
                         "errors": local_errors,
                         "suggested_acoustic_window_seconds": [max(0, offset - 0.8), offset + 5.7]
                         if offset is not None else None})
        (folder / f"segment-{number}.log").write_text(text)
        errors.extend(f"segment{number}: {reason}" for reason in local_errors)
    fault = re.compile(r"AHAL_Powerphone.*(?:PCM ring write failed|integrity fail|refusing invalid|"
                       r"ownership mismatch|ownership drifted|skipping speaker hard-off|"
                       r"skipping mixer restore|failed: status)|"
                       r"AudioStreamOutSink.*Error while writing data to HAL|"
                       r"(?:pcm_open failed|Device or resource busy|getPresentationPosition.*Failed)")
    fault_lines = sorted(set(line for line in (live + "\n" + archived).splitlines() if fault.search(line)))
    (folder / "hal-playback-errors.txt").write_text("\n".join(fault_lines) + ("\n" if fault_lines else ""))
    if fault_lines:
        errors.append(f"{len(fault_lines)} unique HAL/ownership/integrity error lines")
    report = {"run_id": run_id, "transport_and_handoff_log_pass": not errors,
              "acoustic_qualification": "PENDING", "errors": errors, "segments": segments,
              "acoustic_analysis_plan": "Use each recorded launch anchor to isolate its five-second tone with preceding quiet gap; refine onset/offset acoustically and measure all internal phase/amplitude events. Require12037Hz for BUS and12000Hz for ordinary segments. Do not treat intentional inter-segment quiet as dropouts. Timestamp windows are capture-start approximations, not proven acoustic boundaries."}
    (folder / "handoff-qualification.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))
    return 0 if not errors else 1


if __name__ == "__main__":
    raise SystemExit(main())
