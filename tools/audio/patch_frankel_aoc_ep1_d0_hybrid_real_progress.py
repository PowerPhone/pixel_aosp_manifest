#!/usr/bin/env python3
"""Retain D0's real mailbox ISR and add a 1 ms real-counter fallback poll.

This is the fallback to the mailbox-only bounded-progress experiment.  PCM0
keeps ``service->prvdata`` connected to the stock AoC mailbox handler while it
also initializes the existing hrtimer.  Both paths enter the same D0-only
``min(actual_rx, previous_report + period_bytes)`` counter clamp.  Neither path
can advance beyond AoC's real cumulative Rx count; there is no prefill,
availability bypass, or synthetic time-derived position.
"""

from __future__ import annotations

import patch_frankel_aoc_ep1_d0_real_progress as implementation


implementation.PATCHES = (
    # Preserve x8 as the service pointer while testing its mailbox index.
    (0x1A5E0, bytes.fromhex("08015039"), bytes.fromhex("0a015039"),
     "load mailbox index without destroying the service pointer"),
    (0x1A5E4, bytes.fromhex("1f110071"), bytes.fromhex("5f110071"),
     "compare preserved mailbox index"),
    # For mailbox services, connect the stock callback first.  D0 then falls
    # into timer initialization; all other mailbox PCMs take the stock skip.
    (0x1A5EC, bytes.fromhex("e80340f9"), bytes.fromhex("14f901f9"),
     "connect mailbox private data using preserved service pointer"),
    (0x1A5F0, bytes.fromhex("14f901f9"), bytes.fromhex("75000034"),
     "initialize the fallback timer only for PCM device zero"),
    (0x1A5FC, bytes.fromhex("08d09252"), bytes.fromhex("08488852"),
     "1 ms timer low immediate"),
    (0x1A608, bytes.fromhex("0813a072"), bytes.fromhex("e801a072"),
     "1 ms timer high immediate"),
    *implementation.PATCHES[-3:],
)
implementation.PATCHED_SHA256 = (
    "14f768697dfdce17869d91360da54ab9e4f7b8d291e718ff8919f524e7010e98"
)


if __name__ == "__main__":
    raise SystemExit(implementation.main())
