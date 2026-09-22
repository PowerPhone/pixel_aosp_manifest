#!/usr/bin/env python3
"""Extract this Frankel superbin's code regions for offline audio analysis only.

No container modification, signing, loading, or device access is performed.
The DSP external-memory alias is inferred from the matching speaker vtable
targets and instruction bytes, not a general mapping for other AoC versions.
"""

import argparse
import json
from pathlib import Path
import struct
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("firmware", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--objcopy", required=True, type=Path)
    args = parser.parse_args()
    data = args.firmware.read_bytes()
    header = 0x1000
    if struct.unpack_from("<I", data, header)[0] != 0xAABBCCDD:
        raise ValueError("not the expected Frankel superbin header")
    table, stride, count = struct.unpack_from("<III", data, header + 0x70)
    if (stride, count) != (40, 27):
        raise ValueError("unreviewed superbin section layout")
    rows = [struct.unpack_from("<10I", data, header + table + stride * i)
            for i in range(count)]
    if any(row[0] != 0xBEEFBEEF for row in rows):
        raise ValueError("invalid section marker")
    if rows[0][6] != 0x9800D000 or rows[0][4:6] != (0xD000, 0xA61DC0):
        raise ValueError("unreviewed external-memory layout")
    if rows[1][4:6] != (0xA6EDC0, 0xA00000):
        raise ValueError("unreviewed shared-memory layout")
    # Real speaker destructor and Initialize entries in the external region.
    for address in (0x78973200, 0x789732F0, 0x78973354):
        offset = header + address - 0x78000000
        if data[offset:offset + 3] != bytes.fromhex("364100"):
            raise ValueError(f"audio entry mismatch at {address:#x}")
    args.output.mkdir(parents=True, exist_ok=False)
    objcopy = args.objcopy.resolve()
    regions = []
    for name, row, address in (("dsp-external", rows[0], 0x7800D000),
                               ("shared", rows[1], 0x40000000)):
        offset, size = header + row[4], row[5]
        payload = data[offset:offset + size]
        if len(payload) != size:
            raise ValueError("truncated firmware region")
        raw = args.output / f"{name}.bin"
        elf = args.output / f"{name}.elf"
        raw.write_bytes(payload)
        subprocess.run([str(objcopy), "-I", "binary", "-O", "elf32-xtensa-le",
                        "-B", "xtensa", "--rename-section",
                        ".data=.text,alloc,load,readonly,code,contents",
                        f"--change-addresses={address:#x}",
                        str(raw), str(elf)], check=True)
        regions.append({"name": name, "container_offset": hex(offset),
                        "size": size, "analysis_address": hex(address),
                        "raw": str(raw), "elf": str(elf)})
    report = {"firmware": str(args.firmware), "purpose": "offline audio interoperability",
              "version": data[header + 0x30:header + 0x70].split(b"\0")[0].decode(),
              "dsp_external_alias": "inferred; applies to this reviewed Frankel image",
              "regions": regions,
              "section_rows_raw_u32": [[hex(value) for value in row] for row in rows]}
    (args.output / "regions.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
