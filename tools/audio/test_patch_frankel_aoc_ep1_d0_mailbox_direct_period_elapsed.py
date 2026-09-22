#!/usr/bin/env python3
"""Exact-byte tests for real-mailbox D0 direct period delivery."""

from __future__ import annotations

import pathlib
import sys
import unittest


HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import patch_frankel_aoc_ep1_d0_mailbox_direct_period_elapsed as patcher  # noqa: E402


class D0MailboxDirectPeriodElapsedTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.module = (
            HERE.parent.parent
            / "work/audio-research/frankel/"
            "speaker-ep1-source0-192k-d0-mailbox-real-progress-pair/trial-1/"
            "aoc_alsa_dev_util.ep1-source0-192k-d0-mailbox-real-progress.ko"
        )
        if not cls.module.is_file():
            raise unittest.SkipTest(f"missing exact base module: {cls.module}")

    def test_exact_reversible_transform(self) -> None:
        original = self.module.read_bytes()
        self.assertEqual(patcher.classify(original), "d0-mailbox-workqueue")
        candidate = bytearray(original)
        patcher.transform(candidate, "d0-mailbox-direct-period-elapsed")
        self.assertEqual(
            patcher.classify(candidate), "d0-mailbox-direct-period-elapsed"
        )
        patcher.transform(candidate, "d0-mailbox-workqueue")
        self.assertEqual(bytes(candidate), original)

    def test_exact_guarded_words(self) -> None:
        self.assertEqual(patcher.PATCHES[0][0], 0xDA64)
        self.assertEqual(
            patcher.PATCHES[0][2].hex(),
            "68f240b9a838063560c20691eb300094bd3100141f2003d5",
        )
        self.assertEqual(patcher.PATCHES[1][0], 0x1A164)
        self.assertEqual(patcher.PATCHES[1][2].hex(), "0dc8f954")

    def test_partial_state_is_rejected(self) -> None:
        candidate = bytearray(self.module.read_bytes())
        candidate[0x1A164] ^= 1
        with self.assertRaises(ValueError):
            patcher.classify(candidate)


if __name__ == "__main__":
    unittest.main()
