#!/usr/bin/env python3
"""Select fixed-192 kHz primary/deep output profiles in Frankel's AoC HAL.

Google ships the Pixel 10 primary audio HAL only as a stripped proprietary
executable.  Its fixed use-case builder advertises 48 kHz for both normal
framework output paths and its physical output-device interfaces.  The
PowerPhone AoC transport, in contrast, consumes the speaker source with native
192 kHz geometry.  This guarded transformation makes the primary and
deep-buffer mix ports, plus all three built-in physical output interfaces,
negotiate 192 kHz so AudioFlinger performs application-rate conversion before
frames reach that transport.

192000 needs two AArch64 wide-immediate instructions.  The original MOVs are
therefore changed to direct BL instructions targeting one 12-byte helper in
zero alignment padding between two known functions.  The helper returns
192000 in w8 and does not alter stack state or any other register.

The ``rate-only`` state makes only that advertised-rate change and retains
Google's stock D1/D5 PCM selection, geometry, and mixer routes. This lets
AudioFlinger rate-convert ordinary clients when the separately configured AoC
speaker task is already running above the stock clock.

The full ``patched`` state additionally redirects the stock primary PCM to the
deep-buffer physical frontend. D1/source 1 is unstable at native 192 kHz,
while D5/source 5 has a demonstrated non-zero speaker tap and physical acoustic
response. One guarded trampoline therefore changes PCM devices 1 and 5 to
device 5 immediately before pcm_open(). It also changes those two PCMs to the
hardware-qualified
192-frame/twenty-period ALSA geometry during the driver's initial configuration,
before AudioFlinger obtains its minimum buffer size.  The two guarded hooks
use independently reviewed 12-byte alignment caves and share the plain RET in
the rate helper.  The geometry trampoline restores the compare flags consumed
by the instruction immediately after its hook.  Every other playback and
capture PCM number and geometry is preserved.

The selected D1/D5 paths explicitly retain a full 3840-frame start threshold.
The one-millisecond period shortens AP refill notifications without reducing
the twenty-millisecond ring capacity. Previously selected 1920-by-two images
are accepted through their exact instruction bytes and upgraded in place.
Only the reviewed instruction sites are classified; no whole-file hashing is
performed.

The proprietary Start() otherwise calls pcm_start() on an empty prepared
stream, bypassing that threshold. A separate device-and-direction guard
defers this call only for D1/D5 playback. Their first WRITEI auto-starts after
prefill; capture and all other PCM starts tail-call the original function.
The prior one-ms geometry with explicit START remains a recognized input.

That same guarded playback continuation requires its own worker to enter
FIFO/90 with RESET_ON_FORK through the executable's existing
sched_setscheduler import. Failure takes the original Start() error/close
path. A separate guarded PCM minimum-frame getter advertises 960 frames to
Android while retaining the 192-frame ALSA period. This decouples five-ms
framework transactions from one-ms kernel notifications. The old prefill-only
and FIFO-only profiles remain recognized migration inputs.

The stock policy opens both the primary and deep-buffer non-direct mix ports at
boot. Redirecting both ports to D5 makes two AudioFlinger output threads race a
single AoC source-5 ring whenever a UI sound overlaps ordinary media. The full
state changes only the deep-buffer port flag from ``DEEP_BUFFER`` to ``DIRECT``.
That port is consequently no longer a persistent normal-mix candidate, so UI
and ordinary media share the primary output thread. Explicit direct playback
can still open the secondary port on demand.
"""

from __future__ import annotations

import argparse
import dataclasses
import os
import pathlib
import stat
import sys
import tempfile


@dataclasses.dataclass(frozen=True)
class Patch:
    name: str
    offset: int
    before: bytes
    after: bytes


PATCHES = (
    Patch(
        "primary-playback fixed rate 48000 -> helper",
        0x2979E8,
        bytes.fromhex("08709752"),  # mov w8, #48000
        bytes.fromhex("cfa90094"),  # bl  0x2c2124
    ),
    Patch(
        "deep-buffer-playback fixed rate 48000 -> helper",
        0x297CBC,
        bytes.fromhex("08709752"),  # mov w8, #48000
        bytes.fromhex("1aa90094"),  # bl  0x2c2124
    ),
    Patch(
        "deep-buffer output flag DEEP_BUFFER -> DIRECT",
        0x297C6C,
        bytes.fromhex("480b0091"),  # add x8, x26, #2: packed output flag 8
        bytes.fromhex("481700d1"),  # sub x8, x26, #5: packed output flag 1
    ),
    Patch(
        "physical output interface 0 fixed rate 48000 -> helper",
        0x21DE88,
        bytes.fromhex("08709752"),  # mov w8, #48000
        bytes.fromhex("a7900294"),  # bl  0x2c2124
    ),
    Patch(
        "physical output interface 1 fixed rate 48000 -> helper",
        0x21E1F8,
        bytes.fromhex("08709752"),  # mov w8, #48000
        bytes.fromhex("cb8f0294"),  # bl  0x2c2124
    ),
    Patch(
        "physical output interface 2 fixed rate 48000 -> helper",
        0x21E794,
        bytes.fromhex("08709752"),  # mov w8, #48000
        bytes.fromhex("648e0294"),  # bl  0x2c2124
    ),
    Patch(
        "pcm_open device load -> guarded D1/D5-to-D5 trampoline",
        0x28CF38,
        bytes.fromhex("614240b9"),  # ldr w1, [x19, #0x40]
        bytes.fromhex("cfd40094"),  # bl  0x2c2274
    ),
    Patch(
        "PCM config store -> guarded D1/D5 192x20 trampoline",
        0x28C928,
        bytes.fromhex("78260c29"),  # stp w24, w9, [x19, #0x60]
        bytes.fromhex("7fd70094"),  # bl  0x2c2724
    ),
    Patch(
        "fixed 192000-rate helper in function alignment padding",
        0x2C2124,
        bytes(12),
        bytes.fromhex(
            "08c09d52"  # movz w8, #0xee00
            "4800a072"  # movk w8, #0x2, lsl #16
            "c0035fd6"  # ret
        ),
    ),
    Patch(
        "D1/D5-to-D5 trampoline head in function alignment padding",
        0x2C2274,
        bytes(12),
        bytes.fromhex(
            "614240b9"  # ldr  w1, [x19, #0x40]
            "3f140071"  # cmp  w1, #5
            "6e000014"  # b    0x2c2434
        ),
    ),
    Patch(
        "D1/D5-to-D5 trampoline condition in function alignment padding",
        0x2C2434,
        bytes(12),
        bytes.fromhex(
            "2418417a"  # ccmp w1, #1, #4, ne (Z remains set for D5)
            "a1e7ff54"  # b.ne 0x2c212c (rate helper RET; preserve other PCMs)
            "aa000014"  # b    0x2c26e4
        ),
    ),
    Patch(
        "D1/D5-to-D5 trampoline return in function alignment padding",
        0x2C26E4,
        bytes(12),
        bytes.fromhex(
            "a1008052"  # mov  w1, #5
            "91feff17"  # b    0x2c212c (rate helper RET)
            "00000000"  # retain unused alignment word
        ),
    ),
    Patch(
        "D1/D5 PCM geometry trampoline entry in alignment padding",
        0x2C2724,
        bytes(12),
        bytes.fromhex(
            "78260c29"  # stp  w24, w9, [x19, #0x60] (original hook word)
            "6b4240b9"  # ldr  w11, [x19, #0x40] (preserve live w8)
            "de010014"  # b    0x2c2ea4
        ),
    ),
    Patch(
        "D1/D5 PCM geometry condition in alignment padding",
        0x2C2EA4,
        bytes(12),
        bytes.fromhex(
            "7f150071"  # cmp  w11, #5
            "6419417a"  # ccmp w11, #1, #4, ne
            "a2000014"  # b    0x2c3134
        ),
    ),
    Patch(
        "D1/D5 PCM geometry selection in alignment padding",
        0x2C3134,
        bytes(12),
        bytes.fromhex(
            "a1300154"  # b.ne 0x2c5748 (skip start threshold store)
            "16188052"  # mov  w22, #192
            "8a070014"  # b    0x2c4f64
        ),
    ),
    Patch(
        "D1/D5 PCM period-count selection in alignment padding",
        0x2C4F64,
        bytes(12),
        bytes.fromhex(
            "8a028052"  # mov  w10, #20
            "0be08152"  # mov  w11, #3840 (full-ring start threshold)
            "f6010014"  # b    0x2c5744 (store threshold and restore flags)
        ),
    ),
    Patch(
        "PCM geometry hook flag restoration in alignment padding",
        0x2C5744,
        bytes(12),
        bytes.fromhex(
            "6b7600b9"  # str  w11, [x19, #0x74] (pcm_config.start_threshold)
            "1f110071"  # cmp  w8, #4 (flags used by hook-site b.hi)
            "78f2ff17"  # b    0x2c212c (rate helper RET)
        ),
    ),
    Patch(
        "D1/D5 playback defer explicit pcm_start until WRITEI prefill",
        0x28CDE4,
        bytes.fromhex("9f5d0194"),  # bl pcm_start@plt
        bytes.fromhex("28d30094"),  # bl guarded prefill gate
    ),
    Patch(
        "deferred playback start success return in alignment padding",
        0x2C1A68,
        bytes(8),
        bytes.fromhex("00008052 ce2cff17"),  # pid 0; b FIFO/90 setup
    ),
    Patch(
        "deferred playback start device gate in alignment padding",
        0x2C1A84,
        bytes(12),
        bytes.fromhex("684240b9 1f150071 3e030014"),
    ),
    Patch(
        "deferred playback start direction load in alignment padding",
        0x2C2784,
        bytes(12),
        bytes.fromhex("0419417a 69f24039 1e0e0014"),
    ),
    Patch(
        "deferred playback start direction guard in alignment padding",
        0x2C6004,
        bytes(12),
        # ccmp playback,#1,#0,eq; b.ne pcm_start@plt; b success return
        bytes.fromhex("2009417a c1220f54 97eeff17"),
    ),
    Patch(
        "D1/D5 playback FIFO priority in Start unused stack slot",
        0x28CDA4, bytes(12),
        bytes.fromhex("480b8052 e81b00b9 46000014"),
    ),
    Patch(
        "D1/D5 playback FIFO and RESET_ON_FORK policy",
        0x28CEC4, bytes(12),
        bytes.fromhex("21008052 0100a872 46ffff17"),
    ),
    Patch(
        "D1/D5 playback tail-call existing sched_setscheduler import",
        0x28CBE4, bytes(12),
        bytes.fromhex("e2630091 0e5f0114 00000000"),
    ),
    Patch(
        "PCM minimum-frame getter -> scoped D1/D5 playback FMQ960",
        0x28E308, bytes.fromhex("006840b9"), bytes.fromhex("a7cb0014"),
    ),
    Patch(
        "minimum-frame getter D1/D5 device guard",
        0x2C11A4, bytes(12),
        bytes.fromhex("084040b9 1f150071 aa030014"),
    ),
    Patch(
        "minimum-frame getter direction load",
        0x2C2054, bytes(12),
        bytes.fromhex("0419417a 09f04039 aa100014"),
    ),
    Patch(
        "minimum-frame getter direction guard and original period value",
        0x2C6304, bytes(12),
        bytes.fromhex("2009417a 006840b9 e6000014"),
    ),
    Patch(
        "minimum-frame getter scoped 960-frame result",
        0x2C66A4, bytes(12),
        bytes.fromhex("09788052 2001801a c0035fd6"),
    ),
)

PREFILL_START_OFFSETS = {0x28CDE4, 0x2C1A68, 0x2C1A84, 0x2C2784, 0x2C6004}
FIFO90_OFFSETS = {0x28CDA4, 0x28CEC4, 0x28CBE4}
FMQ960_OFFSETS = {0x28E308, 0x2C11A4, 0x2C2054, 0x2C6304, 0x2C66A4}
PREFILL_ONLY_RETURN = bytes.fromhex("00008052 b0010014")

# The scheduler continuation uses Start()'s unused sp+0x18 word. These
# unchanged context guards bind that assumption and the tail-call/import to
# the reviewed binary. No whole-file identity is required.
CONTEXT_GUARDS = (
    (0x28CDB0, bytes.fromhex(
        "3f2303d5 fd7bbca9 f70b00f9 f65702a9 f44f03a9 fd030091")),
    (0x2E4820, bytes.fromhex("90000090 111e46f9 10e23091 20021fd6")),
    (0x2EF298, bytes.fromhex("f0e2280000000000")),
    (0x28E2F0, bytes.fromhex(
        "5f2403d5 08a44339 1f050071 61000054 00a00291 ffeeff17")),
)

# Old full and pre-DIRECT profiles used these same caves with a ten-ms
# period. Keeping the old bytes explicit permits a guarded migration without
# accepting mixed geometry, widening the PCM selectors, or touching capture.
PERIOD10_CAVE_BYTES = {
    0x2C3134: bytes.fromhex("81300154 16f08052 8a070014"),
    0x2C4F64: bytes.fromhex("4a008052 f7010014 00000000"),
    0x2C5744: bytes.fromhex("1f110071 79f2ff17 00000000"),
}

RATE_ONLY_PATCH_NAMES = {
    "primary-playback fixed rate 48000 -> helper",
    "deep-buffer-playback fixed rate 48000 -> helper",
    "physical output interface 0 fixed rate 48000 -> helper",
    "physical output interface 1 fixed rate 48000 -> helper",
    "physical output interface 2 fixed rate 48000 -> helper",
    "fixed 192000-rate helper in function alignment padding",
}


def patch_is_selected(patch: Patch, state: str) -> bool:
    if state == "stock":
        return False
    if state == "rate-only":
        return patch.name in RATE_ONLY_PATCH_NAMES
    if state == "legacy-patched":
        return patch.name != "deep-buffer output flag DEEP_BUFFER -> DIRECT"
    if state in ("period10-patched", "period1-explicit-start",
                 "period1-prefill-start", "fifo90-prefill-start", "patched"):
        return True
    raise ValueError(f"unknown state: {state}")


def expected_patch_bytes(patch: Patch, state: str) -> bytes:
    if not patch_is_selected(patch, state):
        return patch.before
    has_prefill = state in ("period1-prefill-start", "fifo90-prefill-start", "patched")
    if not has_prefill and patch.offset in PREFILL_START_OFFSETS:
        return patch.before
    if state == "period1-prefill-start" and patch.offset == 0x2C1A68:
        return PREFILL_ONLY_RETURN
    if state not in ("fifo90-prefill-start", "patched") and patch.offset in FIFO90_OFFSETS:
        return patch.before
    if state != "patched" and patch.offset in FMQ960_OFFSETS:
        return patch.before
    if state in ("legacy-patched", "period10-patched"):
        return PERIOD10_CAVE_BYTES.get(patch.offset, patch.after)
    return patch.after


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Select Frankel primary/deep fixed-192 kHz HAL profiles."
    )
    parser.add_argument("input", type=pathlib.Path)
    parser.add_argument("output", type=pathlib.Path, nargs="?")
    parser.add_argument("--check", choices=("stock", "rate-only", "patched"))
    parser.add_argument("--set-state", choices=("stock", "rate-only", "patched"))
    parser.add_argument("--in-place", action="store_true")
    return parser.parse_args()


def classify(data: bytes) -> str:
    for offset, expected in CONTEXT_GUARDS:
        if data[offset:offset + len(expected)] != expected:
            raise ValueError(f"reviewed caller/import context changed at {offset:#x}")
    matching_states = []
    for candidate in (
        "stock", "rate-only", "legacy-patched", "period10-patched",
        "period1-explicit-start", "period1-prefill-start", "fifo90-prefill-start", "patched"
    ):
        if all(
            data[patch.offset : patch.offset + len(patch.before)]
            == expected_patch_bytes(patch, candidate)
            for patch in PATCHES
        ):
            matching_states.append(candidate)
    if len(matching_states) != 1:
        raise ValueError("refusing an unknown or partially patched primary audio HAL")
    return matching_states[0]


def transform(data: bytearray, target: str) -> None:
    current = classify(data)
    if current == target:
        return
    for patch in PATCHES:
        before = expected_patch_bytes(patch, current)
        after = expected_patch_bytes(patch, target)
        end = patch.offset + len(before)
        if data[patch.offset:end] != before:
            raise ValueError(f"{patch.name}: source changed during transform")
        data[patch.offset:end] = after
    if classify(data) != target:
        raise AssertionError("transformed HAL failed exact self-validation")


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
    if args.check and (args.output is not None or args.in_place or args.set_state):
        raise ValueError("--check cannot be combined with a write option")
    if not args.check and not args.in_place and args.output is None:
        raise ValueError("apply mode requires OUTPUT or --in-place")

    data = bytearray(args.input.read_bytes())
    state = classify(data)
    if args.check:
        if state != args.check:
            print(f"HAL is {state}, not {args.check}: {args.input}", file=sys.stderr)
            return 1
        print(f"verified {state}: {args.input}")
        return 0

    target = args.set_state or "patched"
    transform(data, target)
    destination = args.input if args.in_place else args.output
    assert destination is not None
    if destination != args.input or state != target:
        write_atomic(destination, data, stat.S_IMODE(args.input.stat().st_mode))
    print(f"selected {target}: {destination}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError) as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(2)
