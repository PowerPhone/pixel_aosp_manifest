#!/usr/bin/env python3
"""Switch Frankel playback start/stop to the F1 SOURCE2 command ABI.

The newer Cubs AoC driver sends the same packed 10-byte source/on payload with
command ID 0x1401.  Frankel's F1 firmware rejects the legacy 0x00c9 command
after accepting EP_SETUP2, so this guarded hardware trial changes only the two
header immediates in aoc_audio_start() and aoc_audio_stop().
"""

from __future__ import annotations

import hashlib
import os
import pathlib
import sys
import tempfile


EXPECTED_SHA256 = "f7c7f9dcdf1efde705be45fc0beeb29a2c958e2db774fd4692e53ae41134dba8"
PATCHES = (
    (0x1270C, bytes.fromhex("2919a072"), bytes.fromhex("2980a272"),
     "aoc_audio_start: CMD_AUDIO_OUTPUT_SOURCE2 (0x1401)"),
    (0x12A6C, bytes.fromhex("2919a072"), bytes.fromhex("2980a272"),
     "aoc_audio_stop: CMD_AUDIO_OUTPUT_SOURCE2 (0x1401)"),
)


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def main() -> int:
    if len(sys.argv) != 3:
        print(f"usage: {sys.argv[0]} INPUT OUTPUT", file=sys.stderr)
        return 2
    source = pathlib.Path(sys.argv[1])
    destination = pathlib.Path(sys.argv[2])
    data = bytearray(source.read_bytes())
    actual_sha = digest(data)
    if actual_sha != EXPECTED_SHA256:
        raise SystemExit(
            f"refusing unexpected input SHA-256 {actual_sha}; expected {EXPECTED_SHA256}"
        )
    for offset, before, after, description in PATCHES:
        if data[offset : offset + len(before)] != before:
            raise SystemExit(
                f"guard mismatch for {description} at file offset 0x{offset:x}"
            )
        data[offset : offset + len(after)] = after
        print(f"patched 0x{offset:x}: {description}")
    destination.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(
        prefix=f".{destination.name}.", dir=destination.parent
    )
    try:
        with os.fdopen(descriptor, "wb") as output:
            output.write(data)
            output.flush()
            os.fsync(output.fileno())
        os.chmod(temporary_name, source.stat().st_mode)
        os.replace(temporary_name, destination)
    except BaseException:
        try:
            os.unlink(temporary_name)
        except FileNotFoundError:
            pass
        raise
    print(f"patched {source} -> {destination}")
    print(f"sha256={digest(data)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
