#!/usr/bin/env python3
"""Inspect/revert the experimental Frankel D12 output-backpressure drain.

The occupancy drain can consume all queued MIC_US halves even after the host
has stopped reading its Fullband output ring.  The stock Fullband tail then
keeps overwriting that output ring and notifying the downstream service, which
can starve the AoC control path during PCM stop.

This patch retains the stock sample copy, cache maintenance, ring commits,
notification, and statistics tail.  Before each 0x600-byte input half it also
queries the output reader and runs that tail only when the output ring has room
for this stream's configured byte count.  The loop remains bounded by the
eight halves in the grown 0x3000-byte MIC_US ring.

Applying this experiment is deliberately disabled.  Frankel's output object
is RingBufferHost, whose virtual availability/size methods enter host IPC.
Calling them in the high-rate per-half loop can contend with the same control
transport needed by PCM stop, while withholding MIC_US consumption worsens
input-ring lapping.  Keep the guarded reverter and byte classifier for forensic
work, but use the occupancy/catch-up path for live qualification.
"""

from __future__ import annotations

import argparse
import dataclasses
import pathlib
import sys

from aoc_factory_diag import AocFactoryDiag
from patch_frankel_aoc_d12_occupancy_drain_192k import (
    OCCUPANCY_DRAIN,
    PATCHES as OCCUPANCY_PATCHES,
    require_foundation,
)
from patch_frankel_aoc_d12_repack_192k import require_resized_idle_geometry
from patch_frankel_aoc_live_d12_192k import require_d12_idle, write_changed_chunks
from trigger_frankel_aoc_d12_ring_resize import (
    block_capture_opens,
    require_all_capture_idle,
    restore_capture_modes,
)


@dataclasses.dataclass(frozen=True)
class Patch:
    name: str
    address: int
    before: bytes
    after: bytes


def padded(code: str, total: int) -> bytes:
    result = bytes.fromhex(code)
    if len(result) > total:
        raise ValueError(f"code is {len(result)} bytes, exceeds {total}-byte cave")
    return result + bytes(total - len(result))


# The helper caves are stock zero-filled.  Keep their complete reviewed spans
# in the classification so a probe, stale experiment, or adjacent instruction
# can never be mistaken for a safe transition state.
ZERO_28 = bytes(28)
ZERO_22 = bytes(22)

INPUT_AVAILABLE = padded(
    "36410032224f42d208b8a4ad03e565c02d0a1df0", 28
)
OUTPUT_FREE = padded(
    # RingBufferHost is polymorphic and does not expose RingBufferStatic's
    # descriptor at +0x44.  This retained forensic body calls virtual SizeGet
    # and AvailableForRead; live apply is disabled below because both methods
    # enter host IPC and are unsuitable inside the per-half callback loop.
    "3641003222505222aaad0325124c4d0aad03bd05e5044ca034c01df0", 28
)
WORKER = padded(
    "36410062a6000c8572d20878c7ad02252e24673a0246ef031df0", 28
)
OUTPUT_LOOP = bytes.fromhex(
    "ad02655323773b0bbd03a52c4a0b558c158608fc1df0"
)
CALLBACK = padded(
    "36410056730152040716a500a2224f580a52251ce00500ad02bd04658cac1df0",
    60,
)


# Apply helpers first and the live callback last.  Revert walks this tuple in
# reverse, disconnecting the callback before reclaiming any helper cave.
PATCHES = (
    Patch(
        "install the direct MIC_US AvailableForRead helper",
        0x403C1814,
        ZERO_28,
        INPUT_AVAILABLE,
    ),
    Patch(
        "install the output-ring free-space helper",
        0x403C1A34,
        ZERO_28,
        OUTPUT_FREE,
    ),
    Patch(
        "install the bounded input-occupancy worker",
        0x4039D524,
        ZERO_28,
        WORKER,
    ),
    Patch(
        "install the per-half output-backpressure loop",
        0x4039E4FA,
        ZERO_22,
        OUTPUT_LOOP,
    ),
    Patch(
        "replace the occupancy callback with the backpressure dispatcher",
        0x403F0C44,
        OCCUPANCY_DRAIN,
        CALLBACK,
    ),
)


# These immutable bytes prove the direct helper target and the output reader
# field used by the stock Fullband consumer.  The latter loads output ring
# this+0x140 and reader this+0x2a8 before calling vtable+0x40.
STATIC_PRECONDITIONS = (
    (
        "RingBufferStatic::AvailableForRead entry",
        0x40381E80,
        bytes.fromhex("364100422211"),
    ),
    (
        "Fullband output-ring/read-pointer consumer",
        0x403E8A2C,
        bytes.fromhex("ae06ae1e156b5024c0f80af02000322f10e00300"),
    ),
)


def parse_args() -> argparse.Namespace:
    repository = pathlib.Path(__file__).resolve().parents[2]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "action",
        choices=(
            "apply",
            "revert",
            "check-occupancy",
            "check-backpressure",
        ),
    )
    parser.add_argument(
        "--adb",
        type=pathlib.Path,
        default=repository / "work/toolchains/platform-tools/adb",
    )
    parser.add_argument("--adb-server-port", type=int, default=5038)
    parser.add_argument("--serial")
    parser.add_argument("--counter", type=lambda value: int(value, 0))
    return parser.parse_args()


def classify(actual: bytes, patch: Patch) -> str:
    if actual == patch.before:
        return "occupancy"
    if actual == patch.after:
        return "backpressure"
    raise ValueError(
        f"{patch.name}: unexpected bytes at 0x{patch.address:08x}: "
        f"{actual.hex()}"
    )


def require_occupancy_prerequisites(transport: AocFactoryDiag) -> None:
    require_foundation(transport)

    # The callback itself is classified below because it is the one site this
    # patch replaces.  The no-sync/period body and period hook must remain in
    # their exact occupancy-drain states in either direction.
    for patch in OCCUPANCY_PATCHES:
        if patch.address == 0x403F0C44:
            continue
        actual = transport.dump(patch.address, len(patch.after))
        if actual != patch.after:
            raise ValueError(
                f"occupancy prerequisite is missing {patch.name} at "
                f"0x{patch.address:08x}: {actual.hex()}"
            )

    for name, address, expected in STATIC_PRECONDITIONS:
        actual = transport.dump(address, len(expected))
        if actual != expected:
            raise ValueError(
                f"{name} changed at 0x{address:08x}: {actual.hex()}"
            )
    print("verified occupancy helpers and static output-reader ABI")


def main() -> int:
    args = parse_args()
    if args.action == "apply":
        raise ValueError(
            "output-backpressure apply is disabled: RingBufferHost virtual "
            "queries enter host IPC and can starve the PCM control transport"
        )
    transport = AocFactoryDiag(
        argparse.Namespace(
            adb=args.adb,
            adb_server_port=args.adb_server_port,
            serial=args.serial,
            core=2,
            counter=args.counter,
        )
    )
    require_d12_idle(transport)
    require_all_capture_idle(transport)
    capture_modes: list[tuple[str, str]] | None = None
    if args.action in ("apply", "revert"):
        # The callback transition needs multiple factory-diag writes.  Block
        # all capture opens and leave them blocked after every failure or
        # interruption; restore modes only after full verification succeeds.
        capture_modes = block_capture_opens(transport)
        require_all_capture_idle(transport)

    require_occupancy_prerequisites(transport)
    require_resized_idle_geometry(transport)

    states: list[str] = []
    for patch in PATCHES:
        actual = transport.dump(patch.address, len(patch.before))
        state = classify(actual, patch)
        states.append(state)
        print(f"{state:12s} 0x{patch.address:08x} {patch.name}")

    if args.action.startswith("check-"):
        wanted = args.action.removeprefix("check-")
        if any(state != wanted for state in states):
            raise ValueError(f"D12 output drain is not uniformly {wanted}")
        return 0

    wanted = "backpressure" if args.action == "apply" else "occupancy"
    if all(state == wanted for state in states):
        if capture_modes is not None:
            restore_capture_modes(transport, capture_modes)
        print(f"D12 output drain is already uniformly {wanted}")
        return 0

    patch_states = list(zip(PATCHES, states, strict=True))
    if args.action == "revert":
        patch_states.reverse()
    for patch, state in patch_states:
        if state == wanted:
            continue
        source = patch.before if args.action == "apply" else patch.after
        destination = patch.after if args.action == "apply" else patch.before
        write_changed_chunks(transport, patch, source, destination)

    for patch in PATCHES:
        expected = patch.after if args.action == "apply" else patch.before
        actual = transport.dump(patch.address, len(expected))
        if actual != expected:
            raise RuntimeError(
                f"verification failed at 0x{patch.address:08x}: "
                f"got {actual.hex()}, expected {expected.hex()}"
            )

    if capture_modes is not None:
        restore_capture_modes(transport, capture_modes)
    print(
        f"verified uniformly {wanted}; changes are volatile and disappear on "
        "AoC/device reboot"
    )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, RuntimeError, ValueError) as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(2)
