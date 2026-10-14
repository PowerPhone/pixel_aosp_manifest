#!/usr/bin/env python3
"""Repack actual captured Cubs partitions, with a narrow recorded overlay.

No device operations, Soong, hash generation, or original-root mutations.
Invoked through build-primary-images.sh for ownership-preserving privileges.
"""

import argparse
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import stat
import subprocess
import time


REPO = Path(__file__).resolve().parents[3]
HAL = "android.hardware.audio.service-aidl.powerphone-cubs"
REMOVED = (
    "etc/init/android.hardware.audio.service-aidl.aoc.rc",
    "etc/vintf/manifest/android.hardware.audio.service-aidl.aoc.xml",
    "etc/vintf/manifest/bluetooth_audio.xml",
)


def fail(message):
    raise SystemExit(f"ERROR: {message}")


def existing(value):
    return Path(value).resolve(strict=True)


def run(command, log=None):
    print("+ " + shlex.join(map(str, command)), flush=True)
    if log is None:
        subprocess.run(list(map(str, command)), check=True)
    else:
        with log.open("w") as stream:
            subprocess.run(list(map(str, command)), check=True,
                           stdout=stream, stderr=subprocess.STDOUT)


def need_file(path):
    if not path.is_file():
        fail(f"missing input: {path}")


def properties(path):
    result = {}
    for line in path.read_text().splitlines():
        if line and not line.lstrip().startswith("#") and "=" in line:
            key, value = line.split("=", 1)
            result[key.strip()] = value.strip()
    return result


def metadata(path):
    """Only capabilities come from META; captured inodes own UID/GID/mode."""
    result = {}
    pattern = re.compile(r"^(.*?)\s+(\d+)\s+(\d+)\s+([0-7]+)\s+capabilities=(0x[0-9a-fA-F]+)(?:\s.*)?$")
    for line in path.read_text().splitlines():
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        match = pattern.fullmatch(line)
        if not match:
            fail(f"unrecognized filesystem metadata in {path}: {line}")
        name, uid, gid, mode, caps = match.groups()
        entry = (int(uid), int(gid), int(mode, 8), int(caps, 16))
        if name in result and result[name] != entry:
            fail(f"conflicting metadata for {name} in {path}")
        result[name] = entry
    return result


def entries(root):
    yield root
    for directory, dirs, files in os.walk(root, followlinks=False):
        dirs.sort()
        files.sort()
        for name in dirs + files:
            yield Path(directory) / name


def fs_config(root, partition, prior, output):
    lines = []
    for path in entries(root):
        rel = path.relative_to(root).as_posix()
        name = "" if rel == "." else f"{partition}/{rel}"
        if any(char.isspace() for char in name):
            fail(f"unsupported whitespace in Android fs_config path: {name!r}")
        inode = path.lstat()
        actual = (inode.st_uid, inode.st_gid, stat.S_IMODE(inode.st_mode))
        old = prior.get(name)
        capabilities = old[3] if old else 0
        if capabilities and actual != old[:3]:
            fail(f"nonzero capability metadata no longer matches captured inode: {name}")
        lines.append(f"{name} {actual[0]} {actual[1]} {actual[2]:o} capabilities=0x{capabilities:x}\n")
    output.write_text("".join(lines))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--live-root", required=True,
                        help="captured baseline/{vendor,system_ext}.img and extracted *-root directory")
    parser.add_argument("--product-out", required=True,
                        help="ONE completed target/product/cubs build supplying HAL, helper and ELF dependencies")
    parser.add_argument("--policy-dir", required=True,
                        help="compile-primary-policy.sh output directory containing COMPLETE")
    parser.add_argument("--output-dir", required=True, help="NEW directory under repo/work/audio-research/cubs")
    parser.add_argument("--host-bin", default=REPO / "work/aosp/out_pixel/cubs/host/linux-x86/bin")
    parser.add_argument("--config-dir", default=REPO / "config/targets/cubs/powerphone")
    parser.add_argument("--metadata-dir", default=REPO / "work/aosp/out_pixel/cubs/target/product/cubs/obj/PACKAGING/target_files_intermediates/cubs-target_files/META",
                        help="META directory; only capability bits are reused, never old ownership/modes")
    parser.add_argument("--allow-frankel-build-output", action="store_true",
                        help="explicit transitional cross-build permission; still requires Cubs-role HAL/helper")
    parser.add_argument("--workers", type=int, default=8)
    parser.add_argument("--max-vendor-bytes", type=int,
                        help="explicit authorized payload ceiling; default is captured vendor image bytes")
    parser.add_argument("--max-system-ext-bytes", type=int,
                        help="explicit authorized payload ceiling; default is captured system_ext image bytes")
    args = parser.parse_args()
    if os.geteuid() != 0:
        fail("run through build-primary-images.sh; ownership preservation requires sudo")
    live, product, policy = map(existing, (args.live_root, args.product_out, args.policy_dir))
    host, config, meta = map(existing, (args.host_bin, args.config_dir, args.metadata_dir))
    output = Path(args.output_dir).resolve()
    work = (REPO / "work/audio-research/cubs").resolve()
    if output.exists() or output == work or not output.is_relative_to(work):
        fail("output must be a NEW descendant of repo/work/audio-research/cubs")
    for source in (live, product, policy, config, meta):
        if output.is_relative_to(source) or source.is_relative_to(output):
            # Sibling output inside the integration root is intentional, but
            # never put it inside the extracted roots or any other input tree.
            if source != live or output in (live / "vendor-root", live / "system_ext-root"):
                fail(f"output overlaps an input tree: {source}")
    for part in ("vendor", "system_ext"):
        if output.is_relative_to(live / f"{part}-root"):
            fail("output cannot be inside a captured partition root")
    allowed = {"cubs"}
    if args.allow_frankel_build_output:
        allowed.add("frankel")
    if product.name not in allowed or product.parent.name != "product" or product.parent.parent.name != "target":
        fail("product-out must be target/product/cubs (or explicitly permitted Frankel cross-build)")
    if not 1 <= args.workers <= 64:
        fail("workers must be 1..64")
    if properties(live / "vendor-root/build.prop").get("ro.product.vendor.device") != "cubs":
        fail("captured vendor is not Cubs")
    need_file(policy / "COMPLETE")
    policy_files = policy / "vendor/etc/selinux"
    for name in ("precompiled_sepolicy", "vendor_sepolicy.cil", "vendor_file_contexts", "vendor_property_contexts"):
        need_file(policy_files / name)
    if "(type cubs_powerphone_boot)" not in (policy_files / "vendor_sepolicy.cil").read_text():
        fail("policy overlay lacks Cubs primary types")
    sources = {
        f"vendor/bin/hw/{HAL}": product / f"vendor/bin/hw/{HAL}",
        "vendor/bin/cubs_powerphone_boot": product / "vendor/bin/cubs_powerphone_boot",
        "vendor/etc/init/cubs_powerphone_services.rc": config / "cubs_powerphone_services.rc",
        "vendor/etc/powerphone-cubs-bluetooth-research.prop": config / "bluetooth-research.prop",
        "vendor/etc/vintf/manifest/cubs_powerphone.xml": config / "cubs_powerphone.xml",
        "system_ext/etc/init/cubs_powerphone_platform_gate.rc": config / "cubs_powerphone_platform_gate.rc",
    }
    for source in sources.values():
        need_file(source)
    readelf = shutil.which("readelf")
    if not readelf:
        fail("host binutils readelf is required")
    for tool in ("mkfs.erofs", "sefcontext_compile"):
        if not os.access(host / tool, os.X_OK):
            fail(f"missing executable Android host tool: {host / tool}")
    old_metadata = {}
    for part in ("vendor", "system_ext"):
        need_file(live / f"baseline/{part}.img")
        need_file(meta / f"{part}_filesystem_config.txt")
        old_metadata[part] = metadata(meta / f"{part}_filesystem_config.txt")
        for name in REMOVED if part == "vendor" else ():
            need_file(live / "vendor-root" / name)

    # Resolve before staging. Cross-partition platform/APEX libraries are
    # requirements of the retained OS, never copied into the vendor namespace.
    dependencies, examined = [], set()
    queue = [(name, source) for name, source in sources.items() if "/bin/" in name]
    while queue:
        installed, source = queue.pop(0)
        if installed in examined:
            continue
        examined.add(installed)
        elf_header = subprocess.check_output([readelf, "-h", str(source)], text=True)
        if "AArch64" not in elf_header or "ELF64" not in elf_header:
            fail(f"not an arm64 Android ELF: {source}")
        dynamic = subprocess.check_output([readelf, "-d", str(source)], text=True)
        for name in re.findall(r"\(NEEDED\).*?\[([^]]+)\]", dynamic):
            if "/" in name:
                fail(f"unexpected path-valued NEEDED entry: {name}")
            candidates = [product / p / name for p in
                          ("vendor/lib64", "vendor/lib64/hw", "system_ext/lib64", "system/lib64", "product/lib64")]
            candidate = next((item for item in candidates if item.is_file()), None)
            if candidate is None:
                apex = sorted((product / "apex").glob(f"*/lib64/bionic/{name}"))
                apex += sorted((product / "apex").glob(f"*/lib64/{name}"))
                candidate = next((item for item in apex if item.is_file()), None)
            if candidate is None:
                fail(f"dependency not found in the same compiled product output: {installed} -> {name}")
            relative = candidate.relative_to(product).as_posix()
            copied = relative.startswith(("vendor/", "system_ext/"))
            dependencies.append({"consumer": installed, "needed": name,
                                 "source": str(candidate), "destination": relative,
                                 "action": "copy-and-traverse" if copied else "retained-platform-or-apex-prerequisite"})
            if copied:
                sources[relative] = candidate
                queue.append((relative, candidate))

    output.mkdir(parents=True, exist_ok=False)
    stage = output / "staging"
    stage.mkdir()
    removals = output / "removed-from-image"
    removals.mkdir()
    source_snapshot = output / "owned-source-snapshot"
    source_snapshot.mkdir()
    (output / "dependency-closure.json").write_text(json.dumps(dependencies, indent=2) + "\n")
    (output / "inputs.json").write_text(json.dumps({
        "live_root": str(live), "product_out": str(product), "policy_dir": str(policy),
        "config_dir": str(config), "metadata_dir": str(meta), "host_bin": str(host),
        "cross_build": product.name != "cubs", "baseline_unchanged": True,
        "verification": "Packaging only; not flashed or hardware-qualified; no hashes calculated."
    }, indent=2) + "\n")
    for part in ("vendor", "system_ext"):
        run(["cp", "-a", "--reflink=auto", "--no-preserve=xattr", live / f"{part}-root", stage / part])
    for name in REMOVED:
        destination = removals / "vendor" / name
        destination.parent.mkdir(parents=True, exist_ok=True)
        (stage / "vendor" / name).rename(destination)

    def install(source, relative, mode=0o644, gid=0):
        destination = stage / relative
        if destination.is_symlink() or not destination.parent.resolve().is_relative_to(stage.resolve()):
            fail(f"refusing overlay through a partition symlink: {relative}")
        if not destination.parent.is_dir():
            fail(f"expected baseline parent is missing: {destination.parent}")
        # install breaks a destination hard link instead of mutating an alias.
        # This WSL host's install rejects numeric groups absent from its NSS
        # database. chown(2) accepts Android IDs without inventing host groups.
        run(["install", "-m", f"{mode:o}", source, destination])
        os.chown(destination, 0, gid)

    for relative, source in sorted(sources.items()):
        binary = "/bin/" in relative
        install(source, relative, 0o755 if binary else 0o644, 2000 if binary else 0)
        if source.is_relative_to(config):
            shutil.copy2(source, source_snapshot / source.name)
    for source in sorted(policy_files.iterdir()):
        if not source.is_file() or source.is_symlink():
            fail(f"unexpected entry in completed policy overlay: {source}")
        install(source, f"vendor/etc/selinux/{source.name}")
    prop_file = stage / "vendor/build.prop"
    prop_lines = prop_file.read_text().splitlines()
    prop_lines = [line for line in prop_lines if not re.match(r"^\s*ro\.audio\.flinger_standbytime_ms\s*=", line)]
    prop_lines += ["", "# Cubs PowerPhone research-primary ownership release.", "ro.audio.flinger_standbytime_ms=0"]
    prop_file.write_text("\n".join(prop_lines) + "\n")

    context_inputs = [live / "live-policy/system/plat_file_contexts",
                      live / "live-policy/product/product_file_contexts",
                      stage / "system_ext/etc/selinux/system_ext_file_contexts",
                      stage / "vendor/etc/selinux/vendor_file_contexts"]
    odm_context = stage / "vendor/odm/etc/selinux/odm_file_contexts"
    if odm_context.is_file():
        context_inputs.append(odm_context)
    contexts, seen = [], set()
    for source in context_inputs:
        need_file(source)
        contexts.append(f"\n# Captured/compiled input: {source}\n")
        for line in source.read_text().splitlines():
            normalized = " ".join(line.split())
            if normalized and not normalized.startswith("#"):
                if normalized in seen:
                    continue
                seen.add(normalized)
            contexts.append(line + "\n")
    context_file = output / "combined_file_contexts"
    context_file.write_text("".join(contexts))
    run([host / "sefcontext_compile", "-o", output / "combined_file_contexts.bin", context_file], output / "contexts-compile.log")
    image_records = []
    for part in ("vendor", "system_ext"):
        fs_file = output / f"{part}_filesystem_config.txt"
        fs_config(stage / part, part, old_metadata[part], fs_file)
        image = output / f"{part}.img"
        command = [host / "mkfs.erofs", "-b4096", "-z", "lz4hc", "-C65536",
                   f"-T{int(time.time())}", "--mkfs-time", "--preserve-mtime",
                   # Android erofs-utils 1.8.3 checks stale errno when parsing
                   # --workers. This no-op option clears it in the real parser.
                   "--uid-offset=0", f"--workers={args.workers}", f"--mount-point={part}",
                   f"--fs-config-file={fs_file}", f"--file-contexts={context_file}",
                   f"--product-out={product}", image, stage / part]
        (output / f"{part}-mkfs-command.txt").write_text(shlex.join(map(str, command)) + "\n")
        run(command, output / f"{part}-mkfs.log")
        baseline_size = (live / f"baseline/{part}.img").stat().st_size
        image_size = image.stat().st_size
        ceiling = getattr(args, f"max_{part}_bytes") or baseline_size
        if not 0 < image_size <= ceiling:
            fail(f"{part} EROFS payload size {image_size} exceeds explicit/default ceiling {ceiling}")
        image_records.append({"partition": part, "image": str(image), "bytes": image_size,
                              "captured_image_bytes": baseline_size, "payload_ceiling_bytes": ceiling,
                              "logical_partition_growth_required": image_size > baseline_size,
                              "avb_footer_added": False})
    (output / "images.json").write_text(json.dumps(image_records, indent=2) + "\n")
    (output / "COMPLETE").write_text(
        "Built actual raw EROFS vendor/system_ext payloads from preserved live roots.\n"
        "SELinux labels regenerated from live contexts plus the compiled owned additions.\n"
        "Removed RC/VINTF files are recoverable in removed-from-image/.\n"
        "No AVB footer added. Flash authorization, AVB handling and hardware qualification remain external.\n")
    (output / "HARDWARE_QUALIFICATION_PENDING").write_text(
        "Hardware candidate only. COMPLETE describes image construction, not API or acoustic success.\n"
        "The parent operator must record actual fresh-boot/API/acoustic results separately.\n")
    # Leave staging inodes root-owned exactly as packed. Make only reports and
    # final payloads convenient for the invoking non-root workspace owner.
    uid, gid = int(os.environ.get("SUDO_UID", 0)), int(os.environ.get("SUDO_GID", 0))
    os.chown(output, uid, gid)
    for path in output.iterdir():
        if path.is_file():
            os.chown(path, uid, gid)
    print(f"Cubs image payloads ready (not flashed): {output}", flush=True)


if __name__ == "__main__":
    main()
