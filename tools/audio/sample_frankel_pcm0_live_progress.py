#!/usr/bin/env python3
"""Bounded live PCM0/AoC progress sampler for Frankel speaker canaries.

Start this program just before a PCM0 tinyplay canary.  A single device-side
shell waits for PCM0's dynamically-created procfs status node, then samples
its state and pointers at nominal +20/+50/+100/+150 ms.  After the last status
sample it reads the
speaker TX and RX RingBuffer descriptors through the already-installed native
AoC diagnostic helper.  The helper and this program are read-only.

The device uptime printed with every sample is authoritative; the nominal
labels intentionally do not hide shell/procfs scheduling latency.
"""

from __future__ import annotations

import argparse
import os
import pathlib
import re
import subprocess
import sys


EXPECTED_DEVICE = "frankel"
PCM_STATUS = "/proc/asound/card0/pcm0p/sub0/status"
PCM_HW_PARAMS = "/proc/asound/card0/pcm0p/sub0/hw_params"
RESTART_COUNT = "/sys/devices/platform/9000000.aoc/restart_count"
COREDUMP_COUNT = "/sys/devices/platform/9000000.aoc/coredump_count"
TX_DESCRIPTOR = 0x4051CDA4
RX_DESCRIPTOR = 0x4051D524
DESCRIPTOR_BYTES = 28
DEFAULT_HELPER = "/data/local/tmp/frankel_aoc_diag"


def positive_int(value: str) -> int:
    parsed = int(value, 0)
    if parsed <= 0:
        raise argparse.ArgumentTypeError("value must be positive")
    return parsed


def absolute_device_path(value: str) -> str:
    if not re.fullmatch(r"/[A-Za-z0-9_./-]+", value):
        raise argparse.ArgumentTypeError(
            "helper must be an absolute device path containing only safe characters"
        )
    return value


def parse_args() -> argparse.Namespace:
    repository = pathlib.Path(__file__).resolve().parents[2]
    parser = argparse.ArgumentParser(
        description=(
            "wait for Frankel PCM0 to open, sample ALSA pointers through 150 ms, "
            "then dump the AoC speaker DMA descriptors"
        )
    )
    parser.add_argument(
        "--adb",
        type=pathlib.Path,
        default=repository / "work/toolchains/platform-tools/adb",
    )
    parser.add_argument("--adb-server-port", type=positive_int, default=5038)
    parser.add_argument("--serial")
    parser.add_argument(
        "--helper", type=absolute_device_path, default=DEFAULT_HELPER
    )
    parser.add_argument(
        "--wait-ms",
        type=positive_int,
        default=3000,
        help="maximum time to wait for PCM0 RUNNING (default: 3000)",
    )
    parser.add_argument(
        "--poll-ms",
        type=positive_int,
        default=5,
        help="RUNNING-state polling interval (default: 5)",
    )
    parser.add_argument(
        "--host-timeout-seconds",
        type=positive_int,
        default=12,
        help="hard host timeout for the complete remote sampler (default: 12)",
    )
    return parser.parse_args()


def remote_script(helper: str, wait_ms: int, poll_ms: int) -> str:
    poll_limit = (wait_ms + poll_ms - 1) // poll_ms
    poll_sleep = f"{poll_ms / 1000:.3f}"
    return f"""
pp_status={PCM_STATUS}
pp_hw_params={PCM_HW_PARAMS}
pp_restart={RESTART_COUNT}
pp_coredump={COREDUMP_COUNT}
pp_helper={helper}
pp_poll_limit={poll_limit}
pp_poll_sleep={poll_sleep}
pp_fail=0

pp_uptime() {{
    cut -d' ' -f1 /proc/uptime
}}

pp_counter() {{
    pp_counter_name=$1
    pp_counter_path=$2
    printf '%s=' "$pp_counter_name"
    if ! cat "$pp_counter_path"; then
        printf 'unreadable\n'
        pp_fail=1
    fi
}}

pp_status_sample() {{
    pp_nominal_ms=$1
    printf 'BEGIN_PCM_STATUS nominal_ms=%s uptime=' "$pp_nominal_ms"
    pp_uptime
    if ! cat "$pp_status"; then
        printf 'status_unreadable=%s\n' "$pp_status"
        pp_fail=1
    fi
    printf 'END_PCM_STATUS nominal_ms=%s uptime=' "$pp_nominal_ms"
    pp_uptime
}}

if [ "$(getprop ro.product.device)" != "{EXPECTED_DEVICE}" ]; then
    printf 'error=wrong_device actual=%s expected={EXPECTED_DEVICE}\n' \
        "$(getprop ro.product.device)"
    exit 64
fi
if [ ! -x "$pp_helper" ]; then
    printf 'error=missing_helper path=%s\n' "$pp_helper"
    exit 64
fi

printf 'sampler=frankel-pcm0-live-progress-v1 wait_begin_uptime='
pp_uptime
pp_counter restart_before "$pp_restart"
pp_counter coredump_before "$pp_coredump"

pp_iteration=0
pp_running=0
while [ "$pp_iteration" -lt "$pp_poll_limit" ]; do
    # Frankel creates this procfs node only while the substream is open.  Do
    # not require RUNNING: a broken no-progress path can remain PREPARED, and
    # observing that distinction is one purpose of this sampler.
    if [ -r "$pp_status" ]; then
        pp_running=1
        break
    fi
    sleep "$pp_poll_sleep"
    pp_iteration=$((pp_iteration + 1))
done
if [ "$pp_running" -ne 1 ]; then
    printf 'error=pcm0_never_opened polls=%s wait_end_uptime=' "$pp_iteration"
    pp_uptime
    pp_counter restart_after "$pp_restart"
    pp_counter coredump_after "$pp_coredump"
    exit 2
fi

printf 'pcm0_open_anchor_uptime='
pp_uptime
printf 'BEGIN_PCM_HW_PARAMS\n'
cat "$pp_hw_params" || pp_fail=1
printf 'END_PCM_HW_PARAMS\n'

sleep 0.020
pp_status_sample 20
sleep 0.030
pp_status_sample 50
sleep 0.050
pp_status_sample 100
sleep 0.050
pp_status_sample 150

printf 'descriptor_dump_begin_uptime='
pp_uptime
printf 'TX_DESCRIPTOR address=0x{TX_DESCRIPTOR:08x} bytes={DESCRIPTOR_BYTES} value='
if ! "$pp_helper" --core 2 dump 0x{TX_DESCRIPTOR:08x} {DESCRIPTOR_BYTES}; then
    printf 'ERROR\n'
    pp_fail=1
fi
printf 'RX_DESCRIPTOR address=0x{RX_DESCRIPTOR:08x} bytes={DESCRIPTOR_BYTES} value='
if ! "$pp_helper" --core 2 dump 0x{RX_DESCRIPTOR:08x} {DESCRIPTOR_BYTES}; then
    printf 'ERROR\n'
    pp_fail=1
fi
printf 'descriptor_dump_end_uptime='
pp_uptime
pp_counter restart_after "$pp_restart"
pp_counter coredump_after "$pp_coredump"
exit "$pp_fail"
""".lstrip()


def main() -> int:
    args = parse_args()
    adb = args.adb.resolve()
    if not adb.is_file():
        print(f"error: adb is not a file: {adb}", file=sys.stderr)
        return 2
    if args.adb_server_port > 65535:
        print("error: adb server port must be at most 65535", file=sys.stderr)
        return 2

    command = [str(adb), "-P", str(args.adb_server_port)]
    if args.serial:
        command += ["-s", args.serial]
    # The qualification image runs adbd as root.  A stdin-fed `sh` opens an
    # interactive Android shell on this build, so pass the generated script as
    # one argv value to `sh -c`; subprocess performs no host-shell expansion.
    command += [
        "exec-out",
        "sh",
        "-c",
        remote_script(args.helper, args.wait_ms, args.poll_ms),
    ]
    environment = os.environ.copy()
    environment["ADB_LIBUSB"] = "1"
    try:
        result = subprocess.run(
            command,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
            timeout=args.host_timeout_seconds,
            env=environment,
        )
    except subprocess.TimeoutExpired as error:
        if error.stdout:
            sys.stdout.buffer.write(error.stdout)
        if error.stderr:
            sys.stderr.buffer.write(error.stderr)
        print(
            f"error: live sampler exceeded {args.host_timeout_seconds}s host timeout",
            file=sys.stderr,
        )
        return 124

    sys.stdout.buffer.write(result.stdout)
    sys.stderr.buffer.write(result.stderr)
    if result.returncode:
        print(
            f"error: device-side live sampler exited {result.returncode}",
            file=sys.stderr,
        )
    return result.returncode


if __name__ == "__main__":
    raise SystemExit(main())
