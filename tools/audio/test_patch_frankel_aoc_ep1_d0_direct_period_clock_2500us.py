#!/usr/bin/env python3
"""Exact-byte tests for the Frankel D0 direct period clock."""

from __future__ import annotations

import pathlib
import sys
import unittest


HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import patch_frankel_aoc_ep1_d0_direct_period_clock_2500us as patcher  # noqa: E402


class D0DirectPeriodClockTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.module = (
            HERE.parent.parent
            / "work/audio-research/frankel/"
            "speaker-ep1-source0-192k-d0-pure-timer-1ms-pair/trial-1/"
            "aoc_alsa_dev_util.ep1-source0-192k-prefill-d0-pure-timer-1ms.ko"
        )
        if not cls.module.is_file():
            raise unittest.SkipTest(f"missing exact base module: {cls.module}")

    def test_exact_reversible_transform(self) -> None:
        original = self.module.read_bytes()
        self.assertEqual(patcher.classify(original), "pure-timer-1ms")
        candidate = bytearray(original)
        patcher.transform(candidate, "d0-direct-period-clock-2500us")
        self.assertEqual(
            patcher.classify(candidate), "d0-direct-period-clock-2500us"
        )
        patcher.transform(candidate, "pure-timer-1ms")
        self.assertEqual(bytes(candidate), original)

    def test_all_caves_avoid_relocated_prefixes(self) -> None:
        cave_offsets = {offset for offset, _a, _b, _n in patcher.PATCHES[:3]}
        self.assertEqual(cave_offsets, {0xD680, 0xD6A4, 0xDA64})
        relocated_prefixes = {0xD674, 0xD678, 0xD698, 0xD69C, 0xDA58, 0xDA5C}
        for offset, before, _after, _name in patcher.PATCHES[:3]:
            span = set(range(offset, offset + len(before)))
            self.assertTrue(span.isdisjoint(relocated_prefixes))

    def test_partial_state_is_rejected(self) -> None:
        candidate = bytearray(self.module.read_bytes())
        candidate[0x1A134] ^= 1
        with self.assertRaises(ValueError):
            patcher.classify(candidate)


if __name__ == "__main__":
    unittest.main()
