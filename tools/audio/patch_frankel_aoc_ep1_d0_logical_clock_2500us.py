#!/usr/bin/env python3
"""Drive Frankel D0's ALSA position from a 2.5 ms logical period clock.

On the 192 kHz EP1/source-0 route, AoC consumes playback data while its
AP-visible shared Rx counter remains stale until teardown.  This exact-module
transform changes only PCM0/D0: every timer tick advances ``pos`` by one ALSA
period modulo ``buffer_size`` and enters the stock period-work path.  It never
changes ``prev_consumed``, so a stale raw counter cannot look like a 32-bit
wrap.  Non-D0 streams replay the displaced comparison and retain stock raw
counter accounting.  The timer period is 2.5 ms, matching 480 frames at
192 kHz.

All three cave fragments are relocation-free arm64 LL/SC fallback tails on
Frankel's LSE-capable CPU.  The transform requires the exact explicit-NULL
pure-timer base named by ``BASE_SHA256`` and is reversible.
"""

from __future__ import annotations

import argparse
import hashlib
import os
import pathlib
import stat
import tempfile


BASE_SHA256 = "0b7150789ed60b53fff596a1239ecc6c968730d7d800f05ecb1128ce70057ebe"
PATCHED_SHA256 = "02a32016fcde5f69ee6e80f2783134b2cd6b39a0538fcbf10440d0a1bb64bfd6"

PATCHES = (
    (
        0xD680,
        bytes.fromhex("287d5f880805001128fd0a88aaffff35bf3b03d5caffff17"),
        bytes.fromhex("68f240b968000034bf0202ebab320014682a41b904000014"),
        "D0 selector, non-D0 compare replay, and pos load",
    ),
    (
        0xD6A4,
        bytes.fromhex("287d5f880805001128fd0a88aaffff35bf3b03d5cfffff17"),
        bytes.fromhex("692241b90801090b6a2641b909010a6b2821881aeb000014"),
        "period add and buffer-modulo cave",
    ),
    (
        0xDA64,
        bytes.fromhex("497d5f8829050011"),
        bytes.fromhex("682a01b9bb310014"),
        "logical pos store and stock period-work return",
    ),
    (
        0x1A134,
        bytes.fromhex("bf0202eb"),
        bytes.fromhex("53cdff17"),
        "route raw-counter comparison through D0 selector",
    ),
    (
        0x1A5FC,
        bytes.fromhex("08488852"),
        bytes.fromhex("08b48452"),
        "timer interval low half 1 ms to 2.5 ms",
    ),
    (
        0x1A608,
        bytes.fromhex("e801a072"),
        bytes.fromhex("c804a072"),
        "timer interval high half 1 ms to 2.5 ms",
    ),
)


def digest(data: bytes | bytearray) -> str:
    return hashlib.sha256(data).hexdigest()


def classify(data: bytes | bytearray) -> str:
    observed = tuple(bytes(data[o:o + len(a)]) for o, a, _b, _n in PATCHES)
    base = tuple(a for _o, a, _b, _n in PATCHES)
    patched = tuple(b for _o, _a, b, _n in PATCHES)
    sha = digest(data)
    if observed == base and sha == BASE_SHA256:
        return "pure-timer"
    if observed == patched and sha == PATCHED_SHA256:
        return "d0-logical-clock-2500us"
    raise ValueError(
        f"unexpected module sha256={sha}; sites={[part.hex() for part in observed]}"
    )


def transform(data: bytearray, wanted: str) -> None:
    current = classify(data)
    if current == wanted:
        return
    for offset, base, patched, name in PATCHES:
        before, after = (
            (base, patched) if wanted == "d0-logical-clock-2500us"
            else (patched, base)
        )
        if bytes(data[offset:offset + len(before)]) != before:
            raise ValueError(f"guard mismatch for {name} at 0x{offset:x}")
        data[offset:offset + len(before)] = after
        print(f"patched 0x{offset:x}: {name}")
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
    parser.add_argument("--check", choices=("pure-timer", "d0-logical-clock-2500us"))
    parser.add_argument(
        "--set-state",
        choices=("pure-timer", "d0-logical-clock-2500us"),
        default="d0-logical-clock-2500us",
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
