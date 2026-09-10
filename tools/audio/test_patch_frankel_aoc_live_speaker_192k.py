#!/usr/bin/env python3
"""Focused composition tests for Frankel's volatile speaker profiles."""

from __future__ import annotations

import unittest
from types import SimpleNamespace

import patch_frankel_aoc_live_speaker_192k as speaker


class MemoryTransport:
    def __init__(self, patches: tuple[speaker.Patch, ...]) -> None:
        self.memory: dict[int, int] = {}
        self.dump_calls: list[tuple[int, int]] = []
        self.write_calls: list[tuple[int, int, int]] = []
        for patch in patches:
            self.put(patch.address, patch.before)
        self.put(speaker.CACHE_FLUSH_DISPATCH.address,
                 speaker.CACHE_FLUSH_DISPATCH.before)

    def put(self, address: int, data: bytes) -> None:
        for offset, value in enumerate(data):
            self.memory[address + offset] = value

    def dump(self, address: int, size: int) -> bytes:
        self.dump_calls.append((address, size))
        return bytes(self.memory.get(address + offset, 0) for offset in range(size))

    def write_unverified(self, address: int, value: int, width: int) -> None:
        self.write_calls.append((address, value, width))
        self.put(address, value.to_bytes(width // 8, "little"))

    def run(self, *args: str, **kwargs: object) -> SimpleNamespace:
        return SimpleNamespace(returncode=1, stderr=b"")


class Source0ProfileTest(unittest.TestCase):
    def test_source0_guard_changes_only_the_source_bit_immediate(self) -> None:
        source5 = speaker.CAVE_GUARD_SOURCE5_Q48_PATCHES
        source0 = speaker.CAVE_GUARD_SOURCE0_Q48_PATCHES

        self.assertEqual(len(source0), len(source5))
        self.assertEqual(
            [(patch.address, patch.before, patch.kind) for patch in source0],
            [(patch.address, patch.before, patch.kind) for patch in source5],
        )
        changed = [
            (left.address, left.after, right.after)
            for left, right in zip(source5, source0, strict=True)
            if left.after != right.after
        ]
        self.assertEqual(
            changed,
            [
                (
                    0x4039D52C,
                    bytes.fromhex("52576704"),
                    bytes.fromhex("52076704"),
                )
            ],
        )

    def test_source0_profile_matches_source5_except_guard_immediate(self) -> None:
        source5 = speaker.profile_patches(speaker.SOURCE5_PROFILE)
        source0 = speaker.profile_patches(speaker.SOURCE0_PROFILE)

        self.assertEqual(len(source0), len(source5))
        self.assertEqual(
            [(patch.address, patch.before, patch.kind) for patch in source0],
            [(patch.address, patch.before, patch.kind) for patch in source5],
        )
        changed_addresses = [
            left.address
            for left, right in zip(source5, source0, strict=True)
            if left.after != right.after
        ]
        self.assertEqual(changed_addresses, [0x4039D52C])

    def test_source0_preflight_uses_ep1_pcm(self) -> None:
        self.assertEqual(
            speaker.playback_status_for_profile(speaker.SOURCE0_PROFILE),
            "/proc/asound/card0/pcm0p/sub0/status",
        )
        self.assertEqual(
            speaker.playback_status_for_profile(speaker.SOURCE5_PROFILE),
            "/proc/asound/card0/pcm5p/sub0/status",
        )
        self.assertEqual(
            speaker.playback_status_for_profile(speaker.SOURCE0_2SLOT_PROFILE),
            "/proc/asound/card0/pcm0p/sub0/status",
        )
        self.assertEqual(
            speaker.playback_status_for_profile(speaker.SOURCE0_4S32_PROFILE),
            "/proc/asound/card0/pcm0p/sub0/status",
        )
        self.assertEqual(
            speaker.playback_status_for_profile(
                speaker.SOURCE0_Q192_4S32_PROFILE
            ),
            "/proc/asound/card0/pcm0p/sub0/status",
        )
        self.assertEqual(
            speaker.playback_status_for_profile(
                speaker.SOURCE0_Q192_2SLOT_PROFILE
            ),
            "/proc/asound/card0/pcm0p/sub0/status",
        )
        self.assertEqual(
            speaker.playback_status_for_profile(
                speaker.SOURCE0_Q192_4S16_PROFILE
            ),
            "/proc/asound/card0/pcm0p/sub0/status",
        )
        self.assertEqual(
            speaker.playback_status_for_profile(
                speaker.SOURCE0_Q192_4S16_FIFO32_PROFILE
            ),
            "/proc/asound/card0/pcm0p/sub0/status",
        )
        self.assertEqual(
            speaker.playback_status_for_profile("enum7-q48-no-tdm"),
            speaker.PLAYBACK_STATUS,
        )

    def test_source0_two_slot_profile_uses_source_zero_guard(self) -> None:
        profile = speaker.profile_patches(speaker.SOURCE0_2SLOT_PROFILE)
        by_address = {patch.address: patch for patch in profile}
        self.assertEqual(by_address[0x4039D52C].after, bytes.fromhex("52076704"))
        self.assertIn(speaker.SPEAKER_TDM_TWO_SLOT_UNUSED_PATCH, profile)
        for patch in speaker.SPEAKER_TDM_TWO_SLOT_DMA_PATCHES:
            self.assertIn(patch, profile)
        for patch in speaker.SPEAKER_TDM_S16_CPU_Q48_LOOP_PATCHES:
            self.assertIn(patch, profile)
        self.assertIn(speaker.SPEAKER_TDM_S16_DMA_Q48_FRAME_PATCH, profile)
        for patch in speaker.SPEAKER_TDM_WIDTH16_PATCHES:
            self.assertNotIn(patch, profile)

    def test_source0_four_s32_profile_has_no_dma_width_edits(self) -> None:
        profile = speaker.profile_patches(speaker.SOURCE0_4S32_PROFILE)
        by_address = {patch.address: patch for patch in profile}
        self.assertEqual(by_address[0x4039D52C].after, bytes.fromhex("52076704"))
        self.assertEqual(by_address[0x403D36F0].after, bytes.fromhex("8122a0c0"))
        self.assertNotIn(speaker.SPEAKER_TDM_TWO_SLOT_UNUSED_PATCH, profile)
        for patch in speaker.SPEAKER_TDM_S16_CPU_Q48_LOOP_PATCHES:
            self.assertIn(patch, profile)
        self.assertIn(speaker.SPEAKER_TDM_S16_DMA_Q48_FRAME_PATCH, profile)
        for patch in speaker.SPEAKER_TDM_WIDTH16_PATCHES:
            self.assertNotIn(patch, profile)
        for patch in speaker.SPEAKER_TDM_S16_DMA_PATCHES:
            self.assertNotIn(patch, profile)

    def test_source0_q192_four_s32_profile_is_native_one_ms_path(self) -> None:
        profile = speaker.profile_patches(speaker.SOURCE0_Q192_4S32_PROFILE)
        by_address = {patch.address: patch for patch in profile}

        self.assertEqual(
            profile,
            speaker.CAVE_RATE_PATCHES
            + speaker.CAVE_GUARD_SOURCE0_Q192_PATCHES
            + speaker.CAVE_TDM_PATCHES
            + speaker.HOOK_PATCHES,
        )
        self.assertEqual(by_address[0x4039D52C].after, bytes.fromhex("52076704"))
        self.assertEqual(by_address[0x4039D530].after, bytes.fromhex("62a0c00c"))
        self.assertEqual(by_address[0x403D36F0].after, bytes.fromhex("812213e3"))
        self.assertNotIn(speaker.EARLY_Q48_HOOK_PATCH, profile)
        self.assertNotIn(speaker.GENERIC_ENUM7_Q48_PATCH, profile)
        for patch in speaker.SPEAKER_TDM_S16_CPU_Q48_LOOP_PATCHES:
            self.assertNotIn(patch, profile)
        self.assertNotIn(speaker.SPEAKER_TDM_S16_DMA_Q48_FRAME_PATCH, profile)
        for patch in speaker.SPEAKER_TDM_WIDTH16_PATCHES:
            self.assertNotIn(patch, profile)
        for patch in speaker.SPEAKER_TDM_S16_DMA_PATCHES:
            self.assertNotIn(patch, profile)

    def test_source0_q192_two_slot_s32_profile_is_native_one_ms_path(self) -> None:
        profile = speaker.profile_patches(speaker.SOURCE0_Q192_2SLOT_PROFILE)
        rate_hook, tdm_hook, activation_hook = speaker.HOOK_PATCHES
        expected = (
            speaker.CAVE_RATE_PATCHES
            + speaker.CAVE_GUARD_SOURCE0_Q192_PATCHES
            + speaker.CAVE_TDM_12288_192_2SLOT_PATCHES
            + speaker.SPEAKER_TDM_TWO_SLOT_CPU_X2_LOOP_PATCHES
            + (rate_hook,)
            + speaker.SPEAKER_TDM_TWO_SLOT_DMA_PATCHES
            + (
                speaker.SPEAKER_TDM_TWO_SLOT_UNUSED_PATCH,
                tdm_hook,
                activation_hook,
            )
        )
        by_address = {patch.address: patch for patch in profile}

        self.assertEqual(profile, expected)
        self.assertEqual(len(by_address), len(profile))
        self.assertEqual(by_address[0x4039D52C].after, bytes.fromhex("52076704"))
        self.assertEqual(by_address[0x4039D530].after, bytes.fromhex("62a0c00c"))
        self.assertEqual(by_address[0x403D36F0].after, bytes.fromhex("8122a0c0"))
        self.assertEqual(by_address[0x403D36F4].after, bytes.fromhex("a0421142"))
        self.assertEqual(by_address[0x403D3C84].after, bytes.fromhex("1b22f066"))
        self.assertEqual(by_address[0x403D3D70].after, bytes.fromhex("1b33f066"))
        self.assertIn(speaker.SPEAKER_TDM_TWO_SLOT_UNUSED_PATCH, profile)
        for patch in speaker.SPEAKER_TDM_TWO_SLOT_DMA_PATCHES:
            self.assertIn(patch, profile)
        for patch in speaker.SPEAKER_TDM_TWO_SLOT_CPU_X2_LOOP_PATCHES:
            self.assertIn(patch, profile)
        self.assertNotIn(speaker.EARLY_Q48_HOOK_PATCH, profile)
        self.assertNotIn(speaker.GENERIC_ENUM7_Q48_PATCH, profile)
        for patch in speaker.CAVE_EARLY_Q48_PATCHES:
            self.assertNotIn(patch, profile)
        for patch in speaker.SPEAKER_TDM_S16_CPU_Q48_LOOP_PATCHES:
            self.assertNotIn(patch, profile)
        self.assertNotIn(speaker.SPEAKER_TDM_S16_DMA_Q48_FRAME_PATCH, profile)
        for patch in speaker.SPEAKER_TDM_WIDTH16_PATCHES:
            self.assertNotIn(patch, profile)
        for patch in speaker.SPEAKER_TDM_S16_DMA_PATCHES:
            self.assertNotIn(patch, profile)

        source_bytes = 192 * 2 * 4
        cpu_copy_bytes = 192 * 2 * 4
        physical_dma_bytes = 192 * 2 * 4
        self.assertEqual(source_bytes, 0x600)
        self.assertEqual(cpu_copy_bytes, source_bytes)
        self.assertEqual(physical_dma_bytes, source_bytes)

    def test_q192_two_slot_cpu_shift_pair_changes_only_x4_to_x2(self) -> None:
        patches = speaker.SPEAKER_TDM_TWO_SLOT_CPU_X2_LOOP_PATCHES

        self.assertEqual(
            [(patch.address, patch.before, patch.after) for patch in patches],
            [
                (
                    0x403D3C84,
                    bytes.fromhex("1b22e066"),
                    bytes.fromhex("1b22f066"),
                ),
                (
                    0x403D3D70,
                    bytes.fromhex("1b33e066"),
                    bytes.fromhex("1b33f066"),
                ),
            ],
        )
        for patch in patches:
            changed = [
                index
                for index, (before, after) in enumerate(
                    zip(patch.before, patch.after, strict=True)
                )
                if before != after
            ]
            self.assertEqual(changed, [2])

    def test_q192_two_slot_cpu_shift_pair_is_guarded_when_unselected(self) -> None:
        selected = speaker.profile_patches(speaker.SOURCE0_Q192_4S32_PROFILE)
        unselected = speaker.unselected_site_patches(selected)

        for patch in speaker.SPEAKER_TDM_TWO_SLOT_CPU_X2_LOOP_PATCHES:
            self.assertIn(patch, unselected)

    def test_source0_q192_four_s16_uses_exact_cpu_q96_copy_geometry(self) -> None:
        profile = speaker.profile_patches(speaker.SOURCE0_Q192_4S16_PROFILE)
        rate_hook, tdm_hook, activation_hook = speaker.HOOK_PATCHES
        expected = (
            speaker.CAVE_RATE_PATCHES
            + speaker.CAVE_GUARD_SOURCE0_Q192_PATCHES
            + speaker.CAVE_TDM_12288_192_PATCHES
            + speaker.SPEAKER_TDM_WIDTH16_PATCHES
            + speaker.SPEAKER_TDM_S16_CPU_Q96_LOOP_PATCHES
            + speaker.SPEAKER_TDM_S16_DMA_PATCHES
            + (rate_hook, tdm_hook, activation_hook)
        )
        by_address = {patch.address: patch for patch in profile}

        self.assertEqual(profile, expected)
        self.assertEqual(len(by_address), len(profile))
        self.assertEqual(by_address[0x4039D52C].after, bytes.fromhex("52076704"))
        self.assertEqual(by_address[0x4039D530].after, bytes.fromhex("62a0c00c"))
        self.assertEqual(by_address[0x403D36F0].after, bytes.fromhex("8122a0c0"))
        self.assertEqual(by_address[0x403D36F4].after, bytes.fromhex("a0421142"))
        self.assertEqual(by_address[0x403D3C80].after, bytes.fromhex("0462a060"))
        self.assertEqual(by_address[0x403D3D6C].after, bytes.fromhex("0862a060"))
        for patch in speaker.SPEAKER_TDM_WIDTH16_PATCHES:
            self.assertIn(patch, profile)
        for patch in speaker.SPEAKER_TDM_S16_DMA_PATCHES:
            self.assertIn(patch, profile)
        for patch in speaker.SPEAKER_TDM_S16_CPU_Q96_LOOP_PATCHES:
            self.assertIn(patch, profile)

        self.assertNotIn(speaker.EARLY_Q48_HOOK_PATCH, profile)
        self.assertNotIn(speaker.GENERIC_ENUM7_Q48_PATCH, profile)
        self.assertNotIn(speaker.SPEAKER_TDM_S16_DMA_Q48_FRAME_PATCH, profile)
        for patch in speaker.CAVE_EARLY_Q48_PATCHES:
            self.assertNotIn(patch, profile)
        for patch in speaker.SPEAKER_TDM_S16_CPU_Q48_LOOP_PATCHES:
            self.assertNotIn(patch, profile)

        source_bytes = 192 * 2 * 4
        cpu_copy_bytes = 96 * 4 * 4
        physical_dma_bytes = 192 * 4 * 2
        self.assertEqual(source_bytes, 0x600)
        self.assertEqual(cpu_copy_bytes, source_bytes)
        self.assertEqual(physical_dma_bytes, source_bytes)

    def test_source14_q192_four_s16_retains_unclamped_crash_evidence(self) -> None:
        profile = speaker.profile_patches(
            "experimental-enum7-q192-tdm12288-192-4xs16-dma"
        )

        for patch in speaker.SPEAKER_TDM_S16_CPU_Q96_LOOP_PATCHES:
            self.assertNotIn(patch, profile)
        for patch in speaker.SPEAKER_TDM_S16_CPU_Q48_LOOP_PATCHES:
            self.assertNotIn(patch, profile)
        self.assertNotIn(speaker.SPEAKER_TDM_S16_DMA_Q48_FRAME_PATCH, profile)

    def test_source0_q192_four_s16_fifo32_uses_exact_burst_geometry(self) -> None:
        profile = speaker.profile_patches(
            speaker.SOURCE0_Q192_4S16_FIFO32_PROFILE
        )
        rate_hook, tdm_hook, activation_hook = speaker.HOOK_PATCHES
        expected = (
            speaker.CAVE_RATE_PATCHES
            + speaker.CAVE_GUARD_SOURCE0_Q192_PATCHES
            + speaker.CAVE_TDM_12288_192_PATCHES
            + speaker.SPEAKER_TDM_WIDTH16_PATCHES
            + speaker.SPEAKER_TDM_S16_CPU_Q96_LOOP_PATCHES
            + speaker.SPEAKER_TDM_S16_DMA_FIFO32_PATCHES
            + (rate_hook, tdm_hook, activation_hook)
        )
        by_address = {patch.address: patch for patch in profile}

        self.assertEqual(profile, expected)
        self.assertEqual(len(by_address), len(profile))
        self.assertEqual(
            {
                address: by_address[address].after
                for address in (
                    0x403AA510,
                    0x403AA534,
                    0x403AA82C,
                    0x403AA84C,
                    0x403AA854,
                )
            },
            {
                0x403AA510: bytes.fromhex("a10f0081"),
                0x403AA534: bytes.fromhex("326100a5"),
                0x403AA82C: bytes.fromhex("03000be0"),
                0x403AA84C: bytes.fromhex("8505d172"),
                0x403AA854: bytes.fromhex("219901a5"),
            },
        )
        for retired_halfword_site in (0x403AA520, 0x403AA840):
            self.assertNotIn(retired_halfword_site, by_address)
        self.assertNotIn(speaker.EARLY_Q48_HOOK_PATCH, profile)
        self.assertNotIn(speaker.SPEAKER_TDM_S16_DMA_Q48_FRAME_PATCH, profile)

        self.assertEqual(192 * 2 * 4, 0x600)
        self.assertEqual(96 * 4 * 4, 0x600)
        self.assertEqual(192 * 4 * 2, 0x600)


class MinimalTrafficTest(unittest.TestCase):
    def test_q192_four_s16_cpu_q96_apply_revert_round_trip(self) -> None:
        profile = speaker.profile_patches(speaker.SOURCE0_Q192_4S16_PROFILE)
        unselected = speaker.unselected_site_patches(profile)
        transport = MemoryTransport(profile + unselected)

        self.assertEqual(
            speaker.run_minimal_traffic(
                transport,
                profile,
                "apply",
                speaker.SOURCE0_Q192_4S16_PROFILE,
            ),
            0,
        )
        for patch in speaker.SPEAKER_TDM_S16_CPU_Q96_LOOP_PATCHES:
            self.assertEqual(
                transport.dump(patch.address, 4), patch.after, patch.name
            )
        self.assertEqual(
            speaker.run_minimal_traffic(
                transport,
                profile,
                "check-patched",
                speaker.SOURCE0_Q192_4S16_PROFILE,
            ),
            0,
        )
        self.assertEqual(
            speaker.run_minimal_traffic(
                transport,
                profile,
                "revert",
                speaker.SOURCE0_Q192_4S16_PROFILE,
            ),
            0,
        )
        for patch in profile:
            self.assertEqual(
                transport.dump(patch.address, 4), patch.before, patch.name
            )

    def test_q192_two_slot_check_apply_revert_round_trip(self) -> None:
        profile = speaker.profile_patches(speaker.SOURCE0_Q192_2SLOT_PROFILE)
        unselected = speaker.unselected_site_patches(profile)
        transport = MemoryTransport(profile + unselected)

        self.assertEqual(
            speaker.run_minimal_traffic(
                transport,
                profile,
                "check-stock",
                speaker.SOURCE0_Q192_2SLOT_PROFILE,
            ),
            0,
        )
        self.assertEqual(transport.write_calls, [])

        self.assertEqual(
            speaker.run_minimal_traffic(
                transport,
                profile,
                "apply",
                speaker.SOURCE0_Q192_2SLOT_PROFILE,
            ),
            0,
        )
        for patch in speaker.SPEAKER_TDM_TWO_SLOT_CPU_X2_LOOP_PATCHES:
            self.assertEqual(
                transport.dump(patch.address, 4), patch.after, patch.name
            )
        caves = tuple(patch for patch in profile if patch.kind == "cave")
        hooks = tuple(patch for patch in profile if patch.kind == "hook")
        apply_addresses = [patch.address for patch in caves + hooks]
        apply_addresses += [speaker.CACHE_FLUSH_DISPATCH.address] * 2
        self.assertEqual(
            [address for address, _value, _width in transport.write_calls],
            apply_addresses,
        )
        apply_write_count = len(transport.write_calls)

        self.assertEqual(
            speaker.run_minimal_traffic(
                transport,
                profile,
                "check-patched",
                speaker.SOURCE0_Q192_2SLOT_PROFILE,
            ),
            0,
        )
        self.assertEqual(len(transport.write_calls), apply_write_count)

        self.assertEqual(
            speaker.run_minimal_traffic(
                transport,
                profile,
                "revert",
                speaker.SOURCE0_Q192_2SLOT_PROFILE,
            ),
            0,
        )
        revert_addresses = [
            patch.address
            for patch in tuple(reversed(hooks)) + tuple(reversed(caves))
        ]
        revert_addresses += [speaker.CACHE_FLUSH_DISPATCH.address] * 2
        self.assertEqual(
            [
                address
                for address, _value, _width in transport.write_calls[
                    apply_write_count:
                ]
            ],
            revert_addresses,
        )
        for patch in profile:
            self.assertEqual(
                transport.dump(patch.address, 4), patch.before, patch.name
            )
        self.assertEqual(
            speaker.run_minimal_traffic(
                transport,
                profile,
                "check-stock",
                speaker.SOURCE0_Q192_2SLOT_PROFILE,
            ),
            0,
        )

    def test_grouped_ranges_cover_words_and_never_exceed_dump_limit(self) -> None:
        profile = speaker.profile_patches(speaker.SOURCE0_2SLOT_PROFILE)
        ranges = speaker.grouped_dump_ranges(profile)
        self.assertLess(len(ranges), len(profile))
        for start, size in ranges:
            self.assertGreater(size, 0)
            self.assertLessEqual(size, speaker.MAX_GROUPED_DUMP_BYTES)
        for patch in profile:
            self.assertTrue(
                any(
                    start <= patch.address and
                    patch.address + 4 <= start + size
                    for start, size in ranges
                )
            )

    def test_minimal_apply_uses_one_set_per_word_and_grouped_guards(self) -> None:
        profile = speaker.profile_patches(speaker.SOURCE0_4S32_PROFILE)
        unselected = speaker.unselected_site_patches(profile)
        transport = MemoryTransport(profile + unselected)

        result = speaker.run_minimal_traffic(
            transport, profile, "apply", speaker.SOURCE0_4S32_PROFILE
        )

        self.assertEqual(result, 0)
        caves = tuple(patch for patch in profile if patch.kind == "cave")
        hooks = tuple(patch for patch in profile if patch.kind == "hook")
        expected_addresses = [patch.address for patch in caves + hooks]
        expected_addresses += [
            speaker.CACHE_FLUSH_DISPATCH.address,
            speaker.CACHE_FLUSH_DISPATCH.address,
        ]
        self.assertEqual(
            [address for address, _value, _width in transport.write_calls],
            expected_addresses,
        )
        for patch in profile:
            self.assertEqual(
                transport.dump(patch.address, 4), patch.after, patch.name
            )
        self.assertEqual(
            transport.dump(speaker.CACHE_FLUSH_DISPATCH.address, 4),
            speaker.CACHE_FLUSH_DISPATCH.before,
        )

        expected_dump_count = (
            len(speaker.grouped_dump_ranges(profile + unselected))
            + len(speaker.grouped_dump_ranges(profile))
            + 2
        )
        # Ignore the direct assertions above, which each call dump once.
        self.assertEqual(
            len(transport.dump_calls) - len(profile) - 1,
            expected_dump_count,
        )

    def test_minimal_guard_failure_happens_before_any_write(self) -> None:
        profile = speaker.profile_patches(speaker.SOURCE0_4S32_PROFILE)
        unselected = speaker.unselected_site_patches(profile)
        transport = MemoryTransport(profile + unselected)
        transport.put(profile[0].address, bytes.fromhex("deadbeef"))

        with self.assertRaisesRegex(ValueError, "unexpected bytes"):
            speaker.run_minimal_traffic(
                transport, profile, "apply", speaker.SOURCE0_4S32_PROFILE
            )
        self.assertEqual(transport.write_calls, [])


if __name__ == "__main__":
    unittest.main()
