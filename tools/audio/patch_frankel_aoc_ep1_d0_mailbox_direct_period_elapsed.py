#!/usr/bin/env python3
"""Deliver Frankel PCM0/D0's real mailbox periods without a workqueue hop.

The exact input module retains the stock AoC mailbox ISR and clamps only D0's
hardware-reported Rx counter to at most one real period per notification.  On
the period-ready path this transform sends PCM device 0 directly through
``aoc_pcm_period_work_handler(&alsa_stream->period_work)``; that small handler
calls ``snd_pcm_period_elapsed()``.  Non-D0 devices branch back to the exact
stock workqueue path.

No timer, prefill, synthetic position, ring availability, or AoC counter is
changed.  The code cave is a relocation-free arm64 LL/SC fallback tail that
is unreachable on Frankel's LSE-capable CPU.  Both branches and the local BL
are tied to this one reviewed module build.
"""

from __future__ import annotations

import argparse
import hashlib
import os
import pathlib
import stat
import tempfile


BASE_SHA256 = "fc990edad9b77b2bb96cd222f6a07503dc12247804c498a769d0436b5cb61cd0"
PATCHED_SHA256 = "fe401845555d26edc29128d544265bf27b537ba7bdaabe8fd50dfa4b658be928"

PATCHES = (
    (
        0xDA64,
        bytes.fromhex("497d5f882905001149fd0b88abffff35bf3b03d5d9ffff17"),
        bytes.fromhex("68f240b9a838063560c20691eb300094bd3100141f2003d5"),
        "D0 selector and synchronous period-handler cave",
    ),
    (
        0x1A164,
        bytes.fromhex("cd000054"),
        bytes.fromhex("0dc8f954"),
        "route period-ready path through D0 delivery selector",
    ),
)


def digest(data: bytes | bytearray) -> str:
    return hashlib.sha256(data).hexdigest()


def classify(data: bytes | bytearray) -> str:
    observed = tuple(bytes(data[o : o + len(a)]) for o, a, _b, _n in PATCHES)
    base = tuple(a for _o, a, _b, _n in PATCHES)
    patched = tuple(b for _o, _a, b, _n in PATCHES)
    sha = digest(data)
    if observed == base and sha == BASE_SHA256:
        return "d0-mailbox-workqueue"
    if observed == patched and sha == PATCHED_SHA256:
        return "d0-mailbox-direct-period-elapsed"
    raise ValueError(
        f"unexpected module sha256={sha}; sites={[part.hex() for part in observed]}"
    )


def transform(data: bytearray, wanted: str) -> None:
    current = classify(data)
    if current == wanted:
        return
    for offset, base, patched, description in PATCHES:
        before, after = (
            (base, patched)
            if wanted == "d0-mailbox-direct-period-elapsed"
            else (patched, base)
        )
        if bytes(data[offset : offset + len(before)]) != before:
            raise ValueError(f"guard mismatch at 0x{offset:x}: {description}")
        data[offset : offset + len(before)] = after
        print(f"patched 0x{offset:x}: {description}")
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
        choices=(
            "d0-mailbox-workqueue",
            "d0-mailbox-direct-period-elapsed",
        ),
    )
    parser.add_argument(
        "--set-state",
        choices=(
            "d0-mailbox-workqueue",
            "d0-mailbox-direct-period-elapsed",
        ),
        default="d0-mailbox-direct-period-elapsed",
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
