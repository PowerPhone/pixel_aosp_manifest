#!/usr/bin/env python3
"""Focused host tests for the one-shot Frankel speaker buffer rebase."""

from __future__ import annotations

import unittest
from types import SimpleNamespace

import patch_frankel_aoc_speaker_buffers_live as buffers


class MemoryTransport:
    def __init__(
        self, allocation: int = 0x40600000
    ) -> None:
        self.memory: dict[int, int] = {}
        self.writes: list[tuple[int, int]] = []
        self.allocation = allocation
        self.allocations = (allocation, allocation + buffers.DMA_TX_OFFSET)
        self.allocation_calls = 0
        self.put(buffers.SPEAKER, buffers.SPEAKER_VTABLE.to_bytes(4, "little"))
        for offset, value in buffers.FIXED_SPEAKER_FIELDS.items():
            self.put(buffers.SPEAKER + offset, value.to_bytes(4, "little"))
        for address, value in (
            (buffers.TX_SIZE_ADDRESS, buffers.STOCK_BANK_BYTES),
            (buffers.SOURCE_SIZE_ADDRESS, buffers.STOCK_BANK_BYTES),
            (buffers.TX_POINTER_ADDRESS, buffers.STOCK_TX_POINTER),
            (buffers.SOURCE_POINTER_ADDRESS, buffers.STOCK_SOURCE_POINTER),
            (buffers.TX_RING_POINTER_ADDRESS, buffers.STOCK_TX_RING),
            (buffers.RX_RING_POINTER_ADDRESS, buffers.STOCK_RX_RING),
            (buffers.SCRATCH_ADDRESS, 0),
            (buffers.ALIGNED_ALLOC_LITERAL_ADDRESS, buffers.ALIGNED_ALLOC_LITERAL),
            (buffers.D12_CALLBACK_SLOT, buffers.STOCK_D12_CALLBACK),
            (buffers.HD_MIC_DISPATCH, buffers.STOCK_HD_MIC_DISPATCH),
        ):
            self.put(address, value.to_bytes(4, "little"))
        for patch in buffers.SCRATCH_LITERAL_PATCHES + buffers.ALLOCATOR_BODY_PATCHES:
            self.put(patch.address, patch.before)
        for ring in buffers.DMA_RINGS:
            for offset, value in (
                (0x00, buffers.RING_VTABLE),
                (0x04, 0x28),
                (0x14, 3),
                (0x18, buffers.SPEAKER),
                (0x3C, ring.metadata),
                (0x40, ring.inline_backing),
                (0x44, ring.descriptor),
                (0xE8, 0xFFFFFFFF),
                (0xFC, 0xFFFFFFFF),
                (0x108, 5),
                (0x10C, 5),
                (0x110, 4),
                (0x114, 0xFFFF),
                (0x170, 0xAC060040),
            ):
                self.put(ring.address + offset, value.to_bytes(4, "little"))
            self.put(ring.address + 0x20, (ring.name + "\0").encode())
            self.put(
                ring.descriptor,
                b"".join(
                    word.to_bytes(4, "little")
                    for word in (0, buffers.STOCK_BANK_BYTES, 0, buffers.STOCK_BANK_BYTES, 0, 0, 1)
                ),
            )
        self.put(allocation, bytes(4))
        self.put(allocation + buffers.ALLOCATION_BYTES - 4, bytes(4))

    def put(self, address: int, data: bytes) -> None:
        for offset, value in enumerate(data):
            self.memory[address + offset] = value

    def dump(self, address: int, size: int) -> bytes:
        return bytes(self.memory.get(address + offset, 0) for offset in range(size))

    def write(self, address: int, value: int, width: int) -> None:
        self.writes.append((address, value))
        self.put(address, value.to_bytes(width // 8, "little"))

    def run(self, *arguments: str, **kwargs: object) -> SimpleNamespace:
        if arguments[-1:] == (buffers.RESTART_COUNT,):
            return SimpleNamespace(returncode=0, stdout=b"2\n", stderr=b"")
        if arguments[-1:] == (buffers.COREDUMP_COUNT,):
            return SimpleNamespace(returncode=0, stdout=b"0\n", stderr=b"")
        if kwargs.get("input_data") is not None:
            dispatch = int.from_bytes(self.dump(buffers.HD_MIC_DISPATCH, 4), "little")
            if dispatch == buffers.ALLOCATOR_BODY_ADDRESS:
                self.allocation_calls += 1
                self.put(
                    buffers.SCRATCH_ADDRESS,
                    self.allocation.to_bytes(4, "little"),
                )
            return SimpleNamespace(returncode=1, stdout=b"", stderr=b"")
        return SimpleNamespace(returncode=0, stdout=b"", stderr=b"")


class SpeakerBufferRebaseTest(unittest.TestCase):
    def test_fixed_object_guards_match_the_reviewed_live_f1_dump(self) -> None:
        self.assertEqual(buffers.FIXED_SPEAKER_FIELDS[0x288], 0x1800)
        self.assertEqual(buffers.FIXED_SPEAKER_FIELDS[0x298], 0x30)
        self.assertEqual(buffers.FIXED_SPEAKER_FIELDS[0x2A0], 0xC0)

    def test_allocator_body_is_exact_reviewed_0x3000_sequence(self) -> None:
        self.assertEqual(
            b"".join(patch.after for patch in buffers.ALLOCATOR_BODY_PATCHES),
            bytes.fromhex(
                "3641004c0a3c0b80bb1181156ee00800410dfca9041df000"
            ),
        )
        self.assertEqual(buffers.BANK_BYTES * 4, buffers.ALLOCATION_BYTES)
        self.assertEqual(buffers.NATIVE_BLOCK_BYTES * 2, buffers.BANK_BYTES)

    def test_allocate_restores_dispatch_body_literal_and_callback(self) -> None:
        transport = MemoryTransport()
        allocation = buffers.allocate(transport, (2, 0))

        self.assertEqual(allocation, transport.allocation)
        self.assertEqual(transport.allocation_calls, 1)
        for patch in (
            (buffers.D12_QUARANTINE,)
            + buffers.SCRATCH_LITERAL_PATCHES
            + buffers.ALLOCATOR_BODY_PATCHES
            + (buffers.ALLOCATOR_DISPATCH,)
        ):
            self.assertEqual(transport.dump(patch.address, 4), patch.before)
        addresses = [address for address, _ in transport.writes]
        body_first = addresses.index(buffers.ALLOCATOR_BODY_ADDRESS)
        allocator_dispatch = transport.writes.index(
            (buffers.HD_MIC_DISPATCH, buffers.ALLOCATOR_BODY_ADDRESS)
        )
        allocator_dispatch_restore = transport.writes.index(
            (buffers.HD_MIC_DISPATCH, buffers.STOCK_HD_MIC_DISPATCH),
            allocator_dispatch,
        )
        body_restore = addresses.index(
            buffers.ALLOCATOR_BODY_ADDRESS,
            body_first + 1,
        )
        callback_restore = len(addresses) - 1
        self.assertLess(body_first, allocator_dispatch)
        self.assertLess(allocator_dispatch, allocator_dispatch_restore)
        self.assertLess(allocator_dispatch_restore, body_restore)
        self.assertEqual(addresses[callback_restore], buffers.D12_CALLBACK_SLOT)

    def test_commit_has_two_contiguous_double_block_banks(self) -> None:
        transport = MemoryTransport()
        buffers.commit_rebase(transport, *transport.allocations)
        self.assertEqual(
            buffers.require_rebased_layout(transport), transport.allocations
        )
        field_writes = [address for address, _ in transport.writes]
        self.assertEqual(
            field_writes,
            [
                buffers.TX_SIZE_ADDRESS,
                buffers.SOURCE_SIZE_ADDRESS,
                buffers.DMA_RINGS[0].descriptor + 4,
                buffers.DMA_RINGS[0].descriptor + 12,
                buffers.DMA_RINGS[1].descriptor + 4,
                buffers.DMA_RINGS[1].descriptor + 12,
                buffers.TX_POINTER_ADDRESS,
                buffers.SOURCE_POINTER_ADDRESS,
                buffers.DMA_RINGS[0].address + 0x40,
                buffers.DMA_RINGS[1].address + 0x40,
            ],
        )

    def test_one_allocation_is_split_into_four_banks(self) -> None:
        transport = MemoryTransport()
        allocation = buffers.allocate(transport, (2, 0))
        dma = allocation + buffers.DMA_TX_OFFSET
        buffers.validate_allocations(transport, allocation, dma)
        self.assertEqual(transport.allocation_calls, 1)
        with self.assertRaises(ValueError):
            buffers.validate_allocations(transport, allocation, dma + 0x40)

    def test_new_allocation_must_be_fully_zero(self) -> None:
        transport = MemoryTransport()
        buffers.require_zero_allocation(transport, transport.allocation)
        transport.put(transport.allocation + 0x901, b"\x7f")
        with self.assertRaisesRegex(ValueError, "is not zero"):
            buffers.require_zero_allocation(transport, transport.allocation)

    def test_partial_or_unknown_layout_is_rejected(self) -> None:
        transport = MemoryTransport()
        transport.put(
            buffers.TX_SIZE_ADDRESS, buffers.BANK_BYTES.to_bytes(4, "little")
        )
        with self.assertRaises(ValueError):
            buffers.require_stock_layout(transport)
        with self.assertRaises(ValueError):
            buffers.require_rebased_layout(transport)

    def test_idle_nonzero_ring_generation_is_preserved_and_accepted(self) -> None:
        transport = MemoryTransport()
        for ring in buffers.DMA_RINGS:
            transport.put(ring.descriptor + 24, (2).to_bytes(4, "little"))
        buffers.require_stock_layout(transport)
        buffers.commit_rebase(transport, *transport.allocations)
        self.assertEqual(
            buffers.require_rebased_layout(transport), transport.allocations
        )
        for ring in buffers.DMA_RINGS:
            self.assertEqual(
                int.from_bytes(transport.dump(ring.descriptor + 24, 4), "little"),
                2,
            )

    def test_allocation_range_and_alignment_are_guarded(self) -> None:
        transport = MemoryTransport()
        with self.assertRaises(ValueError):
            buffers.validate_allocation(transport, 0x40600004)
        with self.assertRaises(ValueError):
            buffers.validate_allocation(transport, 0x40500000)


if __name__ == "__main__":
    unittest.main()
