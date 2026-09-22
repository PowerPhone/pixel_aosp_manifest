#!/usr/bin/env python3
"""Offline exact-byte and fail-closed tests for the D12 batch-two overlay."""

from __future__ import annotations

import contextlib
import io
import unittest
from unittest import mock

import patch_frankel_aoc_d12_host_batch2_192k as batch2


class FakeTransport:
    def __init__(self) -> None:
        self.memory: dict[int, int] = {}
        self.writes: list[tuple[int, int, bytes]] = []

    def load(self, address: int, value: bytes) -> None:
        for offset, byte in enumerate(value):
            self.memory[address + offset] = byte

    def dump(self, address: int, size: int) -> bytes:
        try:
            return bytes(self.memory[address + offset] for offset in range(size))
        except KeyError as error:
            raise AssertionError(f"unseeded fake address 0x{error.args[0]:08x}")

    def write(self, address: int, value: int, width: int) -> None:
        callback_before = self.dump(batch2.batch10.CALLBACK_TABLE_ADDRESS, 4)
        self.load(address, value.to_bytes(width // 8, "little"))
        self.writes.append((address, width, callback_before))


def seeded(profile: str) -> FakeTransport:
    transport = FakeTransport()
    for patch in batch2.batch10.PATCHES:
        transport.load(
            patch.address,
            batch2.profile_region_expected(patch, profile),
        )
    transport.load(
        batch2.batch10.CALLBACK_TABLE_ADDRESS,
        batch2.batch10.CALLBACK_CAP4,
    )
    return transport


class ExactBytesTest(unittest.TestCase):
    def test_batch_two_geometry_and_exact_aligned_writes(self) -> None:
        self.assertEqual(batch2.BATCH2_BLOCKS, 2)
        self.assertEqual(batch2.BATCH2_BYTES, 0x600)
        self.assertEqual(batch2.batch10.BATCH_BYTES // batch2.BATCH2_BYTES, 5)
        self.assertEqual(batch2.batch10.OUTPUT_CAPACITY % batch2.BATCH2_BYTES, 0)

        apply_chunks = [
            (chunk.address, chunk.width, chunk.before.hex(), chunk.after.hex())
            for patch in batch2.PATCHES
            for chunk in batch2.changed_chunks(patch, "apply")
        ]
        self.assertEqual(
            apply_chunks,
            [
                (0x403F64B0, 16, "1cec", "0c6c"),
                (0x403E88BE, 16, "9710", "2710"),
            ],
        )
        revert_chunks = [
            (chunk.address, chunk.width, chunk.before.hex(), chunk.after.hex())
            for patch in reversed(batch2.PATCHES)
            for chunk in batch2.changed_chunks(patch, "revert")
        ]
        self.assertEqual(
            revert_chunks,
            [
                (0x403E88BE, 16, "2710", "9710"),
                (0x403F64B0, 16, "0c6c", "1cec"),
            ],
        )

    def test_full_owned_regions_differ_only_at_reviewed_sites(self) -> None:
        helper_diffs = [
            offset
            for offset, pair in enumerate(
                zip(batch2.batch10.PATCH_HELPERS.batch10, batch2.BATCH2_HELPERS)
            )
            if pair[0] != pair[1]
        ]
        tail_diffs = [
            offset
            for offset, pair in enumerate(
                zip(batch2.batch10.PATCH_TAIL.batch10, batch2.BATCH2_OUTPUT_TAIL)
            )
            if pair[0] != pair[1]
        ]
        self.assertEqual(helper_diffs, [0x23, 0x24])
        self.assertEqual(tail_diffs, [0x3F])

    def test_profile_classifier_rejects_a_mixed_pair(self) -> None:
        transport = seeded("batch10")
        transport.load(
            batch2.batch10.PATCH_HELPERS.address,
            batch2.BATCH2_HELPERS,
        )
        with self.assertRaises(ValueError), contextlib.redirect_stdout(io.StringIO()):
            batch2.read_profile_state(transport)  # type: ignore[arg-type]


class TransitionTest(unittest.TestCase):
    def run_transition(
        self,
        transport: FakeTransport,
        action: str,
        initial: str,
        *,
        runtime_error: bool = False,
    ) -> mock.Mock:
        flush = mock.Mock()
        runtime = mock.Mock(
            side_effect=RuntimeError("injected post-reconnect failure")
            if runtime_error
            else None
        )
        with (
            mock.patch.object(batch2.batch10, "require_stable_idle"),
            mock.patch.object(batch2.batch10, "normalize_fullband_runtime"),
            mock.patch.object(batch2.batch10, "normalize_output_descriptor"),
            mock.patch.object(batch2.batch10, "zero_batch_state"),
            mock.patch.object(batch2, "flush_instruction_cache", flush),
            mock.patch.object(batch2, "read_runtime_state", runtime),
            contextlib.redirect_stdout(io.StringIO()),
        ):
            batch2.transition(transport, action, initial)  # type: ignore[arg-type]
        return flush

    def assert_instruction_writes_are_inert(self, transport: FakeTransport) -> None:
        for address, _width, callback_before in transport.writes:
            if address == batch2.batch10.CALLBACK_TABLE_ADDRESS:
                continue
            self.assertEqual(callback_before, batch2.batch10.CALLBACK_INERT)

    def test_apply_revert_preserves_batch10_as_a_guarded_profile(self) -> None:
        transport = seeded("batch10")
        flush = self.run_transition(transport, "apply", "batch10")
        self.assertEqual(flush.call_count, 1)
        profile, callback = batch2.read_profile_state(transport)  # type: ignore[arg-type]
        self.assertEqual((profile, callback), ("batch2", "cap4"))
        self.assert_instruction_writes_are_inert(transport)

        transport.writes.clear()
        flush = self.run_transition(transport, "revert", "batch2")
        self.assertEqual(flush.call_count, 1)
        profile, callback = batch2.read_profile_state(transport)  # type: ignore[arg-type]
        self.assertEqual((profile, callback), ("batch10", "cap4"))
        self.assert_instruction_writes_are_inert(transport)

    def test_post_reconnect_failure_requarantines_before_rollback(self) -> None:
        transport = seeded("batch10")
        with (
            self.assertRaises(RuntimeError),
            mock.patch.object(batch2.batch10, "require_stable_idle"),
            mock.patch.object(batch2.batch10, "normalize_fullband_runtime"),
            mock.patch.object(batch2.batch10, "normalize_output_descriptor"),
            mock.patch.object(batch2.batch10, "zero_batch_state"),
            mock.patch.object(batch2, "flush_instruction_cache") as flush,
            mock.patch.object(
                batch2,
                "read_runtime_state",
                side_effect=RuntimeError("injected post-reconnect failure"),
            ),
            contextlib.redirect_stdout(io.StringIO()),
        ):
            batch2.transition(transport, "apply", "batch10")  # type: ignore[arg-type]

        self.assertEqual(flush.call_count, 2)
        profile, callback = batch2.read_profile_state(transport)  # type: ignore[arg-type]
        self.assertEqual((profile, callback), ("batch10", "inert"))
        self.assert_instruction_writes_are_inert(transport)


if __name__ == "__main__":
    unittest.main()
