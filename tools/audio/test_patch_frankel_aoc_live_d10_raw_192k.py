#!/usr/bin/env python3
"""Focused host tests for the low-traffic Frankel D10 patch transaction."""

from __future__ import annotations

import contextlib
import io
import unittest
from collections import Counter
from types import SimpleNamespace
from unittest import mock

import patch_frankel_aoc_live_d10_raw_192k as d10


CAVE_ADDRESS = 0x403DB863


class MemoryTransport:
    """Byte-addressed transport with optional ambiguous raw-SET failure."""

    def __init__(
        self,
        state: str = "stock",
        *,
        fail_write_number: int | None = None,
        fail_after_write: bool = False,
    ) -> None:
        self.memory: dict[int, int] = {}
        self.dump_calls: list[tuple[int, int]] = []
        self.write_calls: list[tuple[int, int, int]] = []
        self.run_calls: list[tuple[str, ...]] = []
        self.fail_write_number = fail_write_number
        self.fail_after_write = fail_after_write

        if state not in ("stock", "patched"):
            raise ValueError(state)
        for patch in d10.PATCHES:
            self.put(
                patch.address,
                patch.before if state == "stock" else patch.after,
            )
        for guard in d10.NATIVE_96_STOCK_GUARDS:
            self.put(guard.address, guard.expected)
        self.put(d10.CACHE_FLUSH_DISPATCH.address, d10.CACHE_FLUSH_DISPATCH.before)

    def put(self, address: int, data: bytes) -> None:
        for offset, value in enumerate(data):
            self.memory[address + offset] = value

    def bytes_at(self, address: int, size: int) -> bytes:
        return bytes(self.memory.get(address + offset, 0) for offset in range(size))

    def dump(self, address: int, size: int) -> bytes:
        self.dump_calls.append((address, size))
        return self.bytes_at(address, size)

    def write_unverified(self, address: int, value: int, width: int) -> None:
        self.write_calls.append((address, value, width))
        write_number = len(self.write_calls)
        if write_number == self.fail_write_number and not self.fail_after_write:
            raise RuntimeError("injected raw SET failure before consumption")
        self.put(address, value.to_bytes(width // 8, "little"))
        if write_number == self.fail_write_number and self.fail_after_write:
            raise RuntimeError("injected raw SET failure after consumption")

    def run(self, *arguments: str, **_kwargs: object) -> SimpleNamespace:
        self.run_calls.append(arguments)
        # The qualified cache invalidator may surface tinymix's generic failure.
        return SimpleNamespace(returncode=1, stdout=b"", stderr=b"")


def site_size(site: d10.MemorySite) -> int:
    return len(d10.site_stock_bytes(site))


def expected_patch_order(action: str) -> tuple[d10.Patch, ...]:
    cave = tuple(patch for patch in d10.PATCHES if patch.address == CAVE_ADDRESS)
    activation = tuple(patch for patch in d10.PATCHES if patch.activation)
    support = tuple(
        patch
        for patch in d10.PATCHES
        if patch.address != CAVE_ADDRESS and not patch.activation
    )
    if action == "apply":
        return cave + support + activation
    if action == "revert":
        return activation + tuple(reversed(support)) + tuple(reversed(cave))
    raise ValueError(action)


def expected_chunks(action: str) -> tuple[d10.WriteChunk, ...]:
    return tuple(
        chunk
        for patch in expected_patch_order(action)
        for chunk in d10.changed_chunks(patch, action)
    )


def raw_call(chunk: d10.WriteChunk) -> tuple[int, int, int]:
    return (
        chunk.address,
        int.from_bytes(chunk.after, "little"),
        chunk.width,
    )


def cache_calls() -> list[tuple[int, int, int]]:
    dispatch = d10.CACHE_FLUSH_DISPATCH
    return [
        (dispatch.address, int.from_bytes(dispatch.after, "little"), 32),
        (dispatch.address, int.from_bytes(dispatch.before, "little"), 32),
    ]


class MinimalTrafficTest(unittest.TestCase):
    def run_quiet(
        self, transport: MemoryTransport, action: str, set_delay_ms: int = 0
    ) -> int:
        with contextlib.redirect_stdout(io.StringIO()):
            return d10.run_minimal_traffic(
                transport, action, set_delay_ms=set_delay_ms
            )

    def assert_profile(self, transport: MemoryTransport, state: str) -> None:
        for patch in d10.PATCHES:
            expected = patch.before if state == "stock" else patch.after
            self.assertEqual(
                transport.bytes_at(patch.address, len(expected)),
                expected,
                patch.name,
            )
        self.assertEqual(
            transport.bytes_at(
                d10.CACHE_FLUSH_DISPATCH.address,
                len(d10.CACHE_FLUSH_DISPATCH.before),
            ),
            d10.CACHE_FLUSH_DISPATCH.before,
        )

    def test_grouped_ranges_cover_complete_variable_width_sites(self) -> None:
        all_sites: tuple[d10.MemorySite, ...] = (
            d10.PATCHES
            + d10.NATIVE_96_STOCK_GUARDS
            + (d10.CACHE_FLUSH_DISPATCH,)
        )
        all_ranges = d10.grouped_dump_ranges(all_sites)
        profile_ranges = d10.grouped_dump_ranges(d10.PATCHES)

        self.assertEqual(len(all_ranges), 15)
        self.assertEqual(len(profile_ranges), 14)
        for start, size in all_ranges:
            self.assertGreater(size, 0)
            self.assertLessEqual(size, d10.MAX_GROUPED_DUMP_BYTES)
        for site in all_sites:
            self.assertTrue(
                any(
                    start <= site.address
                    and site.address + site_size(site) <= start + size
                    for start, size in all_ranges
                ),
                getattr(site, "name", hex(site.address)),
            )

        chunks = expected_chunks("apply")
        self.assertEqual(len(chunks), 31)
        self.assertEqual(
            Counter(chunk.width for chunk in chunks),
            {32: 16, 16: 10, 8: 5},
        )

    def test_minimal_apply_writes_cave_first_and_activation_last(self) -> None:
        transport = MemoryTransport("stock")
        chunks = expected_chunks("apply")

        with mock.patch.object(d10.time, "sleep") as sleep:
            self.assertEqual(
                self.run_quiet(transport, "apply", set_delay_ms=2),
                0,
            )

        self.assertEqual(
            transport.write_calls,
            [raw_call(chunk) for chunk in chunks] + cache_calls(),
        )
        self.assertEqual(sleep.call_args_list, [mock.call(0.002)] * len(chunks))
        self.assertTrue(chunks[0].patch.address == CAVE_ADDRESS)
        self.assertTrue(chunks[-1].patch.activation)
        self.assert_profile(transport, "patched")

    def test_minimal_revert_disconnects_activation_and_erases_cave_last(self) -> None:
        transport = MemoryTransport("patched")
        chunks = expected_chunks("revert")

        self.assertEqual(self.run_quiet(transport, "revert"), 0)

        self.assertEqual(
            transport.write_calls,
            [raw_call(chunk) for chunk in chunks] + cache_calls(),
        )
        self.assertTrue(chunks[0].patch.activation)
        self.assertEqual(chunks[-1].patch.address, CAVE_ADDRESS)
        self.assert_profile(transport, "stock")

    def test_unknown_profile_or_stock_guard_fails_before_any_set(self) -> None:
        cases: list[tuple[str, MemoryTransport]] = []

        unknown_patch = MemoryTransport("stock")
        unknown_patch.put(d10.PATCHES[0].address, bytes.fromhex("deadbeef0000"))
        cases.append(("unknown patch", unknown_patch))

        bad_native_guard = MemoryTransport("stock")
        guard = d10.NATIVE_96_STOCK_GUARDS[0]
        corrupted_guard = bytearray(guard.expected)
        corrupted_guard[0] ^= 0xFF
        bad_native_guard.put(guard.address, bytes(corrupted_guard))
        cases.append(("native guard", bad_native_guard))

        bad_dispatch = MemoryTransport("stock")
        bad_dispatch.put(
            d10.CACHE_FLUSH_DISPATCH.address,
            d10.CACHE_FLUSH_DISPATCH.after,
        )
        cases.append(("cache dispatch", bad_dispatch))

        mixed_profile = MemoryTransport("stock")
        mixed_profile.put(d10.PATCHES[0].address, d10.PATCHES[0].after)
        cases.append(("mixed profile", mixed_profile))

        for label, transport in cases:
            with self.subTest(label=label):
                with self.assertRaises((RuntimeError, ValueError)):
                    self.run_quiet(transport, "apply")
                self.assertEqual(transport.write_calls, [])

    def test_ambiguous_raw_set_failure_rolls_back_complete_profile(self) -> None:
        # Exercise both sides of the host/device ambiguity: the failing SET may
        # have been rejected before mutation or consumed before its error reply.
        for fail_after_write in (False, True):
            with self.subTest(fail_after_write=fail_after_write):
                transport = MemoryTransport(
                    "stock",
                    fail_write_number=7,
                    fail_after_write=fail_after_write,
                )
                with self.assertRaisesRegex(
                    RuntimeError, "restored the complete initial profile"
                ):
                    self.run_quiet(transport, "apply")
                self.assert_profile(transport, "stock")

    def test_main_selects_minimal_path_and_restores_capture_modes(self) -> None:
        args = SimpleNamespace(
            action="apply",
            adb="adb",
            adb_server_port=5038,
            serial=None,
            counter=None,
            minimal_traffic=True,
            set_delay_ms=2,
        )
        transport = object()
        modes = {"/dev/snd/pcmC0D10c": "660"}
        with (
            mock.patch.object(d10, "parse_args", return_value=args),
            mock.patch.object(d10, "AocFactoryDiag", return_value=transport),
            mock.patch.object(d10, "require_identity"),
            mock.patch.object(d10, "select_native_helper"),
            mock.patch.object(d10, "block_capture_opens", return_value=modes),
            mock.patch.object(d10, "require_capture_idle"),
            mock.patch.object(d10, "require_strict_runtime"),
            mock.patch.object(d10, "require_stock_guards") as guards,
            mock.patch.object(d10, "read_states") as read_states,
            mock.patch.object(d10, "run_minimal_traffic", return_value=0) as run,
            mock.patch.object(d10, "restore_capture_modes") as restore,
        ):
            self.assertEqual(d10.main(), 0)

        guards.assert_called_once_with(transport)
        read_states.assert_not_called()
        run.assert_called_once_with(transport, "apply", 2)
        restore.assert_called_once_with(transport, modes)


if __name__ == "__main__":
    unittest.main()
