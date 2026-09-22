#!/usr/bin/env python3
"""Select factory or +6 dB UI volume for Frankel's built-in speaker only.

This is custom compensation for the effects-bypassed research image, not a
claim that the factory UI curve has changed. Amplifier code 17 remains factory
stock. Music, alarms, ring, notification, external devices and research BUS
curves are untouched. No hashes are calculated.
"""
from __future__ import annotations

import argparse
from pathlib import Path
import re
import stat
import sys
import xml.etree.ElementTree as ET

from patch_frankel_primary_speaker_route import write_atomic

FACTORY = ((1, -5800), (14, -4650), (28, -3215), (43, -2960),
           (57, -2153), (72, -1823), (86, -1500), (100, -1100))
STATES = {"factory": FACTORY,
          "ui-plus6db": tuple((index, attenuation + 600)
                              for index, attenuation in FACTORY)}
ROUTE = re.compile(
    r'<volume stream="AUDIO_STREAM_SYSTEM" deviceCategory="DEVICE_CATEGORY_SPEAKER">'
    r'.*?</volume>', re.DOTALL)
POINT = re.compile(r'<point>\s*([0-9]+)\s*,\s*(-?[0-9]+)\s*</point>')


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input", type=Path)
    parser.add_argument("--state", choices=STATES, required=True)
    action = parser.add_mutually_exclusive_group(required=True)
    action.add_argument("--in-place", action="store_true")
    action.add_argument("--check", action="store_true")
    args = parser.parse_args()
    if args.input.is_symlink() or not args.input.is_file():
        raise ValueError("input must be a regular, non-symlink file")
    data = args.input.read_bytes()
    text = data.decode("utf-8")
    root = ET.fromstring(text)
    elements = [item for item in root.iter("volume")
                if item.get("stream") == "AUDIO_STREAM_SYSTEM"
                and item.get("deviceCategory") == "DEVICE_CATEGORY_SPEAKER"]
    matches = list(ROUTE.finditer(text))
    if len(elements) != 1 or len(matches) != 1:
        raise ValueError("expected one exact reviewed SYSTEM/SPEAKER volume curve")
    points = tuple(tuple(map(int, (item.text or "").split(",")))
                   for item in elements[0].findall("point"))
    matched = matches[0]
    if points not in STATES.values() or len(POINT.findall(matched.group())) != len(FACTORY):
        raise ValueError("unknown SYSTEM/SPEAKER curve; refusing to overwrite custom tuning")
    prior = next(name for name, curve in STATES.items() if curve == points)
    if args.check:
        if prior != args.state:
            raise ValueError(f"curve is {prior}, expected {args.state}")
    elif prior != args.state:
        desired = iter(STATES[args.state])
        def replacement(_match):
            index, attenuation = next(desired)
            return f"<point>{index},{attenuation}</point>"
        block = POINT.sub(replacement, matched.group())
        output = text[:matched.start()] + block + text[matched.end():]
        write_atomic(args.input, output.encode("utf-8"), stat.S_IMODE(args.input.stat().st_mode))
    print(f"SYSTEM/SPEAKER curve: {prior} -> {args.state}: {args.input}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, ET.ParseError) as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(2)
