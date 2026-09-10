#!/usr/bin/env python3
"""Exact-module tests for the guarded Frankel EP1 ring-prefill patch."""

from __future__ import annotations

import pathlib
import unittest

import patch_frankel_aoc_ep1_d0_ring_prefill as prefill


class Ep1D0RingPrefillTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.repository = pathlib.Path(__file__).resolve().parents[2]
        cls.module = (
            cls.repository
            / "work/audio-research/frankel/speaker-ep1-source0-192k-pair"
            / "trial-1/aoc_alsa_dev_util.ep1-source0-192k.ko"
        )
        if not cls.module.is_file():
            raise unittest.SkipTest("reviewed Frankel EP1 module is not staged")

    def test_round_trip_and_exact_hashes(self) -> None:
        data = bytearray(self.module.read_bytes())
        self.assertEqual(prefill.classify(data), "stock")
        prefill.transform(data, "patched")
        self.assertEqual(prefill.digest(data), prefill.PATCHED_SHA256)
        self.assertEqual(prefill.classify(data), "patched")
        prefill.transform(data, "stock")
        self.assertEqual(prefill.digest(data), prefill.STOCK_SHA256)
        self.assertEqual(prefill.classify(data), "stock")

    def test_unknown_hook_byte_is_rejected(self) -> None:
        data = bytearray(self.module.read_bytes())
        data[0x13658] ^= 0x80
        with self.assertRaises(ValueError):
            prefill.classify(data)

    def test_cave_is_d0_only(self) -> None:
        cave = next(after for offset, _, after, _ in prefill.PATCHES if offset == 0xD970)
        self.assertEqual(
            cave,
            bytes.fromhex("62e70254c8f640b91f01007100e7025472170014"),
        )
        # cmp w8,#0 is the only semantic delta from the reviewed D28 cave,
        # whose corresponding instruction is 1f710071 (cmp w8,#28).
        self.assertEqual(cave[8:12], bytes.fromhex("1f010071"))


if __name__ == "__main__":
    unittest.main()
