#!/usr/bin/env python3
"""Composition tests for the offline Frankel AoC firmware patcher."""

from __future__ import annotations

import hashlib
import pathlib
import subprocess
import sys
import tempfile
import unittest

import patch_frankel_aoc_firmware_4xs32_192k as fixed
import patch_frankel_aoc_firmware_speaker_192k as offline
import patch_frankel_aoc_live_speaker_192k as live


class OfflineProfileTest(unittest.TestCase):
    def test_source0_four_s32_is_exact_live_profile_translation(self) -> None:
        live_patches = live.profile_patches(live.SOURCE0_4S32_PROFILE)
        offline_patches = offline.source0_four_s32_patches()

        self.assertEqual(len(live_patches), 31)
        self.assertEqual(len(offline_patches), len(live_patches))
        for live_patch, offline_patch in zip(
            live_patches, offline_patches, strict=True
        ):
            self.assertEqual(
                offline_patch.offset,
                offline.FIRMWARE_IMAGE_FILE_OFFSET
                + live_patch.address
                - offline.F1_RUNTIME_BASE,
            )
            self.assertEqual(offline_patch.before, live_patch.before)
            self.assertEqual(offline_patch.after, live_patch.after)

    def test_historical_combined_profile_adds_only_reviewed_a32_nop(self) -> None:
        f1 = offline.profile_patches("source0-4s32")
        combined = offline.profile_patches("source0-4s32-outputter-nop")

        self.assertEqual(combined[:-1], f1)
        self.assertEqual(combined[-1], offline.A32_OUTPUTTER_TIMER_NOP)
        self.assertEqual(combined[-1].offset, 0x00B0DE8E)
        self.assertEqual(combined[-1].before, bytes.fromhex("90bb"))
        self.assertEqual(combined[-1].after, bytes.fromhex("00bf"))
        self.assertEqual(len({patch.offset for patch in combined}), 32)

    def test_powerphone_profile_adds_only_allocator_fallback(self) -> None:
        f1 = offline.profile_patches("source0-4s32")
        combined = offline.profile_patches(
            "source0-4s32-allocator-fallback"
        )

        self.assertEqual(combined[:-1], f1)
        self.assertEqual(combined[-1], offline.A32_ALLOCATOR_FALLBACK)
        self.assertEqual(combined[-1].offset, 0x00B10F0E)
        self.assertEqual(combined[-1].before, bytes.fromhex("70d0"))
        self.assertEqual(combined[-1].after, bytes.fromhex("25d0"))
        self.assertEqual(len({patch.offset for patch in combined}), 32)
        self.assertEqual(
            offline.EXPECTED_PATCHED_SHA256[
                "source0-4s32-allocator-fallback"
            ],
            "686d0099eb31d9bc7f24dff46b02962a2ed783b7dd37504296a8cf612ecc3eab",
        )

    def test_fixed_cold_patcher_matches_powerphone_profile(self) -> None:
        canonical = offline.profile_patches(
            "source0-4s32-allocator-fallback"
        )
        fixed_profile = fixed.file_patches()

        self.assertEqual(len(fixed_profile), len(canonical))
        for fixed_patch, canonical_patch in zip(
            fixed_profile, canonical, strict=True
        ):
            self.assertEqual(fixed_patch.offset, canonical_patch.offset)
            self.assertEqual(fixed_patch.before, canonical_patch.before)
            self.assertEqual(fixed_patch.after, canonical_patch.after)
        self.assertEqual(
            fixed.EXPECTED_PATCHED_SHA256,
            offline.EXPECTED_PATCHED_SHA256[
                "source0-4s32-allocator-fallback"
            ],
        )

    def test_powerphone_profile_exact_symmetric_round_trip(self) -> None:
        stock_path = (
            pathlib.Path(__file__).resolve().parents[2]
            / "work/aosp/vendor/google_devices/frankel/proprietary/vendor/firmware/aoc.bin"
        )
        if not stock_path.is_file():
            self.skipTest("private reviewed Frankel stock firmware is unavailable")
        data = bytearray(stock_path.read_bytes())
        profile = "source0-4s32-allocator-fallback"

        self.assertEqual(offline.profile_state(data, profile), "stock")
        offline.select_profile_state(data, profile, "patched")
        self.assertEqual(offline.profile_state(data, profile), "patched")
        self.assertEqual(
            hashlib.sha256(data).hexdigest(),
            offline.EXPECTED_PATCHED_SHA256[profile],
        )
        offline.select_profile_state(data, profile, "patched")
        offline.select_profile_state(data, profile, "stock")
        self.assertEqual(offline.profile_state(data, profile), "stock")
        self.assertEqual(
            hashlib.sha256(data).hexdigest(), offline.EXPECTED_STOCK_SHA256
        )

    def test_cli_in_place_round_trip_is_exact(self) -> None:
        project_root = pathlib.Path(__file__).resolve().parents[2]
        stock_path = (
            project_root
            / "work/aosp/vendor/google_devices/frankel/proprietary/vendor/firmware/aoc.bin"
        )
        if not stock_path.is_file():
            self.skipTest("private reviewed Frankel stock firmware is unavailable")
        profile = "source0-4s32-allocator-fallback"
        with tempfile.TemporaryDirectory(
            prefix=".aoc-firmware-test.", dir=project_root / "work"
        ) as temporary:
            candidate = pathlib.Path(temporary) / "aoc.bin"
            candidate.write_bytes(stock_path.read_bytes())
            command = [
                sys.executable,
                str(pathlib.Path(offline.__file__).resolve()),
                "--profile",
                profile,
                "--in-place",
                str(candidate),
            ]
            subprocess.run(
                command + ["--set-state", "patched"], check=True,
                capture_output=True, text=True
            )
            self.assertEqual(
                hashlib.sha256(candidate.read_bytes()).hexdigest(),
                offline.EXPECTED_PATCHED_SHA256[profile],
            )
            subprocess.run(
                command + ["--set-state", "stock"], check=True,
                capture_output=True, text=True
            )
            self.assertEqual(candidate.read_bytes(), stock_path.read_bytes())


if __name__ == "__main__":
    unittest.main()
