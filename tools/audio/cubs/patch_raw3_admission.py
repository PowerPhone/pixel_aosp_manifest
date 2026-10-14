#!/usr/bin/env python3
"""Extend only the matching Cubs RAW start/stop channel guard from2 to3.

Input should already contain the required capture192/playback admissions.
No firmware edits, device access, image packaging, or hashes are performed.
"""
import argparse
from pathlib import Path

from patch_capture192_admission import Elf, require


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--input', type=Path, required=True)
    p.add_argument('--output', type=Path, required=True)
    p.add_argument('--restore-two', action='store_true')
    a = p.parse_args()
    require(not a.output.exists(), 'Refusing to overwrite an existing output')
    data = a.input.read_bytes()
    elf = Elf(data)
    symbol = elf.symbol('aoc_raw_capture_trigger')
    require(elf.names[symbol[3]] == '.text' and symbol[4:] == (0x1032c, 0x14c),
            'Not the independently inspected Cubs RAW trigger')
    at = elf.offset('.text', 0x1035c)
    require(at == 0x35d90, 'Unexpected exact live module text placement')
    old, new = bytes.fromhex('3f0c0071'), bytes.fromhex('3f100071')
    require(data[at:at + 4] in (old, new), 'RAW channel comparison changed')
    require(data[at - 12:at] == bytes.fromhex('01ec40b9ff430039ff0700f9'),
            'Requested-channel load/packet clearing guard changed')
    require(data[at + 4:at + 8] == bytes.fromhex('ea060054'),
            'RAW >= limit rejection branch changed')
    changed = bytearray(data)
    changed[at:at + 4] = old if a.restore_two else new
    a.output.parent.mkdir(parents=True, exist_ok=True)
    a.output.write_bytes(changed)
    print(f'{a.output}: RAW channel comparison permits{2 if a.restore_two else 3}; firmware support still required')


if __name__ == '__main__':
    main()
