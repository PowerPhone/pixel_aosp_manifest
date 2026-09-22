#!/usr/bin/env python3
"""Exact-module tests for Frankel's D0 one-period startup cushion."""

from __future__ import annotations

import pathlib
import sys
import unittest


HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import patch_frankel_aoc_ep1_d0_one_period_lag as patcher  # noqa: E402


class D0OnePeriodLagPatchTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.module = (
            HERE.parent.parent
            / "work/audio-research/frankel/"
            "speaker-ep1-source0-192k-d0-hybrid-real-progress-pair/trial-1/"
            "aoc_alsa_dev_util.ep1-source0-192k-d0-hybrid-real-progress.ko"
        )
        if not cls.module.is_file():
            raise unittest.SkipTest(f"missing exact base module: {cls.module}")

    def test_exact_reversible_transform(self) -> None:
        original = self.module.read_bytes()
        self.assertEqual(patcher.classify(original), patcher.BASE_STATE)
        candidate = bytearray(original)
        patcher.transform(candidate, patcher.PATCHED_STATE)
        self.assertEqual(patcher.classify(candidate), patcher.PATCHED_STATE)
        patcher.transform(candidate, patcher.BASE_STATE)
        self.assertEqual(bytes(candidate), original)

    def test_lag_formula_and_d0_selector(self) -> None:
        original = self.module.read_bytes()
        candidate = bytearray(original)
        patcher.transform(candidate, patcher.PATCHED_STATE)

        # Existing selector remains: non-D0 returns actual x21 directly, while
        # D0 loads its prior report x2 and enters the replacement formula.
        self.assertEqual(candidate[0xD680:0xD6A4], original[0xD680:0xD6A4])
        self.assertEqual(candidate[0xD680:0xD698].hex(),
                         "68f240b968000034e10315aaaf32001462a640f904000014")

        self.assertEqual(
            candidate[0xD6A4:0xD6BC].hex(),
            "692241b94a40298ba1020aeb4100018b4190819aa4320014",
        )
        self.assertEqual(candidate[0x1A148:0x1A14C].hex(), "61a600f9")

    def test_unrelated_timer_and_write_guard_are_untouched(self) -> None:
        original = self.module.read_bytes()
        candidate = bytearray(original)
        patcher.transform(candidate, patcher.PATCHED_STATE)

        # D0 hybrid mailbox/timer selector and 1 ms interval are unchanged.
        self.assertEqual(candidate[0x1A5E0:0x1A60C], original[0x1A5E0:0x1A60C])
        # aoc_audio_write's avail<count branch remains strict.
        self.assertEqual(candidate[0x13640:0x13660], original[0x13640:0x13660])

    def test_partial_or_wrong_input_is_rejected(self) -> None:
        corrupted = bytearray(self.module.read_bytes())
        corrupted[0xD6AC] ^= 1
        with self.assertRaises(ValueError):
            patcher.classify(corrupted)


if __name__ == "__main__":
    unittest.main()
