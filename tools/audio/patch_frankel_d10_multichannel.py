#!/usr/bin/env python3
"""Reversible experimental delta over the boot-ready D10 mono-192 profile.

This does not modify images or authorize arbitrary AoC addresses. A reviewed
profile supplies exact before/after bytes in the live-mapped shared SRAM.
All audio services and capture routes must be stopped. Restore mono mixer
settings and revert before restarting Android audio. Reboot restores the
packaged mono profile if an experimental capture fails.
"""
from __future__ import annotations

import argparse
import json
import pathlib
import re
import sys
import time

from aoc_factory_diag import AocFactoryDiag
import patch_frankel_aoc_live_d10_raw_192k as mono


class UncachedDiag(AocFactoryDiag):
    def validate_alias(self):
        prior = self.core
        self.core = 1
        try:
            for table, flags in ((0x40009004, 0x1c0e), (0x4000a004, 0x1c12)):
                actual = super().dump(table, 36)
                expected = b"".join(((mb << 20) | flags).to_bytes(4, "little")
                                    for mb in range(1, 10))
                if actual != expected:
                    raise RuntimeError(f"unrecognized live A32 mapping at {table:#x}")
        finally:
            self.core = prior
        print("Live MB1..9 cached/noncacheable section pairs verified", flush=True)

    @staticmethod
    def wire(address, size):
        if not 0x40100000 <= address < address + size <= 0x40a00000:
            raise ValueError(f"address outside reviewed shared SRAM: {address:#x}+{size}")
        return address + 0x40000000

    def dump(self, address, size):
        return super().dump(self.wire(address, size), size)

    def put(self, address, data):
        if generation(self) != self.generation_token:
            raise RuntimeError("AoC generation changed before write; reboot without further mutation")
        # Never fall back to device-side dd for this multi-word transaction.
        self.run("shell", "su", "0", self.native_helper, "--core", str(self.core),
                 "write-raw", str(len(data) * 8),
                 hex(self.wire(address, len(data))), hex(int.from_bytes(data, "little")))


def generation(t):
    state = mono.adb_text(t, "shell", "cat /proc/sys/kernel/random/boot_id; "
                          "cat /sys/devices/platform/9000000.aoc/restart_count; "
                          "cat /sys/devices/platform/9000000.aoc/coredump_count")
    if not re.fullmatch(r"[0-9a-f-]{36}\n[0-9]+\n[0-9]+", state):
        raise RuntimeError(f"invalid AoC generation snapshot: {state!r}")
    return state


def expected_bytes(patches, guards, destination):
    expected = {}
    for p in mono.PATCHES:
        expected.update({p.address + i: b for i, b in enumerate(p.after)})
    for g in mono.NATIVE_96_STOCK_GUARDS:
        expected.update({g.address + i: b for i, b in enumerate(g.expected)})
    for address, data in ((0x4038ea50, bytes.fromhex("c0c83d40")),
                          (0x403f6490, bytes.fromhex("e06d484050ea3840")),
                          (0x403f64a4, bytes.fromhex("36410081faffe0080041f9ff827402627400c020004c021df0000000"))):
        expected.update({address + i: b for i, b in enumerate(data)})
    for g in guards:
        address = int(g["address"], 0)
        data = bytes.fromhex(g["expected_hex"])
        for i, b in enumerate(data):
            if address + i in expected and expected[address + i] != b:
                raise ValueError("profile extra guard conflicts with mono baseline")
            expected[address + i] = b
    for p in patches:
        for i, b in enumerate(p.before):
            if p.address + i in expected and expected[p.address + i] != b:
                raise ValueError(f"delta source conflicts with baseline: {p.name}")
        expected.update({p.address + i: b for i, b in enumerate(
            p.after if destination else p.before)})
    return expected


def verify(t, expected):
    ordered = sorted(expected)
    start = 0
    while start < len(ordered):
        stop = start + 1
        while stop < len(ordered) and ordered[stop] - ordered[start] < 256:
            stop += 1
        address = ordered[start]
        actual = t.dump(address, ordered[stop - 1] - address + 1)
        for byte_address in ordered[start:stop]:
            if actual[byte_address - address] != expected[byte_address]:
                raise ValueError(f"byte guard mismatch at {byte_address:#x}: "
                                 f"{actual[byte_address-address]:02x} != {expected[byte_address]:02x}")
        start = stop


def flush(t):
    for address, expected in (
        (0x403f6490, "e06d484050ea3840"),
        (0x403f64a4, "36410081faffe0080041f9ff827402627400c020004c021df0000000"),
        (0x4038ea50, "c0c83d40"),
    ):
        if t.dump(address, len(bytes.fromhex(expected))) != bytes.fromhex(expected):
            raise ValueError(f"resident coherent cache guard mismatch at {address:#x}")
    selected = bytes.fromhex("a4643f40")
    stock = bytes.fromhex("c0c83d40")
    try:
        t.put(0x4038ea50, selected)
        if t.dump(0x4038ea50, 4) != selected:
            raise RuntimeError("cache dispatch SET not visible")
        try:
            result = t.run("shell", "tinymix", "-D", "0", "--", '"HD Mic gain (cB)"', "0", check=False)
            if result.returncode not in (0, 1):
                raise RuntimeError("cache command transport failed")
        finally:
            # A transport error can follow an already queued AoC command.
            time.sleep(1.5)  # Existing qualified completion allowance, also on error.
    finally:
        current = t.dump(0x4038ea50, 4)
        if current == selected:
            t.put(0x4038ea50, stock)
        elif current != stock:
            raise RuntimeError("unknown HD Mic dispatch during restoration; reboot")
        if t.dump(0x4038ea50, 4) != stock:
            raise RuntimeError("HD Mic dispatch restoration failed; reboot")
    print("Resident coherent F1 cache barrier invoked; stock dispatch restored", flush=True)


def require_source_geometry(t):
    def word(address):
        return int.from_bytes(t.dump(address, 4), "little")
    def pointer(address):
        value = word(address)
        if not 0x40100000 <= value < 0x40a00000 or value % 4:
            raise ValueError(f"not a reviewed shared pointer at {address:#x}: {value:#x}")
        return value
    ap = pointer(0x4054aa58 + 0x1fc)
    pdm = pointer(0x4054aa58 + 0x1f0)
    if word(ap) != 0x40277898 or word(pdm) != 0x4026b650:
        raise ValueError("AP/PDM processor vtable mismatch")
    raw = pointer(ap + 0x144)
    if raw != pointer(pdm + 0x148) or word(raw) != 0x40359c38:
        raise ValueError("PDM destination3 is not the expected AP RAW ring")
    descriptor = pointer(raw + 0x44)
    if word(descriptor + 12) != 0x600:
        raise ValueError("RAW ring is not the reviewed1536-byte two-bank geometry")
    # These are compact ranks for the currently active logical mask, not
    # immutable physical-pad mappings. An idle/mono snapshot may contain -1.
    # The experimental producer must handle missing lanes in S16 as well.
    print(f"AP={ap:#x} PDM={pdm:#x} RAW={raw:#x} banks=768B", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("apply", "revert", "check-mono", "check-multi", "check-multi-bytes", "check-mono-bytes"))
    parser.add_argument("--profile", type=pathlib.Path, required=True)
    parser.add_argument("--adb", type=pathlib.Path, default=pathlib.Path("/usr/bin/adb"))
    parser.add_argument("--adb-server-port", type=int, default=5038)
    parser.add_argument("--serial")
    args = parser.parse_args()
    args.core, args.counter = 2, None
    profile = json.loads(args.profile.read_text())
    patches = tuple(mono.Patch(p["name"], int(p["address"], 0),
                              bytes.fromhex(p["before_hex"]), bytes.fromhex(p["after_hex"]))
                    for p in profile["patches"])
    if not patches:
        raise ValueError("empty experimental profile")
    occupied = set()
    for p in patches:
        UncachedDiag.wire(p.address, len(p.before))
        span = set(range(p.address, p.address + len(p.before)))
        if occupied & span:
            raise ValueError("overlapping delta patches")
        occupied |= span
    original = expected_bytes(patches, profile.get("guards", []), False)
    changed = expected_bytes(patches, profile.get("guards", []), True)
    t = UncachedDiag(args)
    mono.select_native_helper(t)
    if not t.native_helper:
        raise RuntimeError("native diagnostic helper required")
    usage = t.run("shell", "su", "0", t.native_helper, "write-raw", check=False)
    if b"write-raw" not in usage.stdout + usage.stderr:
        raise RuntimeError("update the native diagnostic helper: write-raw support required")
    mono.require_identity(t)
    for service in ("audioserver", "vendor.audio-hal-aidl", "vendor.audio-hal-powerphone"):
        if mono.adb_text(t, "shell", "getprop", f"init.svc.{service}") != "stopped":
            raise RuntimeError(f"stop {service} first")
    if args.action not in ("check-multi-bytes", "check-mono-bytes"):
        mono.require_strict_runtime(t)
    t.run("shell", "/vendor/bin/frankel_aoc_speaker_patch", "check-playback-closed")
    old_generation = generation(t)
    t.generation_token = old_generation
    modes = mono.block_capture_opens(t)
    try:
        mono.require_capture_idle(t)
        t.validate_alias()
        require_source_geometry(t)
        applying = args.action in ("apply", "check-mono", "check-mono-bytes")
        source, target = (original, changed) if applying else (changed, original)
        verify(t, source)
        if args.action.startswith("check-"):
            print(f"{args.action}: exact complete profile verified")
            return 0
        if mono.adb_text(t, "shell", "getprop", "vendor.powerphone.aoc_speaker_192k.ready") != "1":
            raise RuntimeError("boot-ready speaker cache wrapper is required")
        t.run("shell", "setprop", "vendor.powerphone.pdm.ready", "0")
        touched = []
        try:
            for p in patches if applying else reversed(patches):
                for chunk in mono.changed_chunks(p, "apply" if applying else "revert"):
                    touched.append(chunk)
                    t.put(chunk.address, chunk.after)
                    print(f"SET {chunk.address:#x}: {chunk.before.hex()} -> {chunk.after.hex()} {p.name}", flush=True)
            verify(t, target)
            flush(t)
            verify(t, target)
            if generation(t) != old_generation:
                raise RuntimeError("AoC generation changed; reboot")
        except BaseException:
            if generation(t) != old_generation:
                raise RuntimeError("generation changed during mutation; do not roll back into new firmware")
            for chunk in reversed(touched):
                current = t.dump(chunk.address, len(chunk.after))
                if current == chunk.after:
                    t.put(chunk.address, chunk.before)
                elif current != chunk.before:
                    raise RuntimeError("ambiguous partial profile; reboot without restarting audio")
            flush(t)
            verify(t, source)
            if applying:
                t.run("shell", "setprop", "vendor.powerphone.pdm.ready", "1")
            raise
        if not applying:
            t.run("shell", "setprop", "vendor.powerphone.pdm.ready", "1")
        print("Experimental multi-channel delta active; keep Android audio stopped" if applying
              else "Original mono-192 profile restored", flush=True)
    finally:
        mono.restore_capture_modes(t, modes)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, RuntimeError, ValueError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        raise SystemExit(2)
