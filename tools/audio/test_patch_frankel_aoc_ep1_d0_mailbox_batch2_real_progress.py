#!/usr/bin/env python3
"""Exact-byte tests for D0 two-period real mailbox batching."""

from __future__ import annotations

import pathlib
import sys
import unittest


HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import patch_frankel_aoc_ep1_d0_mailbox_batch2_real_progress as patcher  # noqa: E402


class D0MailboxBatch2RealProgressTest(unittest.TestCase):
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
        self.assertEqual(patcher.classify(original), patcher.BASE_STATE)

        candidate = bytearray(original)
        patcher.transform(candidate, patcher.PATCHED_STATE)
        self.assertEqual(patcher.classify(candidate), patcher.PATCHED_STATE)

        patcher.transform(candidate, patcher.BASE_STATE)
        self.assertEqual(bytes(candidate), original)

    def test_only_d0_clamp_addend_changes(self) -> None:
        original = self.module.read_bytes()
        candidate = bytearray(original)
        patcher.transform(candidate, patcher.PATCHED_STATE)

        changed = [
            index
            for index, (before, after) in enumerate(zip(original, candidate))
            if before != after
        ]
        # add ... uxtw -> add ... uxtw #1 changes one immediate byte.
        self.assertEqual(changed, [0xD6A9])
        self.assertEqual(original[0xD6A8 : 0xD6AC].hex(), "4a40298b")
        self.assertEqual(candidate[0xD6A8 : 0xD6AC].hex(), "4a44298b")

        # Retain the existing D0 selector and min(actual, limit) cmp/csel.
        self.assertEqual(candidate[0xD680 : 0xD698], original[0xD680 : 0xD698])
        self.assertEqual(candidate[0xD6AC : 0xD6BC], original[0xD6AC : 0xD6BC])
        self.assertEqual(candidate[0x1A144 : 0x1A148], original[0x1A144 : 0x1A148])

    def test_workqueue_and_deferred_handler_sites_are_untouched(self) -> None:
        original = self.module.read_bytes()
        candidate = bytearray(original)
        patcher.transform(candidate, patcher.PATCHED_STATE)

        # alloc_ordered_workqueue flags: WQ_HIGHPRI plus ordered/unbound bits.
        self.assertEqual(candidate[0x1A48C : 0x1A4A0], original[0x1A48C : 0x1A4A0])
        self.assertEqual(candidate[0x1A48C : 0x1A490].hex(), "41028052")
        self.assertEqual(candidate[0x1A49C : 0x1A4A0].hex(), "4101a072")

        # The mailbox path still calls queue_work_on(WORK_CPU_UNBOUND, ...).
        self.assertEqual(candidate[0x1A17C : 0x1A190], original[0x1A17C : 0x1A190])
        self.assertEqual(candidate[0x1A184 : 0x1A188].hex(), "62c20691")
        self.assertEqual(candidate[0x1A188 : 0x1A18C].hex(), "00048052")

        # aoc_pcm_period_work_handler remains the sole deferred period call.
        self.assertEqual(candidate[0x19E1C : 0x19E40], original[0x19E1C : 0x19E40])

    def test_partial_or_wrong_input_is_rejected(self) -> None:
        candidate = bytearray(self.module.read_bytes())
        candidate[0xD6AC] ^= 1
        with self.assertRaises(ValueError):
            patcher.classify(candidate)


if __name__ == "__main__":
    unittest.main()
