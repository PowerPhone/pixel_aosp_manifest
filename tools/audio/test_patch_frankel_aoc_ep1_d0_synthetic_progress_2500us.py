#!/usr/bin/env python3
"""Exact-module tests for the D0 synthetic-progress diagnostic."""

from __future__ import annotations

import pathlib
import sys
import unittest


HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import patch_frankel_aoc_ep1_d0_synthetic_progress_2500us as patcher  # noqa: E402


class D0SyntheticProgressTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.module = (
            HERE.parent.parent
            / "work/audio-research/frankel/"
            "speaker-ep1-source0-192k-d0-pure-timer-1ms-pair/trial-2/"
            "aoc_alsa_dev_util.ep1-source0-192k-prefill-d0-pure-timer-1ms.ko"
        )
        if not cls.module.is_file():
            raise unittest.SkipTest(f"missing exact trial module: {cls.module}")

    def test_exact_reversible_transform(self) -> None:
        original = self.module.read_bytes()
        self.assertEqual(patcher.classify(original), "pure-timer")
        candidate = bytearray(original)
        patcher.transform(candidate, "synthetic-2500us")
        self.assertEqual(patcher.classify(candidate), "synthetic-2500us")
        patcher.transform(candidate, "pure-timer")
        self.assertEqual(bytes(candidate), original)

    def test_wrong_state_is_rejected(self) -> None:
        candidate = bytearray(self.module.read_bytes())
        candidate[0x1A138] ^= 1
        with self.assertRaises(ValueError):
            patcher.classify(candidate)


if __name__ == "__main__":
    unittest.main()
