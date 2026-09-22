#!/usr/bin/env python3
"""Synthetic-only tests for the guarded offline Frankel manifest patcher."""

from __future__ import annotations

import hashlib
import contextlib
import copy
import io
import json
import pathlib
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import patch_frankel_aoc_offline_manifest as patcher


def synthetic_edit(
    identifier: str, offset: int, before: bytes, after: bytes
) -> patcher.Edit:
    region = patcher.Region("synthetic", 0, 16, 0x1000)
    return patcher.Edit(
        identifier=identifier,
        region=region,
        offset=offset,
        analysis_address=0x1000 + offset,
        before=before,
        after=after,
        semantic_intent="exercise an offline equal-length substitution",
        evidence=("synthetic unit-test fixture",),
    )


def synthetic_manifest() -> dict:
    region = patcher.REGIONS["dsp-external"]
    return {
        "schema": patcher.SCHEMA,
        "target": {
            "profile": patcher.TARGET_PROFILE,
            "codename": "frankel",
            "firmware_size": patcher.EXPECTED_SIZE,
            "input_sha256": patcher.EXPECTED_STOCK_SHA256,
            "firmware_version": patcher.EXPECTED_FIRMWARE_VERSION,
        },
        "review": {
            "status": "incomplete-design",
            "reviewer": "synthetic fixture, not a firmware review",
            "reviewed_at": "unassigned",
        },
        "patch_set": {
            "id": "synthetic.incomplete",
            "summary": "Synthetic fixture only",
            "output_sha256": None,
            "edits": [{
                "id": "synthetic.first",
                "region": region.name,
                "container_offset": region.file_offset + 4,
                "analysis_address": region.analysis_address + 4,
                "expected_hex": "0000",
                "replacement_hex": "aabb",
                "semantic_intent": "Exercise read-only validation",
                "evidence": ["synthetic fixture"],
            }],
        },
    }


def reviewed_manifest(output_digest: str = "1" * 64) -> dict:
    manifest = synthetic_manifest()
    manifest["artifact_class"] = patcher.REVIEWED_ARTIFACT_CLASS
    manifest["review"]["status"] = "reviewed-complete"
    manifest["review"]["scope"] = patcher.REVIEWED_SCOPE
    manifest["qualification"] = {
        field: False for field in patcher.REQUIRED_FALSE_QUALIFICATIONS
    }
    manifest["warnings"] = ["Synthetic offline-only test artifact"]
    manifest["patch_set"]["output_sha256"] = output_digest
    return manifest


class OfflineManifestSyntheticTest(unittest.TestCase):
    def test_guarded_edits_and_final_digest(self) -> None:
        source = bytes(range(16))
        edits = [
            synthetic_edit("synthetic.first", 2, b"\x02\x03", b"\xaa\xbb"),
            synthetic_edit("synthetic.second", 12, b"\x0c", b"\xcc"),
        ]
        expected = bytearray(source)
        expected[2:4] = b"\xaa\xbb"
        expected[12] = 0xCC
        digest = hashlib.sha256(expected).hexdigest()
        self.assertEqual(patcher.apply_edits(source, edits, digest), expected)

    def test_stock_byte_mismatch_is_rejected(self) -> None:
        source = bytes(range(16))
        edit = synthetic_edit("synthetic.guard", 4, b"\xff", b"\x00")
        with self.assertRaisesRegex(ValueError, "stock-byte guard failed"):
            patcher.apply_edits(source, [edit], "0" * 64)

    def test_wrong_final_digest_is_rejected(self) -> None:
        source = bytes(range(16))
        edit = synthetic_edit("synthetic.digest", 4, b"\x04", b"\x99")
        with self.assertRaisesRegex(ValueError, "does not match reviewed"):
            patcher.apply_edits(source, [edit], "0" * 64)

    def test_atomic_publish_never_replaces_existing_output(self) -> None:
        with tempfile.TemporaryDirectory(prefix="frankel-aoc-offline-test.") as temporary:
            output = pathlib.Path(temporary) / "candidate.bin"
            patcher.atomic_publish_new(output, b"first", 0o100640)
            self.assertEqual(output.read_bytes(), b"first")
            with self.assertRaisesRegex(ValueError, "refusing to replace"):
                patcher.atomic_publish_new(output, b"second", 0o100640)
            self.assertEqual(output.read_bytes(), b"first")

    def test_incomplete_repository_manifest_is_fail_closed(self) -> None:
        manifest_path = (
            pathlib.Path(__file__).resolve().parent
            / "manifests/frankel-aoc-speaker-192k.incomplete.json"
        )
        with self.assertRaisesRegex(ValueError, "not review-complete"):
            patcher.parse_manifest(manifest_path.read_bytes())

    def test_incomplete_design_accepts_explicit_null_digest(self) -> None:
        manifest = synthetic_manifest()
        edits, digest, parsed = patcher.parse_manifest(
            json.dumps(manifest).encode(), validate_incomplete_design=True
        )
        self.assertEqual(len(edits), 1)
        self.assertIsNone(digest)
        self.assertEqual(parsed["review"]["status"], "incomplete-design")
        with self.assertRaisesRegex(ValueError, "not review-complete"):
            patcher.parse_manifest(json.dumps(manifest).encode())

    def test_reviewed_validation_still_requires_exact_digest(self) -> None:
        manifest = reviewed_manifest()
        manifest["patch_set"]["output_sha256"] = None
        with self.assertRaisesRegex(ValueError, "64 lowercase hex"):
            patcher.parse_manifest(json.dumps(manifest).encode())
        manifest["patch_set"]["output_sha256"] = "1" * 64
        _, digest, _ = patcher.parse_manifest(json.dumps(manifest).encode())
        self.assertEqual(digest, "1" * 64)
        with self.assertRaisesRegex(ValueError, "requires review.status incomplete-design"):
            patcher.parse_manifest(
                json.dumps(manifest).encode(), validate_incomplete_design=True
            )

    def test_reviewed_manifest_requires_offline_only_metadata(self) -> None:
        valid = reviewed_manifest()
        patcher.parse_manifest(json.dumps(valid).encode())

        bad = copy.deepcopy(valid)
        bad["artifact_class"] = "flashable-firmware"
        with self.assertRaisesRegex(ValueError, "artifact_class"):
            patcher.parse_manifest(json.dumps(bad).encode())

        bad = copy.deepcopy(valid)
        bad["review"]["scope"] = "hardware-qualified"
        with self.assertRaisesRegex(ValueError, "review.scope"):
            patcher.parse_manifest(json.dumps(bad).encode())

        for field in patcher.REQUIRED_FALSE_QUALIFICATIONS:
            bad = copy.deepcopy(valid)
            bad["qualification"][field] = True
            with self.subTest(field=field), self.assertRaisesRegex(
                ValueError, f"qualification.{field}"
            ):
                patcher.parse_manifest(json.dumps(bad).encode())

        bad = copy.deepcopy(valid)
        bad["warnings"] = []
        with self.assertRaisesRegex(ValueError, "warnings"):
            patcher.parse_manifest(json.dumps(bad).encode())

    def test_reviewed_cli_validates_and_writes_only_with_acknowledgement(self) -> None:
        source = bytes(patcher.REGIONS["dsp-external"].file_offset + 16)
        expected = bytearray(source)
        offset = patcher.REGIONS["dsp-external"].file_offset + 4
        expected[offset:offset + 2] = b"\xaa\xbb"
        digest = hashlib.sha256(expected).hexdigest()
        manifest = reviewed_manifest(digest)

        for write in (False, True):
            extra = (
                ["output.bin", "--acknowledge-unsigned-analysis-copy"]
                if write else ["--validate-only"]
            )
            output = io.StringIO()
            with (
                self.subTest(write=write),
                mock.patch.object(sys, "argv", ["patcher", "input", "manifest", *extra]),
                mock.patch.object(patcher, "read_regular", side_effect=[
                    (source, 0o100640),
                    (json.dumps(manifest).encode(), 0o100600),
                ]),
                mock.patch.object(patcher, "verify_frankel_stock") as stock_guard,
                mock.patch.object(patcher, "atomic_publish_new") as publish,
                contextlib.redirect_stdout(output),
            ):
                self.assertEqual(patcher.main(), 0)
                stock_guard.assert_called_once_with(source)
                if write:
                    publish.assert_called_once_with(
                        pathlib.Path("output.bin"), bytes(expected), 0o100640
                    )
                    self.assertIn("DO NOT FLASH OR LOAD", output.getvalue())
                else:
                    publish.assert_not_called()
                    self.assertIn("validated offline patch", output.getvalue())

    def test_incomplete_design_keeps_schema_and_edit_guards(self) -> None:
        valid = synthetic_manifest()
        variants = []
        bad = copy.deepcopy(valid)
        bad["schema"] = "unknown"
        variants.append((bad, "manifest schema"))
        bad = copy.deepcopy(valid)
        del bad["patch_set"]["output_sha256"]
        variants.append((bad, "must be present"))
        bad = copy.deepcopy(valid)
        bad["patch_set"]["output_sha256"] = "not-a-digest"
        variants.append((bad, "64 lowercase hex"))
        for field, value, error in (
            ("analysis_address", patcher.REGIONS["dsp-external"].analysis_address, "mapping disagrees"),
            ("replacement_hex", "abc", "even-length hex"),
            ("replacement_hex", "zzzz", "even-length hex"),
            ("replacement_hex", "aabbcc", "preserve byte length"),
            ("replacement_hex", "0000", "does not change any bytes"),
            ("container_offset", 0, "falls outside region"),
        ):
            bad = copy.deepcopy(valid)
            bad["patch_set"]["edits"][0][field] = value
            variants.append((bad, error))
        bad = copy.deepcopy(valid)
        duplicate = copy.deepcopy(bad["patch_set"]["edits"][0])
        duplicate["id"] = "synthetic.overlap"
        duplicate["container_offset"] += 1
        duplicate["analysis_address"] += 1
        bad["patch_set"]["edits"].append(duplicate)
        variants.append((bad, "overlapping edits"))
        for manifest, error in variants:
            with self.subTest(error=error):
                with self.assertRaisesRegex(ValueError, error):
                    patcher.parse_manifest(
                        json.dumps(manifest).encode(), validate_incomplete_design=True
                    )

    def run_incomplete_main(self, manifest: dict) -> tuple[str, bytes]:
        source = bytes(patcher.REGIONS["dsp-external"].file_offset + 16)
        output = io.StringIO()
        argv = ["patcher", "synthetic-input", "synthetic-manifest", "--validate-incomplete-design"]
        with (
            mock.patch.object(sys, "argv", argv),
            mock.patch.object(patcher, "read_regular", side_effect=[
                (source, 0o100600), (json.dumps(manifest).encode(), 0o100600)
            ]),
            # Isolate CLI behavior; no real firmware is read by these fixtures.
            mock.patch.object(patcher, "verify_frankel_stock") as stock_guard,
            mock.patch.object(patcher, "atomic_publish_new", side_effect=AssertionError("write attempted")) as publish,
            contextlib.redirect_stdout(output),
        ):
            self.assertEqual(patcher.main(), 0)
            stock_guard.assert_called_once_with(source)
            publish.assert_not_called()
        return output.getvalue(), source

    def test_incomplete_cli_prints_preview_and_never_publishes(self) -> None:
        manifest = synthetic_manifest()
        output, source = self.run_incomplete_main(manifest)
        expected = bytearray(source)
        offset = manifest["patch_set"]["edits"][0]["container_offset"]
        expected[offset:offset + 2] = b"\xaa\xbb"
        self.assertIn(f"preview sha256={hashlib.sha256(expected).hexdigest()}", output)
        self.assertIn("no output written; design remains incomplete", output)
        self.assertEqual(manifest["review"]["status"], "incomplete-design")
        self.assertIsNone(manifest["patch_set"]["output_sha256"])

    def test_incomplete_cli_checks_stock_bytes_and_optional_digest(self) -> None:
        manifest = synthetic_manifest()
        manifest["patch_set"]["edits"][0]["expected_hex"] = "0100"
        with self.assertRaisesRegex(ValueError, "stock-byte guard failed"):
            self.run_incomplete_main(manifest)
        manifest = synthetic_manifest()
        manifest["patch_set"]["output_sha256"] = "1" * 64
        with self.assertRaisesRegex(ValueError, "does not match manifest digest"):
            self.run_incomplete_main(manifest)

    def test_incomplete_cli_keeps_stock_identity_guard(self) -> None:
        with (
            mock.patch.object(sys, "argv", ["patcher", "input", "manifest", "--validate-incomplete-design"]),
            mock.patch.object(patcher, "read_regular", side_effect=[
                (b"not firmware", 0o100600),
                (json.dumps(synthetic_manifest()).encode(), 0o100600),
            ]),
            mock.patch.object(patcher, "atomic_publish_new") as publish,
        ):
            with self.assertRaisesRegex(ValueError, "unexpected firmware size"):
                patcher.main()
            publish.assert_not_called()

    def test_incomplete_manifest_still_fails_strict_and_write_modes(self) -> None:
        for extra in (["--validate-only"], ["output.bin", "--acknowledge-unsigned-analysis-copy"]):
            with self.subTest(extra=extra):
                with (
                    mock.patch.object(sys, "argv", ["patcher", "input", "manifest", *extra]),
                    mock.patch.object(patcher, "read_regular", side_effect=[
                        (bytes(16), 0o100600),
                        (json.dumps(synthetic_manifest()).encode(), 0o100600),
                    ]),
                    mock.patch.object(patcher, "verify_frankel_stock"),
                    mock.patch.object(patcher, "atomic_publish_new") as publish,
                ):
                    with self.assertRaisesRegex(ValueError, "not review-complete"):
                        patcher.main()
                    publish.assert_not_called()

    def test_validation_modes_reject_all_write_arguments_before_reading(self) -> None:
        for mode in ("--validate-only", "--validate-incomplete-design"):
            for extra in (["output.bin"], ["--acknowledge-unsigned-analysis-copy"],
                          ["output.bin", "--acknowledge-unsigned-analysis-copy"]):
                with self.subTest(mode=mode, extra=extra):
                    with (
                        mock.patch.object(sys, "argv", ["patcher", "input", "manifest", *extra, mode]),
                        mock.patch.object(patcher, "read_regular") as read,
                        mock.patch.object(patcher, "atomic_publish_new") as publish,
                    ):
                        with self.assertRaisesRegex(ValueError, "does not accept output/write"):
                            patcher.main()
                        read.assert_not_called()
                        publish.assert_not_called()

    def test_validation_modes_are_mutually_exclusive(self) -> None:
        with (
            mock.patch.object(
                sys,
                "argv",
                [
                    "patcher",
                    "input",
                    "manifest",
                    "--validate-only",
                    "--validate-incomplete-design",
                ],
            ),
            contextlib.redirect_stderr(io.StringIO()),
        ):
            with self.assertRaises(SystemExit) as error:
                patcher.parse_args()
            self.assertEqual(error.exception.code, 2)


if __name__ == "__main__":
    unittest.main()
