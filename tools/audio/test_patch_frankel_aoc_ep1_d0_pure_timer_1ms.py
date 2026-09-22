#!/usr/bin/env python3
"""Exact-module tests for Frankel's D0 pure-timer correction."""

from __future__ import annotations

import pathlib
import sys
import unittest


HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import patch_frankel_aoc_ep1_d0_pure_timer_1ms as patcher  # noqa: E402


class D0PureTimerPatchTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.module = (
            HERE.parent.parent
            / "work/audio-research/frankel/"
            "speaker-ep1-source0-192k-d0-hybrid-progress-1ms-pair/trial-1/"
            "aoc_alsa_dev_util.ep1-source0-192k-prefill-d0-hybrid-1ms.ko"
        )
        if not cls.module.is_file():
            raise unittest.SkipTest(f"missing exact trial module: {cls.module}")

    def test_exact_reversible_transform(self) -> None:
        original = self.module.read_bytes()
        self.assertEqual(patcher.classify(original), "hybrid")
        candidate = bytearray(original)
        patcher.transform(candidate, "pure-timer")
        self.assertEqual(patcher.classify(candidate), "pure-timer")
        self.assertEqual(candidate[0x1A5DC : 0x1A5E0].hex(), "1ff901f9")
        patcher.transform(candidate, "hybrid")
        self.assertEqual(bytes(candidate), original)

    def test_corruption_is_rejected(self) -> None:
        candidate = bytearray(self.module.read_bytes())
        candidate[0x1A5DC] ^= 1
        with self.assertRaises(ValueError):
            patcher.classify(candidate)


if __name__ == "__main__":
    unittest.main()
