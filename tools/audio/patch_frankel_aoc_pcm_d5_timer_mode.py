#!/usr/bin/env python3
"""Select the AoC main-PCM timer fallback only for Frankel PCM device 5.

This is a narrower diagnostic successor to the all-main-PCM timer experiment.
It changes the ISR-selection test in ``snd_aoc_pcm_open`` so D5/EP6 uses the
driver's existing 10 ms hrtimer while every other main PCM keeps the stock
mailbox-type decision.  The transform reclaims only an initialization that is
redundant after kzalloc and rearranges existing instructions; it adds no code
cave, relocation, or call.  Do not apply it to another module.
"""

from __future__ import annotations

import hashlib
import os
import pathlib
import sys
import tempfile


EXPECTED_INPUT_SHA256 = (
    "4d64ffb3ce3e7735c0b8b1827e8b33c7554ff1ad0258b31be47f835d67859e7e"
)
PATCHES = (
    # cstream was already zeroed by kzalloc.  Reclaim its explicit zero store
    # to preload chip->opened into unused callee-saved x22 while the mutex is
    # held.
    (0x1A46C, bytes.fromhex("1f0800f9"), bytes.fromhex("360b43f9")),
    # Use the preloaded opened mask, then move the draining=1 store into the
    # instruction which previously performed the now-redundant ORR.
    (0x1A5C8, bytes.fromhex("2a0b43f9"), bytes.fromhex("c80208aa")),
    (0x1A5CC, bytes.fromhex("480108aa"), bytes.fromhex("895e01b9")),
    # Compute timer iff idx==5 OR mbox!=4.  For idx==5, CCMP supplies Z=0;
    # otherwise it performs the original mbox comparison.  The following
    # stock b.ne instruction remains unchanged.
    (0x1A5DC, bytes.fromhex("895e01b9"), bytes.fromhex("bf160071")),
    (0x1A5E4, bytes.fromhex("1f110071"), bytes.fromhex("0019447a")),
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
    observed = digest(data)
    if observed != EXPECTED_INPUT_SHA256:
        raise SystemExit(
            f"refusing unexpected input SHA-256 {observed}; "
            f"expected {EXPECTED_INPUT_SHA256}"
        )
    for offset, before, _after in PATCHES:
        if data[offset : offset + len(before)] != before:
            raise SystemExit(
                f"main PCM ISR-selection sequence mismatch at file offset "
                f"0x{offset:x}"
            )
    for offset, _before, after in PATCHES:
        data[offset : offset + len(after)] = after
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
        "patched main PCM ISR selection: D5/EP6 -> 10 ms timer; "
        "other main PCM devices retain stock mailbox selection"
    )
    print(f"patched {source} -> {destination}")
    print(f"sha256={digest(data)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
