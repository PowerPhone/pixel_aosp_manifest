#!/usr/bin/env python3
"""Exact-module tests for Frankel's D0 bounded-consumption transform."""

from __future__ import annotations

import hashlib
import pathlib
import sys
import unittest


HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import patch_frankel_aoc_ep1_d0_consumed_step as step  # noqa: E402


class D0ConsumedStepPatchTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.repository = HERE.parent.parent
        cls.module = (
            cls.repository
            / "work/audio-research/frankel/"
            "speaker-ep1-source0-192k-d0-pure-timer-1ms-pair/trial-1/"
            "aoc_alsa_dev_util.ep1-source0-192k-prefill-d0-pure-timer-1ms.ko"
        )
        if not cls.module.is_file():
            raise unittest.SkipTest(f"missing exact trial module: {cls.module}")

    def test_exact_base_and_reversible_transform(self) -> None:
        original = self.module.read_bytes()
        self.assertEqual(hashlib.sha256(original).hexdigest(), step.BASE_SHA256)
        self.assertEqual(step.classify(original), "stock")
        candidate = bytearray(original)
        step.transform(candidate, "d0-consumed-step")
        self.assertEqual(hashlib.sha256(candidate).hexdigest(), step.PATCHED_SHA256)
        step.transform(candidate, "stock")
        self.assertEqual(bytes(candidate), original)

    def test_d0_cap_and_wrap_safe_reload_encodings(self) -> None:
        candidate = bytearray(self.module.read_bytes())
        step.transform(candidate, "d0-consumed-step")
        expected = {
            0xD680: "68f240b9",  # ldr w8, [x19, #240] (PCM device index)
            0xD684: "68000034",  # cbz w8, D0 previous-counter reload
            0xD688: "e10315aa",  # non-D0: stock mov x1, x21
            0xD68C: "af320014",  # non-D0: return to stock store
            0xD690: "62a640f9",  # D0: ldr x2, [x19, #328] after wrap printk
            0xD694: "04000014",  # continue in second cave
            0xD6A4: "692241b9",  # ldr w9, [x19, #288] (period bytes)
            0xD6A8: "4a40298b",  # add x10, x2, w9, uxtw
            0xD6AC: "bf020aeb",  # cmp x21, x10
            0xD6B0: "5581959a",  # csel x21, x10, x21, hi
            0xD6B4: "e10315aa",  # stock store argument
            0xD6B8: "a4320014",  # return to stock store
            0x1A144: "4fcdff17",  # normal progress path -> D0 selector
        }
        for offset, encoded in expected.items():
            self.assertEqual(candidate[offset : offset + 4].hex(), encoded)

    def test_partial_or_wrong_input_is_rejected(self) -> None:
        corrupted = bytearray(self.module.read_bytes())
        corrupted[0xD690] ^= 1
        with self.assertRaises(ValueError):
            step.classify(corrupted)


if __name__ == "__main__":
    unittest.main()
