#!/usr/bin/env python3
"""Batch up to two real D0 mailbox periods before deferred ALSA delivery.

The exact input module already keeps PCM0/D0 on the AoC mailbox path and
limits its reported Rx counter to one period per mailbox notification.  Its
period notification is deferred to the driver's dedicated ordered
``WQ_HIGHPRI`` workqueue.

This transform changes the D0-only clamp from::

    min(actual_rx, previous_report + period_bytes)

to::

    min(actual_rx, previous_report + 2 * period_bytes)

This lets ALSA release as many as two periods after one notification when the
hardware counter proves that both were consumed.  The ALSA core documents
that ``snd_pcm_period_elapsed()`` is called once even when more than one
period elapsed, so the existing deferred work item remains correct.  The
reported counter never exceeds the real AoC Rx counter.

No AP timer, synchronous mailbox callback, prefill, fabricated position, ring
availability, or workqueue behavior is introduced.  Non-D0 devices skip this
code cave and retain their exact prior path.  Apply only to ``BASE_SHA256``.
"""

from __future__ import annotations

import argparse
import hashlib
import os
import pathlib
import stat
import tempfile


BASE_SHA256 = "fc990edad9b77b2bb96cd222f6a07503dc12247804c498a769d0436b5cb61cd0"
PATCHED_SHA256 = "3a37fab7d6f47e36edd0c852919457267586d0c4d948356e67c7b46ba5ec51e5"

# .text virtual address 0x66a8, within the existing D0-only clamp cave.
#
#   add x10, x2, w9, uxtw      -> add x10, x2, w9, uxtw #1
#
# w9 is period_bytes, x2 is the previously reported real counter, and x21 is
# the current hardware counter.  The following cmp/csel retains the upper
# bound of x21, so shifting the addend cannot invent hardware progress.
PATCHES = (
    (
        0xD6A8,
        bytes.fromhex("4a40298b"),
        bytes.fromhex("4a44298b"),
        "D0 real-counter clamp from one period to two",
    ),
)

BASE_STATE = "d0-mailbox-real-progress"
PATCHED_STATE = "d0-mailbox-batch2-real-progress"


def digest(data: bytes | bytearray) -> str:
    return hashlib.sha256(data).hexdigest()


def classify(data: bytes | bytearray) -> str:
    observed_sites = tuple(
        bytes(data[offset : offset + len(base)])
        for offset, base, _patched, _description in PATCHES
    )
    base_sites = tuple(base for _offset, base, _patched, _description in PATCHES)
    patched_sites = tuple(
        patched for _offset, _base, patched, _description in PATCHES
    )
    observed_sha = digest(data)

    if observed_sites == base_sites and observed_sha == BASE_SHA256:
        return BASE_STATE
    if observed_sites == patched_sites and observed_sha == PATCHED_SHA256:
        return PATCHED_STATE
    raise ValueError(
        f"unexpected module sha256={observed_sha}; "
        f"sites={[site.hex() for site in observed_sites]}"
    )


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
    write_atomic(args.output, bytes(data), args.input.stat().st_mode)
    print(f"wrote {args.set_state} {args.output} ({digest(data)})")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError) as error:
        print(f"error: {error}", file=__import__("sys").stderr)
        raise SystemExit(2)
