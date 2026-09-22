#!/usr/bin/env python3
"""Create a guarded diagnostic module for Frankel's D28 setup ABI.

This is deliberately a short-lived hardware probe.  Frankel F1 expects PCM
channel 28 in CMD_AUDIO_OUTPUT_EP_SETUP2 and SOURCE, while the independently
routed DAPM BIND command maps IDX_US (19) to source 14.  It does not accept the
legacy CMD_AUDIO_OUTPUT_EP_SETUP for endpoint 28.  Revert the over-broad
open-time remap and wrap only that legacy call so endpoint 28 skips it; all
other playback entrypoints retain the stock call.
"""

from __future__ import annotations

import hashlib
import os
import pathlib
import sys
import tempfile


EXPECTED_SHA256 = "607634b627781b3889317bf3b7e61d221c7f07c4ab36bfdb3f275694cc4a5131"
PATCHES = (
    (
        0x1A628,
        bytes.fromhex(
            "88fe00b9080b40f900894079fdd7ff97"
            "80f600b9e00313aa"
        ),
        bytes.fromhex(
            "bf1e00714901805288fe00b92801951a"
            "e00313aa88f600b9"
        ),
        "restore PCM28 as setup/setup2 channel",
    ),
    (0x13FF4, bytes.fromhex("7de3ff97"), bytes.fromhex("58000094"),
     "call selective legacy-setup wrapper"),
    (0x14140, bytes.fromhex("00000090"), bytes.fromhex("f3000014"),
     "preserve first setup error return through common epilogue"),
    (0x14150, bytes.fromhex("00000090"), bytes.fromhex("ef000014"),
     "preserve setup2 error return through common epilogue"),
    (0x14154, bytes.fromhex("00000091"), bytes.fromhex("28644039"),
     "load legacy setup endpoint in wrapper"),
    (0x14158, bytes.fromhex("e103152a"), bytes.fromhex("1f710071"),
     "compare legacy setup endpoint with D28"),
    (0x1415C, bytes.fromhex("00000094"), bytes.fromhex("40000054"),
     "skip legacy setup only for D28"),
    (0x14160, bytes.fromhex("00000090"), bytes.fromhex("22e3ff17"),
     "tail-call aoc_audio_control for all other endpoints"),
    (0x14164, bytes.fromhex("00000091"), bytes.fromhex("e0031f2a"),
     "return success for skipped D28 legacy setup"),
    (0x14168, bytes.fromhex("eb000014"), bytes.fromhex("c0035fd6"),
     "return from selective legacy-setup wrapper"),
    # Each edited instruction occupied a relocation site in the stock ELF.
    # Clear only r_info (type becomes R_AARCH64_NONE) so the module loader
    # leaves the new raw branch/helper instructions intact.
    (0x52C70, bytes.fromhex("13010000fc070000"), bytes(8),
     "neutralize relocation at VA d140"),
    (0x52CA0, bytes.fromhex("13010000fc070000"), bytes(8),
     "neutralize relocation at VA d150"),
    (0x52CB8, bytes.fromhex("15010000fc070000"), bytes(8),
     "neutralize relocation at VA d154"),
    (0x52CD0, bytes.fromhex("1b01000003080000"), bytes(8),
     "neutralize relocation at VA d15c"),
    (0x52CE8, bytes.fromhex("13010000fc070000"), bytes(8),
     "neutralize relocation at VA d160"),
    (0x52D00, bytes.fromhex("15010000fc070000"), bytes(8),
     "neutralize relocation at VA d164"),
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
        if len(before) != len(after):
            raise AssertionError(description)
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
