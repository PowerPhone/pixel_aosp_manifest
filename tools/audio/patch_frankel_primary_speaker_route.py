#!/usr/bin/env python3
"""Select Frankel's fixed-192 kHz ordinary route and donor speaker gain.

Only the five complete reviewed route stanzas are recognized and transformed;
unrelated XML is preserved. The former gain-6 route remains a migration input.
No whole-file hashes are calculated. Research BUS/raw gain is not changed.
"""

from __future__ import annotations

import argparse
import os
import pathlib
import stat
import sys
import tempfile


ASP_BYPASS_CONTROL = b'    <ctl name="AoC Speaker Mixer ASP Mode" value="ASP_BYPASS" />\n'

LEGACY_ROUTES = (
    (
        b'<path name="primary-playback -> speaker">\n'
        b'    <ctl name="TDM_0_RX Mixer EP2" value="1" />',
        b'<path name="primary-playback -> speaker">\n'
        b'    <ctl name="TDM_0_RX Mixer EP6" value="1" />',
    ),
    (
        b'<path name="deep-buffer-playback -> speaker">\n'
        b'    <ctl name="TDM_0_RX Mixer EP6" value="1" />',
        b'<path name="deep-buffer-playback -> speaker">\n'
        b'    <ctl name="TDM_0_RX Mixer EP6" value="1" />',
    ),
)

PRIOR_ROUTES = (
    (
        LEGACY_ROUTES[0][0],
        b'<path name="primary-playback -> speaker">\n'
        b'    <ctl name="AoC Speaker Mixer ASP Mode" value="ASP_BYPASS" />\n'
        b'    <ctl name="TDM_0_RX Sample Rate" value="SR_192K" />\n'
        b'    <ctl name="TDM_0_RX Format" value="S32_LE" />\n'
        b'    <ctl name="TDM_0_RX Chan" value="Two" />\n'
        b'    <ctl name="TDM_0_RX nSlot" value="Two" />\n'
        b'    <ctl name="TDM_0_RX SlotFmt" value="S32_LE" />\n'
        b'    <ctl name="TDM_0_RX Mixer EP6" value="1" />',
    ),
    (
        LEGACY_ROUTES[1][0],
        b'<path name="deep-buffer-playback -> speaker">\n'
        b'    <ctl name="AoC Speaker Mixer ASP Mode" value="ASP_BYPASS" />\n'
        b'    <ctl name="TDM_0_RX Sample Rate" value="SR_192K" />\n'
        b'    <ctl name="TDM_0_RX Format" value="S32_LE" />\n'
        b'    <ctl name="TDM_0_RX Chan" value="Two" />\n'
        b'    <ctl name="TDM_0_RX nSlot" value="Two" />\n'
        b'    <ctl name="TDM_0_RX SlotFmt" value="S32_LE" />\n'
        b'    <ctl name="TDM_0_RX Mixer EP6" value="1" />',
    ),
    (
        b'  <path name="speaker-earpiece">\n'
        b'    <ctl name="DSP RX1 Source" value="ASPRX1" />\n'
        b'    <ctl name="DSP RX2 Source" value="ASPRX1" />\n'
        b'    <ctl name="PCM Source" value="ASPRX1" />\n'
        b'    <ctl name="Amp Gain" value="6" />\n'
        b'    <ctl name="Main AMP Enable Switch" value="1" />\n'
        b'  </path>',
        b'  <path name="speaker-earpiece">\n'
        b'    <ctl name="DSP RX1 Source" value="ASPRX1" />\n'
        b'    <ctl name="DSP RX2 Source" value="ASPRX1" />\n'
        b'    <ctl name="PCM Source" value="ASPRX1" />\n'
        b'    <ctl name="High Rate PCM Source" value="Zero" />\n'
        b'    <ctl name="Ultrasonic Mode" value="Disabled" />\n'
        b'    <ctl name="Amp Gain" value="6" />\n'
        b'    <ctl name="Digital PCM Volume" value="817" />\n'
        b'    <ctl name="Main AMP Enable Switch" value="1" />\n'
        b'  </path>',
    ),
    (
        b'  <path name="speaker">\n'
        b'    <ctl name="DSP RX1 Source" value="ASPRX1" />\n'
        b'    <ctl name="DSP RX2 Source" value="ASPRX1" />\n'
        b'    <ctl name="Main AMP Enable Switch" value="1" />\n'
        b'    <ctl name="R Main AMP Enable Switch" value="1" />\n'
        b'  </path>',
        b'  <path name="speaker">\n'
        b'    <ctl name="DSP RX1 Source" value="ASPRX1" />\n'
        b'    <ctl name="DSP RX2 Source" value="ASPRX1" />\n'
        b'    <ctl name="PCM Source" value="ASPRX1" />\n'
        b'    <ctl name="High Rate PCM Source" value="Zero" />\n'
        b'    <ctl name="Ultrasonic Mode" value="Disabled" />\n'
        b'    <ctl name="Amp Gain" value="6" />\n'
        b'    <ctl name="Digital PCM Volume" value="817" />\n'
        b'    <ctl name="R PCM Source" value="ASPRX1" />\n'
        b'    <ctl name="R High Rate PCM Source" value="Zero" />\n'
        b'    <ctl name="R Ultrasonic Mode" value="Disabled" />\n'
        b'    <ctl name="R Amp Gain" value="6" />\n'
        b'    <ctl name="R Digital PCM Volume" value="817" />\n'
        b'    <ctl name="Main AMP Enable Switch" value="1" />\n'
        b'    <ctl name="R Main AMP Enable Switch" value="1" />\n'
        b'  </path>',
    ),
    (
        b'  <path name="speaker-safe">\n'
        b'    <ctl name="R Main AMP Enable Switch" value="1" />\n'
        b'  </path>',
        b'  <path name="speaker-safe">\n'
        b'    <ctl name="R DSP RX1 Source" value="ASPRX1" />\n'
        b'    <ctl name="R DSP RX2 Source" value="ASPRX1" />\n'
        b'    <ctl name="R PCM Source" value="ASPRX1" />\n'
        b'    <ctl name="R High Rate PCM Source" value="Zero" />\n'
        b'    <ctl name="R Ultrasonic Mode" value="Disabled" />\n'
        b'    <ctl name="R Amp Gain" value="6" />\n'
        b'    <ctl name="R Digital PCM Volume" value="817" />\n'
        b'    <ctl name="R Main AMP Enable Switch" value="1" />\n'
        b'  </path>',
    ),
)


# Donor speaker/speaker-safe inherit the global amplifier code 17. The old
# research route inadvertently applied the earpiece's code 6 to these routes
# too. Restore only those ordinary routes; earpiece stays 6. Digital volume
# 817, TDM geometry, ASP bypass, telephony, and independent BUS/raw gains stay
# unchanged. The amplifier code's physical dB scale is not inferred here.
ROUTES = tuple(
    (stock, patched.replace(b'Amp Gain" value="6"', b'Amp Gain" value="17"')
     if index in (3, 4) else patched)
    for index, (stock, patched) in enumerate(PRIOR_ROUTES)
)


def complete_routes(patterns: tuple[bytes, ...]) -> tuple[bytes, ...]:
    return tuple(pattern + b"\n  </path>" if index < 2 else pattern
                 for index, pattern in enumerate(patterns))


PROFILES = {
    "stock": complete_routes(tuple(stock for stock, _ in PRIOR_ROUTES)),
    "legacy-patched": complete_routes(
        tuple(legacy for _, legacy in LEGACY_ROUTES)
        + tuple(stock for stock, _ in PRIOR_ROUTES[2:])),
    "pre-asp-patched": complete_routes(tuple(
        patched.replace(ASP_BYPASS_CONTROL, b"") for _, patched in PRIOR_ROUTES)),
    "legacy-gain6": complete_routes(tuple(patched for _, patched in PRIOR_ROUTES)),
    "patched": complete_routes(tuple(patched for _, patched in ROUTES)),
}


def matched_pattern(data: bytes, pattern: bytes) -> bytes | None:
    # A prior XML route edit indented exactly these two lines by eight spaces.
    # Accept that known representation without reformatting unchanged stanzas.
    indented = pattern
    for control in (b"Chan", b"nSlot"):
        line = b'    <ctl name="TDM_0_RX ' + control + b'" value="Two" />'
        indented = indented.replace(line, b"    " + line)
    variants = set((pattern, indented))
    matches = [candidate for candidate in variants if data.count(candidate) == 1]
    if len(matches) != 1 or any(data.count(candidate) > 1 for candidate in variants):
        return None
    return matches[0]


def classify(data: bytes) -> str:
    for name in (b"primary-playback -> speaker", b"deep-buffer-playback -> speaker",
                 b"speaker-earpiece", b"speaker", b"speaker-safe"):
        if data.count(b'<path name="' + name + b'">') != 1:
            raise ValueError(f"missing or duplicate reviewed route: {name.decode()}")
    states = [state for state, patterns in PROFILES.items()
              if all(matched_pattern(data, pattern) is not None for pattern in patterns)]
    if len(states) != 1:
        raise ValueError("unknown or mixed reviewed speaker-route stanzas")
    return states[0]


def transform(data: bytes, target: str) -> bytes:
    state = classify(data)
    if state == target:
        return data
    output = data
    for before, after in zip(PROFILES[state], PROFILES[target]):
        if before == after:
            continue
        actual_before = matched_pattern(output, before)
        if actual_before is None:
            raise ValueError("expected exactly one reviewed speaker route")
        output = output.replace(actual_before, after, 1)
    return output


def write_atomic(destination: pathlib.Path, data: bytes, mode: int) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    if destination.is_symlink() or (destination.exists() and not destination.is_file()):
        raise ValueError(f"refusing unsafe output path: {destination}")
    temporary_name: str | None = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="wb", dir=destination.parent, prefix=f".{destination.name}.", delete=False
        ) as temporary:
            temporary_name = temporary.name
            temporary.write(data)
            temporary.flush()
            os.fsync(temporary.fileno())
        os.chmod(temporary_name, mode)
        os.replace(temporary_name, destination)
        temporary_name = None
    finally:
        if temporary_name is not None:
            pathlib.Path(temporary_name).unlink(missing_ok=True)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("input", type=pathlib.Path)
    parser.add_argument("output", type=pathlib.Path, nargs="?")
    parser.add_argument("--check", choices=("stock", "patched"))
    parser.add_argument("--set-state", choices=("stock", "patched"))
    parser.add_argument("--in-place", action="store_true")
    args = parser.parse_args()

    if args.input.is_symlink() or not args.input.is_file():
        raise ValueError(f"input is not a safe regular file: {args.input}")
    if args.in_place and args.output is not None:
        raise ValueError("OUTPUT and --in-place are mutually exclusive")
    if args.check and (args.output is not None or args.in_place or args.set_state):
        raise ValueError("--check cannot be combined with a write option")
    if not args.check and not args.in_place and args.output is None:
        raise ValueError("apply mode requires OUTPUT or --in-place")

    original = args.input.read_bytes()
    state = classify(original)
    if args.check:
        if state != args.check:
            print(f"mixer paths are {state}, not {args.check}", file=sys.stderr)
            return 1
        print(f"verified {state}: {args.input}")
        return 0

    target = args.set_state or "patched"
    output = transform(original, target)
    destination = args.input if args.in_place else args.output
    assert destination is not None
    if destination != args.input or output != original:
        write_atomic(destination, output, stat.S_IMODE(args.input.stat().st_mode))
    print(f"selected {target} (was {state}): {destination}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError) as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(2)
