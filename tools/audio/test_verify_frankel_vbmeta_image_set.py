#!/usr/bin/env python3

from __future__ import annotations

import importlib.util
import pathlib
import sys
import tempfile
import unittest
from unittest import mock


MODULE_PATH = pathlib.Path(__file__).with_name(
    "verify_frankel_vbmeta_image_set.py"
)
SPEC = importlib.util.spec_from_file_location("frankel_vbmeta_guard", MODULE_PATH)
assert SPEC and SPEC.loader
guard = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = guard
SPEC.loader.exec_module(guard)


def hash_descriptor(partition: str, digest: str) -> str:
    return f"""\
    Hash descriptor:
      Image Size:            4096 bytes
      Hash Algorithm:        sha256
      Partition Name:        {partition}
      Salt:                  {'ab' * 32}
      Digest:                {digest}
      Flags:                 0
"""


class FrankelVbmetaGuardTest(unittest.TestCase):
    def test_complete_root_set_accepts_exact_descriptors(self) -> None:
        digest_vkb = "11" * 32
        digest_boot = "22" * 32
        with tempfile.TemporaryDirectory() as temporary:
            directory = pathlib.Path(temporary)
            root = directory / "vbmeta.img"
            vkb = directory / "vendor_kernel_boot.img"
            boot = directory / "boot.img"
            for path in (root, vkb, boot):
                path.write_bytes(b"image")
            info = {
                root: hash_descriptor("vendor_kernel_boot", digest_vkb)
                + hash_descriptor("boot", digest_boot),
                vkb: hash_descriptor("vendor_kernel_boot", digest_vkb),
                boot: hash_descriptor("boot", digest_boot),
            }
            with mock.patch.object(
                guard, "avb_info", side_effect=lambda _tool, image: info[image]
            ):
                self.assertEqual(
                    guard.verify_root_set(
                        pathlib.Path("avbtool"), root, directory, {}
                    ),
                    2,
                )

    def test_root_set_rejects_one_mismatched_leaf(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            directory = pathlib.Path(temporary)
            root = directory / "vbmeta.img"
            vkb = directory / "vendor_kernel_boot.img"
            root.write_bytes(b"root")
            vkb.write_bytes(b"leaf")
            info = {
                root: hash_descriptor("vendor_kernel_boot", "11" * 32),
                vkb: hash_descriptor("vendor_kernel_boot", "22" * 32),
            }
            with mock.patch.object(
                guard, "avb_info", side_effect=lambda _tool, image: info[image]
            ):
                with self.assertRaisesRegex(guard.GuardError, "descriptor mismatch"):
                    guard.verify_root_set(
                        pathlib.Path("avbtool"), root, directory, {}
                    )

    def test_rewrite_changes_only_unique_vkb_digest(self) -> None:
        old_digest = "33" * 32
        new_digest = "44" * 32
        with tempfile.TemporaryDirectory() as temporary:
            directory = pathlib.Path(temporary)
            root = directory / "vbmeta.img"
            vkb = directory / "vendor_kernel_boot.img"
            output = directory / "donor.img"
            original = b"prefix" + bytes.fromhex(old_digest) + b"suffix"
            root.write_bytes(original)
            vkb.write_bytes(b"leaf")
            info = {
                root: hash_descriptor("vendor_kernel_boot", old_digest),
                vkb: hash_descriptor("vendor_kernel_boot", new_digest),
            }
            with mock.patch.object(
                guard, "avb_info", side_effect=lambda _tool, image: info[image]
            ):
                guard.rewrite_vendor_kernel_boot_digest(
                    pathlib.Path("avbtool"), root, vkb, output
                )
            self.assertEqual(
                output.read_bytes(),
                original.replace(bytes.fromhex(old_digest), bytes.fromhex(new_digest)),
            )

    def test_active_builders_default_to_kernel_only(self) -> None:
        names = (
            "build_frankel_ep1_source0_192k_d0_real_progress_pair.sh",
            "build_frankel_ep1_source0_192k_d0_mailbox_direct_period_elapsed_pair.sh",
            "build_frankel_ep1_source0_192k_d0_mailbox_batch2_real_progress_pair.sh",
        )
        for name in names:
            text = MODULE_PATH.with_name(name).read_text()
            self.assertIn("FRANKEL_ROOT_IMAGE_SET", text, name)
            self.assertIn("KERNEL_ONLY.txt", text, name)
            self.assertIn("make_frankel_experimental_vbmeta.sh", text, name)
            self.assertNotIn("base_vbmeta=", text, name)


if __name__ == "__main__":
    unittest.main()
