#!/usr/bin/env python3
"""Select an exact Frankel PCM0,D0 hardware-backed progress implementation.

The input must be an exact complete 192 kHz module from
``patch_frankel_aoc_192k.py`` or one of the states below. ``mailbox`` keeps the
bounded real mailbox counter, ``pure-timer`` uses only the existing 1 ms timer,
and ``one-period-lag`` keeps mailbox plus the 1 ms real-counter poll while
reporting ``max(previous, actual_rx - period_bytes)``. The final state retains
one real AoC period as startup headroom; it never advances beyond hardware.
"""

from __future__ import annotations

import argparse
import hashlib
import os
import pathlib
import stat
import tempfile


CLEAN_SHA256 = "d0278904c384a61d9d25a44236a3e4a36c087be077b2bd6f0b971ab74b2b3cf8"
MAILBOX_SHA256 = "fc990edad9b77b2bb96cd222f6a07503dc12247804c498a769d0436b5cb61cd0"
PURE_TIMER_SHA256 = "9dd7fad9c61c56d3da79fc162594d1ace8238fa02c270f68f79ad2df4ff6b871"
HYBRID_SHA256 = "14f768697dfdce17869d91360da54ab9e4f7b8d291e718ff8919f524e7010e98"
ONE_PERIOD_LAG_SHA256 = "37cc7ff81bf9804677699d612621ed75a177597e773709ec54924916811818e6"

# offset, source, destination, description
MAILBOX_PATCHES = (
    (0xD680, "287d5f880805001128fd0a88aaffff35bf3b03d5caffff17",
     "68f240b968000034e10315aaaf32001462a640f904000014",
     "D0 mailbox progress selector and previous-counter reload cave"),
    (0xD6A4, "287d5f880805001128fd0a88aaffff35bf3b03d5cfffff17",
     "692241b94a40298bbf020aeb5581959ae10315aaa4320014",
     "D0 mailbox min(actual, previous plus period) cave"),
    (0x1A144, "e10315aa", "4fcdff17",
     "route real consumed-counter path through D0 mailbox clamp"),
)

PURE_TIMER_PATCHES = (
    (0x1A46C, "1f0800f9", "360b43f9", "retain chip opened mask in x22"),
    (0x1A5C8, "2a0b43f9", "c80208aa", "restore opened mask from x22"),
    (0x1A5CC, "480108aa", "895e01b9", "move initial draining store"),
    (0x1A5DC, "895e01b9", "1ff901f9", "disconnect D0 mailbox private data"),
    (0x1A5E0, "08015039", "f5000034", "select timer for PCM0 D0"),
    (0x1A5E4, "1f110071", "0a015039", "load mailbox index for other PCMs"),
    (0x1A5E8, "a1000054", "5f110071", "retain non-D0 mailbox comparison"),
    (0x1A5EC, "e80340f9", "81000054", "route other non-mailbox PCMs to timer"),
    (0x1A5FC, "08d09252", "08488852", "timer interval low half 10 ms to 1 ms"),
    (0x1A608, "0813a072", "e801a072", "timer interval high half 10 ms to 1 ms"),
)

HYBRID_PATCHES = (
    (0x1A5E0, "08015039", "0a015039",
     "load mailbox index without destroying the service pointer"),
    (0x1A5E4, "1f110071", "5f110071", "compare preserved mailbox index"),
    (0x1A5EC, "e80340f9", "14f901f9",
     "connect mailbox private data using preserved service pointer"),
    (0x1A5F0, "14f901f9", "75000034",
     "initialize the fallback timer only for PCM device zero"),
    (0x1A5FC, "08d09252", "08488852", "1 ms timer low immediate"),
    (0x1A608, "0813a072", "e801a072", "1 ms timer high immediate"),
    *MAILBOX_PATCHES,
)

ONE_PERIOD_LAG_PATCHES = (
    (0xD6A4,
     "692241b94a40298bbf020aeb5581959ae10315aaa4320014",
     "692241b94a40298ba1020aeb4100018b4190819aa4320014",
     "D0 max(previous, actual minus one period) counter cave"),
    (0x1A148, "75a600f9", "61a600f9",
     "store lagged x1 result as previous consumed counter"),
)

STATE_SHA256 = {
    "clean": CLEAN_SHA256,
    "mailbox": MAILBOX_SHA256,
    "pure-timer": PURE_TIMER_SHA256,
    "hybrid": HYBRID_SHA256,
    "one-period-lag": ONE_PERIOD_LAG_SHA256,
}
SELECTABLE_STATES = ("mailbox", "pure-timer", "one-period-lag")
EP6_RATE_OFFSET = 0x3F728
EP6_RATE_STOCK = bytes.fromhex("fe000000")
EP6_RATE_PATCHED = bytes.fromhex("fe1f0000")
D5_TIMER_PATCHES = (
    (0x1A46C, bytes.fromhex("1f0800f9"), bytes.fromhex("360b43f9")),
    (0x1A5C8, bytes.fromhex("2a0b43f9"), bytes.fromhex("c80208aa")),
    (0x1A5CC, bytes.fromhex("480108aa"), bytes.fromhex("895e01b9")),
    (0x1A5DC, bytes.fromhex("895e01b9"), bytes.fromhex("bf160071")),
    (0x1A5E4, bytes.fromhex("5f110071"), bytes.fromhex("4019447a")),
)


def digest(data: bytes | bytearray) -> str:
    return hashlib.sha256(data).hexdigest()


def progress_digest(data: bytes | bytearray) -> str:
    """Hash D0 independently of the orthogonal EP6 and D5 selectors."""
    normalized = bytearray(data)
    actual = bytes(
        normalized[EP6_RATE_OFFSET : EP6_RATE_OFFSET + len(EP6_RATE_STOCK)]
    )
    if actual not in (EP6_RATE_STOCK, EP6_RATE_PATCHED):
        raise ValueError(
            f"unexpected EP6 rate word at 0x{EP6_RATE_OFFSET:x}: {actual.hex()}"
        )
    normalized[
        EP6_RATE_OFFSET : EP6_RATE_OFFSET + len(EP6_RATE_STOCK)
    ] = EP6_RATE_STOCK
    d5_states = []
    for offset, before, after in D5_TIMER_PATCHES:
        actual = bytes(normalized[offset : offset + len(before)])
        if actual == before:
            d5_states.append("disabled")
        elif actual == after:
            d5_states.append("enabled")
        else:
            # Other D0 implementations intentionally use overlapping bytes;
            # they are not a partial D5 selection and remain untouched.
            d5_states = []
            break
    if d5_states:
        if len(set(d5_states)) != 1:
            raise ValueError("partially selected D5 timer transform")
        if d5_states[0] == "enabled":
            for offset, before, _after in D5_TIMER_PATCHES:
                normalized[offset : offset + len(before)] = before
    return digest(normalized)


def classify(data: bytes | bytearray) -> str:
    observed = progress_digest(data)
    for state, expected in STATE_SHA256.items():
        if observed == expected:
            return state
    raise ValueError(
        "input is not an exact Frankel D0 progress state: "
        f"sha256={observed}"
    )


def apply_patch_set(data: bytearray, patches: tuple, forward: bool) -> None:
    entries = patches if forward else tuple(reversed(patches))
    for offset, before_hex, after_hex, description in entries:
        before = bytes.fromhex(before_hex)
        after = bytes.fromhex(after_hex)
        source, destination = (before, after) if forward else (after, before)
        end = offset + len(source)
        if bytes(data[offset:end]) != source:
            raise ValueError(f"guard mismatch at 0x{offset:x}: {description}")
        data[offset:end] = destination
        print(f"patched 0x{offset:x}: {description}")


def normalize_clean(data: bytearray, state: str) -> None:
    if state == "pure-timer":
        apply_patch_set(data, PURE_TIMER_PATCHES, False)
        state = "mailbox"
    if state == "mailbox":
        apply_patch_set(data, MAILBOX_PATCHES, False)
        state = "clean"
    elif state == "one-period-lag":
        apply_patch_set(data, ONE_PERIOD_LAG_PATCHES, False)
        state = "hybrid"
    if state == "hybrid":
        apply_patch_set(data, HYBRID_PATCHES, False)
        state = "clean"
    if state != "clean" or progress_digest(data) != CLEAN_SHA256:
        raise AssertionError("failed to normalize exact clean D0 state")


def transform(data: bytearray, wanted: str) -> None:
    current = classify(data)
    if current == wanted:
        return
    normalize_clean(data, current)
    if wanted == "mailbox":
        apply_patch_set(data, MAILBOX_PATCHES, True)
    elif wanted == "pure-timer":
        apply_patch_set(data, MAILBOX_PATCHES, True)
        apply_patch_set(data, PURE_TIMER_PATCHES, True)
    elif wanted == "one-period-lag":
        apply_patch_set(data, HYBRID_PATCHES, True)
        apply_patch_set(data, ONE_PERIOD_LAG_PATCHES, True)
    else:
        raise ValueError(f"unsupported D0 progress state: {wanted}")
    if classify(data) != wanted:
        raise AssertionError("post-transform state mismatch")


def atomic_write(path: pathlib.Path, data: bytes, mode: int) -> None:
    if path.is_symlink() or (path.exists() and not path.is_file()):
        raise ValueError(f"refusing unsafe output: {path}")
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
        pathlib.Path(temporary).unlink(missing_ok=True)
        raise


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input", type=pathlib.Path)
    parser.add_argument("output", type=pathlib.Path, nargs="?")
    parser.add_argument("--check", choices=SELECTABLE_STATES)
    parser.add_argument("--set-state", choices=SELECTABLE_STATES,
                        default="one-period-lag")
    parser.add_argument("--in-place", action="store_true")
    args = parser.parse_args()

    if args.input.is_symlink() or not args.input.is_file():
        raise ValueError(f"unsafe input: {args.input}")
    if args.check and (args.output is not None or args.in_place):
        parser.error("--check cannot write")
    if args.in_place and args.output is not None:
        parser.error("OUTPUT and --in-place are mutually exclusive")
    if not args.check and not args.in_place and args.output is None:
        parser.error("OUTPUT or --in-place is required")

    data = bytearray(args.input.read_bytes())
    current = classify(data)
    if args.check:
        if current != args.check:
            raise ValueError(f"module is {current}, expected {args.check}")
        print(f"verified {args.check}: {args.input}")
        return 0

    transform(data, args.set_state)
    destination = args.input if args.in_place else args.output
    assert destination is not None
    atomic_write(destination, bytes(data), args.input.stat().st_mode)
    print(f"selected {args.set_state}: {destination}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError) as error:
        print(f"error: {error}", file=__import__("sys").stderr)
        raise SystemExit(2)
