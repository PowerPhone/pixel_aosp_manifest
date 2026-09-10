#!/usr/bin/env python3
"""Enable 192 kHz on Frankel's stock EP6/source-5 speaker frontend.

The qualified base module already widens the generic PCM runtime and the
TDM_0_RX backend through 192 kHz.  Frankel's ordinary speaker route uses
PCM0,D5 (EP6/source 5), whose per-DAI rate mask remains 8--48 kHz.  This
guarded transform changes only that per-DAI mask.
"""

from __future__ import annotations

import hashlib
import os
import pathlib
import sys
import tempfile


EXPECTED_INPUT_SHA256 = (
    "f7c7f9dcdf1efde705be45fc0beeb29a2c958e2db774fd4692e53ae41134dba8"
)
PATCH_OFFSET = 0x3F728
BEFORE = bytes.fromhex("fe000000")
AFTER = bytes.fromhex("fe1f0000")


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def main() -> int:
    if len(sys.argv) != 3:
        print(f"usage: {sys.argv[0]} INPUT OUTPUT", file=sys.stderr)
        return 2

    source = pathlib.Path(sys.argv[1])
    destination = pathlib.Path(sys.argv[2])
    data = bytearray(source.read_bytes())
    observed = digest(data)
    if observed != EXPECTED_INPUT_SHA256:
        raise SystemExit(
            f"refusing unexpected input SHA-256 {observed}; "
            f"expected {EXPECTED_INPUT_SHA256}"
        )
    if data[PATCH_OFFSET : PATCH_OFFSET + len(BEFORE)] != BEFORE:
        raise SystemExit(
            f"EP6 rate-mask guard mismatch at file offset 0x{PATCH_OFFSET:x}"
        )
    data[PATCH_OFFSET : PATCH_OFFSET + len(AFTER)] = AFTER

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

    print(
        f"patched EP6 playback rate mask at 0x{PATCH_OFFSET:x}: "
        "8--48 kHz -> 8--192 kHz"
    )
    print(f"patched {source} -> {destination}")
    print(f"sha256={digest(data)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
