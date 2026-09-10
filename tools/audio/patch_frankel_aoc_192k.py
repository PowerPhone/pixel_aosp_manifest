#!/usr/bin/env python3
"""Select the exact stock or qualified Frankel 192 kHz AoC ALSA module.

Google has not published the matching Laguna AoC module source.  Refuse any
binary other than the exact qualified stock or patched module, and perform the
transformation atomically so a build-tree opt-in is safely reversible.

The patched state consolidates the complete module-side transform used by the
qualified PCM0,D10 microphone path and the real-hardware PCM0,D0 / EP1
source-0 speaker path.  It retains the general 192 kHz constraints, the EP3
capture mask and 500 us capture-ring polling, adds EP1 playback admission, and
bounds each real D0 mailbox report to one already-consumed period.  It does
not add a timer, synthetic progress, ring prefill, or short-space bypass.
Historical one-step helpers are kept for trial provenance; finished images
select only this exact stock or complete state.
"""

from __future__ import annotations

import argparse
import dataclasses
import hashlib
import os
import pathlib
import stat
import sys
import tempfile


STOCK_SHA256 = "d71b906b3e386ed8c14d219e767e4bd4a9fda3f0fb45c6d8a75e1bb00b9afe5a"
PATCHED_SHA256 = "fc990edad9b77b2bb96cd222f6a07503dc12247804c498a769d0436b5cb61cd0"
LEGACY_HYBRID_SHA256 = "a25094fcb9f1d01a883f2c9830b31a85ed161062de34f0de54f5bc15037e0c31"


@dataclasses.dataclass(frozen=True)
class Patch:
    name: str
    offset: int
    before: bytes
    after: bytes


PATCHES = (
    # The stock capture STOP path performs a synchronous built-in-microphone
    # health query before it stops the selected transport.  If native D12 has
    # already stalled, CMD 0x00eb times out and the kernel resets all of AoC,
    # obscuring the original PCM error and often breaking subsystem recovery.
    # Branch over that telemetry-only block for this research image.  Capture
    # start/stop and the selected NORMAL/MMAP/RAW trigger remain unchanged.
    Patch(
        "skip stop-time built-in-mic health query",
        0x1282C,
        bytes.fromhex("54030035"),  # cbnz w20, aoc_audio_capture_trigger+0xb0
        bytes.fromhex("1a000014"),  # b     aoc_audio_capture_trigger+0xb0
    ),
    # snd_aoc_pcm_open() materializes a second copy of these limits with
    # immediates.  Patching only the exported snd_pcm_hardware object makes
    # tinypcminfo look correct but leaves hw_params constrained to 96 kHz.
    Patch(
        "runtime PCM maximum low half 96 kHz -> 192 kHz",
        0x1A554,
        bytes.fromhex("09e08ed2"),
        bytes.fromhex("09c09dd2"),
    ),
    Patch(
        "runtime PCM standard-rate mask through 192 kHz",
        0x1A55C,
        bytes.fromhex("c8ff80d2"),
        bytes.fromhex("c8ff83d2"),
    ),
    Patch(
        "runtime PCM maximum high half 96 kHz -> 192 kHz",
        0x1A560,
        bytes.fromhex("2900a0f2"),
        bytes.fromhex("4900a0f2"),
    ),
    Patch(
        "generic PCM standard-rate mask through 192 kHz",
        0x2DBF0,
        bytes.fromhex("fe070040"),
        bytes.fromhex("fe1f0040"),
    ),
    Patch(
        "generic PCM maximum rate 96 kHz -> 192 kHz",
        0x2DBF8,
        bytes.fromhex("00770100"),
        bytes.fromhex("00ee0200"),
    ),
    Patch(
        "audio_ultrasonic playback DAI rate mask 48/96/192 kHz",
        0x3FF68,
        bytes.fromhex("00040000"),
        bytes.fromhex("80140000"),
    ),
    Patch(
        "EP1 capture DAI standard-rate mask through 192 kHz",
        0x40180,
        bytes.fromhex("fe070000"),
        bytes.fromhex("fe1f0000"),
    ),
    Patch(
        "EP5 capture DAI standard-rate mask through 192 kHz",
        0x40480,
        bytes.fromhex("fe070000"),
        bytes.fromhex("fe1f0000"),
    ),
    Patch(
        "TDM_0_RX backend DAI standard-rate mask through 192 kHz",
        0x41168,
        bytes.fromhex("fe000000"),
        bytes.fromhex("fe1f0000"),
    ),
    Patch(
        "INTERNAL_MIC_TX backend DAI standard-rate mask through 192 kHz",
        0x41440,
        bytes.fromhex("fe000000"),
        bytes.fromhex("fe1f0000"),
    ),
    Patch(
        "INTERNAL_MIC_US_TX backend DAI standard-rate mask through 192 kHz",
        0x41500,
        bytes.fromhex("fe070000"),
        bytes.fromhex("fe1f0000"),
    ),
    Patch(
        "playback requests above 96 kHz -> AoC SR_192KHZ (enum 7)",
        0x13F5C,
        bytes.fromhex("08d087525f00086b60020054"),
        bytes.fromhex("5f604071880200541f2003d5"),
    ),
    Patch(
        "reuse the old 16 kHz branch target for AoC SR_192KHZ (enum 7)",
        0x13FB0,
        bytes.fromhex("28008052"),
        bytes.fromhex("e8008052"),
    ),
    Patch(
        "capture requests above 96 kHz -> AoC SR_192KHZ (enum 7)",
        0x1427C,
        bytes.fromhex("087097525f00086b09000014"),
        bytes.fromhex("5f604071e800805208020054"),
    ),
    # Keep the already-qualified selective compatibility behavior for the
    # legacy D28 setup ABI.  D28 must retain its real setup/setup2 channel but
    # does not accept the older setup command.  The wrapper skips only that
    # one call, leaves D0 untouched, and preserves both error epilogues.
    Patch(
        "call selective D28 legacy-setup wrapper",
        0x13FF4,
        bytes.fromhex("7de3ff97"),
        bytes.fromhex("58000094"),
    ),
    Patch(
        "preserve first setup error through common epilogue",
        0x14140,
        bytes.fromhex("00000090"),
        bytes.fromhex("f3000014"),
    ),
    Patch(
        "preserve setup2 error through common epilogue",
        0x14150,
        bytes.fromhex("00000090"),
        bytes.fromhex("ef000014"),
    ),
    Patch(
        "D28 legacy-setup wrapper body",
        0x14154,
        bytes.fromhex("00000091e103152a000000940000009000000091eb000014"),
        bytes.fromhex("286440391f7100714000005422e3ff17e0031f2ac0035fd6"),
    ),
    # The six edited wrapper instructions originally occupied relocation
    # sites.  R_AARCH64_NONE prevents the module loader from rewriting them.
    Patch(
        "neutralize relocation at VA d140",
        0x52C70,
        bytes.fromhex("13010000fc070000"),
        bytes(8),
    ),
    Patch(
        "neutralize relocation at VA d150",
        0x52CA0,
        bytes.fromhex("13010000fc070000"),
        bytes(8),
    ),
    Patch(
        "neutralize relocation at VA d154",
        0x52CB8,
        bytes.fromhex("15010000fc070000"),
        bytes(8),
    ),
    Patch(
        "neutralize relocation at VA d15c",
        0x52CD0,
        bytes.fromhex("1b01000003080000"),
        bytes(8),
    ),
    Patch(
        "neutralize relocation at VA d160",
        0x52CE8,
        bytes.fromhex("13010000fc070000"),
        bytes(8),
    ),
    Patch(
        "neutralize relocation at VA d164",
        0x52D00,
        bytes.fromhex("15010000fc070000"),
        bytes(8),
    ),
    # D0 keeps its stock main-PCM mailbox ISR.  AoC can consume the complete
    # 15,360-byte ring between reports, which is position zero modulo ALSA's
    # four-period buffer.  Use unreachable arm64 LL/SC alternative tails to
    # clamp only D0 to min(actual_rx, previous_report + period_bytes), then
    # redirect the real consumed-counter path through that guarded cave.
    Patch(
        "D0 mailbox progress selector and previous-counter reload cave",
        0xD680,
        bytes.fromhex("287d5f880805001128fd0a88aaffff35bf3b03d5caffff17"),
        bytes.fromhex("68f240b968000034e10315aaaf32001462a640f904000014"),
    ),
    Patch(
        "D0 mailbox min(actual, previous plus period) cave",
        0xD6A4,
        bytes.fromhex("287d5f880805001128fd0a88aaffff35bf3b03d5cfffff17"),
        bytes.fromhex("692241b94a40298bbf020aeb5581959ae10315aaa4320014"),
    ),
    Patch(
        "route real consumed-counter path through D0 mailbox clamp",
        0x1A144,
        bytes.fromhex("e10315aa"),
        bytes.fromhex("4fcdff17"),
    ),
    # PCM0,D0 is EP1 / audio_playback0 / legacy source 0.  Its frontend has a
    # private DAI mask in addition to the generic PCM and TDM backend masks.
    Patch(
        "EP1/audio_playback0 DAI standard-rate mask through 192 kHz",
        0x3F368,
        bytes.fromhex("fe000000"),
        bytes.fromhex("fe1f0000"),
    ),
    # PCM 0,10 is audio_capture2 / EP3.  Its DAI capability record has an
    # independent standard-rate mask, so the generic PCM and backend masks
    # above are insufficient to admit native 192 kHz hw_params.
    Patch(
        "EP3/audio_capture2 DAI standard-rate mask through 192 kHz",
        0x40300,
        bytes.fromhex("fe070000"),
        bytes.fromhex("fe1f0000"),
    ),
    # The ultrasonic AoC service does not use the PCM mailbox.  The host ALSA
    # driver polls its RingBuffer producer counter with this hrtimer interval.
    # Stock's 10 ms interval equals the qualified native-192 period and caused
    # deterministic ring overflow.  The 500 us interval below is the final
    # live-qualified setting; offsets are absolute file offsets (.text starts
    # at 0x7000, and the immediates are at .text+0x106bc/+0x106c8).
    Patch(
        "AoC PCM host-poll interval low half 10 ms -> 500 us",
        0x176BC,
        bytes.fromhex("08d09252"),
        bytes.fromhex("08249452"),
    ),
    Patch(
        "AoC PCM host-poll interval high half 10 ms -> 500 us",
        0x176C8,
        bytes.fromhex("0813a072"),
        bytes.fromhex("e800a072"),
    ),
)

# One pre-integration workspace state used an unqualified D0 short-space
# bypass plus hybrid hrtimer.  Accept that exact whole-file identity only as a
# migration input, remove those changes, and install the hardware-proven real
# mailbox clamp.  Fresh extractions never take this path.
LEGACY_TO_QUALIFIED = (
    Patch(
        "remove legacy D0 insufficient-availability selector cave",
        0xD970,
        bytes.fromhex("62e70254c8f640b91f01007100e7025472170014"),
        bytes.fromhex("510180f9497d5f882905001149fd0b88abffff35"),
    ),
    Patch(
        "restore stock short-availability branch",
        0x13658,
        bytes.fromhex("c6e8ff17"),
        bytes.fromhex("83070054"),
    ),
    Patch("remove hybrid opened-mask preload", 0x1A46C,
          bytes.fromhex("360b43f9"), bytes.fromhex("1f0800f9")),
    Patch("remove hybrid opened-mask update", 0x1A5C8,
          bytes.fromhex("c80208aa"), bytes.fromhex("2a0b43f9")),
    Patch("remove hybrid D0 endpoint comparison", 0x1A5CC,
          bytes.fromhex("bf020071"), bytes.fromhex("480108aa")),
    Patch("remove hybrid progress private data", 0x1A5DC,
          bytes.fromhex("14f901f9"), bytes.fromhex("895e01b9")),
    Patch("restore stock mailbox decision", 0x1A5E4,
          bytes.fromhex("0019447a"), bytes.fromhex("1f110071")),
    Patch("restore stock host-progress low immediate", 0x1A5FC,
          bytes.fromhex("08488852"), bytes.fromhex("08d09252")),
    Patch("restore stock host-progress high immediate", 0x1A608,
          bytes.fromhex("e801a072"), bytes.fromhex("0813a072")),
    Patch(
        "install D0 mailbox progress selector cave",
        0xD680,
        bytes.fromhex("287d5f880805001128fd0a88aaffff35bf3b03d5caffff17"),
        bytes.fromhex("68f240b968000034e10315aaaf32001462a640f904000014"),
    ),
    Patch(
        "install D0 mailbox bounded-counter cave",
        0xD6A4,
        bytes.fromhex("287d5f880805001128fd0a88aaffff35bf3b03d5cfffff17"),
        bytes.fromhex("692241b94a40298bbf020aeb5581959ae10315aaa4320014"),
    ),
    Patch("install D0 mailbox clamp branch", 0x1A144,
          bytes.fromhex("e10315aa"), bytes.fromhex("4fcdff17")),
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Apply or verify the qualified Frankel 192 kHz AoC module patch."
    )
    parser.add_argument("input", type=pathlib.Path, help="stock aoc_alsa_dev_util.ko")
    parser.add_argument(
        "output",
        type=pathlib.Path,
        nargs="?",
        help="patched output (required for apply unless --in-place)",
    )
    parser.add_argument(
        "--check",
        choices=("stock", "patched"),
        help="verify the selected state without writing",
    )
    parser.add_argument(
        "--set-state",
        choices=("stock", "patched"),
        help="select the written state (default: patched)",
    )
    parser.add_argument(
        "--in-place",
        action="store_true",
        help="patch INPUT in place (use only on a disposable build-tree copy)",
    )
    return parser.parse_args()


def classify(data: bytes, patch: Patch) -> str:
    actual = data[patch.offset : patch.offset + len(patch.before)]
    if actual == patch.before:
        return "stock"
    if actual == patch.after:
        return "patched"
    raise ValueError(
        f"{patch.name}: unexpected bytes at 0x{patch.offset:x}: {actual.hex()} "
        f"(expected stock {patch.before.hex()} or patched {patch.after.hex()})"
    )


def classify_module(data: bytes) -> str:
    states = {classify(data, patch) for patch in PATCHES}
    if len(states) != 1:
        raise ValueError("refusing a partially patched module")
    state = states.pop()
    observed_digest = hashlib.sha256(data).hexdigest()
    expected_digest = STOCK_SHA256 if state == "stock" else PATCHED_SHA256
    if observed_digest != expected_digest:
        raise ValueError(
            f"unexpected {state} whole-file SHA-256: {observed_digest} "
            f"(expected {expected_digest})"
        )
    return state


def transform(data: bytearray, target_state: str) -> None:
    """Transform an exact module in memory and revalidate the whole result."""
    current_state = classify_module(data)
    if current_state == target_state:
        return
    for patch in PATCHES:
        replacement = patch.after if target_state == "patched" else patch.before
        source = patch.before if target_state == "patched" else patch.after
        end = patch.offset + len(source)
        if data[patch.offset:end] != source:
            raise ValueError(
                f"{patch.name}: state changed while preparing transformation"
            )
        data[patch.offset:end] = replacement
    if classify_module(data) != target_state:
        raise AssertionError("transformed module failed exact self-validation")


def migrate_legacy_hybrid(data: bytearray) -> bool:
    """Convert only the exact retired hybrid state to the qualified state."""
    if hashlib.sha256(data).hexdigest() != LEGACY_HYBRID_SHA256:
        return False
    for patch in LEGACY_TO_QUALIFIED:
        end = patch.offset + len(patch.before)
        if data[patch.offset:end] != patch.before:
            raise ValueError(
                f"{patch.name}: legacy-state guard mismatch at 0x{patch.offset:x}"
            )
        data[patch.offset:end] = patch.after
    if classify_module(data) != "patched":
        raise AssertionError("legacy migration did not produce qualified bytes")
    return True


def write_atomic(destination: pathlib.Path, data: bytes, mode: int) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    if destination.is_symlink() or (
        destination.exists() and not destination.is_file()
    ):
        raise ValueError(f"refusing unsafe output path: {destination}")

    temporary_name: str | None = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="wb",
            dir=destination.parent,
            prefix=f".{destination.name}.",
            delete=False,
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
    args = parse_args()
    if args.input.is_symlink() or not args.input.is_file():
        raise ValueError(f"input is not a safe regular file: {args.input}")
    if args.in_place and args.output is not None:
        raise ValueError("OUTPUT and --in-place are mutually exclusive")
    if not args.check and not args.in_place and args.output is None:
        raise ValueError("apply mode requires OUTPUT or --in-place")
    if args.check and (
        args.in_place or args.output is not None or args.set_state is not None
    ):
        raise ValueError(
            "--check does not write and cannot be combined with "
            "OUTPUT/--in-place/--set-state"
        )

    data = bytearray(args.input.read_bytes())
    observed_digest = hashlib.sha256(data).hexdigest()
    is_legacy_hybrid = observed_digest == LEGACY_HYBRID_SHA256
    if args.check and is_legacy_hybrid:
        print(
            f"module is retired legacy-hybrid, not {args.check}: {args.input}",
            file=sys.stderr,
        )
        return 1
    migrated = migrate_legacy_hybrid(data)
    current_state = classify_module(data)

    if args.check:
        if current_state != args.check:
            print(
                f"module is uniformly {current_state}, not {args.check}: "
                f"{args.input}",
                file=sys.stderr,
            )
            return 1
        print(f"verified {args.check}: {args.input}")
        return 0

    target_state = args.set_state or "patched"
    transformed = current_state != target_state
    if transformed:
        transform(data, target_state)

    destination = args.input if args.in_place else args.output
    assert destination is not None
    if destination != args.input or migrated or transformed:
        write_atomic(
            destination,
            data,
            stat.S_IMODE(args.input.stat().st_mode),
        )
    action = "already" if not migrated and not transformed else "selected"
    print(f"{action} {target_state}: {destination}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError) as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(2)
