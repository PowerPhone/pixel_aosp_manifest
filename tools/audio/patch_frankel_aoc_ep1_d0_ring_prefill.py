#!/usr/bin/env python3
"""Allow an initial short-availability write only for Frankel PCM0 / EP1.

The reviewed Frankel AoC ALSA utility resets a playback service's write
pointer before the first copy.  On ``audio_playback0`` this can make the
driver report zero available bytes even though the service accepts the first
ring fill.  Redirect the stock ``avail < count`` branch through an otherwise
unreachable arm64 LL/SC fallback tail.  The cave preserves the normal
``avail >= count`` path, permits the short-availability path only when
``entry_point_idx == 0``, and sends every other endpoint to the original
``-EFAULT`` path.

The guard is endpoint-scoped, not first-write-scoped: a later D0 write with
insufficient availability is also permitted.  Use the exact 15,360-byte D0
ring geometry (stereo S32, 480 frames x 4 periods) for the hardware trial;
``aoc_service_write_message`` still rejects a request larger than the ring.

This transform is tied to the already EP1-rate-patched module from the
Frankel CP2A.260805.005 trial.  Every site and whole-file digest is guarded,
and the transform is reversible.  The code cave is valid on Frankel because
its detected arm64 LSE feature replaces the preceding fallback branch.
"""

from __future__ import annotations

import argparse
import hashlib
import os
import pathlib
import stat
import tempfile


STOCK_SHA256 = "d0278904c384a61d9d25a44236a3e4a36c087be077b2bd6f0b971ab74b2b3cf8"
PATCHED_SHA256 = "99bde9252fff1ade24b49e66a9f0938d6e70e2d0c41768f73be582bdb0483105"

PATCHES = (
    (
        0xD970,
        bytes.fromhex("510180f9497d5f882905001149fd0b88abffff35"),
        bytes.fromhex("62e70254c8f640b91f01007100e7025472170014"),
        "D0-only insufficient-availability selector cave",
    ),
    (
        0x13658,
        bytes.fromhex("83070054"),
        bytes.fromhex("c6e8ff17"),
        "aoc_audio_write short-availability branch to selector cave",
    ),
)


def digest(data: bytes | bytearray) -> str:
    return hashlib.sha256(data).hexdigest()


def classify(data: bytes | bytearray) -> str:
    observed = tuple(
        bytes(data[offset : offset + len(before)])
        for offset, before, _, _ in PATCHES
    )
    stock = tuple(before for _, before, _, _ in PATCHES)
    patched = tuple(after for _, _, after, _ in PATCHES)
    observed_digest = digest(data)
    if observed == stock and observed_digest == STOCK_SHA256:
        return "stock"
    if observed == patched and observed_digest == PATCHED_SHA256:
        return "patched"
    raise ValueError(
        "unexpected or partially patched module: "
        f"sha256={observed_digest}, guarded={[part.hex() for part in observed]}"
    )


def transform(data: bytearray, wanted: str) -> None:
    state = classify(data)
    if state == wanted:
        return
    for offset, before, after, description in PATCHES:
        source, destination = (
            (before, after) if wanted == "patched" else (after, before)
        )
        actual = bytes(data[offset : offset + len(source)])
        if actual != source:
            raise ValueError(
                f"guard mismatch for {description} at 0x{offset:x}: "
                f"got {actual.hex()}, expected {source.hex()}"
            )
        data[offset : offset + len(source)] = destination
        print(f"patched 0x{offset:x}: {description}")
    if classify(data) != wanted:
        raise AssertionError("post-patch classification failed")


def atomic_write(path: pathlib.Path, data: bytes, mode: int) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(descriptor, "wb") as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.chmod(temporary, stat.S_IMODE(mode))
        os.replace(temporary, path)
    except BaseException:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass
        raise


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input", type=pathlib.Path)
    parser.add_argument("output", type=pathlib.Path, nargs="?")
    parser.add_argument("--check", choices=("stock", "patched"))
    parser.add_argument("--set-state", choices=("stock", "patched"), default="patched")
    args = parser.parse_args()

    data = bytearray(args.input.read_bytes())
    state = classify(data)
    if args.check:
        if state != args.check:
            raise ValueError(f"module is {state}, expected {args.check}")
        print(f"verified {args.input} is {state}")
        return 0
    if args.output is None:
        parser.error("OUTPUT is required when applying a patch")

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
