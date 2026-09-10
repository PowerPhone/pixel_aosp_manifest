#!/usr/bin/env python3
"""Repack the baseline VKB with only EP6's ALSA playback rate-mask widened."""
import argparse
import json
import pathlib
import shlex
import struct
import subprocess

ROOT = pathlib.Path(__file__).resolve().parents[2]
DEFAULT_OUT = ROOT / "work/audio-research/frankel/stock-kernel-reference-20260905/ep6-rate-only"
MODULE = "lib/modules/aoc_alsa_dev_util.ko"
BEFORE = bytes.fromhex("fe000000")
AFTER = bytes.fromhex("fe1f0000")


def module_range(cpio):
    position = 0
    matches = []
    while position + 110 <= len(cpio):
        header = cpio[position:position + 110]
        if header[:6] != b"070701":
            raise SystemExit("Expected newc archive")
        size = int(header[54:62], 16)
        name_size = int(header[94:102], 16)
        name = bytes(cpio[position + 110:position + 110 + name_size - 1]).decode()
        start = (position + 110 + name_size + 3) & ~3
        if name.removeprefix("./") == MODULE:
            matches.append((start, size))
        if name == "TRAILER!!!":
            break
        position = (start + size + 3) & ~3
    if len(matches) != 1:
        raise SystemExit("Expected exactly one AoC ALSA module in ramdisk")
    return matches[0]


def rate_offset(module):
    if module[:6] != b"\x7fELF\x02\x01" or struct.unpack_from("<H", module, 18)[0] != 183:
        raise SystemExit("Expected little-endian AArch64 ELF64 module")
    section_offset = struct.unpack_from("<Q", module, 40)[0]
    entry_size, count = struct.unpack_from("<HH", module, 58)
    sections = [struct.unpack_from("<IIQQQQIIQQ", module, section_offset + i * entry_size)
                for i in range(count)]
    candidates = []
    for section in sections:
        if section[1] != 2:
            continue
        strings_section = sections[section[6]]
        strings = module[strings_section[4]:strings_section[4] + strings_section[5]]
        for offset in range(section[4], section[4] + section[5], section[9]):
            name, _, _, index, value, size = struct.unpack_from("<IBBHQQ", module, offset)
            symbol = strings[name:strings.find(b"\0", name)]
            if symbol == b"aoc_dai_drv":
                candidates.append((sections[index][4] + value, size))
    if len(candidates) != 1 or candidates[0][1] != 10752:
        raise SystemExit("Unexpected baseline aoc_dai_drv symbol/layout")
    base, _ = candidates[0]
    entry = base + 5 * 0xc0
    if struct.unpack_from("<I", module, entry + 8)[0] != 5:
        raise SystemExit("DAI entry is not EP6/id5")
    offset = entry + 0xa0
    if offset != 0x3f728 or module[offset:offset + 4] != BEFORE:
        raise SystemExit("Unexpected EP6 playback rate field")
    return offset


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base", type=pathlib.Path,
                        default=ROOT / "artifacts/frankel/device/vendor_kernel_boot.img")
    parser.add_argument("--output", type=pathlib.Path, default=DEFAULT_OUT)
    args = parser.parse_args()
    base = args.base.resolve()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    image = output / "vendor_kernel_boot.img"
    if image.exists():
        raise SystemExit(f"Refusing to overwrite {image}; use a fresh --output directory")
    host = ROOT / "work/aosp/out_pixel/frankel/host/linux-x86/bin"
    unpacked = output / "build-unpacked"
    result = subprocess.run([str(host / "unpack_bootimg"), "--boot_img", str(base),
                             "--out", str(unpacked), "--format", "mkbootimg"],
                            check=True, text=True, capture_output=True)
    arguments = shlex.split(result.stdout)
    fragments = [arguments[i + 1] for i, item in enumerate(arguments)
                 if item == "--vendor_ramdisk_fragment"]
    if len(fragments) != 1:
        raise SystemExit("Expected baseline with one vendor ramdisk fragment")
    fragment = pathlib.Path(fragments[0])
    original = subprocess.run(["lz4", "-dc", str(fragment)], check=True, capture_output=True).stdout
    start, size = module_range(original)
    module = original[start:start + size]
    offset = rate_offset(module)
    changed = bytearray(original)
    changed[start + offset:start + offset + 4] = AFTER
    (output / "aoc_alsa_dev_util.baseline.ko").write_bytes(module)
    (output / "aoc_alsa_dev_util.ep6-rate-only.ko").write_bytes(changed[start:start + size])
    subprocess.run(["lz4", "-q", "-f", "-l", "-12", "-", str(fragment)],
                   input=changed, check=True)
    subprocess.run([str(host / "mkbootimg"), *arguments,
                    "--vendor_boot", str(image)], check=True)
    raw_bytes = image.stat().st_size
    partition_bytes = base.stat().st_size
    if raw_bytes >= partition_bytes:
        raise SystemExit("Repacked image does not fit baseline partition size")
    with image.open("r+b") as stream:
        stream.truncate(partition_bytes)
    manifest = {
        "base": str(base.relative_to(ROOT)),
        "scope": "EP6 playback ALSA rate mask only; no new code or firmware changes",
        "module": MODULE, "symbol": "aoc_dai_drv", "dai_index": 5,
        "dai_id": 5, "dai_stride": "0xc0", "playback_rates_field": "0xa0",
        "module_file_offset": hex(offset), "before": BEFORE.hex(), "after": AFTER.hex(),
        "changed_module_bytes": 1,
        "archive_metadata_and_other_file_payloads": "preserved byte-for-byte",
        "dtb_bootconfig_and_boot_header_arguments": "reused from baseline unpack",
        "ramdisk_compression": "legacy lz4 -12", "raw_image_bytes": raw_bytes,
        "partition_image_bytes": partition_bytes,
        "avb": "unsigned raw vendor boot image, zero padded; no vbmeta output or changes",
        "requires": "existing unlocked bootloader and disabled AVB verification",
        "qualification": "not flashed or tested by this builder",
    }
    (output / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    (output / "mkbootimg-arguments.txt").write_text(result.stdout + "\n")
    objdump = ROOT / "work/aosp/prebuilts/clang/host/linux-x86/clang-r596125/bin/llvm-objdump"
    disassembly = subprocess.run([str(objdump), "-D", "--no-show-raw-insn", "--section=.text",
                                 "--start-address=0xcf44", "--stop-address=0xcfc8",
                                 str(output / "aoc_alsa_dev_util.baseline.ko")],
                                check=True, capture_output=True, text=True).stdout
    (output / "baseline-playback-rate-mapper.txt").write_text(disassembly)
    print(f"Built {image}; only module rate field {offset:#x}: {BEFORE.hex()} -> {AFTER.hex()}")


if __name__ == "__main__":
    main()
