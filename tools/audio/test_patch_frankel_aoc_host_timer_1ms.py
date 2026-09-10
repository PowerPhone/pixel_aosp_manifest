#!/usr/bin/env python3
"""Exact-module tests for Frankel's 1 ms AoC host timer transform."""

from __future__ import annotations

import hashlib
import pathlib
import subprocess
import tempfile
import unittest

import patch_frankel_aoc_host_timer_1ms as timer


class HostTimerTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.repository = pathlib.Path(__file__).resolve().parents[2]
        cls.module = (
            cls.repository
            / "work/aosp/vendor/google_devices/frankel/stock-kernel/aoc_alsa_dev_util.ko"
        )
        if not cls.module.is_file() or hashlib.sha256(cls.module.read_bytes()).hexdigest() != timer.BASE_SHA256:
            raise unittest.SkipTest("exact already-192-kHz Frankel module is not staged")

    def test_round_trip_and_unknown_byte_rejection(self) -> None:
        original = bytearray(self.module.read_bytes())
        self.assertEqual(timer.classify(original), "stock")
        timer.transform(original, "fast")
        self.assertEqual(timer.classify(original), "fast")
        timer.transform(original, "stock")
        self.assertEqual(timer.classify(original), "stock")

        text_offset, _ = timer.elf_text(original)
        original[text_offset + timer.LOW_OFFSET] ^= 0x80
        with self.assertRaises(ValueError):
            timer.classify(original)

    def test_reference_assembly_encodings(self) -> None:
        clang = self.repository / "work/aosp/prebuilts/clang/host/linux-x86/clang-r596125/bin/clang"
        objdump = self.repository / "work/aosp/prebuilts/clang/host/linux-x86/clang-r596125/bin/llvm-objdump"
        if not clang.is_file() or not objdump.is_file():
            self.skipTest("pinned Android clang tools are absent")
        source = self.repository / "tools/audio/device/frankel_aoc_host_timer_1ms.S"
        with tempfile.TemporaryDirectory() as directory:
            output = pathlib.Path(directory) / "timer.o"
            subprocess.run(
                [clang, "--target=aarch64-linux-gnu", "-c", source, "-o", output],
                check=True,
            )
            decoded = subprocess.run(
                [objdump, "-d", output], check=True, capture_output=True, text=True
            ).stdout
        self.assertIn("5292d008", decoded)
        self.assertIn("72a01308", decoded)
        self.assertIn("52884808", decoded)
        self.assertIn("72a001e8", decoded)


if __name__ == "__main__":
    unittest.main()
