#!/usr/bin/env python3
"""Move Frankel D12 stream-8 notification after its 0xc00-byte commit.

The stock stream-8 producer notifies Fullband Ultrasonic before it repacks and
commits the new native-192 block.  Because downstream notifications coalesce,
the consumer can wake on the old occupancy and receive only one 96-frame half
per millisecond.  This guarded patch preserves the original notification byte
count and arguments, but orders the operations as repack, writer commit, MEMW,
then notify.

This is a volatile CP2A.260805.005 F1 patch.  Applying it requires the complete
grown-ring/repacker/cap-eight occupancy profile and idle card-0 capture paths.
"""

from __future__ import annotations

import argparse
import dataclasses
import pathlib
import sys

from aoc_factory_diag import AocFactoryDiag
from patch_frankel_aoc_d12_occupancy_drain_192k import (
    FOUNDATION_ADDRESSES as OCCUPANCY_FOUNDATION_ADDRESSES,
    PATCHES as OCCUPANCY_PATCHES,
)
from patch_frankel_aoc_d12_repack_192k import (
    MEMMOVE_LITERAL,
    MEMMOVE_LITERAL_ADDRESS,
    PATCHES as REPACK_PATCHES,
    REPACK_ADVANCE_REGION,
    require_resized_idle_geometry,
)
from patch_frankel_aoc_live_d12_192k import (
    PATCHES as BASE_PATCHES,
    require_d12_idle,
    write_changed_chunks,
)
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


ZERO_28 = bytes(28)

# Built from device/frankel_aoc_d12_postcommit_notify_192.S with the qualified
# RT500 Xtensa assembler's --no-transform --no-target-align modes.  Classify
# each entire reviewed cave so stale diagnostics or partial experiments fail
# closed instead of being accepted as executable padding.
POSTCOMMIT_NOTIFY = padded(
    "364100422119a2247cb2211acd020c1e0c0fe58fc31df0", 28
)
POSTCOMMIT_WRITER = padded(
    "364100a22120480a422406b135e2e00400c02000ad02a520001df0", 28
)
POSTCOMMIT_ADVANCE_REGION = padded(
    "2d0ca5b23bad02a5ea06462800", 14
)
PRECOMMIT_CALL = bytes.fromhex("e00800")
SUPPRESS_PRECOMMIT_CALL = bytes.fromhex("f02000")


# Apply leaf/helper code first, connect the route-8 trampoline next, and make
# the behavior single-notify only as the final live-site change.  Revert walks
# this tuple backward: restore the stock pre-notify first, disconnect the
# trampoline, then reclaim helpers.
PATCHES = (
    Patch(
        "install the post-commit NotifyDownstreamFilters helper",
        0x403C1A34,
        ZERO_28,
        POSTCOMMIT_NOTIFY,
    ),
    Patch(
        "install the 0xc00 writer-commit/MEMW/notify wrapper",
        0x403C1814,
        ZERO_28,
        POSTCOMMIT_WRITER,
    ),
    Patch(
        "replace the stream-8 repack trampoline with commit-then-notify",
        0x403BA962,
        REPACK_ADVANCE_REGION,
        POSTCOMMIT_ADVANCE_REGION,
    ),
    Patch(
        "suppress the original route-8 pre-commit notification",
        0x403BACB5,
        PRECOMMIT_CALL,
        SUPPRESS_PRECOMMIT_CALL,
    ),
)


# These immutable instructions prove the stack fields and virtual commit tail
# copied by the helper.  The first span ends immediately before the callx8
# classified above.  The second is the common AdvanceWritePointer sequence;
# the third proves that 0x403baa11 is the valid post-commit resume point.
STATIC_PRECONDITIONS = (
    (
        "route-8 notification argument setup",
        0x403BACA0,
        bytes.fromhex("ae8dbe4615612e92d8479081de9d3c4390818121fb"),
    ),
    (
        "common RingBufferStatic writer commit",
        0x403BAA05,
        bytes.fromhex("a22118480abd024864e00400"),
    ),
    (
        "post-commit producer resume instruction",
        0x403BAA11,
        bytes.fromhex("ad05"),
    ),
)


def parse_args() -> argparse.Namespace:
    repository = pathlib.Path(__file__).resolve().parents[2]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "action",
        choices=("apply", "revert", "check-precommit", "check-postcommit"),
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
        return "precommit"
    if actual == patch.after:
        return "postcommit"
    raise ValueError(
        f"{patch.name}: unexpected bytes at 0x{patch.address:08x}: "
        f"{actual.hex()} (precommit {patch.before.hex()}, "
        f"postcommit {patch.after.hex()})"
    )


def require_profile_prerequisites(transport: AocFactoryDiag) -> None:
    """Require the exact native-192, repack, and cap-eight foundation."""

    occupancy_addresses = {patch.address for patch in OCCUPANCY_PATCHES}
    repack_addresses = {patch.address for patch in REPACK_PATCHES}
    base_by_address = {patch.address: patch for patch in BASE_PATCHES}

    # Verify native producer/fanout sites that have not subsequently been
    # replaced by the occupancy or grown-ring profiles.
    for address in OCCUPANCY_FOUNDATION_ADDRESSES:
        if address in occupancy_addresses or address in repack_addresses:
            continue
        patch = base_by_address[address]
        actual = transport.dump(address, len(patch.after))
        if actual != patch.after:
            raise ValueError(
                f"native-192 foundation is missing {patch.name} at "
                f"0x{address:08x}: {actual.hex()}"
            )

    # Exact occupancy bytes include the cap-eight callback itself, not merely
    # its callback-table pointer or period helper.
    for patch in OCCUPANCY_PATCHES:
        actual = transport.dump(patch.address, len(patch.after))
        if actual != patch.after:
            raise ValueError(
                f"cap-eight occupancy profile is missing {patch.name} at "
                f"0x{patch.address:08x}: {actual.hex()}"
            )

    # The current 0x403ba962 trampoline is classified as this patch's mutable
    # before/after site.  Every other grown-ring repacker instruction remains
    # an immutable prerequisite in either direction.
    for patch in REPACK_PATCHES:
        if patch.address == 0x403BA962:
            continue
        actual = transport.dump(patch.address, len(patch.after))
        if actual != patch.after:
            raise ValueError(
                f"grown-ring repacker is missing {patch.name} at "
                f"0x{patch.address:08x}: {actual.hex()}"
            )

    literal = transport.dump(MEMMOVE_LITERAL_ADDRESS, len(MEMMOVE_LITERAL))
    if literal != MEMMOVE_LITERAL:
        raise ValueError(
            f"memmove literal changed at 0x{MEMMOVE_LITERAL_ADDRESS:08x}: "
            f"{literal.hex()}"
        )

    for name, address, expected in STATIC_PRECONDITIONS:
        actual = transport.dump(address, len(expected))
        if actual != expected:
            raise ValueError(f"{name} changed at 0x{address:08x}: {actual.hex()}")

    print("verified native-192/repack/cap-eight profile and producer ABI")


def transition_patch(
    transport: AocFactoryDiag,
    patch: Patch,
    source: bytes,
    destination: bytes,
) -> None:
    """Recheck and verify one phase before a later phase can reference it."""

    actual = transport.dump(patch.address, len(source))
    if actual == destination:
        return
    if actual != source:
        raise ValueError(
            f"{patch.name}: changed before transition at "
            f"0x{patch.address:08x}: {actual.hex()}"
        )
    write_changed_chunks(transport, patch, source, destination)
    actual = transport.dump(patch.address, len(destination))
    if actual != destination:
        raise RuntimeError(
            f"{patch.name}: phase verification failed at "
            f"0x{patch.address:08x}: got {actual.hex()}, "
            f"expected {destination.hex()}"
        )


def main() -> int:
    args = parse_args()
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
        # Multiple factory-diag writes form the transition.  Block every card-0
        # capture node and recheck all capture FDs before the first mutation.
        # Exceptions deliberately leave the nodes mode 000 (fail closed).
        capture_modes = block_capture_opens(transport)
        require_all_capture_idle(transport)

    require_profile_prerequisites(transport)
    require_resized_idle_geometry(transport)

    states: list[str] = []
    for patch in PATCHES:
        actual = transport.dump(patch.address, len(patch.before))
        state = classify(actual, patch)
        states.append(state)
        print(f"{state:10s} 0x{patch.address:08x} {patch.name}")

    if args.action.startswith("check-"):
        wanted = args.action.removeprefix("check-")
        if any(state != wanted for state in states):
            raise ValueError(f"route-8 notification is not uniformly {wanted}")
        return 0

    wanted = "postcommit" if args.action == "apply" else "precommit"
    if all(state == wanted for state in states):
        if capture_modes is not None:
            restore_capture_modes(transport, capture_modes)
        print(f"route-8 notification is already uniformly {wanted}")
        return 0

    patch_states = list(zip(PATCHES, states, strict=True))
    if args.action == "revert":
        patch_states.reverse()
    for patch, state in patch_states:
        if state == wanted:
            continue
        source = patch.before if args.action == "apply" else patch.after
        destination = patch.after if args.action == "apply" else patch.before
        # Verify each helper completely before connecting a caller to it.  On
        # revert, reverse ordering disconnects callers before zeroing helpers.
        transition_patch(transport, patch, source, destination)

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
