#!/usr/bin/env python3
"""Offline transition tests for the guarded Frankel whole-block patcher."""

from __future__ import annotations

import contextlib
import io
import unittest

import patch_frankel_aoc_d12_wholeblock_mono_192k as wholeblock


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
        size = width // 8
        table_before = self.dump(wholeblock.CALLBACK_TABLE_ADDRESS, 4)
        encoded = value.to_bytes(size, "little")
        self.load(address, encoded)
        self.writes.append((address, width, table_before))


def seeded(profile: str, *, connected: bool = True) -> FakeTransport:
    transport = FakeTransport()
    for patch in wholeblock.PATCHES:
        value = patch.full if profile == "full" else patch.wholeblock
        transport.load(patch.address, value)
    transport.load(
        wholeblock.CALLBACK_TABLE_ADDRESS,
        wholeblock.CALLBACK_TWO_PASS if connected else wholeblock.CALLBACK_STOCK,
    )
    return transport


def transition(transport: FakeTransport, action: str) -> None:
    with contextlib.redirect_stdout(io.StringIO()):
        wholeblock.transition_profile(transport, action)  # type: ignore[arg-type]


class WholeBlockTransitionTest(unittest.TestCase):
    def assert_profile(self, transport: FakeTransport, profile: str) -> None:
        for patch in wholeblock.PATCHES:
            expected = patch.full if profile == "full" else patch.wholeblock
            self.assertEqual(transport.dump(patch.address, len(expected)), expected)
        self.assertEqual(
            transport.dump(wholeblock.CALLBACK_TABLE_ADDRESS, 4),
            wholeblock.CALLBACK_TWO_PASS,
        )

    def assert_non_table_writes_quarantined(self, transport: FakeTransport) -> None:
        table_start = wholeblock.CALLBACK_TABLE_ADDRESS
        for address, _width, table_before in transport.writes:
            if table_start <= address < table_start + 4:
                continue
            self.assertEqual(table_before, wholeblock.CALLBACK_STOCK)

    def test_apply_and_revert_round_trip(self) -> None:
        transport = seeded("full")
        original = dict(transport.memory)

        transition(transport, "apply")
        self.assert_profile(transport, "wholeblock")
        self.assert_non_table_writes_quarantined(transport)
        self.assertEqual(transport.writes[0][0], wholeblock.CALLBACK_TABLE_ADDRESS)
        self.assertEqual(transport.writes[-1][0], wholeblock.CALLBACK_TABLE_ADDRESS)

        transport.writes.clear()
        transition(transport, "revert")
        self.assert_profile(transport, "full")
        self.assertEqual(transport.memory, original)
        self.assert_non_table_writes_quarantined(transport)
        self.assertEqual(transport.writes[0][0], wholeblock.CALLBACK_TABLE_ADDRESS)
        self.assertEqual(transport.writes[-1][0], wholeblock.CALLBACK_TABLE_ADDRESS)

    def test_resume_interrupted_apply_from_quarantine(self) -> None:
        transport = seeded("full", connected=False)
        for patch in wholeblock.PATCHES[:4]:
            transport.load(patch.address, patch.wholeblock)

        transition(transport, "apply")
        self.assert_profile(transport, "wholeblock")
        self.assert_non_table_writes_quarantined(transport)
        self.assertNotEqual(transport.writes[0][0], wholeblock.CALLBACK_TABLE_ADDRESS)
        self.assertEqual(transport.writes[-1][0], wholeblock.CALLBACK_TABLE_ADDRESS)

    def test_resume_interrupted_revert_from_quarantine(self) -> None:
        transport = seeded("wholeblock", connected=False)
        for patch in reversed(wholeblock.PATCHES[3:]):
            transport.load(patch.address, patch.full)

        transition(transport, "revert")
        self.assert_profile(transport, "full")
        self.assert_non_table_writes_quarantined(transport)
        self.assertEqual(transport.writes[-1][0], wholeblock.CALLBACK_TABLE_ADDRESS)

    def test_unknown_site_fails_before_callback_quarantine(self) -> None:
        transport = seeded("full")
        patch = wholeblock.PATCHES[3]
        transport.memory[patch.address] ^= 0xFF

        with self.assertRaises(ValueError), contextlib.redirect_stdout(io.StringIO()):
            wholeblock.transition_profile(transport, "apply")  # type: ignore[arg-type]
        self.assertEqual(transport.writes, [])
        self.assertEqual(
            transport.dump(wholeblock.CALLBACK_TABLE_ADDRESS, 4),
            wholeblock.CALLBACK_TWO_PASS,
        )

    def test_exact_linked_bytes_and_bounds(self) -> None:
        by_address = {patch.address: patch for patch in wholeblock.PATCHES}
        self.assertEqual(
            by_address[0x403E872D].wholeblock.hex(), "ff10751007008014"
        )
        self.assertEqual(by_address[0x403E877D].wholeblock.hex(), "807711")
        self.assertEqual(by_address[0x403E882D].wholeblock.hex(), "403490c13146")
        self.assertEqual(by_address[0x403E883A].wholeblock.hex(), "aee5b88e1b93")
        self.assertEqual(by_address[0x403E886A].wholeblock.hex(), "42d508c12146")
        self.assertEqual(by_address[0x403E867E].wholeblock.hex(), "7ef3bc0f0771")
        self.assertEqual(len(wholeblock.NO_SYNC_MONO_HELPER), 51)
        self.assertTrue(
            wholeblock.NO_SYNC_MONO_HELPER.startswith(
                bytes.fromhex(
                    "00000036410042030040402466140a5d0262d50840349086e4c81df0"
                )
            )
        )
        self.assertEqual(len(wholeblock.WHOLEBLOCK_CALLBACK), 60)
        self.assertEqual(0x403F0C44 + len(wholeblock.WHOLEBLOCK_CALLBACK), 0x403F0C80)
        self.assertEqual(wholeblock.WHOLEBLOCK_CALLBACK[49:52].hex(), "a58105")
        self.assertLessEqual(wholeblock.MONO_BLOCK_BYTES, 0x81C - 0x21C)
        self.assertEqual(
            wholeblock.OUTPUT_WAKE_THRESHOLD_BYTES % wholeblock.MONO_BLOCK_BYTES,
            0,
        )
        self.assertEqual(
            wholeblock.OUTPUT_DESCRIPTOR_CAPACITY % wholeblock.MONO_BLOCK_BYTES,
            0,
        )


if __name__ == "__main__":
    unittest.main()
