"""Host-only tests for delayed/interleaved AoC factory-diag dump output."""

from __future__ import annotations

import pathlib
import struct
import sys
import unittest
from types import SimpleNamespace


sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from aoc_factory_diag import AocFactoryDiag  # noqa: E402


class DelayedDumpTest(unittest.TestCase):
    def make_transport(
        self, transactions: list[str], delayed: list[str]
    ) -> AocFactoryDiag:
        transport = object.__new__(AocFactoryDiag)
        transport.core = 1
        transport.native_helper = None

        def transact(_command: int, _payload: bytes) -> str:
            return transactions.pop(0)

        def debug_output() -> str:
            return delayed.pop(0)

        transport.transact = transact  # type: ignore[method-assign]
        transport.debug_output = debug_output  # type: ignore[method-assign]
        return transport

    def test_accepts_memory_lines_from_a_later_debug_read(self) -> None:
        transport = self.make_transport(
            ["A3: unrelated statistics"],
            ["A3: more statistics", "0x4016cf58: 01 02 03 04"],
        )
        self.assertEqual(transport.dump(0x4016CF58, 4), b"\x01\x02\x03\x04")

    def test_retries_only_the_read_command_after_delayed_output_is_empty(self) -> None:
        transport = self.make_transport(
            ["noise", "0x81401000: ff 01 00 00"],
            ["noise", "noise"],
        )
        self.assertEqual(transport.dump(0x81401000, 4), b"\xff\x01\x00\x00")


class UnverifiedWriteTest(unittest.TestCase):
    def test_direct_path_issues_one_set_and_advances_counter(self) -> None:
        transport = object.__new__(AocFactoryDiag)
        transport.core = 2
        transport.counter = 7
        transport.native_helper = None
        calls: list[tuple[int, bytes]] = []

        def transact(command: int, payload: bytes) -> str:
            calls.append((command, payload))
            return ""

        transport.transact = transact  # type: ignore[method-assign]
        transport.write_unverified(0x403D36F0, 0xC0A02281, 32)

        self.assertEqual(len(calls), 1)
        self.assertEqual(calls[0][0], 0x25)
        self.assertEqual(
            struct.unpack("<iIIB", calls[0][1]),
            (2, 0x403D36F0, 0xC0A02281, 0),
        )
        self.assertEqual(transport.counter, 8)

    def test_new_native_helper_uses_write_raw_without_fallback(self) -> None:
        transport = object.__new__(AocFactoryDiag)
        transport.core = 2
        transport.counter = 7
        transport.native_helper = "/data/local/tmp/frankel_aoc_diag"
        commands: list[tuple[str, ...]] = []

        def run(*arguments: str, **_kwargs: object) -> SimpleNamespace:
            commands.append(arguments)
            return SimpleNamespace(returncode=0, stderr=b"")

        transport.run = run  # type: ignore[method-assign]
        transport.transact = lambda *_args: self.fail("unexpected fallback")  # type: ignore[method-assign]
        transport.write_unverified(0x403D36F0, 0xC0A02281, 32)

        self.assertEqual(
            commands,
            [
                (
                    "shell", "su", "0",
                    "/data/local/tmp/frankel_aoc_diag", "--core", "2",
                    "write-raw", "32", "0x403d36f0", "0xc0a02281",
                )
            ],
        )

    def test_old_native_helper_usage_error_falls_back_once(self) -> None:
        transport = object.__new__(AocFactoryDiag)
        transport.core = 2
        transport.counter = 255
        transport.native_helper = "/data/local/tmp/frankel_aoc_diag"
        calls: list[tuple[int, bytes]] = []
        transport.run = lambda *_args, **_kwargs: SimpleNamespace(  # type: ignore[method-assign]
            returncode=64, stderr=b"usage"
        )
        transport.transact = (  # type: ignore[method-assign]
            lambda command, payload: calls.append((command, payload)) or ""
        )

        transport.write_unverified(0x403D36F0, 0xC0A02281, 32)

        self.assertEqual(len(calls), 1)
        self.assertEqual(transport.counter, 0)


if __name__ == "__main__":
    unittest.main()
