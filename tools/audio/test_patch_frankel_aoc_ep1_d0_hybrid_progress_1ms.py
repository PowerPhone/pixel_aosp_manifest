#!/usr/bin/env python3
"""Exact-module tests for Frankel's D0/EP1 hybrid progress transform."""

from __future__ import annotations

import hashlib
import pathlib
import sys
import unittest


HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import patch_frankel_aoc_ep1_d0_hybrid_progress_1ms as timer  # noqa: E402


class D0HybridProgressPatchTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.repository = HERE.parent.parent
        cls.module = (
            cls.repository
            / "work/audio-research/frankel/"
            "speaker-ep1-source0-192k-prefill-pair/trial-1/"
            "aoc_alsa_dev_util.ep1-source0-192k-prefill.ko"
        )
        if not cls.module.is_file():
            raise unittest.SkipTest(f"missing exact trial module: {cls.module}")

    def test_exact_base_and_reversible_transform(self) -> None:
        original = self.module.read_bytes()
        self.assertEqual(hashlib.sha256(original).hexdigest(), timer.BASE_SHA256)
        self.assertEqual(timer.classify(original), "interrupt")
        candidate = bytearray(original)
        timer.transform(candidate, "d0-hybrid-1ms")
        self.assertEqual(hashlib.sha256(candidate).hexdigest(), timer.PATCHED_SHA256)
        timer.transform(candidate, "interrupt")
        self.assertEqual(bytes(candidate), original)

    def test_selector_and_interval_encodings(self) -> None:
        candidate = bytearray(self.module.read_bytes())
        timer.transform(candidate, "d0-hybrid-1ms")
        expected = {
            0x1A5CC: "bf020071",  # cmp w21, #0
            0x1A5DC: "14f901f9",  # str x20, [x8, #1008] (prvdata)
            0x1A5E4: "0019447a",  # ccmp w8, #4, #0, ne
            0x1A5E8: "a1000054",  # original b.ne timer remains
            0x1A5FC: "08488852",  # mov w8, #0x4240
            0x1A608: "e801a072",  # movk w8, #0xf, lsl #16
        }
        for offset, encoded in expected.items():
            self.assertEqual(candidate[offset : offset + 4].hex(), encoded)

    def test_partial_or_wrong_input_is_rejected(self) -> None:
        corrupted = bytearray(self.module.read_bytes())
        corrupted[0x1A5FC] ^= 1
        with self.assertRaises(ValueError):
            timer.classify(corrupted)


if __name__ == "__main__":
    unittest.main()
