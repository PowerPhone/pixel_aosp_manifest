#!/usr/bin/env python3
"""Retain one real D0 period as an ALSA playback startup cushion.

At 192 kHz the Frankel ``audio_playback0`` AoC ring holds exactly one
1,920-frame stereo-S32 period (15,360 bytes).  ALSA therefore reaches XRUN as
soon as AoC consumes the first physical ring: the hardware pointer catches the
application pointer before a second physical-ring write can be submitted.

This exact-module transform is applied on top of the clean D0 hybrid
real-progress profile.  It changes the D0 counter result from::

    min(actual_rx, previous_report + period_bytes)

to::

    max(previous_report, actual_rx - period_bytes)

The first real period is consequently retained as a reporting cushion.  Once
AoC has consumed it, the physical ring is empty while ALSA still exposes one
logical period of write space; userspace can enqueue the second ring without
an XRUN.  Thereafter every reported byte remains backed by AoC's cumulative
Rx counter and the reported position stays exactly one configured period
behind it.  No ring-availability bypass or synthetic clock is introduced.

This is deliberately limited to PCM0 by the existing D0 selector.  It is
intended for a 1,920-frame period, two-period ALSA buffer, and 1,920-frame
start threshold.  The final physical period must be allowed to play before
STOP because ALSA position intentionally trails it.
"""

from __future__ import annotations

import argparse
import hashlib
import os
import pathlib
import stat
import tempfile


BASE_SHA256 = "14f768697dfdce17869d91360da54ab9e4f7b8d291e718ff8919f524e7010e98"
PATCHED_SHA256 = "37cc7ff81bf9804677699d612621ed75a177597e773709ec54924916811818e6"

BASE_STATE = "d0-hybrid-real-progress"
PATCHED_STATE = "d0-hybrid-one-period-lag"

PATCHES = (
    (
        0xD6A4,
        bytes.fromhex(
            "692241b9 4a40298b bf020aeb 5581959a e10315aa a4320014"
        ),
        bytes.fromhex(
            "692241b9 4a40298b a1020aeb 4100018b 4190819a a4320014"
        ),
        "D0 max(previous, actual minus one period) counter cave",
    ),
    (
        0x1A148,
        bytes.fromhex("75a600f9"),
        bytes.fromhex("61a600f9"),
        "store lagged x1 result as previous consumed counter",
    ),
)


def digest(data: bytes | bytearray) -> str:
    return hashlib.sha256(data).hexdigest()


def site_state(data: bytes | bytearray) -> str:
    actual = tuple(
        bytes(data[offset : offset + len(base)])
        for offset, base, _patched, _description in PATCHES
    )
    base = tuple(base for _offset, base, _patched, _description in PATCHES)
    patched = tuple(
        patched for _offset, _base, patched, _description in PATCHES
    )
    if actual == base:
        return BASE_STATE
    if actual == patched:
        return PATCHED_STATE
    raise ValueError(
        "mixed or unknown guarded sites: "
        f"{[value.hex() for value in actual]}"
    )


def classify(data: bytes | bytearray) -> str:
    state = site_state(data)
    expected = BASE_SHA256 if state == BASE_STATE else PATCHED_SHA256
    observed = digest(data)
    if expected != "TO_BE_FILLED" and observed != expected:
        raise ValueError(
            f"unexpected {state} whole-file SHA-256: {observed}, "
            f"expected {expected}"
        )
    return state


def transform(data: bytearray, wanted: str) -> None:
    current = classify(data)
    if current == wanted:
        return
    if wanted not in (BASE_STATE, PATCHED_STATE):
        raise ValueError(f"unsupported state: {wanted}")
    for offset, base, patched, description in PATCHES:
        before, after = (
            (base, patched) if wanted == PATCHED_STATE else (patched, base)
        )
        if bytes(data[offset : offset + len(before)]) != before:
            raise ValueError(f"guard mismatch at 0x{offset:x}: {description}")
        data[offset : offset + len(before)] = after
        print(f"patched 0x{offset:x}: {description}")
    if site_state(data) != wanted:
        raise AssertionError("post-patch site classification failed")


def atomic_write(path: pathlib.Path, data: bytes, mode: int) -> None:
    if path.is_symlink() or (path.exists() and not path.is_file()):
        raise ValueError(f"refusing unsafe output: {path}")
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(
        prefix=f".{path.name}.", dir=path.parent
    )
    try:
        with os.fdopen(descriptor, "wb") as stream:
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
    parser.add_argument("--check", choices=(BASE_STATE, PATCHED_STATE))
    parser.add_argument(
        "--set-state",
        choices=(BASE_STATE, PATCHED_STATE),
        default=PATCHED_STATE,
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
    atomic_write(args.output, bytes(data), args.input.stat().st_mode)
    print(f"wrote {args.set_state} {args.output} ({digest(data)})")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError) as error:
        print(f"error: {error}", file=__import__("sys").stderr)
        raise SystemExit(2)
