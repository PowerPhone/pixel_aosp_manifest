#!/usr/bin/env python3
"""Build the reversible Frankel D28-to-source0 playback trial module.

Frankel's F1 firmware accepts D28 EP_SETUP2 and its dedicated
``audio_playback28`` ring, but rejects endpoint 28 in the legacy SOURCE
enable/disable command.  This diagnostic transform preserves D28 setup and
ring selection while changing only D28 SOURCE packets and the IDX_US DAPM
binding to ordinary, firmware-supported playback source 0.  Every other
playback source retains its original command value.

The input is the already-qualified, selective D28 module used by the safe
image.  Exact input bytes are required at every patch site and the output is
written atomically.
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


PATCHES = (
    # aoc_audio_start: retain the command header/counter, but select source 0
    # only when alsa_stream->entry_point_idx is 28.  The final halfword is
    # {source, on}; all other streams retain their original source and on=1.
    (0x12700, "e9370039", "1f710071", "start: compare endpoint with 28"),
    (0x12704, "49018052", "ec03881a", "start: select source 0 only for D28"),
    (0x1270C, "2919a072", "4b01a0d2", "start: construct command header"),
    (0x12710, "e8530039", "2b19c0f2", "start: construct command header"),
    (0x12714, "28008052", "2b1d78b3", "start: insert sequence byte"),
    (0x1272C, "ff330039", "ebc300f8", "start: store command header"),
    (0x12730, "e9e300b8", "8c011832", "start: set on=1"),
    (0x12734, "e8570039", "ec2b0079", "start: store source/on pair"),

    # aoc_audio_stop: identical guarded source selection, with on=0.
    (0x12A60, "e9370039", "1f710071", "stop: compare endpoint with 28"),
    (0x12A64, "49018052", "ec03881a", "stop: select source 0 only for D28"),
    (0x12A6C, "2919a072", "4b01a0d2", "stop: construct command header"),
    (0x12A84, "ff330039", "2b19c0f2", "stop: construct command header"),
    (0x12A88, "e9e300b8", "2b1d78b3", "stop: insert sequence byte"),
    (0x12A8C, "e8530039", "ebc300f8", "stop: store command header"),
    (0x12A90, "ff570039", "ec2b0079", "stop: store source/on pair"),

    # ep_id_to_source(): change only IDX_US (19) from SPEAKER_US (14) to 0.
    # This makes the DAPM BIND2 packet agree with the guarded SOURCE alias.
    (0x10664, "c0018052", "e0031f2a", "bind IDX_US to source 0"),
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
    actual_digest = digest(data)
    if actual_digest != EXPECTED_INPUT_SHA256:
        raise SystemExit(
            f"refusing unexpected input SHA-256 {actual_digest}; "
            f"expected {EXPECTED_INPUT_SHA256}"
        )

    for offset, before_hex, after_hex, description in PATCHES:
        before = bytes.fromhex(before_hex)
        after = bytes.fromhex(after_hex)
        if len(before) != len(after):
            raise AssertionError(description)
        actual = data[offset : offset + len(before)]
        if actual != before:
            raise SystemExit(
                f"guard mismatch at 0x{offset:x} for {description}: "
                f"got {actual.hex()}, expected {before.hex()}"
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
