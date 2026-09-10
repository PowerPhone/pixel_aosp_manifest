#!/usr/bin/env python3
"""Exact-byte tests for Frankel's D0 2.5 ms logical clock."""

from __future__ import annotations

import hashlib
import pathlib
import sys
import unittest


HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import patch_frankel_aoc_ep1_d0_logical_clock_2500us as clock  # noqa: E402


class D0LogicalClockTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.module = (
            HERE.parent.parent
            / "work/audio-research/frankel/"
            "speaker-ep1-source0-192k-d0-pure-timer-1ms-pair/trial-2/"
            "aoc_alsa_dev_util.ep1-source0-192k-prefill-d0-pure-timer-1ms.ko"
        )
        if not cls.module.is_file():
            raise unittest.SkipTest(f"missing exact base module: {cls.module}")

    def test_exact_reversible_transform(self) -> None:
        original = self.module.read_bytes()
        self.assertEqual(hashlib.sha256(original).hexdigest(), clock.BASE_SHA256)
        self.assertEqual(clock.classify(original), "pure-timer")
        candidate = bytearray(original)
        clock.transform(candidate, "d0-logical-clock-2500us")
        self.assertEqual(hashlib.sha256(candidate).hexdigest(), clock.PATCHED_SHA256)
        clock.transform(candidate, "pure-timer")
        self.assertEqual(bytes(candidate), original)

    def test_control_flow_and_logical_pos_bytes(self) -> None:
        candidate = bytearray(self.module.read_bytes())
        clock.transform(candidate, "d0-logical-clock-2500us")
        expected = {
            0xD680: "68f240b9",  # idx
            0xD684: "68000034",  # D0 -> logical clock
            0xD688: "bf0202eb",  # non-D0 displaced raw-counter compare
            0xD68C: "ab320014",  # non-D0 -> stock condition branches
            0xD690: "682a41b9",  # D0 current pos
            0xD6A4: "692241b9",  # period bytes
            0xD6A8: "0801090b",  # pos + period
            0xD6AC: "6a2641b9",  # buffer bytes
            0xD6B0: "09010a6b",  # wrapped candidate and flags
            0xD6B4: "2821881a",  # select wrapped iff sum >= buffer
            0xDA64: "682a01b9",  # store logical pos only
            0xDA68: "bb310014",  # stock prev_pos/period-work path
            0x1A134: "53cdff17",  # redirect before raw compare
            0x1A5FC: "08b48452",  # 2,500,000 ns low half
            0x1A608: "c804a072",  # 2,500,000 ns high half
        }
        for offset, encoded in expected.items():
            self.assertEqual(candidate[offset:offset + 4].hex(), encoded)
        # prev_consumed's stock store is intact but unreachable for D0.
        self.assertEqual(candidate[0x1A148:0x1A14C].hex(), "75a600f9")

    def test_partial_state_is_rejected(self) -> None:
        corrupted = bytearray(self.module.read_bytes())
        corrupted[0xDA64] ^= 1
        with self.assertRaises(ValueError):
            clock.classify(corrupted)


if __name__ == "__main__":
    unittest.main()
