#!/usr/bin/env python3
"""Reject stale halves in a Frankel D10 RAW 192 kHz mono capture."""

from __future__ import annotations

import argparse
import pathlib
import struct
import sys
import wave


BLOCK_SAMPLES = 96
HALF_SAMPLES = 48
SAMPLE_BYTES = 2
REPLAY_LAGS = range(1, 17)


def non_negative(value: str) -> int:
    parsed = int(value, 0)
    if parsed < 0:
        raise argparse.ArgumentTypeError("must be non-negative")
    return parsed


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Verify that every interior 96-sample D10 S16 block has a fresh "
            "second half, adequate value diversity, and no exact short-lag "
            "96-frame replay after the startup settling interval"
        )
    )
    parser.add_argument("wav", type=pathlib.Path)
    parser.add_argument(
        "--edge-blocks",
        type=non_negative,
        default=32,
        help="ignore this many startup and shutdown blocks (default: 32)",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    with wave.open(str(args.wav), "rb") as capture:
        channels = capture.getnchannels()
        sample_width = capture.getsampwidth()
        rate = capture.getframerate()
        frames = capture.getnframes()
        compression = capture.getcomptype()
        if (
            channels != 1
            or sample_width != SAMPLE_BYTES
            or rate != 192000
            or compression != "NONE"
        ):
            raise ValueError(
                "expected uncompressed mono S16_LE/192000 WAV, got "
                f"channels={channels} width={sample_width * 8} rate={rate} "
                f"compression={compression}"
            )
        payload = capture.readframes(frames)

    block_bytes = BLOCK_SAMPLES * SAMPLE_BYTES
    half_bytes = HALF_SAMPLES * SAMPLE_BYTES
    complete_blocks = len(payload) // block_bytes
    first_block = args.edge_blocks
    last_block = complete_blocks - args.edge_blocks
    if last_block <= first_block:
        raise ValueError(
            f"capture has only {complete_blocks} complete 96-sample blocks; "
            f"cannot exclude {args.edge_blocks} at each edge"
        )

    zero_second: list[int] = []
    repeated_halves: list[int] = []
    replayed_blocks: list[tuple[int, int]] = []
    second_values: set[int] = set()
    zero_half = bytes(half_bytes)
    for block_number in range(first_block, last_block):
        offset = block_number * block_bytes
        block = payload[offset : offset + block_bytes]
        first = payload[offset : offset + half_bytes]
        second = payload[offset + half_bytes : offset + block_bytes]
        if second == zero_half:
            zero_second.append(block_number)
        if second == first:
            repeated_halves.append(block_number)
        second_values.update(value[0] for value in struct.iter_unpack("<h", second))
        for lag in REPLAY_LAGS:
            previous_number = block_number - lag
            if previous_number < first_block:
                continue
            previous_offset = previous_number * block_bytes
            if block == payload[previous_offset : previous_offset + block_bytes]:
                replayed_blocks.append((block_number, lag))
                break

    checked = last_block - first_block
    print(
        f"frames={frames} complete_blocks={complete_blocks} checked_blocks={checked} "
        f"zero_second_halves={len(zero_second)} "
        f"repeated_halves={len(repeated_halves)} "
        f"short_lag_replayed_blocks={len(replayed_blocks)} "
        f"second_half_unique_values={len(second_values)}"
    )
    if zero_second or repeated_halves or replayed_blocks or len(second_values) < 16:
        details: list[str] = []
        if zero_second:
            details.append(
                "zero-second-half blocks="
                + ",".join(str(value) for value in zero_second[:16])
            )
        if repeated_halves:
            details.append(
                "repeated-half blocks="
                + ",".join(str(value) for value in repeated_halves[:16])
            )
        if len(second_values) < 16:
            details.append(
                "second-half value diversity="
                f"{len(second_values)} values {sorted(second_values)[:16]}"
            )
        if replayed_blocks:
            details.append(
                "short-lag replay block/lag="
                + ",".join(f"{block}/{lag}" for block, lag in replayed_blocks[:16])
            )
        raise RuntimeError(
            "D10 96-sample block freshness failed: " + "; ".join(details)
        )
    print("verified fresh second 48 samples in every checked D10 block")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, RuntimeError, ValueError, wave.Error) as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(2)
