#!/usr/bin/env python3
"""Apply a guarded, reboot-volatile Frankel native-D12 192 kHz AoC patch."""

from __future__ import annotations

import argparse
import dataclasses
import pathlib
import sys

from aoc_factory_diag import AocFactoryDiag


@dataclasses.dataclass(frozen=True)
class Patch:
    name: str
    address: int
    before: bytes
    after: bytes


PATCHES = (
    Patch(
        "admit sample-rate enum 7 in the stream validator",
        0x403B75C9,
        bytes.fromhex("bf78b8084c0c8014"),
        bytes.fromhex("bf88b8084c1c8014"),
    ),
    Patch(
        "classify sample-rate enums 6 and 7 as high-rate streams",
        0x403B7670,
        bytes.fromhex("bf60b5002c088413"),
        bytes.fromhex("bf68b5002c088413"),
    ),
    Patch(
        "notify downstream filters for sample-rate enums 6 and 7",
        0x403B9EAC,
        bytes.fromhex("bf60411a04448617"),
        bytes.fromhex("bf68411a04448617"),
    ),
    Patch(
        "install CMD 0x146 Stream 6 rate-enum patch body",
        0x4038FB34,
        bytes.fromhex("000000000000000000000000"),
        bytes.fromhex("b2224e0c75524b7c46060000"),
    ),
    Patch(
        "install two-pass Fullband Ultrasonic drain shim",
        0x403F0C44,
        bytes.fromhex("00" * 44),
        bytes.fromhex(
            "36410056f30020a22040b420a5baf7ad"
            "02bd046500001df03641004203004040"
            "245d0262d50840349046f2de"
        ),
    ),
    Patch(
        "install Fullband Ultrasonic 192 kHz period-cadence shim",
        0x403F0C70,
        bytes.fromhex("00" * 12),
        bytes.fromhex("72030ff2030ef0ff11c681de"),
    ),
    Patch(
        "install full-input-ring reader-sync trampoline",
        0x403F648D,
        bytes.fromhex("00" * 17),
        bytes.fromhex("403490c2a600f0cc1128a2e00200c6e6c8"),
    ),
    Patch(
        "route CMD 0x146 through Stream 6 metadata patch",
        0x4038FB56,
        bytes.fromhex("b2224e"),
        bytes.fromhex("86f6ff"),
    ),
    Patch(
        "native PDM clock 3.2 MHz -> 6.4 MHz",
        0x403B84B0,
        bytes.fromhex("00d43000"),
        bytes.fromhex("00a86100"),
    ),
    Patch(
        "select the existing disabled-HPF branch at 192 kHz",
        0x403B85F6,
        bytes.fromhex("820580"),
        bytes.fromhex("82a000"),
    ),
    Patch(
        "native PDM callback quantum 96 -> 192 frames",
        0x403B8880,
        bytes.fromhex("eef3d3431380"),
        bytes.fromhex("eef3d3431680"),
    ),
    Patch(
        "native PDM output rate 96000 -> 192000",
        0x403B88DD,
        bytes.fromhex("8e9444ee9d93"),
        bytes.fromhex("7e9444ee9d93"),
    ),
    Patch(
        "native PDM bookkeeping quantum 96 -> 192 frames",
        0x403B88FE,
        bytes.fromhex("3df0"),
        bytes.fromhex("4a44"),
    ),
    Patch(
        "install ring-output-8 full-block byte-count literal",
        0x403BA0F4,
        bytes.fromhex("00000000"),
        bytes.fromhex("000c0000"),
    ),
    Patch(
        "install ring-output-8 full-block advance trampoline",
        0x403BA968,
        bytes.fromhex("000000000000"),
        bytes.fromhex("21e3fd862500"),
    ),
    Patch(
        "calculate 96/192-frame DMA quantum for sample-rate enums 6/7",
        0x403BAAD5,
        bytes.fromhex("9e61b4870461fe61ae010381ed04"),
        bytes.fromhex("92210b0c370018400077a1707141"),
    ),
    Patch(
        "advance ring output 8 by one explicit 0xc00-byte native block",
        0x403BACB8,
        bytes.fromhex("a22257"),
        bytes.fromhex("062bff"),
    ),
    Patch(
        "route sample-rate enums 6 and 7 through the high-rate DMA quantum",
        0x403BAA7B,
        bytes.fromhex("ff608414163c8413"),
        bytes.fromhex("ff688414163c8413"),
    ),
    Patch(
        "native timestamp interval 1 ms -> 0.5 ms",
        0x403BA544,
        bytes.fromhex("8e046c91eb92"),
        bytes.fromhex("8e046092eb92"),
    ),
    Patch(
        "native timestamp diagnostic value 1 ms -> 0.5 ms",
        0x403BA585,
        bytes.fromhex("ee48acfd0f93"),
        bytes.fromhex("ee48a0fe0f93"),
    ),
    Patch(
        "D12 fullband-ultrasonic metadata enum 6 -> enum 7",
        0x403E8695,
        bytes.fromhex("3f60730017188014"),
        bytes.fromhex("3f70730017188014"),
    ),
    Patch(
        "double Fullband Ultrasonic invocation-count period geometry",
        0x403E867E,
        bytes.fromhex("7ef3bc0f0771"),
        bytes.fromhex("867b21f02000"),
    ),
    Patch(
        "synchronize the Fullband Ultrasonic reader one full ring behind",
        0x403E882D,
        bytes.fromhex("4ee421439087"),
        bytes.fromhex("061737f02000"),
    ),
    Patch(
        "route Fullband Ultrasonic callbacks through the two-pass drain shim",
        0x4027C768,
        bytes.fromhex("d0873e40"),
        bytes.fromhex("440c3f40"),
    ),
)


COHERENT_DRAIN_ADDRESSES = frozenset(
    (
        0x403F0C44,
        0x403F0C70,
        0x403F648D,
        0x403BA0F4,
        0x403BA968,
        0x403BACB8,
        0x403E867E,
        0x403E882D,
        0x4027C768,
    )
)


# Sites that are required only when one 192-frame native callback is split
# into two stock 96-frame processor invocations.  They must stay stock for the
# preferred half-millisecond profile: PdmV3 then emits one correctly laid-out
# 96-frame planar block every 0.5 ms, so neither a two-pass drain nor a forced
# 0xc00-byte ring advance is valid.
TWO_PASS_DRAIN_ADDRESSES = frozenset(
    (
        0x403F0C44,
        0x403F648D,
        0x403BA0F4,
        0x403BA968,
        0x403BACB8,
        0x403E882D,
        0x4027C768,
    )
)


PROFILE_EXCLUDED_ADDRESSES = {
    # Keep the known-good 96-frame native/fanout path while changing the PDM
    # clock and advertised sample rate.  The timestamp checker then directly
    # reveals the physical rate: 19,200 ticks means 192 kHz.
    "clock96": frozenset(
        (0x403B8880, 0x403B88FE, 0x403BAAD5, 0x403BA544, 0x403BA585)
    )
    | COHERENT_DRAIN_ADDRESSES,
    # A true 192 kHz source naturally produces 96 frames every 0.5 ms.  Retain
    # the stock planar 96-frame data path, use the 0.5-ms timestamp checks, and
    # double only the downstream invocation-count period geometry so its
    # notification cadence remains expressed in wall-clock milliseconds.
    "halfms96": frozenset((0x403B8880, 0x403B88FE, 0x403BAAD5))
    | TWO_PASS_DRAIN_ADDRESSES,
    # Exercise the native engine's 192-frame input/output blocks while keeping
    # the stock enum-6 fanout body (which still yields 96 for enum 7 through the
    # separately widened branch).
    "native192": frozenset((0x403BAAD5, 0x403BA544, 0x403BA585))
    | COHERENT_DRAIN_ADDRESSES,
    "full": frozenset((0x403BA544, 0x403BA585)),
}


def parse_args() -> argparse.Namespace:
    repository = pathlib.Path(__file__).resolve().parents[2]
    parser = argparse.ArgumentParser(
        description="Guard and apply the volatile Frankel AoC D12 192 kHz patch"
    )
    parser.add_argument(
        "action",
        choices=(
            "apply",
            "revert",
            "set-profile",
            "check-stock",
            "check-patched",
        ),
    )
    parser.add_argument(
        "--profile",
        choices=tuple(PROFILE_EXCLUDED_ADDRESSES),
        default="full",
        help="staged diagnostic profile (default: full coherent candidate)",
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
        return "stock"
    if actual == patch.after:
        return "patched"
    raise ValueError(
        f"{patch.name}: unexpected bytes at 0x{patch.address:08x}: {actual.hex()} "
        f"(stock {patch.before.hex()}, patched {patch.after.hex()})"
    )


def write_changed_chunks(
    transport: AocFactoryDiag, patch: Patch, source: bytes, destination: bytes
) -> None:
    """Write a reviewed patch using the widest naturally aligned commands."""

    offset = 0
    while offset < len(source):
        address = patch.address + offset
        remaining = len(source) - offset
        width_bytes = next(
            width
            for width in (4, 2, 1)
            if remaining >= width and address % width == 0
        )
        old = source[offset : offset + width_bytes]
        new = destination[offset : offset + width_bytes]
        if old != new:
            transport.write(
                address, int.from_bytes(new, "little"), width_bytes * 8
            )
            print(
                f"write{width_bytes * 8:<2d} 0x{address:08x} "
                f"{old.hex()}->{new.hex()}  {patch.name}"
            )
        offset += width_bytes


def require_d12_idle(transport: AocFactoryDiag) -> None:
    """Require a closed PCM 0,12 so route activation resets its ring to offset 0."""

    pcm = "/dev/snd/pcmC0D12c"
    present = transport.run("shell", "su", "0", "test", "-c", pcm, check=False)
    if present.returncode:
        raise RuntimeError(f"required D12 capture PCM is missing: {pcm}")
    # The ring exposes only a contiguous pointer; the coherent 192-frame path
    # relies on the normal route-open ResetWritePointer call and then commits
    # exactly one full ring per callback.  Never install/remove its live hooks
    # while a stock half-ring stream can be parked at offset 0x600.
    command = (
        "su 0 sh -c 'find /proc/[0-9]*/fd -type l "
        "-printf \"%p:%l\\\\n\" 2>/dev/null | "
        f"grep -F :{pcm} || true'"
    )
    users = transport.run("shell", command).stdout.decode(errors="replace").strip()
    if users:
        raise RuntimeError(
            "PCM 0,12 is active; stop the capture before changing AoC code:\n" + users
        )


def main() -> int:
    args = parse_args()
    transport_args = argparse.Namespace(
        adb=args.adb,
        adb_server_port=args.adb_server_port,
        serial=args.serial,
        core=2,
        counter=args.counter,
    )
    transport = AocFactoryDiag(transport_args)
    if args.action in ("apply", "revert", "set-profile"):
        require_d12_idle(transport)
    excluded = PROFILE_EXCLUDED_ADDRESSES[args.profile]

    if args.action == "set-profile":
        states_by_address: dict[int, str] = {}
        print(f"profile={args.profile} sites={len(PATCHES)} mode=exact")
        for patch in PATCHES:
            actual = transport.dump(patch.address, len(patch.before))
            state = classify(actual, patch)
            states_by_address[patch.address] = state
            wanted = "stock" if patch.address in excluded else "patched"
            print(
                f"{state:7s}->{wanted:7s} 0x{patch.address:08x} "
                f"{actual.hex()}  {patch.name}"
            )

        # Disconnect any live hooks before erasing their code caves.  Then
        # install new caves before making their hooks reachable.
        for patch in reversed(PATCHES):
            if (
                patch.address in excluded
                and states_by_address[patch.address] == "patched"
            ):
                write_changed_chunks(transport, patch, patch.after, patch.before)
        for patch in PATCHES:
            if (
                patch.address not in excluded
                and states_by_address[patch.address] == "stock"
            ):
                write_changed_chunks(transport, patch, patch.before, patch.after)

        for patch in PATCHES:
            expected = patch.before if patch.address in excluded else patch.after
            actual = transport.dump(patch.address, len(expected))
            if actual != expected:
                raise RuntimeError(
                    f"profile verification failed at 0x{patch.address:08x}: "
                    f"got {actual.hex()}, expected {expected.hex()}"
                )
        print(
            f"verified exact {args.profile} profile; changes are volatile and "
            "disappear on AoC/device reboot"
        )
        return 0

    patches = tuple(patch for patch in PATCHES if patch.address not in excluded)
    print(f"profile={args.profile} sites={len(patches)}")
    states = []
    for patch in patches:
        actual = transport.dump(patch.address, len(patch.before))
        state = classify(actual, patch)
        states.append(state)
        print(f"{state:7s} 0x{patch.address:08x} {actual.hex()}  {patch.name}")

    if args.action.startswith("check-"):
        wanted = args.action.removeprefix("check-")
        if any(state != wanted for state in states):
            raise ValueError(f"AoC patch is not uniformly {wanted}")
        return 0

    source_state, destination_state = (
        ("stock", "patched") if args.action == "apply" else ("patched", "stock")
    )
    if all(state == destination_state for state in states):
        print(f"AoC is already uniformly {destination_state}")
        return 0
    patch_states = list(zip(patches, states, strict=True))
    # Install a code cave before making it reachable.  On revert, disconnect the
    # trampoline before erasing the cave so an in-flight command cannot execute
    # partially restored instructions.
    if args.action == "revert":
        patch_states.reverse()
    for patch, state in patch_states:
        if state == destination_state:
            continue
        source = patch.before if args.action == "apply" else patch.after
        destination = patch.after if args.action == "apply" else patch.before
        write_changed_chunks(transport, patch, source, destination)

    for patch in patches:
        expected = patch.after if args.action == "apply" else patch.before
        actual = transport.dump(patch.address, len(expected))
        if actual != expected:
            raise RuntimeError(
                f"verification failed at 0x{patch.address:08x}: "
                f"got {actual.hex()}, expected {expected.hex()}"
            )
    print(
        f"verified uniformly {destination_state}; changes are volatile and disappear on AoC/device reboot"
    )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, RuntimeError, ValueError) as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(2)
