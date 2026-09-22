#!/usr/bin/env python3
"""Deliver Frankel PCM0/D0 periods directly from its 2.5 ms hrtimer.

The exact input module already gives only PCM device 0 a synthetic 480-frame
position clock while all other PCM devices retain stock AoC-counter progress.
Its D0-only cave currently rejoins ``aoc_pcm_irq_process`` immediately before
the stock ``queue_work_on()`` path.  Replace that cave tail with a direct call
to ``aoc_pcm_period_work_handler(&alsa_stream->period_work)`` and then return
through the stock IRQ-process epilogue.  The handler in turn calls
``snd_pcm_period_elapsed()``.

This removes one workqueue enqueue/dequeue per D0 period without changing the
timer, logical position, AoC ring counters, or any non-D0 stream.  The local
BL is relocation-free.  Its target and return branch are tied to this one
reviewed, unstripped Frankel module build.
"""

from __future__ import annotations

import argparse
import hashlib
import os
import pathlib
import stat
import tempfile


BASE_SHA256 = "1ce8ca36e915d5c3cd05d5e5f731f5374caf9f4c349111dadb01c4ed684f84e2"
PATCHED_SHA256 = "cc82b4ebdd4b5f758c7ebc7fd1d58d4264e1fc54b68b52e3761a6590c160513c"
OFFSET = 0xDA70

# At .text+0x6a70, reached only through the prior PCM-device-zero selector:
#
#   stock delivery:  b 0x13154; nop; nop
#   direct delivery: add x0,x19,#0x1b0       // &alsa_stream->period_work
#                    bl  0x12e1c             // aoc_pcm_period_work_handler
#                    b   0x13168              // stock irq-process epilogue
#
# aoc_pcm_period_work_handler subtracts 0x1a8 from x0 and loads the substream
# at alsa_stream+8, exactly matching queue_work_on's stock +0x1b0 work pointer.
WORKQUEUE = bytes.fromhex("b93100141f2003d51f2003d5")
DIRECT = bytes.fromhex("60c20691ea300094bc310014")


def digest(data: bytes | bytearray) -> str:
    return hashlib.sha256(data).hexdigest()


def classify(data: bytes | bytearray) -> str:
    observed = bytes(data[OFFSET : OFFSET + len(WORKQUEUE)])
    sha = digest(data)
    if observed == WORKQUEUE and sha == BASE_SHA256:
        return "d0-workqueue-period"
    if observed == DIRECT and sha == PATCHED_SHA256:
        return "d0-direct-period-elapsed"
    raise ValueError(
        f"unexpected module sha256={sha}; site@0x{OFFSET:x}={observed.hex()}"
    )


def transform(data: bytearray, wanted: str) -> None:
    current = classify(data)
    if current == wanted:
        return
    before, after = (
        (WORKQUEUE, DIRECT)
        if wanted == "d0-direct-period-elapsed"
        else (DIRECT, WORKQUEUE)
    )
    if bytes(data[OFFSET : OFFSET + len(before)]) != before:
        raise ValueError("guard mismatch at D0 period-delivery cave tail")
    data[OFFSET : OFFSET + len(before)] = after
    if classify(data) != wanted:
        raise AssertionError("post-patch classification failed")


def write_atomic(path: pathlib.Path, data: bytes, mode: int) -> None:
    if path.is_symlink() or (path.exists() and not path.is_file()):
        raise ValueError(f"refusing unsafe output: {path}")
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.chmod(temporary, stat.S_IMODE(mode))
        os.replace(temporary, path)
    except BaseException:
        pathlib.Path(temporary).unlink(missing_ok=True)
        raise


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input", type=pathlib.Path)
    parser.add_argument("output", type=pathlib.Path, nargs="?")
    parser.add_argument(
        "--check",
        choices=("d0-workqueue-period", "d0-direct-period-elapsed"),
    )
    parser.add_argument(
        "--set-state",
        choices=("d0-workqueue-period", "d0-direct-period-elapsed"),
        default="d0-direct-period-elapsed",
    )
    args = parser.parse_args()

    if args.input.is_symlink() or not args.input.is_file():
        raise ValueError(f"unsafe input: {args.input}")
    data = bytearray(args.input.read_bytes())
    current = classify(data)
    if args.check:
        if args.output is not None:
            parser.error("OUTPUT is incompatible with --check")
        if current != args.check:
            raise ValueError(f"module is {current}, expected {args.check}")
        print(f"verified {args.input} is {current}")
        return 0
    if args.output is None:
        parser.error("OUTPUT is required when patching")

    transform(data, args.set_state)
    write_atomic(args.output, bytes(data), args.input.stat().st_mode)
    print(f"wrote {args.set_state} {args.output} ({digest(data)})")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError) as error:
        print(f"error: {error}", file=__import__("sys").stderr)
        raise SystemExit(2)
