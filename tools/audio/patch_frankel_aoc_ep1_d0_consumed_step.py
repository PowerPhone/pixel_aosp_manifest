#!/usr/bin/env python3
"""Step Frankel D0's reported ring consumption by at most one ALSA period.

At 192 kHz AoC can advance ``audio_playback0``'s 15,360-byte read counter by
one complete ALSA buffer before the 1 ms host timer observes it.  The stock
position becomes zero modulo the buffer, so ALSA cannot distinguish progress
from no progress.  This exact-module transform changes only D0: each poll
reports ``min(actual_consumed, previous_reported + period_bytes)``.  Repeated
polls therefore expose a full-ring jump as four real, bounded period steps and
then stop exactly at the hardware counter.  The D0 cave reloads the previous
counter after the stock wrap diagnostic (whose printk may clobber registers),
so counter wrap and every non-D0 stream retain the original accounting paths.

The two small selectors occupy arm64 LL/SC alternative tails that are
unreachable on Frankel's LSE-capable CPU.  Patched bytes contain no relocation
sites.  Input must be the exact pure-timer trial named by ``BASE_SHA256``.
"""

from __future__ import annotations

import argparse
import hashlib
import os
import pathlib
import stat
import tempfile


BASE_SHA256 = "053900e08ffb5fb62ce7b4929f3bf6ef1db3d66991d4824ee37a008563f5f42f"
PATCHED_SHA256 = "4e1be77f4e60596e0e16a64dc448cb201b0f297b2b79efab6aec50049a89b129"

PATCHES = (
    (
        0xD680,
        bytes.fromhex("287d5f880805001128fd0a88aaffff35bf3b03d5caffff17"),
        bytes.fromhex("68f240b968000034e10315aaaf32001462a640f904000014"),
        "D0 selector, previous-counter reload, and non-D0 return cave",
    ),
    (
        0xD6A4,
        bytes.fromhex("287d5f880805001128fd0a88aaffff35bf3b03d5cfffff17"),
        bytes.fromhex("692241b94a40298bbf020aeb5581959ae10315aaa4320014"),
        "one-period min(actual, previous+period) cave",
    ),
    (
        0x1A144,
        bytes.fromhex("e10315aa"),
        bytes.fromhex("4fcdff17"),
        "redirect normal consumed-counter path",
    ),
)


def digest(data: bytes | bytearray) -> str:
    return hashlib.sha256(data).hexdigest()


def classify(data: bytes | bytearray) -> str:
    seen = tuple(bytes(data[o:o + len(a)]) for o, a, _b, _d in PATCHES)
    stock = tuple(a for _o, a, _b, _d in PATCHES)
    patched = tuple(b for _o, _a, b, _d in PATCHES)
    sha = digest(data)
    if seen == stock and sha == BASE_SHA256:
        return "stock"
    if seen == patched and sha == PATCHED_SHA256:
        return "d0-consumed-step"
    raise ValueError(f"unexpected module sha256={sha}; sites={[x.hex() for x in seen]}")


def transform(data: bytearray, wanted: str) -> None:
    current = classify(data)
    if current == wanted:
        return
    for offset, stock, patched, description in PATCHES:
        before, after = ((stock, patched) if wanted == "d0-consumed-step"
                         else (patched, stock))
        if bytes(data[offset:offset + len(before)]) != before:
            raise ValueError(f"guard mismatch at 0x{offset:x}: {description}")
        data[offset:offset + len(before)] = after
        print(f"patched 0x{offset:x}: {description}")
    if classify(data) != wanted:
        raise AssertionError("post-patch classification failed")


def atomic_write(path: pathlib.Path, data: bytes, mode: int) -> None:
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
    parser.add_argument("--check", choices=("stock", "d0-consumed-step"))
    parser.add_argument("--set-state", choices=("stock", "d0-consumed-step"),
                        default="d0-consumed-step")
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
