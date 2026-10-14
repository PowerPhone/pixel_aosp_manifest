#!/usr/bin/env python3
"""Assemble a separate Cubs research OS bundle; never build, flash or hash."""

import argparse
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
from datetime import datetime, timezone


REPO = Path(__file__).resolve().parents[3]
PHYSICAL = ("boot", "init_boot", "dtbo", "vendor_boot", "vendor_kernel_boot",
            "vbmeta_system", "vbmeta_vendor", "vbmeta")
LOGICAL = ("system", "system_dlkm", "product", "vendor_dlkm", "system_ext", "vendor")
KIND = "cubs-powerphone-captured-v1"


def fail(message):
    raise SystemExit("ERROR: " + message)


def regular(value):
    path = Path(value).absolute()
    if path.is_symlink() or not path.is_file() or path.stat().st_size == 0:
        fail(f"missing, empty or symlink input: {path}")
    return path.resolve()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--boot-dir", required=True, help="captured boot_a.img etc.; not artifacts/cubs")
    parser.add_argument("--source-slot", choices=("a", "b"), default="a")
    parser.add_argument("--baseline-dir", required=True, help="captured six logical partition images")
    parser.add_argument("--baseline-properties", required=True, help="captured getprop output identifying this baseline")
    parser.add_argument("--vendor-kernel-boot", required=True, help="selected custom-kernel admission image")
    parser.add_argument("--primary-images", required=True, help="explicit completed build-primary-images output (e.g. images-v5)")
    parser.add_argument("--output-dir", required=True, help="NEW artifacts/cubs-powerphone-* or work/audio-research/cubs descendant")
    parser.add_argument("--platform-tools", default=REPO / "work/toolchains/platform-tools-37.0.1/platform-tools")
    parser.add_argument("--assemble", action="store_true", help="copy the planned images; default only prints the local plan")
    args = parser.parse_args()
    output = Path(args.output_dir).resolve()
    artifacts = (REPO / "artifacts").resolve()
    research = (REPO / "work/audio-research/cubs").resolve()
    if not ((output.parent == artifacts and output.name.startswith("cubs-powerphone-") and
             output.name != "cubs-powerphone-") or
            (output != research and output.is_relative_to(research))):
        fail("output must be a new artifacts/cubs-powerphone-* or work/audio-research/cubs descendant")
    if output.exists():
        fail(f"never overwrite an existing output: {output}")
    boot, baseline, primary = (Path(value).resolve(strict=True) for value in
                               (args.boot_dir, args.baseline_dir, args.primary_images))
    for source in (boot, baseline, primary):
        if output.is_relative_to(source) or source.is_relative_to(output):
            fail(f"output overlaps an input directory: {source}")
    identity = regular(args.baseline_properties)
    values = dict(re.findall(r"^\[([^\]]+)\]: \[([^\]]*)\]$", identity.read_text(), re.MULTILINE))
    if values.get("ro.product.device") != "cubs":
        fail("captured properties do not identify Cubs")
    requirements = {
        "product": "cubs",
        "bootloader": values.get("ro.bootloader", ""),
        "baseband": values.get("ro.build.expect.baseband", ""),
    }
    if any(not re.fullmatch(r"[A-Za-z0-9_.:-]+", value) for value in requirements.values()):
        fail("captured product/bootloader/baseband identity is missing or malformed")
    regular(primary / "COMPLETE")
    inputs_report = regular(primary / "inputs.json")
    images_report = regular(primary / "images.json")
    tools = Path(args.platform_tools).resolve(strict=True)
    for tool in ("adb", "fastboot"):
        if not os.access(tools / tool, os.X_OK):
            fail(f"missing platform-tools executable: {tools / tool}")
    sources = {name: regular(boot / f"{name}_{args.source_slot}.img")
               for name in PHYSICAL if name != "vendor_kernel_boot"}
    sources["vendor_kernel_boot"] = regular(args.vendor_kernel_boot)
    for name in LOGICAL:
        sources[name] = regular((primary if name in ("vendor", "system_ext") else baseline) / f"{name}.img")
    runner = regular(REPO / "scripts/audio/cubs/flash-powerphone.sh")
    runbook = regular(REPO / "scripts/audio/cubs/POWERPHONE_BUNDLE.md")
    records = [{"partition": name, "mode": "bootloader" if name in PHYSICAL else "fastbootd",
                "source": str(sources[name]), "bytes": sources[name].stat().st_size,
                "source_mtime_ns": sources[name].stat().st_mtime_ns}
               for name in PHYSICAL + LOGICAL]
    plan = {"kind": KIND, "created_utc": datetime.now(timezone.utc).isoformat(),
            "baseline_fingerprint": values.get("ro.build.fingerprint", ""),
            "baseline_source_slot": args.source_slot, "output": str(output),
            "firmware_prerequisites": requirements, "images": records,
            "primary_image_inputs": json.loads(inputs_report.read_text()),
            "primary_image_records": json.loads(images_report.read_text()),
            "qualification": "NOT QUALIFIED BY ASSEMBLY; exact packaged-image hardware evidence is separate",
            "scope": "14 current-slot OS partitions only; retain existing bootloader/radio/pvmfw; no slot switch",
            "hashes": "not generated or checked"}
    print(json.dumps(plan, indent=2), flush=True)
    if not args.assemble:
        print("PLAN ONLY: no output directory, image copies or device operations. Add --assemble to copy.")
        return
    output.parent.mkdir(parents=True, exist_ok=True)
    stage = Path(tempfile.mkdtemp(prefix=output.name + ".assembling-", dir=output.parent))
    try:
        for record in records:
            source = sources[record["partition"]]
            before = source.stat()
            destination = stage / f"{record['partition']}.img"
            # Never hard-link source images: later source edits must not mutate a bundle.
            subprocess.run(["cp", "--reflink=auto", "--sparse=always", "--", str(source), str(destination)], check=True)
            after = source.stat()
            if (before.st_size, before.st_mtime_ns, before.st_ino) != (after.st_size, after.st_mtime_ns, after.st_ino):
                fail(f"source changed while copying: {source}")
            if destination.stat().st_size != record["bytes"]:
                fail(f"incomplete copy: {destination}")
        shutil.copy2(runner, stage / "flash-all.sh")
        (stage / "flash-all.sh").chmod(0o755)
        shutil.copy2(runbook, stage / "README.md")
        shutil.copy2(identity, stage / "baseline-properties.txt")
        (stage / "bundle-kind").write_text(KIND + "\n")
        (stage / "BUNDLE_INFO.json").write_text(json.dumps(plan, indent=2) + "\n")
        (stage / "firmware-requirements.txt").write_text("".join(f"{key}={value}\n" for key, value in requirements.items()))
        (stage / "image-sizes.tsv").write_text("".join(f"{item['partition']}\t{item['bytes']}\n" for item in records))
        (stage / "host-platform-tools-path.txt").write_text(str(tools) + "\n")
        (stage / "HARDWARE_QUALIFICATION_PENDING").write_text(
            "Assembly copied this closure; it did not establish boot, API, acoustic or lifecycle success.\n"
            "Retain actual full-bundle flash/reboot results separately before calling this a tested release.\n")
        (stage / "COMPLETE").write_text("Complete local image copy; not hardware qualification.\n")
        # Same-filesystem publication; never merge with or overwrite a prior bundle.
        if output.exists():
            fail(f"output appeared during assembly: {output}")
        stage.rename(output)
    except BaseException:
        print(f"Incomplete assembly retained for inspection: {stage}", flush=True)
        raise
    print(f"ASSEMBLED (not flashed or qualified): {output}")


if __name__ == "__main__":
    main()
