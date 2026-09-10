#!/usr/bin/env python3
"""Create a guarded, unsigned Frankel AoC analysis copy from a manifest.

This tool is deliberately offline-only.  It does not access a device, sign an
image, bypass firmware authentication, or make its output loadable.  Every
accepted manifest is tied to the exact reviewed stock Frankel ``aoc.bin`` and
must describe equal-length substitutions in mapped analysis regions. Incomplete
designs may only be inspected with the explicitly read-only validation mode.

WARNING: changing any covered byte invalidates the OEM firmware signature.
The output is for offline analysis only and MUST NOT be flashed or loaded.
"""

from __future__ import annotations

import argparse
import dataclasses
import hashlib
import json
import os
import pathlib
import re
import stat
import struct
import sys
import tempfile
from typing import Any


SCHEMA = "frankel-aoc-offline-patch/v1"
TARGET_PROFILE = "frankel-cp2a-260805-005-aoc"
EXPECTED_SIZE = 24_791_040
EXPECTED_STOCK_SHA256 = (
    "ac6d7d86e6aa78379bfa3db5eaea4dadebf8113dc8f46aab52d55f3987064abd"
)
EXPECTED_FIRMWARE_VERSION = "15070001-polygon"

HEADER_OFFSET = 0x1000
SUPERBIN_MAGIC = 0xAABBCCDD
SECTION_MARKER = 0xBEEFBEEF
EXPECTED_TABLE = 0xC000
EXPECTED_STRIDE = 40
EXPECTED_SECTION_COUNT = 27

HEX_DIGEST = re.compile(r"[0-9a-f]{64}")
HEX_BYTES = re.compile(r"(?:[0-9a-fA-F]{2})+")
IDENTIFIER = re.compile(r"[a-z0-9][a-z0-9._-]{2,79}")
REVIEWED_ARTIFACT_CLASS = "unsigned-offline-analysis-copy-only"
REVIEWED_SCOPE = "exact-offline-semantic-byte-construction"
REQUIRED_FALSE_QUALIFICATIONS = (
    "oem_signature_valid_if_applied",
    "loadable",
    "flashable",
    "hardware_qualified_192khz",
    "acoustic_bandwidth_qualified",
)


@dataclasses.dataclass(frozen=True)
class Region:
    name: str
    file_offset: int
    size: int
    analysis_address: int

    @property
    def file_end(self) -> int:
        return self.file_offset + self.size


REGIONS = {
    "dsp-external": Region("dsp-external", 0xE000, 0xA61DC0, 0x7800D000),
    "shared": Region("shared", 0xA6FDC0, 0xA00000, 0x40000000),
}


@dataclasses.dataclass(frozen=True)
class Edit:
    identifier: str
    region: Region
    offset: int
    analysis_address: int
    before: bytes
    after: bytes
    semantic_intent: str
    evidence: tuple[str, ...]


def sha256(data: bytes | bytearray) -> str:
    return hashlib.sha256(data).hexdigest()


def parse_integer(value: Any, field: str) -> int:
    if isinstance(value, bool):
        raise ValueError(f"{field} must be an integer or 0x-prefixed string")
    if isinstance(value, int):
        parsed = value
    elif isinstance(value, str) and re.fullmatch(r"0x[0-9a-fA-F]+", value):
        parsed = int(value, 16)
    else:
        raise ValueError(f"{field} must be an integer or 0x-prefixed string")
    if parsed < 0:
        raise ValueError(f"{field} must not be negative")
    return parsed


def parse_hex_bytes(value: Any, field: str) -> bytes:
    if not isinstance(value, str) or not HEX_BYTES.fullmatch(value):
        raise ValueError(f"{field} must be a non-empty, even-length hex string")
    return bytes.fromhex(value)


def require_text(value: Any, field: str) -> str:
    if not isinstance(value, str) or not value.strip():
        raise ValueError(f"{field} must be non-empty text")
    return value.strip()


def read_regular(path: pathlib.Path, description: str) -> tuple[bytes, int]:
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(path, flags)
    except OSError as error:
        raise ValueError(f"cannot open safe {description} {path}: {error}") from error
    try:
        metadata = os.fstat(descriptor)
        if not stat.S_ISREG(metadata.st_mode):
            raise ValueError(f"{description} is not a regular file: {path}")
        with os.fdopen(descriptor, "rb", closefd=False) as stream:
            return stream.read(), metadata.st_mode
    finally:
        os.close(descriptor)


def verify_frankel_stock(data: bytes) -> None:
    if len(data) != EXPECTED_SIZE:
        raise ValueError(
            f"unexpected firmware size {len(data)}; expected {EXPECTED_SIZE}"
        )
    observed = sha256(data)
    if observed != EXPECTED_STOCK_SHA256:
        raise ValueError(
            "input is not the exact reviewed stock Frankel aoc.bin "
            f"(sha256={observed})"
        )
    if struct.unpack_from("<I", data, HEADER_OFFSET)[0] != SUPERBIN_MAGIC:
        raise ValueError("unexpected Frankel superbin magic")
    table, stride, count = struct.unpack_from("<III", data, HEADER_OFFSET + 0x70)
    if (table, stride, count) != (
        EXPECTED_TABLE,
        EXPECTED_STRIDE,
        EXPECTED_SECTION_COUNT,
    ):
        raise ValueError("unexpected Frankel superbin section-table layout")
    rows = [
        struct.unpack_from("<10I", data, HEADER_OFFSET + table + stride * index)
        for index in range(count)
    ]
    if any(row[0] != SECTION_MARKER for row in rows):
        raise ValueError("unexpected Frankel superbin section marker")
    if rows[0][4:7] != (0xD000, 0xA61DC0, 0x9800D000):
        raise ValueError("unexpected Frankel external-memory section")
    if rows[1][4:6] != (0xA6EDC0, 0xA00000):
        raise ValueError("unexpected Frankel shared-memory section")
    raw_version = data[HEADER_OFFSET + 0x30 : HEADER_OFFSET + 0x70]
    version = raw_version.split(b"\0", 1)[0].decode("ascii")
    if version != EXPECTED_FIRMWARE_VERSION:
        raise ValueError(f"unexpected Frankel firmware version {version!r}")


def parse_manifest(
    raw: bytes, *, validate_incomplete_design: bool = False
) -> tuple[list[Edit], str | None, dict[str, Any]]:
    try:
        manifest = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ValueError(f"invalid UTF-8 JSON manifest: {error}") from error
    if not isinstance(manifest, dict):
        raise ValueError("manifest root must be an object")
    if manifest.get("schema") != SCHEMA:
        raise ValueError(f"manifest schema must be {SCHEMA!r}")

    target = manifest.get("target")
    if not isinstance(target, dict):
        raise ValueError("manifest target must be an object")
    exact_target = {
        "profile": TARGET_PROFILE,
        "codename": "frankel",
        "firmware_size": EXPECTED_SIZE,
        "input_sha256": EXPECTED_STOCK_SHA256,
        "firmware_version": EXPECTED_FIRMWARE_VERSION,
    }
    for field, expected in exact_target.items():
        if target.get(field) != expected:
            raise ValueError(
                f"manifest target.{field} must equal the reviewed value {expected!r}"
            )

    review = manifest.get("review")
    if not isinstance(review, dict):
        raise ValueError("manifest review must be an object")
    status = review.get("status")
    if validate_incomplete_design:
        if status != "incomplete-design":
            raise ValueError(
                "--validate-incomplete-design requires review.status incomplete-design"
            )
    elif status != "reviewed-complete":
        raise ValueError(
            "manifest is not review-complete; incomplete design manifests cannot "
            "produce firmware copies"
        )
    require_text(review.get("reviewer"), "review.reviewer")
    require_text(review.get("reviewed_at"), "review.reviewed_at")
    if status == "reviewed-complete":
        if manifest.get("artifact_class") != REVIEWED_ARTIFACT_CLASS:
            raise ValueError(
                "reviewed manifest artifact_class must explicitly identify an "
                "unsigned offline-analysis copy"
            )
        if review.get("scope") != REVIEWED_SCOPE:
            raise ValueError(
                f"review.scope must equal {REVIEWED_SCOPE!r}"
            )
        qualification = manifest.get("qualification")
        if not isinstance(qualification, dict):
            raise ValueError("reviewed manifest qualification must be an object")
        for field in REQUIRED_FALSE_QUALIFICATIONS:
            if qualification.get(field) is not False:
                raise ValueError(
                    f"qualification.{field} must be exactly false for an "
                    "offline analysis copy"
                )
        warnings = manifest.get("warnings")
        if not isinstance(warnings, list) or not warnings:
            raise ValueError("reviewed manifest warnings must be a non-empty list")
        for index, warning in enumerate(warnings):
            require_text(warning, f"warnings[{index}]")

    patch_set = manifest.get("patch_set")
    if not isinstance(patch_set, dict):
        raise ValueError("manifest patch_set must be an object")
    patch_id = require_text(patch_set.get("id"), "patch_set.id")
    if not IDENTIFIER.fullmatch(patch_id):
        raise ValueError("patch_set.id has invalid characters or length")
    require_text(patch_set.get("summary"), "patch_set.summary")
    output_digest = patch_set.get("output_sha256")
    if output_digest is None and validate_incomplete_design:
        if "output_sha256" not in patch_set:
            raise ValueError("patch_set.output_sha256 must be present (null is allowed)")
    elif not isinstance(output_digest, str) or not HEX_DIGEST.fullmatch(output_digest):
        raise ValueError("patch_set.output_sha256 must be 64 lowercase hex digits")
    if output_digest == EXPECTED_STOCK_SHA256:
        raise ValueError("reviewed patch output must differ from stock")

    raw_edits = patch_set.get("edits")
    if not isinstance(raw_edits, list) or not raw_edits:
        raise ValueError("reviewed patch_set.edits must be a non-empty list")
    if len(raw_edits) > 256:
        raise ValueError("refusing a manifest with more than 256 edits")

    edits: list[Edit] = []
    identifiers: set[str] = set()
    for index, raw_edit in enumerate(raw_edits):
        field = f"patch_set.edits[{index}]"
        if not isinstance(raw_edit, dict):
            raise ValueError(f"{field} must be an object")
        identifier = require_text(raw_edit.get("id"), f"{field}.id")
        if not IDENTIFIER.fullmatch(identifier) or identifier in identifiers:
            raise ValueError(f"{field}.id is invalid or duplicated")
        identifiers.add(identifier)
        region_name = raw_edit.get("region")
        if region_name not in REGIONS:
            raise ValueError(f"{field}.region must name a reviewed analysis region")
        region = REGIONS[region_name]
        offset = parse_integer(raw_edit.get("container_offset"), f"{field}.container_offset")
        address = parse_integer(raw_edit.get("analysis_address"), f"{field}.analysis_address")
        before = parse_hex_bytes(raw_edit.get("expected_hex"), f"{field}.expected_hex")
        after = parse_hex_bytes(raw_edit.get("replacement_hex"), f"{field}.replacement_hex")
        if len(before) != len(after):
            raise ValueError(f"{field} must preserve byte length")
        if before == after:
            raise ValueError(f"{field} does not change any bytes")
        if not (region.file_offset <= offset and offset + len(before) <= region.file_end):
            raise ValueError(f"{field} falls outside region {region.name}")
        mapped_offset = region.file_offset + address - region.analysis_address
        if mapped_offset != offset:
            raise ValueError(
                f"{field} address/offset mapping disagrees with region {region.name}"
            )
        semantic_intent = require_text(
            raw_edit.get("semantic_intent"), f"{field}.semantic_intent"
        )
        raw_evidence = raw_edit.get("evidence")
        if not isinstance(raw_evidence, list) or not raw_evidence:
            raise ValueError(f"{field}.evidence must be a non-empty list")
        evidence = tuple(
            require_text(item, f"{field}.evidence[{item_index}]")
            for item_index, item in enumerate(raw_evidence)
        )
        edits.append(
            Edit(
                identifier,
                region,
                offset,
                address,
                before,
                after,
                semantic_intent,
                evidence,
            )
        )

    ordered = sorted(edits, key=lambda edit: edit.offset)
    for previous, current in zip(ordered, ordered[1:]):
        if previous.offset + len(previous.before) > current.offset:
            raise ValueError(
                f"overlapping edits: {previous.identifier} and {current.identifier}"
            )
    return ordered, output_digest, manifest


def preview_edits(data: bytes, edits: list[Edit]) -> bytes:
    """Check stock bytes and construct an in-memory preview; never write files."""
    result = bytearray(data)
    for edit in edits:
        end = edit.offset + len(edit.before)
        actual = bytes(result[edit.offset:end])
        if actual != edit.before:
            raise ValueError(
                f"{edit.identifier}: stock-byte guard failed at {edit.offset:#x}; "
                f"found {actual.hex()}, expected {edit.before.hex()}"
            )
        result[edit.offset:end] = edit.after
    return bytes(result)


def apply_edits(data: bytes, edits: list[Edit], output_digest: str) -> bytes:
    result = preview_edits(data, edits)
    observed = sha256(result)
    if observed != output_digest:
        raise ValueError(
            f"patched output digest {observed} does not match reviewed manifest "
            f"digest {output_digest}"
        )
    return result


def atomic_publish_new(path: pathlib.Path, data: bytes, mode: int) -> None:
    """Publish one new regular file atomically without replacing anything."""

    path.parent.mkdir(parents=True, exist_ok=True)
    if os.path.lexists(path):
        raise ValueError(f"refusing to replace existing output: {path}")
    descriptor, temporary_name = tempfile.mkstemp(
        prefix=f".{path.name}.", dir=path.parent
    )
    temporary = pathlib.Path(temporary_name)
    try:
        with os.fdopen(descriptor, "wb") as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        # Preserve ordinary read/write permissions only.  An analysis blob
        # never needs execute, set-ID, or sticky bits inherited from INPUT.
        output_mode = stat.S_IMODE(mode) & 0o666
        os.chmod(temporary, output_mode or 0o600)
        # A hard-link publication is atomic and fails if OUTPUT appeared after
        # the lexists check.  It therefore never overwrites a user's file.
        os.link(temporary, path, follow_symlinks=False)
        temporary.unlink()
        directory = os.open(path.parent, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        temporary.unlink(missing_ok=True)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("input", type=pathlib.Path, help="exact stock Frankel aoc.bin")
    parser.add_argument("manifest", type=pathlib.Path, help="semantic JSON manifest")
    parser.add_argument("output", type=pathlib.Path, nargs="?", help="new unsigned copy")
    validation = parser.add_mutually_exclusive_group()
    validation.add_argument(
        "--validate-only", action="store_true",
        help="strictly validate a reviewed-complete manifest without writing",
    )
    validation.add_argument(
        "--validate-incomplete-design", action="store_true",
        help="check an incomplete-design manifest and print an unreviewed preview digest; never write",
    )
    parser.add_argument(
        "--acknowledge-unsigned-analysis-copy",
        action="store_true",
        help="required to write: acknowledge that output cannot be flashed or loaded",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if args.validate_only or args.validate_incomplete_design:
        if args.output is not None or args.acknowledge_unsigned_analysis_copy:
            mode = (
                "--validate-incomplete-design"
                if args.validate_incomplete_design else "--validate-only"
            )
            raise ValueError(f"{mode} does not accept output/write acknowledgement")
    else:
        if args.output is None:
            raise ValueError("write mode requires OUTPUT")
        if not args.acknowledge_unsigned_analysis_copy:
            raise ValueError(
                "write mode requires --acknowledge-unsigned-analysis-copy"
            )
        if args.input.absolute() == args.output.absolute():
            raise ValueError("OUTPUT must be a separate copy, never INPUT")

    source, source_mode = read_regular(args.input, "firmware input")
    manifest_raw, _ = read_regular(args.manifest, "patch manifest")
    verify_frankel_stock(source)
    edits, output_digest, manifest = parse_manifest(
        manifest_raw, validate_incomplete_design=args.validate_incomplete_design
    )
    patch_id = manifest["patch_set"]["id"]

    if args.validate_incomplete_design:
        preview = preview_edits(source, edits)
        preview_digest = sha256(preview)
        if output_digest is not None and preview_digest != output_digest:
            raise ValueError(
                f"preview digest {preview_digest} does not match manifest digest {output_digest}"
            )
        print(
            f"validated incomplete design structure and byte guards {patch_id}: "
            f"{len(edits)} edits, preview sha256={preview_digest}"
        )
        print("READ-ONLY: no output written; design remains incomplete and unqualified")
        return 0

    if output_digest is None:
        raise ValueError("reviewed validation/write mode requires an output digest")
    result = apply_edits(source, edits, output_digest)

    if args.validate_only:
        print(
            f"validated offline patch {patch_id}: {len(edits)} edits, "
            f"unsigned output sha256={output_digest}"
        )
        return 0

    assert args.output is not None
    atomic_publish_new(args.output, result, source_mode)
    print(f"wrote unsigned offline-analysis copy: {args.output}")
    print(f"patch_set={patch_id} sha256={output_digest}")
    print("WARNING: OEM SIGNATURE INVALID; DO NOT FLASH OR LOAD THIS OUTPUT")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError) as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(2)
