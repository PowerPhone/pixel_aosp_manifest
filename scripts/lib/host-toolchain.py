#!/usr/bin/env python3
"""Safely extract and attest the workspace's pinned host toolchains."""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
import shutil
import stat
import sys
import tarfile
import tempfile
import zipfile
from pathlib import Path
from typing import Any, BinaryIO, Iterator


class VerificationError(Exception):
    """An input is unsafe or does not match its pinned reference."""


def fail(message: str) -> None:
    raise VerificationError(message)


def lstat_regular(path: Path, label: str) -> os.stat_result:
    try:
        result = path.lstat()
    except FileNotFoundError:
        fail(f"{label} is missing: {path}")
    if not stat.S_ISREG(result.st_mode):
        fail(f"{label} is not a regular, non-symlink file: {path}")
    if result.st_nlink != 1:
        fail(f"{label} is not a singly linked regular file: {path}")
    return result


def open_verified_file(path: Path, expected_sha256: str, label: str) -> BinaryIO:
    if len(expected_sha256) != 64 or any(
        character not in "0123456789abcdef" for character in expected_sha256
    ):
        fail(f"{label} has an invalid expected SHA-256")
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_CLOEXEC", 0)
    try:
        descriptor = os.open(path, flags)
    except OSError as error:
        fail(f"cannot open {label} {path}: {error}")
    try:
        status = os.fstat(descriptor)
        if not stat.S_ISREG(status.st_mode) or status.st_nlink != 1:
            fail(f"{label} is not a regular, singly linked file: {path}")
        digest = hashlib.sha256()
        while chunk := os.read(descriptor, 1024 * 1024):
            digest.update(chunk)
        actual = digest.hexdigest()
        if actual != expected_sha256:
            fail(f"{label} SHA-256 is {actual}, expected {expected_sha256}: {path}")
        os.lseek(descriptor, 0, os.SEEK_SET)
        return os.fdopen(descriptor, "rb")
    except Exception:
        os.close(descriptor)
        raise


def real_directory(path: Path, label: str) -> os.stat_result:
    try:
        result = path.lstat()
    except FileNotFoundError:
        fail(f"{label} is missing: {path}")
    if not stat.S_ISDIR(result.st_mode):
        fail(f"{label} is not a real directory: {path}")
    return result


def safe_component_text(value: str, label: str) -> None:
    if "\\" in value or any(ord(character) < 32 for character in value):
        fail(f"{label} contains a backslash or control character: {value!r}")


def archive_path_parts(name: str) -> tuple[str, ...]:
    safe_component_text(name, "archive member name")
    if not name or name.startswith("/"):
        fail(f"archive member has an empty or absolute name: {name!r}")
    parts = tuple(name.split("/"))
    if any(part in ("", ".", "..") for part in parts):
        fail(f"archive member name is not canonical: {name!r}")
    return parts


def validate_link_target(
    member_parts: tuple[str, ...], target: str
) -> tuple[str, ...]:
    safe_component_text(target, "archive symlink target")
    if not target or target.startswith("/"):
        fail(f"archive symlink has an empty or absolute target: {target!r}")
    resolved = list(member_parts[:-1])
    for component in target.split("/"):
        if component in ("", "."):
            fail(f"archive symlink target is not canonical: {target!r}")
        if component == "..":
            if len(resolved) <= 1:
                fail(f"archive symlink escapes its root: {target!r}")
            resolved.pop()
        else:
            resolved.append(component)
    if not resolved or resolved[0] != member_parts[0]:
        fail(f"archive symlink escapes its root: {target!r}")
    return tuple(resolved)


def validated_members(
    archive: Path, expected_root: str, expected_sha256: str
) -> tuple[
    tarfile.TarFile,
    BinaryIO,
    list[tuple[tarfile.TarInfo, tuple[str, ...]]],
]:
    if "/" in expected_root or expected_root in ("", ".", ".."):
        fail(f"invalid expected archive root: {expected_root!r}")
    safe_component_text(expected_root, "expected archive root")
    archive_file = open_verified_file(
        archive, expected_sha256, "toolchain archive"
    )
    try:
        opened = tarfile.open(fileobj=archive_file, mode="r:*")
    except (OSError, tarfile.TarError) as error:
        archive_file.close()
        fail(f"cannot read toolchain archive {archive}: {error}")

    validated: list[tuple[tarfile.TarInfo, tuple[str, ...]]] = []
    by_path: dict[tuple[str, ...], tarfile.TarInfo] = {}
    link_targets: dict[tuple[str, ...], tuple[str, ...]] = {}
    try:
        for member in opened.getmembers():
            parts = archive_path_parts(member.name)
            if parts[0] != expected_root:
                fail(
                    "archive member is outside the single expected root "
                    f"{expected_root!r}: {member.name!r}"
                )
            if parts in by_path:
                fail(f"archive contains a duplicate member: {member.name!r}")
            if member.mode & 0o7000:
                fail(f"archive member has unsafe special mode bits: {member.name!r}")
            if member.issparse():
                fail(f"archive contains an unsupported sparse file: {member.name!r}")
            if not (member.isdir() or member.isreg() or member.issym()):
                fail(f"archive contains an unsupported entry type: {member.name!r}")
            if member.issym():
                link_targets[parts] = validate_link_target(parts, member.linkname)
            by_path[parts] = member
            validated.append((member, parts))

        if not validated:
            fail("toolchain archive is empty")
        for _member, parts in validated:
            for length in range(1, len(parts)):
                ancestor = by_path.get(parts[:length])
                if ancestor is not None and not ancestor.isdir():
                    fail(
                        "archive member has a non-directory ancestor: "
                        f"{'/'.join(parts)!r}"
                    )
        root_member = by_path.get((expected_root,))
        if root_member is not None and not root_member.isdir():
            fail(f"archive root is not a directory: {expected_root!r}")
        for link_path, target_path in link_targets.items():
            target_member = by_path.get(target_path)
            if target_member is None or not target_member.isreg():
                fail(
                    "archive symlink does not target an archive-owned regular file: "
                    f"{'/'.join(link_path)!r}"
                )
    except Exception:
        opened.close()
        archive_file.close()
        raise
    return opened, archive_file, validated


def safe_extract(
    archive: Path, expected_root: str, expected_sha256: str, destination: Path
) -> Path:
    real_directory(destination, "archive extraction directory")
    if any(destination.iterdir()):
        fail(f"archive extraction directory is not empty: {destination}")

    opened, archive_file, members = validated_members(
        archive, expected_root, expected_sha256
    )
    try:
        explicit_directories: dict[tuple[str, ...], int] = {}
        all_directories: set[tuple[str, ...]] = {(expected_root,)}
        for member, parts in members:
            for length in range(1, len(parts)):
                all_directories.add(parts[:length])
            if member.isdir():
                all_directories.add(parts)
                explicit_directories[parts] = member.mode & 0o777

        for parts in sorted(all_directories, key=lambda value: (len(value), value)):
            directory = destination.joinpath(*parts)
            directory.mkdir(mode=0o700)

        for member, parts in members:
            target = destination.joinpath(*parts)
            if member.isdir():
                continue
            if member.isreg():
                source = opened.extractfile(member)
                if source is None:
                    fail(f"cannot read archive member data: {member.name!r}")
                descriptor = os.open(
                    target,
                    os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0),
                    0o600,
                )
                with source, os.fdopen(descriptor, "wb") as output:
                    shutil.copyfileobj(source, output)
                os.chmod(target, member.mode & 0o777, follow_symlinks=False)
            else:
                os.symlink(member.linkname, target)

        for parts in sorted(all_directories, key=lambda value: (-len(value), value)):
            mode = explicit_directories.get(parts, 0o755)
            os.chmod(destination.joinpath(*parts), mode, follow_symlinks=False)
    finally:
        opened.close()
        archive_file.close()
    extracted_root = destination / expected_root
    real_directory(extracted_root, "extracted archive root")
    return extracted_root


def safe_extract_zip(
    archive: Path, expected_root: str, expected_sha256: str, destination: Path
) -> Path:
    real_directory(destination, "archive extraction directory")
    if any(destination.iterdir()):
        fail(f"archive extraction directory is not empty: {destination}")
    if "/" in expected_root or expected_root in ("", ".", ".."):
        fail(f"invalid expected archive root: {expected_root!r}")
    safe_component_text(expected_root, "expected archive root")

    archive_file = open_verified_file(
        archive, expected_sha256, "toolchain ZIP archive"
    )
    try:
        opened = zipfile.ZipFile(archive_file)
    except (OSError, zipfile.BadZipFile) as error:
        archive_file.close()
        fail(f"cannot read toolchain ZIP archive {archive}: {error}")
    try:
        members: list[tuple[zipfile.ZipInfo, tuple[str, ...], int, bool]] = []
        by_path: dict[tuple[str, ...], bool] = {}
        for member in opened.infolist():
            name = member.filename[:-1] if member.filename.endswith("/") else member.filename
            parts = archive_path_parts(name)
            if parts[0] != expected_root:
                fail(
                    "ZIP archive member is outside the single expected root "
                    f"{expected_root!r}: {member.filename!r}"
                )
            if parts in by_path:
                fail(f"ZIP archive contains a duplicate member: {member.filename!r}")
            if member.flag_bits & 0x1:
                fail(f"ZIP archive contains an encrypted member: {member.filename!r}")
            if member.create_system != 3:
                fail(f"ZIP archive member lacks pinned Unix type/mode: {member.filename!r}")
            raw_mode = member.external_attr >> 16
            entry_type = stat.S_IFMT(raw_mode)
            is_directory = member.is_dir()
            if is_directory:
                if entry_type not in (0, stat.S_IFDIR):
                    fail(f"ZIP directory has an inconsistent type: {member.filename!r}")
            elif entry_type != stat.S_IFREG:
                fail(f"ZIP archive contains an unsupported entry type: {member.filename!r}")
            mode = stat.S_IMODE(raw_mode)
            if mode & 0o7000:
                fail(f"ZIP archive member has unsafe special mode bits: {member.filename!r}")
            by_path[parts] = is_directory
            members.append((member, parts, mode, is_directory))

        if not members:
            fail("toolchain ZIP archive is empty")
        for _member, parts, _mode, _is_directory in members:
            for length in range(1, len(parts)):
                ancestor_type = by_path.get(parts[:length])
                if ancestor_type is False:
                    fail(
                        "ZIP archive member has a non-directory ancestor: "
                        f"{'/'.join(parts)!r}"
                    )
        if by_path.get((expected_root,)) is False:
            fail(f"ZIP archive root is not a directory: {expected_root!r}")

        explicit_directories: dict[tuple[str, ...], int] = {}
        all_directories: set[tuple[str, ...]] = {(expected_root,)}
        for _member, parts, mode, is_directory in members:
            for length in range(1, len(parts)):
                all_directories.add(parts[:length])
            if is_directory:
                all_directories.add(parts)
                explicit_directories[parts] = mode
        for parts in sorted(all_directories, key=lambda value: (len(value), value)):
            destination.joinpath(*parts).mkdir(mode=0o700)
        for member, parts, mode, is_directory in members:
            if is_directory:
                continue
            target = destination.joinpath(*parts)
            descriptor = os.open(
                target,
                os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0),
                0o600,
            )
            with opened.open(member) as source, os.fdopen(descriptor, "wb") as output:
                shutil.copyfileobj(source, output)
            os.chmod(target, mode, follow_symlinks=False)
        for parts in sorted(all_directories, key=lambda value: (-len(value), value)):
            os.chmod(
                destination.joinpath(*parts),
                explicit_directories.get(parts, 0o755),
                follow_symlinks=False,
            )
    finally:
        opened.close()
        archive_file.close()
    extracted_root = destination / expected_root
    real_directory(extracted_root, "extracted ZIP archive root")
    return extracted_root


def file_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def tree_entries(root: Path) -> Iterator[tuple[str, str, int, str | None]]:
    root_status = real_directory(root, "toolchain installation root")
    yield "", "directory", stat.S_IMODE(root_status.st_mode), None

    def visit(directory: Path, prefix: str) -> Iterator[tuple[str, str, int, str | None]]:
        try:
            entries = sorted(os.scandir(directory), key=lambda entry: entry.name)
        except OSError as error:
            fail(f"cannot inspect toolchain directory {directory}: {error}")
        for entry in entries:
            relative = f"{prefix}/{entry.name}" if prefix else entry.name
            status = entry.stat(follow_symlinks=False)
            mode = stat.S_IMODE(status.st_mode)
            path = Path(entry.path)
            if stat.S_ISDIR(status.st_mode):
                yield relative, "directory", mode, None
                yield from visit(path, relative)
            elif stat.S_ISREG(status.st_mode):
                if status.st_nlink != 1:
                    fail(f"toolchain regular file has an unsafe link count: {path}")
                yield relative, "file", mode, file_sha256(path)
            elif stat.S_ISLNK(status.st_mode):
                yield relative, "symlink", mode, os.readlink(path)
            else:
                fail(f"toolchain tree contains an unsupported entry type: {path}")

    yield from visit(root, "")


def compare_trees(
    expected: Path,
    installed: Path,
    excluded_installed_roots: tuple[str, ...] = (),
) -> None:
    def excluded(relative: str) -> bool:
        return any(
            relative == excluded_root or relative.startswith(f"{excluded_root}/")
            for excluded_root in excluded_installed_roots
        )

    expected_entries = {entry[0]: entry[1:] for entry in tree_entries(expected)}
    for excluded_root in excluded_installed_roots:
        if any(
            relative == excluded_root or relative.startswith(f"{excluded_root}/")
            for relative in expected_entries
        ):
            fail(f"archive unexpectedly owns reserved overlay path: {excluded_root}")
    installed_entries = {
        entry[0]: entry[1:]
        for entry in tree_entries(installed)
        if not excluded(entry[0])
    }
    expected_paths = set(expected_entries)
    installed_paths = set(installed_entries)
    missing = sorted(expected_paths - installed_paths)
    extra = sorted(installed_paths - expected_paths)
    if missing:
        fail(f"toolchain installation is missing archive entry: {missing[0]}")
    if extra:
        fail(f"toolchain installation has an unexpected entry: {extra[0]}")
    for relative in sorted(expected_paths):
        if expected_entries[relative] != installed_entries[relative]:
            fail(f"toolchain archive equivalence mismatch at: {relative or '.'}")


def load_json(path: Path, label: str) -> Any:
    lstat_regular(path, label)

    def reject_duplicate(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
        result: dict[str, Any] = {}
        for key, value in pairs:
            if key in result:
                fail(f"{label} contains a duplicate JSON key: {key!r}")
            result[key] = value
        return result

    try:
        with path.open("r", encoding="utf-8") as source:
            return json.load(source, object_pairs_hook=reject_duplicate)
    except (UnicodeError, json.JSONDecodeError, OSError) as error:
        fail(f"cannot parse {label} {path}: {error}")


def json_equal(actual: Any, expected: Any) -> bool:
    options = {"sort_keys": True, "separators": (",", ":")}
    return json.dumps(actual, **options) == json.dumps(expected, **options)


def require_mode(path: Path, expected_mode: int, label: str, directory: bool) -> None:
    status = real_directory(path, label) if directory else lstat_regular(path, label)
    actual_mode = stat.S_IMODE(status.st_mode)
    if actual_mode != expected_mode:
        fail(f"{label} mode is {actual_mode:o}, expected {expected_mode:o}: {path}")


def require_exact_children(path: Path, expected: set[str], label: str) -> None:
    real_directory(path, label)
    actual = {entry.name for entry in os.scandir(path)}
    if actual != expected:
        fail(
            f"{label} entries differ; expected {sorted(expected)!r}, "
            f"found {sorted(actual)!r}"
        )


def package_lock_entry(
    package: dict[str, Any], url: str, archive: Path, expected_sha256: str
) -> dict[str, Any]:
    archive_file = open_verified_file(
        archive, expected_sha256, "Yarn package archive"
    )
    try:
        archive_digest = hashlib.sha512()
        for chunk in iter(lambda: archive_file.read(1024 * 1024), b""):
            archive_digest.update(chunk)
    finally:
        archive_file.close()
    try:
        raw_bin = package["bin"]
        normalized_bin = {
            name: target[2:] if target.startswith("./") else target
            for name, target in raw_bin.items()
        }
    except (AttributeError, KeyError, TypeError) as error:
        fail(f"Yarn package metadata has an invalid bin map: {error}")
    expected: dict[str, Any] = {
        "version": package.get("version"),
        "resolved": url,
        "integrity": "sha512-"
        + base64.b64encode(archive_digest.digest()).decode("ascii"),
        "hasInstallScript": any(
            name in package.get("scripts", {})
            for name in ("preinstall", "install", "postinstall")
        ),
        "license": package.get("license"),
        "bin": normalized_bin,
        "engines": package.get("engines"),
    }
    return expected


def verify_yarn_overlay(
    extracted_package: Path,
    archive: Path,
    node_root: Path,
    expected_version: str,
    expected_url: str,
    expected_sha256: str,
) -> None:
    node_modules = node_root / "node_modules"
    launchers = node_modules / ".bin"
    installed_package = node_modules / "yarn"
    require_mode(node_modules, 0o755, "Yarn node_modules directory", True)
    require_mode(launchers, 0o755, "Yarn launcher directory", True)
    require_exact_children(
        node_modules, {".bin", ".package-lock.json", "yarn"}, "Yarn node_modules"
    )
    require_exact_children(launchers, {"yarn", "yarnpkg"}, "Yarn launcher directory")

    expected_target = "../yarn/bin/yarn.js"
    for launcher_name in ("yarn", "yarnpkg"):
        launcher = launchers / launcher_name
        try:
            status = launcher.lstat()
        except FileNotFoundError:
            fail(f"Yarn launcher is missing: {launcher}")
        if not stat.S_ISLNK(status.st_mode):
            fail(f"Yarn launcher is not a symbolic link: {launcher}")
        target = os.readlink(launcher)
        if target != expected_target:
            fail(
                f"Yarn launcher target is {target!r}, expected {expected_target!r}: "
                f"{launcher}"
            )

    compare_trees(extracted_package, installed_package)
    package = load_json(extracted_package / "package.json", "Yarn archive package.json")
    if not isinstance(package, dict) or package.get("name") != "yarn":
        fail("Yarn archive package.json does not identify the yarn package")
    if package.get("version") != expected_version:
        fail("Yarn archive package.json version differs from the pinned version")

    root_package_path = node_root / "package.json"
    root_lock_path = node_root / "package-lock.json"
    module_lock_path = node_modules / ".package-lock.json"
    require_mode(root_package_path, 0o644, "Yarn root package.json", False)
    require_mode(root_lock_path, 0o644, "Yarn root package lock", False)
    require_mode(module_lock_path, 0o644, "Yarn module package lock", False)
    root_package = load_json(root_package_path, "Yarn root package.json")
    root_lock = load_json(root_lock_path, "Yarn root package lock")
    module_lock = load_json(module_lock_path, "Yarn module package lock")
    dependency = {"dependencies": {"yarn": expected_version}}
    if not json_equal(root_package, dependency):
        fail("Yarn root package.json differs from the pinned overlay metadata")

    lock_entry = package_lock_entry(
        package, expected_url, archive, expected_sha256
    )
    lock_name = node_root.name
    expected_root_lock = {
        "name": lock_name,
        "lockfileVersion": 3,
        "requires": True,
        "packages": {
            "": dependency,
            "node_modules/yarn": lock_entry,
        },
    }
    expected_module_lock = {
        "name": lock_name,
        "lockfileVersion": 3,
        "requires": True,
        "packages": {"node_modules/yarn": lock_entry},
    }
    if not json_equal(root_lock, expected_root_lock):
        fail("Yarn root package-lock.json differs from the pinned overlay metadata")
    if not json_equal(module_lock, expected_module_lock):
        fail("Yarn node_modules package lock differs from the pinned overlay metadata")


def write_json_exclusive(path: Path, value: Any) -> None:
    descriptor = os.open(
        path,
        os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0),
        0o600,
    )
    with os.fdopen(descriptor, "w", encoding="utf-8") as output:
        json.dump(value, output, indent=2)
        output.write("\n")
    os.chmod(path, 0o644, follow_symlinks=False)


def stage_yarn_overlay(
    archive: Path,
    archive_root: str,
    expected_sha256: str,
    node_root: Path,
    expected_version: str,
    expected_url: str,
    scratch_parent: Path,
) -> None:
    real_directory(node_root, "Node staging root")
    reserved = (
        node_root / "package.json",
        node_root / "package-lock.json",
        node_root / "node_modules",
    )
    for path in reserved:
        try:
            path.lstat()
        except FileNotFoundError:
            continue
        fail(f"Yarn overlay destination is not empty: {path}")

    temporary, extracted_package = with_reference_tree(
        archive, archive_root, expected_sha256, scratch_parent
    )
    try:
        package = load_json(extracted_package / "package.json", "Yarn archive package.json")
        if not isinstance(package, dict) or package.get("name") != "yarn":
            fail("Yarn archive package.json does not identify the yarn package")
        if package.get("version") != expected_version:
            fail("Yarn archive package.json version differs from the pinned version")

        node_modules = node_root / "node_modules"
        launchers = node_modules / ".bin"
        node_modules.mkdir(mode=0o755)
        os.chmod(node_modules, 0o755)
        launchers.mkdir(mode=0o755)
        os.chmod(launchers, 0o755)
        installed_package = node_modules / "yarn"
        os.rename(extracted_package, installed_package)
        os.symlink("../yarn/bin/yarn.js", launchers / "yarn")
        os.symlink("../yarn/bin/yarn.js", launchers / "yarnpkg")

        dependency = {"dependencies": {"yarn": expected_version}}
        lock_entry = package_lock_entry(
            package, expected_url, archive, expected_sha256
        )
        lock_name = node_root.name
        root_lock = {
            "name": lock_name,
            "lockfileVersion": 3,
            "requires": True,
            "packages": {
                "": dependency,
                "node_modules/yarn": lock_entry,
            },
        }
        module_lock = {
            "name": lock_name,
            "lockfileVersion": 3,
            "requires": True,
            "packages": {"node_modules/yarn": lock_entry},
        }
        write_json_exclusive(node_root / "package.json", dependency)
        write_json_exclusive(node_root / "package-lock.json", root_lock)
        write_json_exclusive(node_modules / ".package-lock.json", module_lock)
    finally:
        shutil.rmtree(temporary)


def with_reference_tree(
    archive: Path, expected_root: str, expected_sha256: str, scratch_parent: Path
) -> tuple[Path, Path]:
    real_directory(scratch_parent, "toolchain verification scratch directory")
    temporary = Path(
        tempfile.mkdtemp(prefix=".host-toolchain-verify.", dir=scratch_parent)
    )
    try:
        reference = safe_extract(
            archive, expected_root, expected_sha256, temporary
        )
    except Exception:
        shutil.rmtree(temporary)
        raise
    return temporary, reference


def with_reference_zip_tree(
    archive: Path, expected_root: str, expected_sha256: str, scratch_parent: Path
) -> tuple[Path, Path]:
    real_directory(scratch_parent, "toolchain verification scratch directory")
    temporary = Path(
        tempfile.mkdtemp(prefix=".host-toolchain-verify.", dir=scratch_parent)
    )
    try:
        reference = safe_extract_zip(
            archive, expected_root, expected_sha256, temporary
        )
    except Exception:
        shutil.rmtree(temporary)
        raise
    return temporary, reference


def command_extract(arguments: argparse.Namespace) -> None:
    safe_extract(
        Path(arguments.archive),
        arguments.root,
        arguments.sha256,
        Path(arguments.destination),
    )


def command_extract_zip(arguments: argparse.Namespace) -> None:
    safe_extract_zip(
        Path(arguments.archive),
        arguments.root,
        arguments.sha256,
        Path(arguments.destination),
    )


def command_validate_archive(arguments: argparse.Namespace) -> None:
    opened, archive_file, _members = validated_members(
        Path(arguments.archive), arguments.root, arguments.sha256
    )
    opened.close()
    archive_file.close()


def command_verify_node(arguments: argparse.Namespace) -> None:
    temporary, reference = with_reference_tree(
        Path(arguments.archive),
        arguments.root,
        arguments.sha256,
        Path(arguments.scratch_parent),
    )
    try:
        compare_trees(
            reference,
            Path(arguments.installed),
            ("package.json", "package-lock.json", "node_modules"),
        )
    finally:
        shutil.rmtree(temporary)


def command_verify_yarn(arguments: argparse.Namespace) -> None:
    archive = Path(arguments.archive)
    temporary, reference = with_reference_tree(
        archive,
        arguments.root,
        arguments.sha256,
        Path(arguments.scratch_parent),
    )
    try:
        verify_yarn_overlay(
            reference,
            archive,
            Path(arguments.node_root),
            arguments.version,
            arguments.url,
            arguments.sha256,
        )
    finally:
        shutil.rmtree(temporary)


def command_stage_yarn(arguments: argparse.Namespace) -> None:
    stage_yarn_overlay(
        Path(arguments.archive),
        arguments.root,
        arguments.sha256,
        Path(arguments.node_root),
        arguments.version,
        arguments.url,
        Path(arguments.scratch_parent),
    )


def command_verify_file(arguments: argparse.Namespace) -> None:
    path = Path(arguments.path)
    verified = open_verified_file(path, arguments.sha256, arguments.label)
    verified.close()


def command_verify_zip_tree(arguments: argparse.Namespace) -> None:
    temporary, reference = with_reference_zip_tree(
        Path(arguments.archive),
        arguments.root,
        arguments.sha256,
        Path(arguments.scratch_parent),
    )
    try:
        compare_trees(reference, Path(arguments.installed))
    finally:
        shutil.rmtree(temporary)


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser()
    commands = result.add_subparsers(dest="command", required=True)

    extract = commands.add_parser("extract")
    extract.add_argument("--archive", required=True)
    extract.add_argument("--root", required=True)
    extract.add_argument("--sha256", required=True)
    extract.add_argument("--destination", required=True)
    extract.set_defaults(handler=command_extract)

    extract_zip = commands.add_parser("extract-zip")
    extract_zip.add_argument("--archive", required=True)
    extract_zip.add_argument("--root", required=True)
    extract_zip.add_argument("--sha256", required=True)
    extract_zip.add_argument("--destination", required=True)
    extract_zip.set_defaults(handler=command_extract_zip)

    validate_archive = commands.add_parser("validate-archive")
    validate_archive.add_argument("--archive", required=True)
    validate_archive.add_argument("--root", required=True)
    validate_archive.add_argument("--sha256", required=True)
    validate_archive.set_defaults(handler=command_validate_archive)

    verify_node = commands.add_parser("verify-node")
    verify_node.add_argument("--archive", required=True)
    verify_node.add_argument("--root", required=True)
    verify_node.add_argument("--sha256", required=True)
    verify_node.add_argument("--installed", required=True)
    verify_node.add_argument("--scratch-parent", required=True)
    verify_node.set_defaults(handler=command_verify_node)

    verify_yarn = commands.add_parser("verify-yarn")
    verify_yarn.add_argument("--archive", required=True)
    verify_yarn.add_argument("--root", required=True)
    verify_yarn.add_argument("--sha256", required=True)
    verify_yarn.add_argument("--node-root", required=True)
    verify_yarn.add_argument("--scratch-parent", required=True)
    verify_yarn.add_argument("--version", required=True)
    verify_yarn.add_argument("--url", required=True)
    verify_yarn.set_defaults(handler=command_verify_yarn)

    stage_yarn = commands.add_parser("stage-yarn")
    stage_yarn.add_argument("--archive", required=True)
    stage_yarn.add_argument("--root", required=True)
    stage_yarn.add_argument("--sha256", required=True)
    stage_yarn.add_argument("--node-root", required=True)
    stage_yarn.add_argument("--scratch-parent", required=True)
    stage_yarn.add_argument("--version", required=True)
    stage_yarn.add_argument("--url", required=True)
    stage_yarn.set_defaults(handler=command_stage_yarn)

    verify_file = commands.add_parser("verify-file")
    verify_file.add_argument("--path", required=True)
    verify_file.add_argument("--sha256", required=True)
    verify_file.add_argument("--label", required=True)
    verify_file.set_defaults(handler=command_verify_file)

    verify_zip_tree = commands.add_parser("verify-zip-tree")
    verify_zip_tree.add_argument("--archive", required=True)
    verify_zip_tree.add_argument("--root", required=True)
    verify_zip_tree.add_argument("--sha256", required=True)
    verify_zip_tree.add_argument("--installed", required=True)
    verify_zip_tree.add_argument("--scratch-parent", required=True)
    verify_zip_tree.set_defaults(handler=command_verify_zip_tree)
    return result


def main() -> int:
    try:
        arguments = parser().parse_args()
        arguments.handler(arguments)
    except VerificationError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    except (OSError, tarfile.TarError, zipfile.BadZipFile) as error:
        print(f"error: host-toolchain verification failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
