"""Host-only tests for the Frankel A32 raw-PDM diagnostic snapshot."""

from __future__ import annotations

import contextlib
import io
import pathlib
import struct
import sys
import unittest
from types import SimpleNamespace


sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import frankel_a32_raw_pdm as raw_pdm  # noqa: E402


class FakeHardware:
    def __init__(self, state: raw_pdm.DeviceState) -> None:
        self.state_value = state
        self.state_calls = 0

    def state(self) -> raw_pdm.DeviceState:
        self.state_calls += 1
        return self.state_value


class ObservedStateTest(unittest.TestCase):
    def make_state(self) -> raw_pdm.DeviceState:
        words = {address: 0 for address in raw_pdm.COMMON_ADDRESSES}
        words[raw_pdm.PDM_GLOBAL_CONFIG] = raw_pdm.STOCK_PDM_GLOBAL_CONFIG
        words[raw_pdm.CLOCK_GATE_STATUS] = 1
        for controller in raw_pdm.ALL_CONTROLLERS:
            for offset in raw_pdm.SAFE_CONTROLLER_OFFSETS:
                words[raw_pdm.controller_address(controller, offset)] = 0
        return raw_pdm.DeviceState(
            identity={
                "device": raw_pdm.EXPECTED_DEVICE,
                "vendor_build_id": raw_pdm.EXPECTED_VENDOR_BUILD_ID,
            },
            capture_status={"card0-capture-fd-scan": "closed"},
            handles=[
                raw_pdm.Handle(
                    address=0x40001000,
                    active=0,
                    controller=2,
                    pcm_rate=96_000,
                    main_object=0x40002000,
                    callback=0x78001000,
                    next_address=0,
                ),
                raw_pdm.Handle(
                    address=0x40003000,
                    active=0,
                    controller=7,
                    pcm_rate=48_000,
                    main_object=0x40004000,
                    callback=0x78002000,
                    next_address=0,
                ),
            ],
            words=words,
        )

    def test_check_idle_prints_complete_snapshot_before_rejection(self) -> None:
        hardware = FakeHardware(self.make_state())
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            with self.assertRaisesRegex(RuntimeError, "stock PDM clock divider"):
                raw_pdm.operation_check_idle(
                    hardware, SimpleNamespace(controllers=(0, 2, 3))
                )
        text = output.getvalue()

        self.assertEqual(hardware.state_calls, 1)
        self.assertIn(
            "observed-state: operation=check-idle validation=pending", text
        )
        for address in raw_pdm.COMMON_ADDRESSES:
            self.assertIn(
                f"name={raw_pdm.COMMON_ADDRESS_LABELS[address]} "
                f"address={raw_pdm.hex32(address)} "
                f"value={raw_pdm.hex32(hardware.state_value.words[address])}",
                text,
            )
        for controller in raw_pdm.ALL_CONTROLLERS:
            for offset in raw_pdm.SAFE_CONTROLLER_OFFSETS:
                address = raw_pdm.controller_address(controller, offset)
                self.assertIn(
                    f"observed-pdm controller={controller} "
                    f"name={raw_pdm.CONTROLLER_OFFSET_LABELS[offset]} "
                    f"offset=0x{offset:02x} address={raw_pdm.hex32(address)} ",
                    text,
                )
        self.assertNotIn("offset=0x0c", text)
        self.assertIn("observed-handle controller=0 state=none", text)
        self.assertIn(
            "observed-handle controller=2 address=0x40001000 active=0", text
        )
        self.assertIn(
            "observed-handle controller=7 address=0x40003000 active=0", text
        )
        self.assertIn("state=outside-controller-range", text)
        self.assertNotIn("all software-owner guards passed", text)

    def test_words_reads_grouped_allowlist_and_never_fifo_pop(self) -> None:
        hardware = object.__new__(raw_pdm.Hardware)
        reads: list[tuple[int, int]] = []

        class FakeTransport:
            def dump(self, address: int, size: int) -> bytes:
                reads.append((address, size))
                return b"".join(
                    struct.pack("<I", word_address)
                    for word_address in range(address, address + size, 4)
                )

        hardware.transport = FakeTransport()  # type: ignore[assignment]
        words = hardware.words()
        expected = set(raw_pdm.COMMON_ADDRESSES)
        for controller in raw_pdm.ALL_CONTROLLERS:
            expected.update(
                raw_pdm.controller_address(controller, offset)
                for offset in raw_pdm.SAFE_CONTROLLER_OFFSETS
            )

        self.assertEqual(set(words), expected)
        self.assertEqual(words, {address: address for address in expected})
        read_words = {
            address
            for start, size in reads
            for address in range(start, start + size, 4)
        }
        self.assertEqual(read_words, expected)
        self.assertEqual(sum(size // 4 for _, size in reads), len(expected))
        self.assertEqual(len(reads), 23)
        self.assertIn((raw_pdm.PDM_GLOBAL_CONFIG, 4), reads)
        self.assertIn((raw_pdm.PDM_ACTIVITY_CONTROL, 4), reads)
        self.assertNotIn((raw_pdm.PDM_GLOBAL_CONFIG, 8), reads)
        self.assertNotIn((raw_pdm.PDM_GLOBAL_CONFIG, 12), reads)
        self.assertNotIn(raw_pdm.REG_FIFO_POP, raw_pdm.SAFE_CONTROLLER_OFFSETS)
        for controller in raw_pdm.ALL_CONTROLLERS:
            self.assertNotIn(
                raw_pdm.controller_address(controller, raw_pdm.REG_FIFO_POP),
                read_words,
            )


class TransactionJournalTest(unittest.TestCase):
    def test_intent_is_journaled_before_target_write(self) -> None:
        events: list[tuple[str, object]] = []

        class RegisterHardware:
            def __init__(self) -> None:
                self.words = {raw_pdm.PDM_ACTIVITY_CONTROL: 0}

            def read32(self, address: int) -> int:
                return self.words[address]

            def write32(self, address: int, value: int) -> None:
                events.append(("write", (address, value)))
                self.words[address] = value

        def journal(records: list[raw_pdm.WriteRecord]) -> None:
            events.append(
                (
                    "journal",
                    tuple((item.address, item.before, item.after) for item in records),
                )
            )

        hardware = RegisterHardware()
        transaction = raw_pdm.Transaction(hardware, journal)  # type: ignore[arg-type]
        raw_pdm.set_pdm_activity(transaction, True)

        self.assertEqual(events[0][0], "journal")
        self.assertEqual(events[1][0], "write")
        self.assertEqual(
            events[0][1],
            ((raw_pdm.PDM_ACTIVITY_CONTROL, 0, raw_pdm.PDM_ACTIVITY_ACTIVE),),
        )
        self.assertEqual(hardware.words[raw_pdm.PDM_ACTIVITY_CONTROL], 1)

    def test_pdm_start_stop_common_control_order(self) -> None:
        events: list[tuple[str, int]] = []

        class RegisterHardware:
            def __init__(self) -> None:
                self.words = {
                    raw_pdm.PDM_ACTIVITY_CONTROL: 0,
                    raw_pdm.CLOCK_GATE_CONFIG: 0,
                    raw_pdm.CLOCK_GATE_ENABLE: 0,
                }

            def read32(self, address: int) -> int:
                return self.words[address]

            def write32(self, address: int, value: int) -> None:
                events.append((raw_pdm.COMMON_ADDRESS_LABELS[address], value))
                self.words[address] = value

        hardware = RegisterHardware()
        transaction = raw_pdm.Transaction(hardware)  # type: ignore[arg-type]
        raw_pdm.set_pdm_activity(transaction, True)
        raw_pdm.set_pdm_clock(transaction, True)
        raw_pdm.set_pdm_clock(transaction, False)
        raw_pdm.set_pdm_activity(transaction, False)

        self.assertEqual(
            events,
            [
                ("pdm_activity_control", 1),
                ("clock_gate_enable", 1),
                ("clock_gate_enable", 0),
                ("pdm_activity_control", 0),
            ],
        )


if __name__ == "__main__":
    unittest.main()
