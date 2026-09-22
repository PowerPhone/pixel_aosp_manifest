#!/usr/bin/env python3
"""Wait for D5 playback and capture current F1 speaker/source buffers.

Uses the existing AoC factory transport (including FRANKEL_AOC_DIAG_DEVICE),
only performs reads on the phone, and records current pointers before using
them. Dumps are split into at most 256-byte commands. These are sequential
live snapshots, not an atomic view of all buffers.
"""

from __future__ import annotations

import argparse
import json
import pathlib
import subprocess
import time

from aoc_factory_diag import AocFactoryDiag

SPEAKER = 0x4051B0B8
PCM_STATUS = "/proc/asound/card0/pcm5p/sub0/status"


def u32(data: bytes, offset: int = 0) -> int:
    return int.from_bytes(data[offset:offset + 4], "little")


def plausible(pointer: int) -> bool:
    return 0x40000000 <= pointer < 0x42000000 and pointer % 4 == 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--adb", type=pathlib.Path, default=pathlib.Path("/usr/bin/adb"))
    parser.add_argument("--adb-server-port", type=int, default=5037)
    parser.add_argument("--serial")
    parser.add_argument("--counter", type=lambda value: int(value, 0))
    parser.add_argument("--output", type=pathlib.Path, required=True)
    parser.add_argument("--wait-seconds", type=float, default=60)
    parser.add_argument("--buffer-bytes", type=int, default=1024)
    args = parser.parse_args()
    if args.wait_seconds < 0 or not 4 <= args.buffer_bytes <= 0xC00 or args.buffer_bytes % 4:
        parser.error("use a nonnegative wait and buffer size divisible by four, at most 0xc00")
    args.core = 2
    transport = AocFactoryDiag(args)
    args.output.mkdir(parents=True, exist_ok=False)
    metadata = {"speaker_address": SPEAKER, "core": 2, "started_host_ns": time.time_ns(),
                "buffer_bytes": args.buffer_bytes, "dumps": {}, "errors": []}

    def publish() -> None:
        (args.output / "metadata.json").write_text(json.dumps(metadata, indent=2) + "\n")

    def capture(name: str, address: int, length: int) -> bytes:
        if not plausible(address):
            raise ValueError(f"implausible {name} pointer 0x{address:08x}")
        start_ns = time.time_ns()
        result = bytearray()
        try:
            for offset in range(0, length, 256):
                result.extend(transport.dump(address + offset, min(256, length - offset)))
        finally:
            payload = bytes(result)
            (args.output / f"{name}.bin").write_bytes(payload)
            (args.output / f"{name}.hex").write_text(payload.hex() + "\n")
            metadata["dumps"][name] = {"address": address, "requested_bytes": length,
                                         "captured_bytes": len(payload), "start_host_ns": start_ns,
                                         "end_host_ns": time.time_ns()}
            publish()
        print(f"{name}: 0x{address:08x} {len(result)} bytes", flush=True)
        return bytes(result)

    publish()
    deadline = time.monotonic() + args.wait_seconds
    while True:
        status = transport.run("shell", "cat", PCM_STATUS, check=False).stdout.decode(errors="replace")
        # CONFIG_SND_VERBOSE_PROCFS is disabled on this kernel, including
        # during active streaming. Use the dedicated staged player's lifetime
        # as the fallback trigger; these snapshots are diagnostic reads only.
        player = transport.run("shell", "pidof", "frankel_aoc_staged_play", check=False)
        if "RUNNING" in status or player.returncode == 0:
            time.sleep(0.5)
            metadata["running_status"] = status
            metadata["playback_seen_host_ns"] = time.time_ns()
            publish()
            break
        if time.monotonic() >= deadline:
            metadata["errors"].append("D5 did not reach RUNNING before timeout")
            metadata["last_pcm_status"] = status
            publish()
            return 1
        time.sleep(0.1)

    try:
        # Resolve buffers from a compact active-object snapshot before any
        # longer SRAM capture. These pointers can differ after every boot.
        vtable = capture("speaker_vtable", SPEAKER, 4)
        if u32(vtable) != 0x40275D00:
            raise ValueError("unexpected speaker vtable")
        source_header = capture("speaker_source_header", SPEAKER + 0x1C0, 0x10)
        layout = capture("speaker_buffer_layout", SPEAKER + 0x280, 0x54)
        rings = capture("speaker_dma_ring_pointers", SPEAKER + 0x200, 8)
        mix_creator = u32(source_header)
        metadata["source_flags"] = u32(source_header, 0xC)
        tx_scratch = u32(layout, 0x44)
        mixed_source = u32(layout, 0x48)
        tx_extent = u32(layout, 0x28)
        tx_ring = u32(rings)
        rx_ring = u32(rings, 4)
        metadata["pointers"] = {"mix_creator": mix_creator, "tx_scratch": tx_scratch,
                                  "mixed_source": mixed_source, "tx_ring": tx_ring,
                                  "rx_ring": rx_ring, "tx_extent": tx_extent}
        tx_ring_head = capture("tx_ring_object", tx_ring, 0x50)
        tx_backing = u32(tx_ring_head, 0x40)
        metadata["pointers"]["tx_dma_backing"] = tx_backing
        publish()
        capture("cpu_tx_scratch", tx_scratch, args.buffer_bytes)
        capture("cpu_mixed_source", mixed_source, args.buffer_bytes)
        capture("dma_tx_bank0", tx_backing, args.buffer_bytes)
        # The current ring comprises two 0x600-byte DMA periods. Retain the
        # software extent above as separate evidence if it still differs.
        capture("dma_tx_bank1", tx_backing + 0x600, args.buffer_bytes)
        creator = capture("mix_creator", mix_creator, 0xB0)
        entries = []
        for index in range(4):
            entry = {"index": index, "transport": u32(creator, 0x1C + 20 * index),
                     "context": u32(creator, 0x20 + 20 * index),
                     "resync_count": u32(creator, 0x24 + 20 * index),
                     "underrun_count": u32(creator, 0x28 + 20 * index)}
            entries.append(entry)
        metadata["source_entries"] = entries
        publish()
        for entry in entries:
            for kind in ("transport", "context"):
                pointer = entry[kind]
                if plausible(pointer):
                    capture(f"source{entry['index']}_{kind}", pointer, 0x60)
        metadata["final_pcm_status"] = transport.run("shell", "cat", PCM_STATUS, check=False).stdout.decode(errors="replace")
        publish()
        return 0
    except (RuntimeError, ValueError, subprocess.SubprocessError) as error:
        metadata["errors"].append(str(error))
        publish()
        print(f"ERROR: {error}", flush=True)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
