#!/usr/bin/env python3
"""Decode the stock AoCx V3 CommandResult returned by Android service call."""
import re
import struct
import sys


def main():
    words = []
    for line in sys.stdin:
        if re.match(r"\s*0x[0-9a-fA-F]+:", line):
            line = line.split(":", 1)[1]
        elif "Parcel(" in line:
            line = line.split("Parcel(", 1)[1]
        else:
            continue
        for token in line.split():
            if not re.fullmatch(r"[0-9a-fA-F]{8}", token):
                break
            words.append(int(token, 16))
    data = b"".join(struct.pack("<I", word) for word in words)
    position = 0

    def integer():
        nonlocal position
        if position + 4 > len(data):
            raise ValueError("truncated parcel")
        value = struct.unpack_from("<i", data, position)[0]
        position += 4
        return value

    if integer() != 0:
        raise ValueError("Binder exception in service response")
    if integer() != 1:
        raise ValueError("missing CommandResult parcelable")
    start = position
    size = integer()
    if size < 16 or start + size > len(data):
        raise ValueError("invalid CommandResult size")
    status = integer() & 0xFF  # AIDL byte is encoded as a 32-bit parcel field.
    integer()  # Numeric float result; these tap operations return text.
    count = integer()
    if not 0 <= count <= 4096:
        raise ValueError("invalid CommandResult string count")
    for _ in range(count):
        length = integer()
        if length < 0 or position + 2 * (length + 1) > start + size:
            raise ValueError("invalid CommandResult string length")
        text = data[position:position + 2 * length].decode("utf-16-le")
        position = (position + 2 * (length + 1) + 3) & ~3
        print(text)
    if position != start + size:
        raise ValueError("unexpected trailing CommandResult fields")
    if status:
        print(f"AoCx returned status={status}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (ValueError, UnicodeError, struct.error) as error:
        print(f"Cannot decode AoCx reply: {error}", file=sys.stderr)
        sys.exit(1)
