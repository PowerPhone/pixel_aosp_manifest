#!/usr/bin/env python3
"""Bounded Cubs API-test precondition after wake/unlock, not boot warm-up.

Read-only observations: require unlocked/not-transitioning keyguard, then a
500-ms span of consecutive native PCM-closed checks. Busy samples or a >250-ms
observation gap reset the span. This is not a hardware lease or permission to
ignore contention after launch. Never stops services or mutates firmware.
"""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import time


def wait_exclusive_pcm(adb, environment, output_dir):
    output_dir = Path(output_dir)
    output_dir.mkdir(parents=True, exist_ok=False)
    began = time.monotonic()
    deadline = began + 5
    observations = []
    stable_since = None
    last_idle = None
    unlocked = False
    passed = False
    failure = "five-second exclusive-PCM preflight deadline"

    def observe(kind, command):
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError(failure)
        started = time.monotonic()
        result = subprocess.run(adb + ["shell", command], env=environment,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                text=True, timeout=min(2, remaining))
        ended = time.monotonic()
        text = result.stdout.replace("\r", "")
        name = f"{len(observations):03d}-{kind}.txt"
        (output_dir / name).write_text(text)
        observations.append({"kind": kind, "start_ms": (started-began)*1000,
                             "end_ms": (ended-began)*1000, "exit_status": result.returncode,
                             "evidence": name})
        return result.returncode, text, ended

    def keyguard_finished():
        status, text, ended = observe("keyguard", "dumpsys activity activities")
        ready = status == 0 and all(re.search(r"^\s*" + key + r"=false\s*$", text, re.M)
                                    for key in ("mKeyguardShowing", "mAodShowing", "mKeyguardGoingAway"))
        observations[-1]["keyguard_transition_finished"] = bool(ready)
        return ready, ended

    try:
        while time.monotonic() < deadline:
            if not unlocked:
                unlocked, _ = keyguard_finished()
                stable_since = last_idle = None
                if not unlocked:
                    time.sleep(min(.05, max(0, deadline-time.monotonic())))
                    continue
            status, text, now = observe("pcm", "timeout 1 /vendor/bin/cubs_powerphone_boot --check-idle")
            idle = status == 0 and re.search(r"^CUBS_PCM_IDLE devices=\d+ streams=\d+ D5p=closed D10c=closed$", text, re.M)
            gap_ok = last_idle is None or now-last_idle <= .25
            if not idle or not gap_ok:
                stable_since = None
                last_idle = None
            if idle:
                if stable_since is None:
                    stable_since = now
                last_idle = now
            observations[-1].update(closed=bool(idle), observation_gap_ok=gap_ok,
                                    consecutive_closed_ms=0 if stable_since is None else (now-stable_since)*1000)
            if idle and now-stable_since >= .5:
                unlocked, _ = keyguard_finished()
                if not unlocked:
                    stable_since = last_idle = None
                    continue
                # Recheck closure after the final keyguard query; a queued UI
                # track during that read must not become a false idle result.
                status, text, now = observe("pcm-final", "timeout 1 /vendor/bin/cubs_powerphone_boot --check-idle")
                final_idle = status == 0 and re.search(r"^CUBS_PCM_IDLE devices=\d+ streams=\d+ D5p=closed D10c=closed$", text, re.M)
                final_gap_ok = now-last_idle <= .25
                observations[-1].update(closed=bool(final_idle), observation_gap_ok=final_gap_ok,
                                        consecutive_closed_ms=(now-stable_since)*1000)
                if final_idle and final_gap_ok:
                    passed = True
                    break
                stable_since = last_idle = None
            time.sleep(min(.05, max(0, deadline-time.monotonic())))
    except Exception as error:
        failure = str(error)
    result = {"status": "PASS" if passed else "FAIL", "purpose": "exclusive-PCM API-test precondition, not boot warm-up",
              "timeout_seconds": 5, "minimum_consecutive_closed_ms": 500, "maximum_observation_gap_ms": 250,
              "elapsed_ms": (time.monotonic()-began)*1000, "failure": None if passed else failure,
              "observations": observations,
              "limits": "Sampled closure is not an ownership lease; later HAL errors and existing failures remain failures. No service, property, mixer or firmware changes."}
    (output_dir / "preflight.json").write_text(json.dumps(result, indent=2)+"\n")
    if not passed:
        raise RuntimeError("Cubs exclusive-PCM preflight failed: " + failure)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--adb", required=True)
    parser.add_argument("--adb-server-port", type=int)
    parser.add_argument("--serial")
    parser.add_argument("--output-dir", required=True, type=Path)
    args = parser.parse_args()
    adb = [args.adb]
    if args.adb_server_port is not None:
        adb += ["-P", str(args.adb_server_port)]
    if args.serial:
        adb += ["-s", args.serial]
    wait_exclusive_pcm(adb, dict(os.environ), args.output_dir)
    print("Cubs exclusive-PCM precondition met: keyguard finished; at least 500 ms consecutive closed observations.")


if __name__ == "__main__":
    main()
