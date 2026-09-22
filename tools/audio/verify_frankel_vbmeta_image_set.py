#!/usr/bin/env python3
"""Check that a Frankel root vbmeta describes the images it will accompany.

This deliberately compares AVB descriptors, not whole-file hashes.  It catches
the dangerous case where a perfectly valid experimental vendor_kernel_boot is
combined with a root vbmeta copied from a different system/vendor build.
"""

from __future__ import annotations

import argparse
import pathlib
import re
import subprocess
import sys
from dataclasses import dataclass


HEX_256 = re.compile(r"^[0-9a-fA-F]{64}$")


class GuardError(RuntimeError):
    pass


@dataclass(frozen=True)
class Descriptor:
    kind: str
    partition: str
    fields: tuple[tuple[str, str], ...]

    @property
    def values(self) -> dict[str, str]:
        return dict(self.fields)


def avb_info(avbtool: pathlib.Path, image: pathlib.Path) -> str:
    if not image.is_file() or image.is_symlink():
        raise GuardError(f"missing or unsafe image: {image}")
    result = subprocess.run(
        [str(avbtool), "info_image", "--image", str(image)],
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    if result.returncode:
        detail = result.stderr.strip() or result.stdout.strip()
        raise GuardError(f"avbtool cannot inspect {image}: {detail}")
    return result.stdout


def parse_descriptors(info: str) -> list[Descriptor]:
    descriptors: list[Descriptor] = []
    kind: str | None = None
    fields: dict[str, str] = {}

    def finish() -> None:
        nonlocal kind, fields
        if kind == "Chain Partition":
            raise GuardError(
                "chain-partition descriptors are not supported by this Frankel guard"
            )
        if kind in {"Hash", "Hashtree"}:
            partition = fields.get("Partition Name")
            if not partition:
                raise GuardError(f"{kind} descriptor has no partition name")
            descriptors.append(
                Descriptor(kind, partition, tuple(sorted(fields.items())))
            )
        kind = None
        fields = {}

    for line in info.splitlines():
        header = re.match(r"^    (Hash|Hashtree|Chain Partition) descriptor:$", line)
        if header:
            finish()
            kind = header.group(1)
            continue
        if re.match(r"^    [A-Za-z].*:$", line):
            finish()
            continue
        if kind is not None:
            field = re.match(r"^      ([^:]+):\s*(.*)$", line)
            if field:
                fields[field.group(1).strip()] = field.group(2).strip()
    finish()
    return descriptors


def descriptor_for(
    avbtool: pathlib.Path, image: pathlib.Path, partition: str
) -> Descriptor:
    matches = [
        item
        for item in parse_descriptors(avb_info(avbtool, image))
        if item.partition == partition
    ]
    if len(matches) != 1:
        raise GuardError(
            f"expected exactly one {partition} descriptor in {image}; "
            f"found {len(matches)}"
        )
    return matches[0]


def comparable_fields(descriptor: Descriptor) -> dict[str, str]:
    # Every field below is authenticated and material to the partition mapping.
    # Ignore no descriptor field except presentation-only keys (there currently
    # are none), so format additions fail closed until reviewed.
    return descriptor.values


def compare_descriptors(
    root: Descriptor, leaf: Descriptor, root_image: pathlib.Path, leaf_image: pathlib.Path
) -> None:
    if root.kind != leaf.kind or comparable_fields(root) != comparable_fields(leaf):
        raise GuardError(
            f"AVB descriptor mismatch for {root.partition}: "
            f"{root_image} does not describe {leaf_image}"
        )


def parse_overrides(values: list[str]) -> dict[str, pathlib.Path]:
    result: dict[str, pathlib.Path] = {}
    for value in values:
        partition, separator, raw_path = value.partition("=")
        if not separator or not re.fullmatch(r"[a-z0-9_]+", partition) or not raw_path:
            raise GuardError(f"invalid --override value: {value!r}")
        if partition in result:
            raise GuardError(f"duplicate override for {partition}")
        result[partition] = pathlib.Path(raw_path).resolve()
    return result


def verify_pair(
    avbtool: pathlib.Path, root_vbmeta: pathlib.Path, vendor_kernel_boot: pathlib.Path
) -> None:
    compare_descriptors(
        descriptor_for(avbtool, root_vbmeta, "vendor_kernel_boot"),
        descriptor_for(avbtool, vendor_kernel_boot, "vendor_kernel_boot"),
        root_vbmeta,
        vendor_kernel_boot,
    )


def verify_root_set(
    avbtool: pathlib.Path,
    root_vbmeta: pathlib.Path,
    image_set: pathlib.Path,
    overrides: dict[str, pathlib.Path],
) -> int:
    if not image_set.is_dir() or image_set.is_symlink():
        raise GuardError(f"missing or unsafe image-set directory: {image_set}")
    root_descriptors = parse_descriptors(avb_info(avbtool, root_vbmeta))
    if not root_descriptors:
        raise GuardError(f"root vbmeta contains no partition descriptors: {root_vbmeta}")
    seen: set[str] = set()
    for root_descriptor in root_descriptors:
        partition = root_descriptor.partition
        if partition in seen:
            raise GuardError(f"duplicate root descriptor for {partition}")
        seen.add(partition)
        leaf_image = overrides.get(partition, image_set / f"{partition}.img")
        compare_descriptors(
            root_descriptor,
            descriptor_for(avbtool, leaf_image, partition),
            root_vbmeta,
            leaf_image,
        )
    unused = sorted(set(overrides) - seen)
    if unused:
        raise GuardError(
            "override partition is absent from root vbmeta: " + ", ".join(unused)
        )
    return len(seen)


def digest_for(descriptor: Descriptor) -> str:
    key = "Digest" if descriptor.kind == "Hash" else "Root Digest"
    digest = descriptor.values.get(key, "").lower()
    if not HEX_256.fullmatch(digest):
        raise GuardError(
            f"invalid or missing {key.lower()} in {descriptor.partition} descriptor"
        )
    return digest


def rewrite_vendor_kernel_boot_digest(
    avbtool: pathlib.Path,
    root_vbmeta: pathlib.Path,
    vendor_kernel_boot: pathlib.Path,
    output: pathlib.Path,
) -> None:
    root_descriptor = descriptor_for(avbtool, root_vbmeta, "vendor_kernel_boot")
    leaf_descriptor = descriptor_for(
        avbtool, vendor_kernel_boot, "vendor_kernel_boot"
    )
    root_fields = comparable_fields(root_descriptor).copy()
    leaf_fields = comparable_fields(leaf_descriptor).copy()
    old_digest = digest_for(root_descriptor)
    new_digest = digest_for(leaf_descriptor)
    root_fields.pop("Digest", None)
    leaf_fields.pop("Digest", None)
    if root_descriptor.kind != "Hash" or root_fields != leaf_fields:
        raise GuardError(
            "candidate vendor_kernel_boot changes descriptor metadata other than its digest"
        )
    source = root_vbmeta.read_bytes()
    old = bytes.fromhex(old_digest)
    new = bytes.fromhex(new_digest)
    if source.count(old) != 1:
        raise GuardError(
            "guarded vendor_kernel_boot digest is not unique in root vbmeta"
        )
    if output.exists():
        raise GuardError(f"refusing to overwrite output: {output}")
    output.write_bytes(source.replace(old, new, 1))


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    result.add_argument("--avbtool", required=True, type=pathlib.Path)
    subparsers = result.add_subparsers(dest="command", required=True)

    pair = subparsers.add_parser("pair", help="compare root and VKB descriptors")
    pair.add_argument("--vbmeta", required=True, type=pathlib.Path)
    pair.add_argument("--vendor-kernel-boot", required=True, type=pathlib.Path)

    root_set = subparsers.add_parser(
        "root-set", help="compare every root descriptor with a complete image set"
    )
    root_set.add_argument("--vbmeta", required=True, type=pathlib.Path)
    root_set.add_argument("--image-set", required=True, type=pathlib.Path)
    root_set.add_argument("--override", action="append", default=[])

    digest = subparsers.add_parser("digest", help="print one partition digest")
    digest.add_argument("--image", required=True, type=pathlib.Path)
    digest.add_argument("--partition", required=True)

    rewrite = subparsers.add_parser(
        "rewrite-vkb-digest",
        help="copy a root vbmeta while replacing only its VKB descriptor digest",
    )
    rewrite.add_argument("--vbmeta", required=True, type=pathlib.Path)
    rewrite.add_argument("--vendor-kernel-boot", required=True, type=pathlib.Path)
    rewrite.add_argument("--output", required=True, type=pathlib.Path)
    return result


def main() -> int:
    args = parser().parse_args()
    avbtool = args.avbtool.resolve()
    if not avbtool.is_file() or avbtool.is_symlink():
        raise GuardError(f"missing or unsafe avbtool: {avbtool}")
    if args.command == "pair":
        verify_pair(avbtool, args.vbmeta.resolve(), args.vendor_kernel_boot.resolve())
        print("compatible: root vbmeta describes vendor_kernel_boot")
    elif args.command == "root-set":
        count = verify_root_set(
            avbtool,
            args.vbmeta.resolve(),
            args.image_set.resolve(),
            parse_overrides(args.override),
        )
        print(f"compatible: root vbmeta describes {count} image(s)")
    elif args.command == "digest":
        print(digest_for(descriptor_for(avbtool, args.image.resolve(), args.partition)))
    elif args.command == "rewrite-vkb-digest":
        rewrite_vendor_kernel_boot_digest(
            avbtool,
            args.vbmeta.resolve(),
            args.vendor_kernel_boot.resolve(),
            args.output.resolve(),
        )
    else:  # pragma: no cover - argparse makes this unreachable.
        raise GuardError(f"unsupported command: {args.command}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except GuardError as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(1)
