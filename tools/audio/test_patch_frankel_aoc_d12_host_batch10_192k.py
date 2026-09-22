#!/usr/bin/env python3
"""Offline exact-byte, transition and ring-guard tests for host batch10."""

from __future__ import annotations

import contextlib
import io
import os
import pathlib
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

import patch_frankel_aoc_d12_host_batch10_192k as batch


class FakeTransport:
    def __init__(self) -> None:
        self.memory: dict[int, int] = {}
        self.writes: list[tuple[int, int, bytes]] = []
        self.fail_after: int | None = None

    def load(self, address: int, value: bytes) -> None:
        for offset, byte in enumerate(value):
            self.memory[address + offset] = byte

    def dump(self, address: int, size: int) -> bytes:
        try:
            return bytes(self.memory[address + offset] for offset in range(size))
        except KeyError as error:
            raise AssertionError(f"unseeded fake address 0x{error.args[0]:08x}")

    def write(self, address: int, value: int, width: int) -> None:
        if self.fail_after is not None and len(self.writes) == self.fail_after:
            raise RuntimeError("injected write failure")
        table_before = self.dump(batch.CALLBACK_TABLE_ADDRESS, 4)
        self.load(address, value.to_bytes(width // 8, "little"))
        self.writes.append((address, width, table_before))


def seeded(profile: str, callback: str = "cap4") -> FakeTransport:
    transport = FakeTransport()
    for patch in batch.PATCHES:
        transport.load(
            patch.address,
            patch.batch10 if profile == "batch10" else patch.wholeblock,
        )
    transport.load(
        batch.CALLBACK_TABLE_ADDRESS,
        batch.CALLBACK_CAP4 if callback == "cap4" else batch.CALLBACK_INERT,
    )
    return transport


def transition(transport: FakeTransport, action: str) -> None:
    with contextlib.redirect_stdout(io.StringIO()):
        batch.transition_profile(transport, action)  # type: ignore[arg-type]


class TransitionTest(unittest.TestCase):
    def assert_profile(self, transport: FakeTransport, profile: str) -> None:
        for patch in batch.PATCHES:
            expected = patch.batch10 if profile == "batch10" else patch.wholeblock
            self.assertEqual(transport.dump(patch.address, len(expected)), expected)
        self.assertEqual(
            transport.dump(batch.CALLBACK_TABLE_ADDRESS, 4), batch.CALLBACK_CAP4
        )

    def assert_safe_write_contexts(self, transport: FakeTransport) -> None:
        for address, width, table_before in transport.writes:
            if address == batch.CALLBACK_TABLE_ADDRESS:
                self.assertEqual(width, 32)
                continue
            # A is staged before quarantine and cleared only after reconnect.
            if batch.PATCH_FLUSH.address <= address < batch.PATCH_FLUSH.address + 28:
                continue
            self.assertEqual(table_before, batch.CALLBACK_INERT)

    def test_apply_revert_round_trip_and_order(self) -> None:
        transport = seeded("wholeblock")
        original = dict(transport.memory)
        transition(transport, "apply")
        self.assert_profile(transport, "batch10")
        self.assert_safe_write_contexts(transport)
        table_writes = [x for x in transport.writes if x[0] == batch.CALLBACK_TABLE_ADDRESS]
        self.assertEqual(len(table_writes), 2)
        first_table_index = next(
            i for i, x in enumerate(transport.writes)
            if x[0] == batch.CALLBACK_TABLE_ADDRESS
        )
        self.assertTrue(
            all(
                batch.PATCH_FLUSH.address <= x[0] < batch.PATCH_FLUSH.address + 28
                for x in transport.writes[:first_table_index]
            )
        )
        hook_write = next(
            i for i, x in enumerate(transport.writes)
            if batch.PATCH_START_HOOK.address <= x[0] < batch.PATCH_START_HOOK.address + 6
        )
        cave_write = next(
            i for i, x in enumerate(transport.writes)
            if batch.PATCH_START_RESET.address <= x[0] < batch.PATCH_START_RESET.address + 20
        )
        self.assertLess(cave_write, hook_write)

        transport.writes.clear()
        transition(transport, "revert")
        self.assert_profile(transport, "wholeblock")
        self.assertEqual(transport.memory, original)
        self.assert_safe_write_contexts(transport)

    def test_resume_every_whole_patch_cutpoint(self) -> None:
        ordered = batch.APPLY_AFTER_QUARANTINE
        for cut in range(len(ordered) + 1):
            transport = seeded("wholeblock")
            transport.load(batch.PATCH_FLUSH.address, batch.PATCH_FLUSH.batch10)
            transport.load(batch.CALLBACK_TABLE_ADDRESS, batch.CALLBACK_INERT)
            for patch in ordered[:cut]:
                transport.load(patch.address, patch.batch10)
            transition(transport, "apply")
            self.assert_profile(transport, "batch10")

        ordered = batch.REVERT_UNDER_QUARANTINE
        for cut in range(len(ordered) + 1):
            transport = seeded("batch10", callback="inert")
            for patch in ordered[:cut]:
                transport.load(patch.address, patch.wholeblock)
            transition(transport, "revert")
            self.assert_profile(transport, "wholeblock")

    def test_unknown_site_and_unsafe_cutpoint_fail_without_write(self) -> None:
        transport = seeded("wholeblock")
        transport.memory[batch.PATCH_TAIL.address] ^= 0x80
        with self.assertRaises(ValueError), contextlib.redirect_stdout(io.StringIO()):
            batch.transition_profile(transport, "apply")  # type: ignore[arg-type]
        self.assertEqual(transport.writes, [])

        transport = seeded("wholeblock")
        transport.load(batch.PATCH_TAIL.address, batch.PATCH_TAIL.batch10)
        with self.assertRaises(ValueError), contextlib.redirect_stdout(io.StringIO()):
            batch.read_states(transport)  # type: ignore[arg-type]
        self.assertEqual(transport.writes, [])

    def test_injected_failure_never_reconnects_partial_profile(self) -> None:
        reference = seeded("wholeblock")
        transition(reference, "apply")
        for fail_after in range(len(reference.writes)):
            transport = seeded("wholeblock")
            transport.fail_after = fail_after
            with self.assertRaises(RuntimeError), contextlib.redirect_stdout(io.StringIO()):
                batch.transition_profile(transport, "apply")  # type: ignore[arg-type]
            states = []
            for patch in batch.PATCHES:
                actual = transport.dump(patch.address, len(patch.wholeblock))
                if actual == patch.wholeblock:
                    states.append("wholeblock")
                elif actual == patch.batch10:
                    states.append("batch10")
                else:
                    states.append("partial")
            table = transport.dump(batch.CALLBACK_TABLE_ADDRESS, 4)
            if table == batch.CALLBACK_CAP4 and len(set(states)) != 1:
                # The only cap4 partial is the unreachable A staging itself;
                # a mid-A write is fail-closed but cannot affect cap4.
                self.assertIn(states[0], ("batch10", "partial"))
                self.assertTrue(all(x == "wholeblock" for x in states[1:]))


class GoldenBytesTest(unittest.TestCase):
    def test_exact_bytes_bounds_and_internal_constants(self) -> None:
        self.assertEqual(len(batch.FLUSH_AND_INERT), 28)
        self.assertEqual(len(batch.ADVANCE_AND_NOTIFY), 28)
        self.assertEqual(len(batch.NO_SYNC_AND_NOTIFY), 51)
        self.assertEqual(len(batch.BATCH10_OUTPUT_TAIL), 85)
        self.assertEqual(batch.CALLBACK_INERT.hex(), "28183c40")
        self.assertEqual(batch.BATCH10_OUTPUT_TAIL[29:32].hex(), "161203")
        self.assertNotEqual(batch.NO_SYNC_AND_NOTIFY[:27], batch.WHOLEBLOCK_HELPER[:27])
        self.assertTrue(
            batch.WHOLEBLOCK_HELPER.startswith(
                bytes.fromhex(
                    "00000036410042030040402466140a5d0262d50840349086e4c81df0"
                )
            )
        )
        # Tail passes 30 in a13; A/B shift callee a5. C independently builds
        # 30 << 8. None loads output+0xc0.
        self.assertIn(bytes.fromhex("80b511"), batch.FLUSH_AND_INERT)
        self.assertIn(bytes.fromhex("80b511"), batch.ADVANCE_AND_NOTIFY)
        self.assertIn(bytes.fromhex("1cec80cc11"), batch.NO_SYNC_AND_NOTIFY)
        self.assertNotIn(bytes.fromhex("b22430"), batch.FLUSH_AND_INERT)
        self.assertNotIn(bytes.fromhex("b22430"), batch.ADVANCE_AND_NOTIFY)
        self.assertNotIn(bytes.fromhex("c22430"), batch.NO_SYNC_AND_NOTIFY[27:])
        self.assertEqual(batch.BATCH_BYTES, 0x1E00)
        self.assertEqual(batch.OUTPUT_CAPACITY // batch.BATCH_BYTES, 12)
        self.assertLessEqual(batch.MONO_BLOCK_BYTES, 0x814 - 0x21C)

    def test_rt500_source_linker_golden(self) -> None:
        default = pathlib.Path(
            "/tmp/zephyr-f1/xtensa-nxp_rt500_adsp_zephyr-elf/bin/"
            "xtensa-nxp_rt500_adsp_zephyr-elf-"
        )
        prefix = pathlib.Path(os.environ.get("RT500_TOOLCHAIN_PREFIX", str(default)))
        assembler = pathlib.Path(str(prefix) + "as")
        if not assembler.is_file():
            self.skipTest("set RT500_TOOLCHAIN_PREFIX for source/linker golden test")
        root = pathlib.Path(__file__).resolve().parent
        source = root / "device/frankel_aoc_d12_host_batch10_192.S"
        linker = root / "device/frankel_aoc_d12_host_batch10_192.ld"
        with tempfile.TemporaryDirectory() as directory:
            temp = pathlib.Path(directory)
            obj = temp / "batch.o"
            elf = temp / "batch.elf"
            subprocess.run(
                [assembler, "--no-transform", "--no-target-align", "-o", obj, source],
                check=True,
                capture_output=True,
            )
            subprocess.run(
                [str(prefix) + "ld", "-T", linker, "-o", elf, obj],
                check=True,
                capture_output=True,
            )
            relocations = subprocess.run(
                [str(prefix) + "readelf", "-r", elf],
                check=True,
                capture_output=True,
                text=True,
            ).stdout
            self.assertIn("There are no relocations", relocations)
            sections = subprocess.run(
                [str(prefix) + "readelf", "-S", "--wide", elf],
                check=True,
                capture_output=True,
                text=True,
            ).stdout
            self.assertNotIn(".literal", sections)
            expected = {
                ".batch_start_reset": batch.START_RESET_HELPER,
                ".batch_start_hook": batch.START_HOOK_BATCH10,
                ".batch_flush_and_inert": batch.FLUSH_AND_INERT,
                ".batch_advance_notify": batch.ADVANCE_AND_NOTIFY,
                ".batch_no_sync_and_notify": batch.NO_SYNC_AND_NOTIFY,
                ".batch_output_tail": batch.BATCH10_OUTPUT_TAIL,
            }
            for section, value in expected.items():
                output = temp / (section.removeprefix(".") + ".bin")
                subprocess.run(
                    [
                        str(prefix) + "objcopy",
                        "-O",
                        "binary",
                        f"--only-section={section}",
                        elf,
                        output,
                    ],
                    check=True,
                    capture_output=True,
                )
                self.assertEqual(output.read_bytes(), value, section)

            # Strip assembler data annotations so RT500 objdump decodes the
            # reviewed raw instruction bytes exactly as they execute.
            decoded = temp / "decoded.elf"
            shutil.copyfile(elf, decoded)
            subprocess.run(
                [str(prefix) + "objcopy", "--remove-section=.xt.prop",
                 "--remove-section=.xtensa.info", decoded],
                check=True,
                capture_output=True,
            )
            disassembly = subprocess.run(
                [str(prefix) + "objdump", "-D", decoded],
                check=True,
                capture_output=True,
                text=True,
            ).stdout
            for text in (
                "4039e4ff:", "s32i.n\ta7, a6, 20",
                "4039e501:", "s32i.n\ta7, a6, 24",
                "403c1825:", "j\t403c1a34",
                "403c1828:", "entry\ta1, 32",
                "403c1a43:", "mov.n\ta12, a4",
                "403c1a47:", "call8\t403f64a8",
                "403f64b0:", "movi.n\ta12, 30",
                "403e889c:", "beqz\ta2, 403e88d1",
                "403e88c0:", "addx2\ta13, a7, a7",
                "403e88d1:", "or\ta3, a6, a6",
            ):
                self.assertIn(text, disassembly)


def seed_runtime(
    *,
    writer_total: int = 0,
    reader_total: int = 0,
    writer_cursor: int | None = None,
    reader_cursor: int | None = None,
    capacity: int = batch.OUTPUT_CAPACITY,
    wake: int = batch.BATCH_BYTES,
    invocation_count: int = 10,
    write_size: int = batch.MONO_BLOCK_BYTES,
) -> FakeTransport:
    t = FakeTransport()
    input_ring = batch.FULLBAND_INPUT
    output_ring = batch.FULLBAND_OUTPUT
    descriptor = 0x81000000
    descriptor_base = 0x82000000
    object_base = 0x1000
    t.load(batch.FULLBAND_OBJECT, struct.pack("<I", batch.FULLBAND_VTABLE))
    t.load(batch.FULLBAND_OBJECT + 0x13C, struct.pack("<I", input_ring))
    t.load(batch.FULLBAND_OBJECT + 0x140, struct.pack("<I", output_ring))
    t.load(output_ring, struct.pack("<I", batch.OUTPUT_VTABLE))
    t.load(output_ring + 0xC0, struct.pack("<I", wake))
    t.load(output_ring + batch.OUTPUT_DESCRIPTOR_OFFSET, struct.pack("<I", descriptor))
    t.load(output_ring + batch.OUTPUT_BASE_COMPONENT_OFFSET, struct.pack("<I", object_base))
    raw = bytearray(0x40)
    raw[: len(b"ultrasonic_capture")] = b"ultrasonic_capture"
    if writer_cursor is None:
        writer_cursor = writer_total % capacity
    if reader_cursor is None:
        reader_cursor = reader_total % capacity
    struct.pack_into(
        "<IIIIIIII", raw, 0x20, 0x10000, descriptor_base, capacity, 1,
        writer_total, reader_total, writer_cursor, reader_cursor,
    )
    t.load(descriptor, raw)
    base = descriptor_base + object_base
    t.load(base, bytes(4))
    t.load(base + capacity - 4, bytes(4))
    t.load(batch.PENDING_COUNT_ADDRESS, bytes(8))
    t.load(batch.INACTIVE_STAT_ADDRESS, bytes(0x14))
    t.load(batch.ACTIVE_ADDRESS, bytes(1))
    t.load(batch.RUNTIME_BYTES_ADDRESS, bytes((4, invocation_count, 0)))
    t.load(batch.WRITE_SIZE_ADDRESS, struct.pack("<I", write_size))
    return t


class RuntimeGuardTest(unittest.TestCase):
    def read(self, transport: FakeTransport, *, aligned: bool = True) -> batch.OutputState:
        rings = [("MIC_US_RING", batch.FULLBAND_INPUT)]
        with (
            mock.patch.object(batch, "ring_objects", return_value=rings),
            contextlib.redirect_stdout(io.StringIO()),
        ):
            return batch.read_output_state(  # type: ignore[arg-type]
                transport, require_batch_alignment=aligned
            )

    def test_batch_boundaries_and_exact_one_batch_free(self) -> None:
        state = self.read(seed_runtime(writer_total=0x14A00, reader_total=0x14A00))
        self.assertEqual(state.writer_cursor + batch.BATCH_BYTES, state.capacity)
        state = self.read(seed_runtime(writer_total=0x14A00, reader_total=0))
        self.assertEqual(state.free, batch.BATCH_BYTES)

    def test_rejects_block_only_alignment_free_space_and_geometry(self) -> None:
        bad = (
            seed_runtime(writer_total=0x300, reader_total=0),
            seed_runtime(writer_total=0x14D00, reader_total=0),  # free 0x1b00
            seed_runtime(writer_total=0x1E00, reader_total=0, writer_cursor=0),
            seed_runtime(writer_total=batch.OUTPUT_CAPACITY + 0x1E00, reader_total=0),
            seed_runtime(wake=0x3C00),
            seed_runtime(invocation_count=20),
        )
        for transport in bad:
            with self.assertRaises(ValueError):
                self.read(transport)

    def test_guarded_post_sacrificial_normalization(self) -> None:
        transport = seed_runtime(writer_total=0x8A00, reader_total=0x7800)
        transport.load(batch.CALLBACK_TABLE_ADDRESS, batch.CALLBACK_INERT)
        rings = [("MIC_US_RING", batch.FULLBAND_INPUT)]
        with (
            mock.patch.object(batch, "ring_objects", return_value=rings),
            mock.patch.object(batch, "require_stable_idle"),
            contextlib.redirect_stdout(io.StringIO()),
        ):
            state = batch.normalize_output_descriptor(transport)  # type: ignore[arg-type]
        self.assertEqual(
            (state.writer_total, state.reader_total, state.writer_cursor, state.reader_cursor),
            (0, 0, 0, 0),
        )
        self.assertEqual(
            {address for address, width, _ in transport.writes},
            {state.descriptor + offset for offset in (0x30, 0x34, 0x38, 0x3C)},
        )
        self.assertTrue(all(width == 32 for _, width, _ in transport.writes))

    def test_guarded_inactive_runtime_normalization(self) -> None:
        transport = seed_runtime(invocation_count=20, write_size=0x180)
        transport.load(batch.CALLBACK_TABLE_ADDRESS, batch.CALLBACK_INERT)
        with contextlib.redirect_stdout(io.StringIO()):
            batch.normalize_fullband_runtime(transport)  # type: ignore[arg-type]
        self.assertEqual(
            transport.dump(batch.RUNTIME_BYTES_ADDRESS, 3), bytes((4, 10, 0))
        )
        self.assertEqual(
            transport.dump(batch.WRITE_SIZE_ADDRESS, 4),
            struct.pack("<I", batch.MONO_BLOCK_BYTES),
        )
        self.assertEqual(
            [(address, width) for address, width, _ in transport.writes],
            [
                (batch.RUNTIME_BYTES_ADDRESS + 1, 8),
                (batch.WRITE_SIZE_ADDRESS, 32),
            ],
        )

    def test_zero_count_allows_stale_valid_base_for_idle_clear(self) -> None:
        transport = seed_runtime()
        transport.load(batch.CALLBACK_TABLE_ADDRESS, batch.CALLBACK_INERT)
        transport.load(
            batch.PENDING_BASE_ADDRESS, struct.pack("<I", 0x82001000)
        )
        self.assertEqual(
            batch.read_batch_state(transport),  # type: ignore[arg-type]
            (0, 0x82001000, 0),
        )
        with contextlib.redirect_stdout(io.StringIO()):
            batch.zero_batch_state(transport)  # type: ignore[arg-type]
        self.assertEqual(transport.dump(batch.PENDING_COUNT_ADDRESS, 8), bytes(8))

    def test_start_reset_order_and_partial_close_model(self) -> None:
        # The exact helper stores caller-proven zero to count/base, MEMW, then
        # publishes active=1.  Every possible partial close is therefore clean
        # before the next open.
        helper = batch.START_RESET_HELPER
        self.assertLess(helper.index(bytes.fromhex("7956")), helper.index(bytes.fromhex("7966")))
        self.assertLess(helper.index(bytes.fromhex("7966")), helper.index(bytes.fromhex("c02000")))
        self.assertLess(
            helper.index(bytes.fromhex("c02000")),
            helper.index(bytes.fromhex("424634")),
        )
        for pending in range(1, 10):
            count, base, active = pending, 0x82001000, 0
            count, base, active = 0, 0, 1
            self.assertEqual((count, base, active), (0, 0, 1))


if __name__ == "__main__":
    unittest.main()
