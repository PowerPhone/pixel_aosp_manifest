"""Exact-module tests for Frankel's build-selected 192 kHz transform."""

from __future__ import annotations

import hashlib
import pathlib
import unittest

import patch_frankel_aoc_192k as patcher


class QualifiedPowerPhoneModuleTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.repository = pathlib.Path(__file__).resolve().parents[2]
        cls.module = (
            cls.repository
            / "work/aosp/vendor/google_devices/frankel/stock-kernel/"
            / "aoc_alsa_dev_util.ko"
        )
        if not cls.module.is_file():
            raise unittest.SkipTest("Frankel generated-vendor module is not staged")
        digest = hashlib.sha256(cls.module.read_bytes()).hexdigest()
        if digest not in (patcher.STOCK_SHA256, patcher.PATCHED_SHA256):
            raise unittest.SkipTest("staged Frankel module has an unrelated identity")

    def exact_states(self) -> tuple[bytearray, bytearray]:
        stock = bytearray(self.module.read_bytes())
        if patcher.classify_module(stock) == "patched":
            patcher.transform(stock, "stock")
        patched = bytearray(stock)
        patcher.transform(patched, "patched")
        return stock, patched

    def test_exact_round_trip(self) -> None:
        stock, patched = self.exact_states()
        self.assertEqual(hashlib.sha256(stock).hexdigest(), patcher.STOCK_SHA256)
        self.assertEqual(hashlib.sha256(patched).hexdigest(), patcher.PATCHED_SHA256)
        self.assertEqual(patcher.classify_module(stock), "stock")
        self.assertEqual(patcher.classify_module(patched), "patched")

        patcher.transform(patched, "stock")
        self.assertEqual(patched, stock)
        patcher.transform(patched, "patched")
        self.assertEqual(
            hashlib.sha256(patched).hexdigest(), patcher.PATCHED_SHA256
        )

    def test_qualified_capture_and_real_mailbox_playback_bytes(self) -> None:
        stock, patched = self.exact_states()
        expected = {
            0xD680: (
                "287d5f880805001128fd0a88aaffff35bf3b03d5caffff17",
                "68f240b968000034e10315aaaf32001462a640f904000014",
            ),
            0xD6A4: (
                "287d5f880805001128fd0a88aaffff35bf3b03d5cfffff17",
                "692241b94a40298bbf020aeb5581959ae10315aaa4320014",
            ),
            0x1A144: ("e10315aa", "4fcdff17"),
            0x3F368: ("fe000000", "fe1f0000"),
            0x40300: ("fe070000", "fe1f0000"),
            0x176BC: ("08d09252", "08249452"),
            0x176C8: ("0813a072", "e800a072"),
        }
        for offset, (stock_hex, patched_hex) in expected.items():
            width = len(bytes.fromhex(stock_hex))
            self.assertEqual(stock[offset : offset + width], bytes.fromhex(stock_hex))
            self.assertEqual(
                patched[offset : offset + width], bytes.fromhex(patched_hex)
            )

        # The final hardware-proven state deliberately retains stock D0
        # short-space handling and host-timer selection.
        for offset, unchanged_hex in {
            0x13658: "83070054",
            0x1A5FC: "08d09252",
            0x1A608: "0813a072",
        }.items():
            unchanged = bytes.fromhex(unchanged_hex)
            self.assertEqual(stock[offset : offset + len(unchanged)], unchanged)
            self.assertEqual(patched[offset : offset + len(unchanged)], unchanged)

    def test_partial_and_unknown_modules_are_rejected(self) -> None:
        stock, _ = self.exact_states()
        first = patcher.PATCHES[0]
        stock[first.offset : first.offset + len(first.after)] = first.after
        with self.assertRaisesRegex(ValueError, "partially patched"):
            patcher.classify_module(stock)

        stock, _ = self.exact_states()
        stock[-1] ^= 0x01
        with self.assertRaisesRegex(ValueError, "unexpected stock whole-file"):
            patcher.classify_module(stock)


if __name__ == "__main__":
    unittest.main()
