#!/usr/bin/env python3
"""Exact-byte tests for Frankel's D0 direct period delivery."""

from __future__ import annotations

import pathlib
import sys
import unittest


HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import patch_frankel_aoc_ep1_d0_direct_period_elapsed_2500us as patcher  # noqa: E402


class D0DirectPeriodElapsedTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.module = (
            HERE.parent.parent
            / "work/audio-research/frankel/"
            "speaker-ep1-source0-192k-d0-direct-period-clock-2500us-pair/"
            "module-only/"
            "aoc_alsa_dev_util.ep1-source0-192k-prefill-"
            "d0-direct-period-clock-2500us.ko"
        )
        if not cls.module.is_file():
            raise unittest.SkipTest(f"missing exact base module: {cls.module}")

    def test_exact_reversible_transform(self) -> None:
        original = self.module.read_bytes()
        self.assertEqual(patcher.classify(original), "d0-workqueue-period")
        candidate = bytearray(original)
        patcher.transform(candidate, "d0-direct-period-elapsed")
        self.assertEqual(patcher.classify(candidate), "d0-direct-period-elapsed")
        patcher.transform(candidate, "d0-workqueue-period")
        self.assertEqual(bytes(candidate), original)

    def test_exact_control_flow_words(self) -> None:
        self.assertEqual(patcher.OFFSET, 0xDA70)
        self.assertEqual(patcher.WORKQUEUE.hex(), "b93100141f2003d51f2003d5")
        self.assertEqual(patcher.DIRECT.hex(), "60c20691ea300094bc310014")

    def test_partial_state_is_rejected(self) -> None:
        candidate = bytearray(self.module.read_bytes())
        candidate[patcher.OFFSET] ^= 1
        with self.assertRaises(ValueError):
            patcher.classify(candidate)


if __name__ == "__main__":
    unittest.main()
