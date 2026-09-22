#!/usr/bin/env python3
"""Stage a Frankel D5 RT-worker kernel ramdisk without changing its baseline.

Input is an already-extracted, pre-RT vendor-kernel ramdisk. The optional
--baseline-module supplies the prepared/sanitized AoC util module instead of
the ramdisk's copy. A fresh staging directory receives ramdisk-root/ for the
existing image packer and originals/ plus a JSON preparation report outside
that payload. No image is packed or flashed and no hashes are calculated.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import shutil

from patch_frankel_aoc_d5_rt_period_worker import helper_crcs, patch


UTIL = "aoc_alsa_dev_util.ko"
HELPER = "frankel_d5_period_rt.ko"


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ValueError(message)


def regular(path: Path) -> Path:
    require(path.is_file() and not path.is_symlink(),
            f"expected a regular non-symlink file: {path}")
    return path.resolve(strict=True)


def update_load(source: str) -> tuple[str, dict]:
    lines = source.splitlines(keepends=True)
    selected = []
    entries = []
    for index, line in enumerate(lines):
        item = line.split("#", 1)[0].strip()
        if not item:
            continue
        require(len(item.split()) == 1, f"unexpected modules.load entry: {line!r}")
        entries.append(item)
        require(Path(item).name != HELPER, "modules.load already contains the RT helper")
        if Path(item).name == UTIL:
            selected.append((index, item))
    require(len(selected) == 1, "modules.load must contain exactly one AoC util entry")
    index, util_path = selected[0]
    helper_path = str(Path(util_path).with_name(HELPER))
    lines.insert(index, helper_path + "\n")
    return "".join(lines), {
        "module_load_count_before": len(entries),
        "module_load_count_after": len(entries) + 1,
        "helper_load_entry": helper_path,
        "load_before": util_path,
    }


def update_dep(source: str) -> tuple[str, dict]:
    lines = source.splitlines(keepends=True)
    selected = []
    for index, line in enumerate(lines):
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        require(":" in line, f"unexpected modules.dep entry: {line!r}")
        key, value = line.split(":", 1)
        require(Path(key.strip()).name != HELPER and
                not any(Path(item).name == HELPER for item in value.split()),
                "modules.dep already references the RT helper")
        if Path(key.strip()).name == UTIL:
            selected.append((index, key.strip(), value.split()))
    require(len(selected) == 1, "modules.dep must define exactly one AoC util entry")
    index, util_path, dependencies = selected[0]
    helper_path = str(Path(util_path).with_name(HELPER))
    lines[index] = util_path + ": " + " ".join([helper_path, *dependencies]) + "\n"
    lines.insert(index, helper_path + ":\n")
    return "".join(lines), {
        "helper_dependency_entry": helper_path,
        "util_dependency_entry": util_path,
        "preserved_util_dependencies": dependencies,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("baseline_ramdisk", type=Path,
                        help="extracted pre-RT ramdisk containing lib/modules")
    parser.add_argument("staging_directory", type=Path,
                        help="new directory; must not exist")
    parser.add_argument("--helper", type=Path, required=True,
                        help="built frankel_d5_period_rt.ko")
    parser.add_argument("--symvers", type=Path, required=True,
                        help="Module.symvers from that helper build")
    parser.add_argument("--baseline-module", type=Path,
                        help="optional post-sanitization AoC util module override")
    args = parser.parse_args()
    try:
        require(args.baseline_ramdisk.is_dir() and not args.baseline_ramdisk.is_symlink(),
                "baseline ramdisk must be a real directory")
        baseline = args.baseline_ramdisk.resolve(strict=True)
        for relative in ("lib", "lib/modules"):
            path = baseline / relative
            require(path.is_dir() and not path.is_symlink(),
                    f"baseline directory must not be a symlink: {path}")
        module_directory = baseline / "lib/modules"
        ramdisk_util = regular(module_directory / UTIL)
        load_path = regular(module_directory / "modules.load")
        dep_path = regular(module_directory / "modules.dep")
        require(not (module_directory / HELPER).exists(),
                "baseline ramdisk already contains the RT helper; use a pre-RT baseline")
        util = regular(args.baseline_module) if args.baseline_module else ramdisk_util
        helper = regular(args.helper)
        versions = regular(args.symvers)
        require(helper.name == HELPER, f"helper filename must be {HELPER}")
        require(not args.staging_directory.exists() and not args.staging_directory.is_symlink(),
                "staging directory already exists; choose a fresh path")
        staging = args.staging_directory.resolve()
        require(not staging.is_relative_to(baseline),
                "staging directory must be outside the baseline ramdisk")

        # Resolve all guarded changes before creating the staging directory.
        changed, report = patch(util.read_bytes(), helper_crcs(versions))
        load_text, load_report = update_load(load_path.read_text())
        dep_text, dep_report = update_dep(dep_path.read_text())

        staging.mkdir(parents=True, exist_ok=False)
        payload = staging / "ramdisk-root"
        originals = staging / "originals"
        originals.mkdir()
        shutil.copy2(ramdisk_util, originals / UTIL)
        shutil.copy2(load_path, originals / "modules.load")
        shutil.copy2(dep_path, originals / "modules.dep")
        if util != ramdisk_util:
            shutil.copy2(util, originals / "prepared-aoc_alsa_dev_util.ko")
        shutil.copy2(versions, staging / "frankel_d5_period_rt.Module.symvers")
        # Preserve unrelated files and symlinks verbatim. Files changed below
        # were required to be regular files in non-symlink lib/modules parents.
        shutil.copytree(baseline, payload, symlinks=True)
        target_modules = payload / "lib/modules"
        (target_modules / UTIL).write_bytes(changed)
        shutil.copy2(helper, target_modules / HELPER)
        (target_modules / "modules.load").write_text(load_text)
        (target_modules / "modules.dep").write_text(dep_text)
        report.update(load_report)
        report.update(dep_report)
        report.update({
            "baseline_ramdisk": str(baseline),
            "baseline_module": str(util),
            "helper": str(helper),
            "symvers": str(versions),
            "prepared_ramdisk": str(payload),
            "preserved_originals": str(originals),
            "baseline_modified": False,
            "image_packed": False,
            "device_accessed": False,
        })
        (staging / "preparation.json").write_text(json.dumps(report, indent=2) + "\n")
        print(json.dumps(report, indent=2))
    except (OSError, ValueError, KeyError) as error:
        parser.exit(1, f"error: {error}\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
