#!/usr/bin/env python3
"""Apply a guarded, reboot-volatile Frankel high-rate speaker AoC patch.

The three live hooks are complete aligned F1 words.  Code caves are populated
before any hook is made reachable; revert disconnects all hooks before it
erases any cave.  This tool is intentionally tied to one reviewed Frankel
vendor build and refuses unknown bytes at every patch site.
"""

from __future__ import annotations

import argparse
import dataclasses
import pathlib
import sys
import time

from aoc_factory_diag import AocFactoryDiag
from frankel_aoc_speaker_q192_profile import NATIVE_SOURCE5_Q192_WORDS


EXPECTED_DEVICE = "frankel"
EXPECTED_VENDOR_BUILD_ID = "CP2A.260805.005"
PLAYBACK_STATUS = "/proc/asound/card0/pcm28p/sub0/status"
SOURCE5_PROFILE = "experimental-enum7-early-q48-tdm12288-192-4xs16-dma-source5"
SOURCE5_Q192_2SLOT_PROFILE = (
    "experimental-enum7-q192-tdm12288-192-2xs32-dma-source5"
)
SOURCE0_PROFILE = "experimental-enum7-early-q48-tdm12288-192-4xs16-dma-source0"
SOURCE0_2SLOT_PROFILE = (
    "experimental-enum7-early-q48-tdm12288-192-2xs32-dma-source0"
)
SOURCE0_4S32_PROFILE = (
    "experimental-enum7-early-q48-tdm24576-192-4xs32-source0"
)
SOURCE0_Q192_4S32_PROFILE = (
    "experimental-enum7-q192-tdm24576-192-4xs32-source0"
)
SOURCE0_Q192_2SLOT_PROFILE = (
    "experimental-enum7-q192-tdm12288-192-2xs32-dma-source0"
)
SOURCE0_Q192_4S16_PROFILE = (
    "experimental-enum7-q192-tdm12288-192-4xs16-dma-source0"
)
SOURCE0_Q192_4S16_FIFO32_PROFILE = (
    "experimental-enum7-q192-tdm12288-192-4xs16-dma-fifo32-source0"
)
PROFILE_PLAYBACK_STATUS = {
    SOURCE5_PROFILE: "/proc/asound/card0/pcm5p/sub0/status",
    SOURCE5_Q192_2SLOT_PROFILE: "/proc/asound/card0/pcm5p/sub0/status",
    SOURCE0_PROFILE: "/proc/asound/card0/pcm0p/sub0/status",
    SOURCE0_2SLOT_PROFILE: "/proc/asound/card0/pcm0p/sub0/status",
    SOURCE0_4S32_PROFILE: "/proc/asound/card0/pcm0p/sub0/status",
    SOURCE0_Q192_4S32_PROFILE: "/proc/asound/card0/pcm0p/sub0/status",
    SOURCE0_Q192_2SLOT_PROFILE: "/proc/asound/card0/pcm0p/sub0/status",
    SOURCE0_Q192_4S16_PROFILE: "/proc/asound/card0/pcm0p/sub0/status",
    SOURCE0_Q192_4S16_FIFO32_PROFILE: "/proc/asound/card0/pcm0p/sub0/status",
}
CACHE_FLUSH_CONTROL = "HD Mic gain (cB)"


@dataclasses.dataclass(frozen=True)
class Patch:
    name: str
    address: int
    before: bytes
    after: bytes
    kind: str

    def __post_init__(self) -> None:
        if self.address & 3 or len(self.before) != 4 or len(self.after) != 4:
            raise ValueError(f"{self.name}: live patches must be aligned words")


# Cave A replays the two instructions at 0x4038ba78.  For sink 0 it loads the
# per-sink enum selected by cave B; every other sink retains stock enum 5.  It
# then stores the frame quantum and returns at 0x4038ba84.  Because cave B is
# the only writer of enum 7, the guard remains sink 0 plus the profile-selected
# source bit.
CAVE_RATE_PATCHES = (
    Patch("speaker rate cave A word 0", 0x4038AEE8, bytes.fromhex("00000000"), bytes.fromhex("924bfca2"), "cave"),
    Patch("speaker rate cave A word 1", 0x4038AEEC, bytes.fromhex("00000000"), bytes.fromhex("25718841"), "cave"),
    Patch("speaker rate cave A word 2", 0x4038AEF0, bytes.fromhex("00000000"), bytes.fromhex("0c5b5628"), "cave"),
    Patch("speaker rate cave A word 3", 0x4038AEF4, bytes.fromhex("00000000"), bytes.fromhex("00b20c8a"), "cave"),
    Patch("speaker rate cave A word 4", 0x4038AEF8, bytes.fromhex("00000000"), bytes.fromhex("625c3946"), "cave"),
    Patch("speaker rate cave A word 5", 0x4038AEFC, bytes.fromhex("00000000"), bytes.fromhex("e1020000"), "cave"),
)

# Cave B replays the loads at 0x4038ba4c, checks saved sink index 0 and source
# bitmap bit 14, sets the 192-frame quantum and per-sink enum 7, then returns
# at 0x4038ba52.  The byte at 0x4039d520 belongs to the preceding accessor and
# is deliberately preserved in the first aligned word.
CAVE_GUARD_PATCHES = (
    Patch("speaker guard cave B word 0", 0x4039D520, bytes.fromhex("6b000000"), bytes.fromhex("6b821432"), "cave"),
    Patch("speaker guard cave B word 1", 0x4039D524, bytes.fromhex("00000000"), bytes.fromhex("7223da28"), "cave"),
    Patch("speaker guard cave B word 2", 0x4039D528, bytes.fromhex("00000000"), bytes.fromhex("41ccb20c"), "cave"),
    Patch("speaker guard cave B word 3", 0x4039D52C, bytes.fromhex("00000000"), bytes.fromhex("52e76704"), "cave"),
    Patch("speaker guard cave B word 4", 0x4039D530, bytes.fromhex("00000000"), bytes.fromhex("62a0c00c"), "cave"),
    Patch("speaker guard cave B word 5", 0x4039D534, bytes.fromhex("00000000"), bytes.fromhex("7222448a"), "cave"),
    Patch("speaker guard cave B word 6", 0x4039D538, bytes.fromhex("00000000"), bytes.fromhex("8645b900"), "cave"),
)

# Diagnostic alternative for the guarded path: select enum 7 while retaining
# the stock 48-frame mixer quantum already placed in a6 at 0x4038ba4a.  Replace
# only cave B's `movi a6, 192` with a same-width three-byte NOP.  This avoids
# overflowing speaker-side loops and buffers dimensioned for 48 frames.
CAVE_GUARD_Q48_PATCHES = tuple(
    Patch(
        patch.name,
        patch.address,
        patch.before,
        bytes.fromhex("f020000c") if patch.address == 0x4039D530 else patch.after,
        patch.kind,
    )
    for patch in CAVE_GUARD_PATCHES
)

# Frankel's physical speaker frontend is PCM0,D5 / EP6 (source 5), rather
# than the source-14 diagnostic path used while the firmware guard was first
# decoded.  Change only the source-bit immediate in cave B; all sink, enum,
# and q48 checks remain identical.  The aligned word encodes the same FLIX
# packet with bit 5 selected instead of bit 14.
CAVE_GUARD_SOURCE5_Q48_PATCHES = tuple(
    Patch(
        patch.name.replace("speaker guard", "speaker source-5 guard"),
        patch.address,
        patch.before,
        bytes.fromhex("52576704")
        if patch.address == 0x4039D52C
        else patch.after,
        patch.kind,
    )
    for patch in CAVE_GUARD_Q48_PATCHES
)

# Native one-millisecond EP6 / PCM5 profile. This is the source-5 counterpart
# of the source-0 q192 guard: retain cave B's 192-frame quantum and change only
# its source-bitmap test from bit 14 to bit 5. Source 5 is the stock physical
# speaker frontend and, unlike source 0, has demonstrated non-zero speaker data.
CAVE_GUARD_SOURCE5_Q192_PATCHES = tuple(
    Patch(
        patch.name.replace("speaker guard", "speaker source-5 q192 guard"),
        patch.address,
        patch.before,
        bytes.fromhex("52576704")
        if patch.address == 0x4039D52C
        else patch.after,
        patch.kind,
    )
    for patch in CAVE_GUARD_PATCHES
)

# EP1 / PCM0 is Frankel's native legacy source-0 frontend.  Retarget the same
# otherwise-qualified q48 speaker profile by changing only the bit index of
# cave B's source-bitmap test.  In this FLIX packet 0xE selects bit 14, 0x5
# selects bit 5, and 0x0 selects bit 0; the sink-0 and enum-7 guards remain
# byte-for-byte identical.
CAVE_GUARD_SOURCE0_Q48_PATCHES = tuple(
    Patch(
        patch.name.replace("speaker guard", "speaker source-0 guard"),
        patch.address,
        patch.before,
        bytes.fromhex("52076704")
        if patch.address == 0x4039D52C
        else patch.after,
        patch.kind,
    )
    for patch in CAVE_GUARD_Q48_PATCHES
)

# Native one-millisecond EP1 / PCM0 profile.  Retarget the original q192
# guard from source bit 14 to source bit 0, but deliberately retain cave B's
# `movi a6, 192`.  Unlike the q48 source-0 profile above, this makes the F1
# producer run once per millisecond while preserving enum 7 throughout the
# speaker pipeline.
CAVE_GUARD_SOURCE0_Q192_PATCHES = tuple(
    Patch(
        patch.name.replace("speaker guard", "speaker source-0 q192 guard"),
        patch.address,
        patch.before,
        bytes.fromhex("52076704")
        if patch.address == 0x4039D52C
        else patch.after,
        patch.kind,
    )
    for patch in CAVE_GUARD_PATCHES
)

# Native 96 kHz control profile.  Keep the same speaker/source guard, select
# enum 6, and pass a coherent 96-frame one-millisecond quantum.  The stock
# generic enum mapper at 0x403c8990 already maps enum 6 to 96 frames, so this
# profile deliberately does not patch the mapper or clamp the result.
CAVE_GUARD_NATIVE96_PATCHES = tuple(
    Patch(
        patch.name.replace("guard", "native-96 guard"),
        patch.address,
        patch.before,
        (
            bytes.fromhex("62a0600c")
            if patch.address == 0x4039D530
            else bytes.fromhex("6222448a")
            if patch.address == 0x4039D534
            else patch.after
        ),
        patch.kind,
    )
    for patch in CAVE_GUARD_PATCHES
)

# Cave C runs only in AudioHardwareSinkSpeaker::Start.  ControllerAocx has
# already selected a stock 48-frame or guarded 96/192-frame quantum.  The
# speaker bus uses one millisecond blocks, so copy that value to the TDM
# frame-rate field and multiply it by 128 (four 32-bit slots) for the
# 6.144/12.288/24.576 MHz bit clock.  This also restores the stock values on
# the next ordinary 48 kHz speaker start.
CAVE_TDM_PATCHES = (
    Patch("speaker TDM cave C word 0", 0x403D36F0, bytes.fromhex("81000000"), bytes.fromhex("812213e3"), "cave"),
    Patch("speaker TDM cave C word 1", 0x403D36F4, bytes.fromhex("00000000"), bytes.fromhex("90421142"), "cave"),
    Patch("speaker TDM cave C word 2", 0x403D36F8, bytes.fromhex("00000000"), bytes.fromhex("63a22263"), "cave"),
    Patch("speaker TDM cave C word 3", 0x403D36FC, bytes.fromhex("00000000"), bytes.fromhex("a6a2236f"), "cave"),
    Patch("speaker TDM cave C word 4", 0x403D3700, bytes.fromhex("00000000"), bytes.fromhex("0c0b0646"), "cave"),
    Patch("speaker TDM cave C word 5", 0x403D3704, bytes.fromhex("00000000"), bytes.fromhex("02000000"), "cave"),
)

# The generic enum-7 AudioHardwareSink path writes 192 frames into the speaker
# subclass after configureMixer has retained its stock 48-frame quantum.  Do
# not modify the still-partly-undecoded FLIX mapper.  Instead, clamp the final
# speaker object field at +0x1c6 immediately inside
# AudioHardwareSinkSpeaker::Start, then replay the stock TDM derivation.  The
# instructions were linked for F1 address 0x403d36f1; the first byte of the
# aligned word at 0x403d36f0 and the final two zero bytes are preserved.
CAVE_TDM_LATE_Q48_STOCK_PATCHES = (
    Patch("speaker late-q48 cave C word 0", 0x403D36F0, bytes.fromhex("81000000"), bytes.fromhex("813c0442"), "cave"),
    Patch("speaker late-q48 cave C word 1", 0x403D36F4, bytes.fromhex("00000000"), bytes.fromhex("53e32213"), "cave"),
    Patch("speaker late-q48 cave C word 2", 0x403D36F8, bytes.fromhex("00000000"), bytes.fromhex("e3904211"), "cave"),
    Patch("speaker late-q48 cave C word 3", 0x403D36FC, bytes.fromhex("00000000"), bytes.fromhex("4263a222"), "cave"),
    Patch("speaker late-q48 cave C word 4", 0x403D3700, bytes.fromhex("00000000"), bytes.fromhex("63a6a223"), "cave"),
    Patch("speaker late-q48 cave C word 5", 0x403D3704, bytes.fromhex("00000000"), bytes.fromhex("6f0c0bc6"), "cave"),
    Patch("speaker late-q48 cave C word 6", 0x403D3708, bytes.fromhex("00000000"), bytes.fromhex("44020000"), "cave"),
)

# Once the late 48-frame clamp is qualified independently, force a 192 kHz
# physical frame rate and multiply by 64 for four 16-bit slots.  This gives a
# 12.288 MHz bit clock, within the stock AoC clock source, while leaving the
# host stream at four S32 samples.
CAVE_TDM_LATE_Q48_12288_192_PATCHES = tuple(
    Patch(
        patch.name.replace("stock", "12.288 MHz/192 kHz"),
        patch.address,
        patch.before,
        (
            bytes.fromhex("53e322a0")
            if patch.address == 0x403D36F4
            else bytes.fromhex("c0a04211")
            if patch.address == 0x403D36F8
            else patch.after
        ),
        patch.kind,
    )
    for patch in CAVE_TDM_LATE_Q48_STOCK_PATCHES
)

# The 0x403d4018 speaker hook above runs after AudioHardwareSink has already
# logged and consumed its block geometry.  Intercept the earlier generic
# calculation instead.  The cave replays the stock descriptor load and
# multiply, identifies only enum 7 by its selected 192-frame value in a4,
# replaces that result with 48, stores it, and resumes at the first untouched
# instruction.  Every other generic sink retains its stock result.
# 0x403d3878 is a reviewed
# 20-byte function-padding cave distinct from the D10/D12 capture caves and
# from the speaker TDM cave at 0x403d36f1.
CAVE_EARLY_Q48_PATCHES = (
    Patch("speaker early-q48 cave word 0", 0x403D3878, bytes.fromhex("00000000"), bytes.fromhex("d20312d0"), "cave"),
    Patch("speaker early-q48 cave word 1", 0x403D387C, bytes.fromhex("00000000"), bytes.fromhex("f4d1d2a0"), "cave"),
    Patch("speaker early-q48 cave word 2", 0x403D3880, bytes.fromhex("00000000"), bytes.fromhex("c0d79401"), "cave"),
    Patch("speaker early-q48 cave word 3", 0x403D3884, bytes.fromhex("00000000"), bytes.fromhex("3c0ff252"), "cave"),
    Patch("speaker early-q48 cave word 4", 0x403D3888, bytes.fromhex("00000000"), bytes.fromhex("e30647d4"), "cave"),
)

# The base early clamp recognizes enum 7 through its 192-frame value in a4.
# Enum 6 reaches the same calculation with 96 in a4, so reuse the cave while
# changing only its comparison constant from 192 to 96.  The immediate spans
# two aligned words; Sky1 encoding proves that only byte 0 at 0x403d3880
# changes (`movi a13, 192` -> `movi a13, 96`).
CAVE_EARLY_Q48_ENUM6_PATCHES = tuple(
    Patch(
        patch.name.replace("early-q48", "enum6 early-q48"),
        patch.address,
        patch.before,
        bytes.fromhex("60d79401") if patch.address == 0x403D3880 else patch.after,
        patch.kind,
    )
    for patch in CAVE_EARLY_Q48_PATCHES
)

# Jump before the stock l8ui/mul16s/s16i sequence.  The first three bytes are
# a complete linked jump to 0x403d3878; byte 3 belongs to the now-unreachable
# multiply and is preserved so the hook remains one atomic aligned write.
EARLY_Q48_HOOK_PATCH = Patch(
    "clamp generic sink geometry before allocation/logging",
    0x403C89A0,
    bytes.fromhex("d20312d0"),
    bytes.fromhex("06b52bd0"),
    "hook",
)

# With the guarded enum-7 path using a 48-frame (quarter-millisecond) quantum,
# the speaker subclass must not derive its bus rate from that quantum.  Force
# only the first value loaded into a2 to 192; the stock shift/store sequence
# then programs 24.576 MHz and 192 kHz without touching the subclass's many
# fixed 48-frame loops and 0x180/0x300-byte buffers.
CAVE_TDM_FIXED192_PATCHES = tuple(
    Patch(
        patch.name,
        patch.address,
        patch.before,
        bytes.fromhex("8122a0c0") if patch.address == 0x403D36F0 else patch.after,
        patch.kind,
    )
    for patch in CAVE_TDM_PATCHES
)

# Enum 6 with an early 48-frame allocation clamp must not derive a 48 kHz bus
# rate from that bounded geometry.  Force only the cave's initial scalar to
# 96; the unchanged four-S32-slot shift of seven then produces a 12.288 MHz
# clock and stores a 96 kHz physical frame rate.  Sky1 encodes the replacement
# instruction at 0x403d36f1 as `movi a2, 96` (`22 a0 60`).
CAVE_TDM_FIXED96_PATCHES = tuple(
    Patch(
        patch.name.replace("derive", "force 12.288 MHz/96 kHz"),
        patch.address,
        patch.before,
        bytes.fromhex("8122a060") if patch.address == 0x403D36F0 else patch.after,
        patch.kind,
    )
    for patch in CAVE_TDM_PATCHES
)

# The AoC speaker clock divider is based on a 12.288 MHz source and rejects a
# requested 24.576 MHz clock.  Four 16-bit physical slots at 192 kHz require
# exactly 12.288 MHz, so force the rate to 192 and use a shift of six rather
# than the stock four-S32-slot shift of seven.
CAVE_TDM_12288_192_PATCHES = tuple(
    Patch(
        patch.name.replace("derive", "force 12.288 MHz/192 kHz"),
        patch.address,
        patch.before,
        (
            bytes.fromhex("8122a0c0")
            if patch.address == 0x403D36F0
            else bytes.fromhex("a0421142")
            if patch.address == 0x403D36F4
            else patch.after
        ),
        patch.kind,
    )
    for patch in CAVE_TDM_PATCHES
)

# True two-S32-slot variant for the D28 speaker path.  In addition to forcing
# a 192 kHz frame rate and its 12.288 MHz bit clock, write the aligned 32-bit
# slot-count field at speaker +0x28c before the first TDMDesignWare call at
# 0x403d4042.  The neighboring +0x290 field is untouched.  This cave was
# linked for F1 address 0x403d36f1 and returns to the first untouched
# instruction at 0x403d401e.
CAVE_TDM_12288_192_2SLOT_PATCHES = (
    Patch("speaker two-slot TDM cave C word 0", 0x403D36F0, bytes.fromhex("81000000"), bytes.fromhex("8122a0c0"), "cave"),
    Patch("speaker two-slot TDM cave C word 1", 0x403D36F4, bytes.fromhex("00000000"), bytes.fromhex("a0421142"), "cave"),
    Patch("speaker two-slot TDM cave C word 2", 0x403D36F8, bytes.fromhex("00000000"), bytes.fromhex("63a22263"), "cave"),
    Patch("speaker two-slot TDM cave C word 3", 0x403D36FC, bytes.fromhex("00000000"), bytes.fromhex("a60c2442"), "cave"),
    Patch("speaker two-slot TDM cave C word 4", 0x403D3700, bytes.fromhex("00000000"), bytes.fromhex("63a3a223"), "cave"),
    Patch("speaker two-slot TDM cave C word 5", 0x403D3704, bytes.fromhex("00000000"), bytes.fromhex("6f0c0bc6"), "cave"),
    Patch("speaker two-slot TDM cave C word 6", 0x403D3708, bytes.fromhex("00000000"), bytes.fromhex("44020000"), "cave"),
)

# Both Start branches pass `(slot_count - 4)` at caller SP+24 into the DMA
# setup helper at 0x403aa43c.  Once +0x28c is two slots, retain the same
# zero-unused-slot meaning by changing that functional subtraction to two.
# Sky1 FLIX decoding proves the complete packet at 0x403d4172 changes only
# byte 1: `ae8d...` is addi -4, `aecd...` is addi -2.  The first two bytes of
# this aligned live word belong to the preceding packet and are preserved.
SPEAKER_TDM_TWO_SLOT_UNUSED_PATCH = Patch(
    "speaker DMA unused-slot basis 4 -> 2",
    0x403D4170,
    bytes.fromhex("97d1ae8d"),
    bytes.fromhex("97d1aecd"),
    "hook",
)

# Experimental true-two-slot DMA support.  DMAStartRingTxRxDualChannel
# normally asserts that num_enabled_slots_ is four or eight, then derives the
# number of two-channel DMA groups as slots / 4.  A two-slot speaker therefore
# needs both instructions changed as one profile: accept exactly two (or the
# still-stock eight case) and derive one group with slots / 2.  Applying only
# the assertion patch is invalid because zero groups reaches the helper as
# unsigned -1 after its mandatory decrement.  These sites are deliberately
# absent from every other profile.
#
# The first patch changes the complete `beqi a7, 4, 0x403aa4d2` instruction
# spanning 0x403aa4c7..0x403aa4c9 while preserving its neighboring FLIX byte.
# The second changes only the shift immediate in the packet
# `{ s32i a11, a1, 228; srli a11, a7, 2 }` at 0x403aa4fc.
# The later descriptor-size calculations at 0x403aaad9..0x403aaaf6 and
# 0x403aab91..0x403aabb2 remain `frames * slots * 4`; that is correct for this
# two-S32 profile and yields the speaker's 48 * 2 * 4 = 384-byte block.  It is
# not correct for a four-S16 bus, which is why this profile must never include
# SPEAKER_TDM_WIDTH16_PATCHES.  The unchanged fallback test still recognizes
# eight slots, but slots / 2 is not the stock eight-slot grouping.  Safety
# therefore relies on cave C forcing +0x28c to exactly two before activation.
SPEAKER_TDM_TWO_SLOT_DMA_PATCHES = (
    Patch(
        "experimental speaker DMA enabled-slot guard 4 -> 2",
        0x403AA4C8,
        bytes.fromhex("47073f86"),
        bytes.fromhex("27073f86"),
        "hook",
    ),
    Patch(
        "experimental speaker DMA group divisor 4 -> 2",
        0x403AA4FC,
        bytes.fromhex("be31bfc9"),
        bytes.fromhex("be31bfc5"),
        "hook",
    ),
)

# AudioHardwareSinkSpeaker::Start passes the physical RX and TX slot widths to
# TDMDesignWare through two compact `movi.n a11, 32` instructions.  Four S16
# slots need both calls to receive 16.  These are selected only together with
# the 12.288/192 cave and disconnected before revert restores them.
SPEAKER_TDM_WIDTH16_PATCHES = (
    Patch("speaker TDM RX slot width 32 -> 16", 0x403D4060, bytes.fromhex("2c0b4864"), bytes.fromhex("1c0b4864"), "hook"),
    Patch("speaker TDM TX slot width 32 -> 16", 0x403D406C, bytes.fromhex("2c0b4874"), bytes.fromhex("1c0b4874"), "hook"),
)

# The enum-7 setup leaves speaker +0x298 at 192 even though the guarded early
# quantum patch makes the sink's internal block 48 frames.  Start loads that
# field at 0x403d4150 only to pass it as the descriptor-frame-count argument to
# DMAStartRingTxRxDualChannel in either branch.  Passing 192 made each patched
# S16 descriptor 192 * 4 * 2 = 0x600 bytes and generated a 24-iteration PL330
# loop.  Force this call-local argument to 48, producing 0x180-byte descriptors
# and six iterations, without changing the object field.  Sky1 confirms the three-
# byte `l32i a5,a3,0x298` becomes the same-width `movi a5,48`, while the next
# two-byte `l32i.n a8,a7,0` beginning at 0x403d4153 remains untouched.
SPEAKER_TDM_S16_DMA_Q48_FRAME_PATCH = Patch(
    "speaker S16 DMA descriptor frame count 192 -> 48",
    0x403D4150,
    bytes.fromhex("5223a688"),
    bytes.fromhex("52a03088"),
    "hook",
)

# AudioHardwareSinkSpeaker's format-copy path independently treats the same
# +0x298 physical-rate field as its block frame count.  With +0x298 kept at 192
# for the TDM hardware, its two alternative mask/copy loops each iterate over
# 192 * 4 words and can copy 0xc00 bytes into a q48-sized TX bank.  A live core
# proved the active path copied speaker+0x2c8 to the TX bank with every word
# masked by 0xffffff00, overwriting the following RX object and task stack.
# Replace only the per-iteration bounds in both alternatives with 48 frames;
# the physical-rate field and all TDM configuration remain 192 kHz.  Each
# aligned word preserves the preceding two-byte store and changes the following
# three-byte `l32i a6,a13,0x298` to same-width `movi a6,48`.
SPEAKER_TDM_S16_CPU_Q48_LOOP_PATCHES = (
    Patch(
        "speaker S16 primary format-copy loop frames 192 -> 48",
        0x403D3C80,
        bytes.fromhex("04622da6"),
        bytes.fromhex("0462a030"),
        "hook",
    ),
    Patch(
        "speaker S16 alternate format-copy loop frames 192 -> 48",
        0x403D3D6C,
        bytes.fromhex("08622da6"),
        bytes.fromhex("0862a030"),
        "hook",
    ),
)

# Native-q192 source 0 is stereo S32: one millisecond is
# 192 frames * 2 channels * 4 bytes = 0x600 bytes.  The four-S16 physical
# representation is the same size (192 * 4 slots * 2 bytes), but the speaker
# format-copy loops unconditionally multiply their local scalar by four as if
# every physical slot were an independent S32 word.  Leaving +0x298 at 192
# therefore copies 0xc00 bytes and a live source-14 trial proved that it walks
# beyond both 0x600-byte banks into the following DMA objects and speaker-task
# stack.  Supply 96 only to these two local x4 loop calculations: 96 * 4
# 32-bit words = 0x600 bytes.  This still copies all 192 stereo S32 frames and
# does not change the native producer quantum, TDM rate, or 192-frame DMA
# descriptor.  Both alternative loops must always be patched together.
SPEAKER_TDM_S16_CPU_Q96_LOOP_PATCHES = (
    Patch(
        "speaker S16 primary format-copy words 192x4 -> 96x4",
        0x403D3C80,
        bytes.fromhex("04622da6"),
        bytes.fromhex("0462a060"),
        "hook",
    ),
    Patch(
        "speaker S16 alternate format-copy words 192x4 -> 96x4",
        0x403D3D6C,
        bytes.fromhex("08622da6"),
        bytes.fromhex("0862a060"),
        "hook",
    ),
)

# Native-q192 stereo S32 contains exactly two 32-bit words per frame.  The
# speaker's two alternative format-copy paths do not consult the physical
# slot-count field at +0x28c: both load the 192-frame field at +0x298 and then
# unconditionally shift it left by two, copying four words per frame.  Merely
# forcing +0x28c to two in the Start cave therefore still copies 0xc00 bytes
# into a 0x600-byte bank.  Change only those two local word-count shifts from
# x4 to x2.  Each aligned live word preserves the preceding two-byte addi.n;
# byte 2 is the first byte of the three-byte slli and byte 4 remains stock.
SPEAKER_TDM_TWO_SLOT_CPU_X2_LOOP_PATCHES = (
    Patch(
        "speaker two-slot primary format-copy words x4 -> x2",
        0x403D3C84,
        bytes.fromhex("1b22e066"),
        bytes.fromhex("1b22f066"),
        "hook",
    ),
    Patch(
        "speaker two-slot alternate format-copy words x4 -> x2",
        0x403D3D70,
        bytes.fromhex("1b33e066"),
        bytes.fromhex("1b33f066"),
        "hook",
    ),
)

# The native-q192 worker copies one complete 0x600-byte stereo-S32 block, but
# the stock processing tail still commits and notifies only the q48-sized
# 0x180 bytes. That advances the host ring at exactly one quarter of the
# declared rate even while TDM is clocked at 192 kHz. Keep both byte counts
# coherent: the first commits the ring and the second notifies downstream.
SPEAKER_Q192_COMMIT_BYTES_PATCHES = (
    Patch(
        "speaker q192 ring commit bytes 0x180 -> 0x600",
        0x403D3E1C,
        bytes.fromhex("20c2a180"),
        bytes.fromhex("20c2a600"),
        "hook",
    ),
    Patch(
        "speaker q192 downstream notify bytes 0x180 -> 0x600",
        0x403D3E2C,
        bytes.fromhex("61c2a180"),
        bytes.fromhex("61c2a600"),
        "hook",
    ),
)

# Two setup paths also program the speaker worker's bank/DMA byte length.  If
# they retain the stock 0x180-byte q48 value while the native-q192 source path
# consumes 0x600-byte stereo-S32 blocks, the hardware sink reports a periodic
# "expected 384, available 768" overrun and the host ring still advances in
# 0x180-byte units.  Keep both object initializers at the same 0x600-byte
# quantum as the worker commit and downstream notification above.  The second
# immediate straddles two aligned words, so both words are independently
# guarded.
SPEAKER_Q192_BUFFER_LENGTH_PATCHES = (
    Patch(
        "speaker q192 primary buffer bytes 0x180 -> 0x600",
        0x403D3A34,
        bytes.fromhex("a1808198"),
        bytes.fromhex("a6008198"),
        "hook",
    ),
    Patch(
        "speaker q192 alternate buffer bytes low word",
        0x403D3A40,
        bytes.fromhex("386bc2a1"),
        bytes.fromhex("386bc2a6"),
        "hook",
    ),
    Patch(
        "speaker q192 alternate buffer bytes high word",
        0x403D3A44,
        bytes.fromhex("808195ee"),
        bytes.fromhex("008195ee"),
        "hook",
    ),
)

# MixCreator::ReadFromSram receives the source-frame count in a3.  The stock
# speaker worker asks for 48 frames even after the sink/TDM geometry is raised
# to 192, so D0 advances at one quarter rate.  This guarded prologue trampoline
# changes only calls whose frame argument is exactly 48; all other users fall
# through unchanged.  The hook is connected only after the complete cave is
# present and is removed first on revert.
SPEAKER_Q192_SOURCE_READ_PATCHES = (
    Patch(
        "speaker q192 source-read cave word 0",
        0x403C9454,
        bytes.fromhex("00000000"),
        bytes.fromhex("36810082"),
        "cave",
    ),
    Patch(
        "speaker q192 source-read cave word 1",
        0x403C9458,
        bytes.fromhex("00000000"),
        bytes.fromhex("a0308793"),
        "cave",
    ),
    Patch(
        "speaker q192 source-read cave word 2",
        0x403C945C,
        bytes.fromhex("00000000"),
        bytes.fromhex("02e03311"),
        "cave",
    ),
    Patch(
        "speaker q192 source-read cave word 3",
        0x403C9460,
        bytes.fromhex("00000000"),
        bytes.fromhex("c6970000"),
        "cave",
    ),
    Patch(
        "speaker q192 source-read 48 -> 192 trampoline",
        0x403C96C0,
        bytes.fromhex("3681005e"),
        bytes.fromhex("0664ff5e"),
        "hook",
    ),
)

# DMAStartRingTxRxDualChannel is specialized for S32 slots in this firmware.
# In addition to the two descriptor lengths below, it emits DMA microcode
# address advances/rewinds by passing `(num_enabled_slots_ << 2)` as the byte
# count to the builder at 0x403a0250.  A four-S16 bus needs every one of those
# byte counts changed to `num_enabled_slots_ << 1`.  Stock Start passes
# `(num_enabled_slots_ - 4)` as the ninth argument, so four slots make the
# helper's local `a5` zero.  That selects the setup at 0x403aa735 and the five
# shifts at 0x403aa751..0x403aa7ad before converging on 0x403aa7c4.  The common
# initial/loop shifts at 0x403aa568/0x403aa580 execute too.  The alternate
# nonzero-a5 branch at 0x403aa663..0x403aa70d is patched as well, keeping the
# helper byte-width coherent whichever branch is selected.
#
# The last two FLIX packets calculate the final microcode stride and the RX/TX
# descriptor byte lengths.  With the unchanged 48-frame quantum and four S16
# slots, both descriptor +0x14 fields become 48 * 4 * 2 = 384 bytes, matching
# the speaker's fixed internal block instead of the corrupting 768 bytes.
# Every patch changes only a shift immediate; raw stock words and before/after
# Sky1 disassembly were verified against Frankel CP2A.260805.005.
SPEAKER_TDM_S16_DMA_BYTE_COUNT_PATCHES = (
    # Common initial/loop slot-byte counts.
    Patch("speaker S16 DMA common initial byte count", 0x403AA568, bytes.fromhex("ee11a997"), bytes.fromhex("ee11ad97"), "hook"),
    Patch("speaker S16 DMA common loop byte count", 0x403AA580, bytes.fromhex("6e96b87f"), bytes.fromhex("6e96bc7f"), "hook"),
    # Alternate nonzero-a5 branch.
    Patch("speaker S16 DMA nonzero path byte count 0", 0x403AA660, bytes.fromhex("060c1be0"), bytes.fromhex("060c1bf0"), "hook"),
    Patch("speaker S16 DMA nonzero path byte count 1", 0x403AA684, bytes.fromhex("1be0c811"), bytes.fromhex("1bf0c811"), "hook"),
    Patch("speaker S16 DMA nonzero path byte count 2", 0x403AA6A4, bytes.fromhex("060c1be0"), bytes.fromhex("060c1bf0"), "hook"),
    Patch("speaker S16 DMA nonzero path byte count 3", 0x403AA6C8, bytes.fromhex("1be0c811"), bytes.fromhex("1bf0c811"), "hook"),
    Patch("speaker S16 DMA nonzero path byte count 4", 0x403AA6E8, bytes.fromhex("060c1be0"), bytes.fromhex("060c1bf0"), "hook"),
    Patch("speaker S16 DMA nonzero path byte count 5", 0x403AA70C, bytes.fromhex("1be0c811"), bytes.fromhex("1bf0c811"), "hook"),
    # Zero-a5 branch selected by stock Start's four-slot speaker call.
    Patch("speaker S16 DMA zero-path setup byte count", 0x403AA734, bytes.fromhex("016e96b8"), bytes.fromhex("016e96bc"), "hook"),
    Patch("speaker S16 DMA zero path byte count 0", 0x403AA750, bytes.fromhex("1be0c811"), bytes.fromhex("1bf0c811"), "hook"),
    Patch("speaker S16 DMA zero path byte count 1", 0x403AA768, bytes.fromhex("e0c81165"), bytes.fromhex("f0c81165"), "hook"),
    Patch("speaker S16 DMA zero path byte count 2", 0x403AA77C, bytes.fromhex("060c1be0"), bytes.fromhex("060c1bf0"), "hook"),
    Patch("speaker S16 DMA zero path byte count 3", 0x403AA794, bytes.fromhex("0c1be0c8"), bytes.fromhex("0c1bf0c8"), "hook"),
    Patch("speaker S16 DMA zero path byte count 4", 0x403AA7AC, bytes.fromhex("1be0c811"), bytes.fromhex("1bf0c811"), "hook"),
    # Both alternatives converge before this final slot-byte-count use.
    Patch("speaker S16 DMA common final byte count", 0x403AA7C4, bytes.fromhex("4eff7923"), bytes.fromhex("4eff7d23"), "hook"),
    Patch("speaker S16 DMA effective-slot byte stride", 0x403AA868, bytes.fromhex("7e41a81b"), bytes.fromhex("7e41ac1b"), "hook"),
)

SPEAKER_TDM_S16_DMA_DESCRIPTOR_PATCHES = (
    Patch("speaker S16 DMA TX descriptor length", 0x403AAAF0, bytes.fromhex("5e93a913"), bytes.fromhex("5e93ad13"), "hook"),
    Patch("speaker S16 DMA RX descriptor length", 0x403AABAC, bytes.fromhex("fe94a98f"), bytes.fromhex("fe94ad8f"), "hook"),
)

# The PL330 channel-control words independently describe each side of the TX
# and RX bursts.  The address/descriptor edits above are insufficient while
# those CCR builders still describe 16-byte S32 bursts: a live q48 core showed
# 70 TX completions but 40,388 RX completions in under half a second.  Keep
# each four-slot transfer at eight bytes by changing TX from 1x16 -> 4x4 to
# 1x8 -> 4x2, and RX from 4x4 -> 4x4 to 4x2 -> 4x2.  The resulting generated
# CCR values are 0x000cc007 (TX) and 0x000cc033 (RX).
SPEAKER_TDM_S16_DMA_CCR_PATCHES = (
    Patch(
        "speaker S16 DMA TX source burst width 16 -> 8 bytes",
        0x403AA510,
        bytes.fromhex("a1130081"),
        bytes.fromhex("a10f0081"),
        "hook",
    ),
    Patch(
        "speaker S16 DMA TX destination slot width 4 -> 2 bytes",
        0x403AA520,
        bytes.fromhex("f9213911"),
        bytes.fromhex("f921f911"),
        "hook",
    ),
    Patch(
        "speaker S16 DMA RX source slot width 4 -> 2 bytes",
        0x403AA82C,
        bytes.fromhex("02000be0"),
        bytes.fromhex("020007e0"),
        "hook",
    ),
    Patch(
        "speaker S16 DMA RX destination slot width 4 -> 2 bytes",
        0x403AA840,
        bytes.fromhex("2139117e"),
        bytes.fromhex("2199117e"),
        "hook",
    ),
)

# The first S16 trial kept every burst four beats wide by shrinking the TDM
# peripheral access itself to 16 bits.  It prepared without corrupting the
# speaker object but never received a first DMA completion.  DesignWare's TDM
# FIFO is a 32-bit MMIO register even when each physical slot is 16 bits.
# Preserve eight bytes per frame while restoring 32-bit peripheral beats:
# TX is one 8-byte memory beat -> two 4-byte FIFO beats; RX is the exact
# inverse, two 4-byte FIFO beats -> one 8-byte memory beat.  The resulting
# CCRs are 0x00054007 and 0x0001c015.  The source/destination edits below were
# decoded as complete Sky1 FLIX packets; the retired halfword MMIO width sites
# at 0x403aa520/0x403aa840 are deliberately absent.
SPEAKER_TDM_S16_DMA_FIFO32_CCR_PATCHES = (
    SPEAKER_TDM_S16_DMA_CCR_PATCHES[0],
    Patch(
        "speaker S16 DMA TX FIFO burst length 4 -> 2",
        0x403AA534,
        bytes.fromhex("726100a5"),
        bytes.fromhex("326100a5"),
        "hook",
    ),
    Patch(
        "speaker S16 DMA RX memory width 4 -> 8 bytes",
        0x403AA82C,
        bytes.fromhex("02000be0"),
        bytes.fromhex("03000be0"),
        "hook",
    ),
    Patch(
        "speaker S16 DMA RX FIFO burst length 4 -> 2",
        0x403AA84C,
        bytes.fromhex("990dc972"),
        bytes.fromhex("8505d172"),
        "hook",
    ),
    Patch(
        "speaker S16 DMA RX memory burst length 4 -> 1",
        0x403AA854,
        bytes.fromhex("216901a5"),
        bytes.fromhex("219901a5"),
        "hook",
    ),
)

SPEAKER_TDM_S16_DMA_PATCHES = (
    SPEAKER_TDM_S16_DMA_BYTE_COUNT_PATCHES
    + SPEAKER_TDM_S16_DMA_CCR_PATCHES
    + SPEAKER_TDM_S16_DMA_DESCRIPTOR_PATCHES
)

SPEAKER_TDM_S16_DMA_FIFO32_PATCHES = (
    SPEAKER_TDM_S16_DMA_BYTE_COUNT_PATCHES
    + SPEAKER_TDM_S16_DMA_FIFO32_CCR_PATCHES
    + SPEAKER_TDM_S16_DMA_DESCRIPTOR_PATCHES
)

# The generic AudioHardwareSink enum-7 mapper otherwise writes a 192-frame
# block into speaker +0x1c6 before AudioHardwareSinkSpeaker::Start.  This FLIX
# slot encodes frame count divided by eight: stock 0x18 reports 192 frames, a
# live 0x04 trial reported 32, and exact 48 is therefore 0x06.  Clamp only this
# field while leaving the native enum-7 rate decode at 192 kHz.  Treat it as a
# pre-activation patch: enum 7 is unreachable until the final configureMixer
# hook is connected, and revert removes that hook before restoring this word.
GENERIC_ENUM7_Q48_PATCH = Patch(
    "generic enum-7 block frames 192 -> 48",
    0x403C8978,
    bytes.fromhex("18801446"),
    bytes.fromhex("06801446"),
    "cave",
)

# Both hook instructions fit wholly in one naturally aligned 32-bit write.
# Their fourth bytes are unreachable after the jump and remain stock.
HOOK_PATCHES = (
    Patch("route rate/quantum store through cave A", 0x4038BA78, bytes.fromhex("9e8bdad6"), bytes.fromhex("061bfdd6"), "hook"),
    Patch("derive speaker TDM rate and clock from quantum in cave C", 0x403D4018, bytes.fromhex("aee3bc42"), bytes.fromhex("46b5fd42"), "hook"),
    # Activation hook last: caves A/C are stock-equivalent while cave B has
    # not selected the profile's guarded non-stock rate and quantum.
    Patch("route configureMixer guard through cave B", 0x4038BA4C, bytes.fromhex("8e548f4d"), bytes.fromhex("46b4464d"), "hook"),
)

CAVE_PATCHES = CAVE_RATE_PATCHES + CAVE_GUARD_PATCHES + CAVE_TDM_PATCHES
PATCHES = CAVE_PATCHES + HOOK_PATCHES

# A normal data-pointer call through CMD 0x016c is the qualified cold F1
# dispatch point.  Temporarily redirect it to the WUQI whole-I-cache
# invalidator after every apply and revert, then restore the stock pointer.
# The invalidator returns 64 after invalidating all cache lines and ISYNC.
CACHE_FLUSH_DISPATCH = Patch(
    "HD Mic gain dispatch -> whole F1 I-cache invalidator",
    0x4038EA50,
    bytes.fromhex("c0c83d40"),
    bytes.fromhex("e06d4840"),
    "transient",
)


def integer(value: str) -> int:
    return int(value, 0)


def parse_args() -> argparse.Namespace:
    repository = pathlib.Path(__file__).resolve().parents[2]
    parser = argparse.ArgumentParser(
        description="Guard and apply a volatile Frankel high-rate speaker AoC patch"
    )
    parser.add_argument(
        "action", choices=("apply", "revert", "check-stock", "check-patched")
    )
    parser.add_argument(
        "--adb",
        type=pathlib.Path,
        default=repository / "work/toolchains/platform-tools/adb",
    )
    parser.add_argument("--adb-server-port", type=int, default=5038)
    parser.add_argument("--serial")
    parser.add_argument("--counter", type=integer)
    parser.add_argument(
        "--profile",
        choices=(
            "full",
            "stock-equivalent",
            "tdm-cave-stock-values",
            "enum7-q48-fixed-tdm",
            "enum6-q96-tdm12288-96-s32",
            "enum6-early-q48-tdm12288-96-s32",
            "enum7-q48-tdm12288-192-s16",
            "enum7-late-q48-stock-tdm",
            "enum7-late-q48-tdm12288-192-s16",
            "enum7-early-q48-no-tdm",
            "experimental-enum7-early-q48-tdm12288-192-2xs32-dma",
            "experimental-enum7-early-q48-tdm12288-192-4xs16-dma",
            SOURCE5_PROFILE,
            SOURCE5_Q192_2SLOT_PROFILE,
            SOURCE0_PROFILE,
            SOURCE0_2SLOT_PROFILE,
            SOURCE0_4S32_PROFILE,
            SOURCE0_Q192_4S32_PROFILE,
            SOURCE0_Q192_2SLOT_PROFILE,
            SOURCE0_Q192_4S16_PROFILE,
            SOURCE0_Q192_4S16_FIFO32_PROFILE,
            "experimental-enum7-q192-tdm12288-192-4xs16-dma",
            "enum7-early-q48-tdm12288-192-s16",
            "enum7-q48-no-tdm",
            "enum7-q192-no-tdm",
        ),
        default="enum7-q48-no-tdm",
        help=(
            "explicit hardware-isolation profile; the default is the "
            "firmware-audited 48-frame/192-kHz sink control without a TDM hook; "
            "the experimental two-slot DMA profile is valid only while its "
            "cave forces exactly two S32 slots"
        ),
    )
    parser.add_argument(
        "--allow-active-playback",
        action="store_true",
        help=(
            "permit a deliberate patch while the selected playback PCM is not "
            "closed"
        ),
    )
    parser.add_argument(
        "--allow-incomplete-boot",
        action="store_true",
        help=(
            "permit an early-boot hardware trial before sys.boot_completed=1; "
            "all other Frankel, build, root, device-node, and PCM-idle guards remain"
        ),
    )
    parser.add_argument(
        "--minimal-traffic",
        action="store_true",
        help=(
            "opt in to grouped before/after snapshots and exactly one "
            "unverified SET command per changed word; this preserves all "
            "profile guards and final verification while avoiding the "
            "hundreds of diagnostic commands produced by per-word "
            "dump/set/dump"
        ),
    )
    parser.add_argument(
        "--set-delay-ms",
        type=int,
        default=0,
        help=(
            "sleep this many milliseconds after each profile SET in "
            "--minimal-traffic mode so A32's shared diagnostic work queue can "
            "drain (default: 0)"
        ),
    )
    args = parser.parse_args()
    if args.set_delay_ms < 0 or args.set_delay_ms > 5000:
        parser.error("--set-delay-ms must be between 0 and 5000")
    if args.set_delay_ms and not args.minimal_traffic:
        parser.error("--set-delay-ms requires --minimal-traffic")
    return args


def adb_text(transport: AocFactoryDiag, *arguments: str) -> str:
    result = transport.run(*arguments)
    return result.stdout.decode(errors="replace").strip()


def playback_status_for_profile(profile: str) -> str:
    """Return the ALSA status node belonging to the profile's source."""

    return PROFILE_PLAYBACK_STATUS.get(profile, PLAYBACK_STATUS)


def preflight(
    transport: AocFactoryDiag,
    allow_active_playback: bool,
    allow_incomplete_boot: bool = False,
    playback_status_path: str = PLAYBACK_STATUS,
) -> None:
    state = adb_text(transport, "get-state")
    if state != "device":
        raise RuntimeError(f"ADB target is not online: {state!r}")
    device = adb_text(transport, "shell", "getprop", "ro.product.device")
    vendor_build = adb_text(transport, "shell", "getprop", "ro.vendor.build.id")
    boot_completed = adb_text(transport, "shell", "getprop", "sys.boot_completed")
    if device != EXPECTED_DEVICE:
        raise RuntimeError(f"refusing non-Frankel target ({device!r})")
    if vendor_build != EXPECTED_VENDOR_BUILD_ID:
        raise RuntimeError(
            f"refusing unreviewed vendor build {vendor_build!r}; "
            f"expected {EXPECTED_VENDOR_BUILD_ID!r}"
        )
    if boot_completed != "1" and not allow_incomplete_boot:
        raise RuntimeError("Frankel has not completed boot")
    uid = adb_text(transport, "shell", "su", "0", "id", "-u")
    if uid != "0":
        raise RuntimeError(f"root shell is required (su 0 uid={uid!r})")
    for mode, path in (
        ("-r", "/dev/acd-factory_diag"),
        ("-w", "/dev/acd-factory_diag"),
        ("-r", "/dev/acd-debug"),
    ):
        result = transport.run("shell", "su", "0", "test", mode, path, check=False)
        if result.returncode:
            raise RuntimeError(f"required device node check failed: test {mode} {path}")
    status_result = transport.run(
        "shell", "su", "0", "cat", playback_status_path, check=False
    )
    playback_status = (
        status_result.stdout.decode(errors="replace").strip()
        if status_result.returncode == 0
        else "unavailable"
    )
    if (
        playback_status == "unavailable"
        and playback_status_path == "/proc/asound/card0/pcm5p/sub0/status"
        and not allow_active_playback
    ):
        # This kernel omits PCM proc status. The device helper establishes
        # exclusive D5 ownership directly through ALSA instead.
        transport.run("shell", "/vendor/bin/frankel_aoc_speaker_patch", "check-playback-closed")
        playback_status = "closed"
    if playback_status != "closed" and not allow_active_playback:
        raise RuntimeError(
            f"playback idleness at {playback_status_path} is not established "
            f"({playback_status!r}); "
            "stop playback or pass --allow-active-playback deliberately"
        )


def classify(actual: bytes, patch: Patch) -> str:
    if actual == patch.before:
        return "stock"
    if actual == patch.after:
        return "patched"
    raise ValueError(
        f"{patch.name}: unexpected bytes at 0x{patch.address:08x}: "
        f"{actual.hex()} (stock {patch.before.hex()}, patched {patch.after.hex()})"
    )


def read_states(
    transport: AocFactoryDiag, patches: tuple[Patch, ...]
) -> dict[Patch, str]:
    states: dict[Patch, str] = {}
    for patch in patches:
        actual = transport.dump(patch.address, 4)
        state = classify(actual, patch)
        states[patch] = state
        print(f"{state:7s} 0x{patch.address:08x} {actual.hex()}  {patch.name}")
    return states


MAX_GROUPED_DUMP_BYTES = 256


def grouped_dump_ranges(patches: tuple[Patch, ...]) -> tuple[tuple[int, int], ...]:
    """Cover patch words with the fewest greedy <=256-byte read ranges."""

    addresses = sorted({patch.address for patch in patches})
    ranges: list[tuple[int, int]] = []
    if not addresses:
        return ()
    start = addresses[0]
    end = start + 4
    for address in addresses[1:]:
        if address + 4 - start <= MAX_GROUPED_DUMP_BYTES:
            end = address + 4
        else:
            ranges.append((start, end - start))
            start = address
            end = address + 4
    ranges.append((start, end - start))
    return tuple(ranges)


def read_patch_words_grouped(
    transport: AocFactoryDiag, patches: tuple[Patch, ...]
) -> dict[int, bytes]:
    """Read each requested patch word using grouped diagnostic dumps."""

    by_address: dict[int, Patch] = {}
    for patch in patches:
        previous = by_address.setdefault(patch.address, patch)
        if previous.before != patch.before:
            raise ValueError(
                f"conflicting stock guards at 0x{patch.address:08x}"
            )
    words: dict[int, bytes] = {}
    for start, size in grouped_dump_ranges(patches):
        data = transport.dump(start, size)
        if len(data) != size:
            raise RuntimeError(
                f"short grouped AoC dump at 0x{start:08x}: "
                f"got {len(data)}, expected {size}"
            )
        for address in by_address:
            if start <= address and address + 4 <= start + size:
                offset = address - start
                words[address] = data[offset : offset + 4]
    missing = sorted(set(by_address) - set(words))
    if missing:
        raise RuntimeError(
            "grouped AoC dump omitted patch word(s): "
            + ", ".join(f"0x{address:08x}" for address in missing)
        )
    return words


def profile_patches(profile: str) -> tuple[Patch, ...]:
    rate_hook, tdm_hook, activation_hook = HOOK_PATCHES
    if profile == "full":
        return PATCHES
    if profile == "stock-equivalent":
        return CAVE_RATE_PATCHES + CAVE_TDM_PATCHES + (rate_hook, tdm_hook)
    if profile == "tdm-cave-stock-values":
        return CAVE_TDM_PATCHES + (tdm_hook,)
    if profile == "enum7-q48-fixed-tdm":
        return (
            CAVE_RATE_PATCHES
            + CAVE_GUARD_Q48_PATCHES
            + CAVE_TDM_FIXED192_PATCHES
            + (GENERIC_ENUM7_Q48_PATCH,)
            + (rate_hook, tdm_hook, activation_hook)
        )
    if profile == "enum6-q96-tdm12288-96-s32":
        return (
            CAVE_RATE_PATCHES
            + CAVE_GUARD_NATIVE96_PATCHES
            + CAVE_TDM_PATCHES
            + (rate_hook, tdm_hook, activation_hook)
        )
    if profile == "enum6-early-q48-tdm12288-96-s32":
        return (
            CAVE_RATE_PATCHES
            + CAVE_GUARD_NATIVE96_PATCHES
            + CAVE_EARLY_Q48_ENUM6_PATCHES
            + CAVE_TDM_FIXED96_PATCHES
            + (EARLY_Q48_HOOK_PATCH, rate_hook, tdm_hook, activation_hook)
        )
    if profile == "enum7-q48-tdm12288-192-s16":
        return (
            CAVE_RATE_PATCHES
            + CAVE_GUARD_Q48_PATCHES
            + CAVE_TDM_12288_192_PATCHES
            + SPEAKER_TDM_WIDTH16_PATCHES
            + (GENERIC_ENUM7_Q48_PATCH,)
            + (rate_hook, tdm_hook, activation_hook)
        )
    if profile == "enum7-late-q48-stock-tdm":
        return (
            CAVE_RATE_PATCHES
            + CAVE_GUARD_Q48_PATCHES
            + CAVE_TDM_LATE_Q48_STOCK_PATCHES
            + (rate_hook, tdm_hook, activation_hook)
        )
    if profile == "enum7-late-q48-tdm12288-192-s16":
        return (
            CAVE_RATE_PATCHES
            + CAVE_GUARD_Q48_PATCHES
            + CAVE_TDM_LATE_Q48_12288_192_PATCHES
            + SPEAKER_TDM_WIDTH16_PATCHES
            + (rate_hook, tdm_hook, activation_hook)
        )
    if profile == "enum7-early-q48-no-tdm":
        return (
            CAVE_RATE_PATCHES
            + CAVE_GUARD_Q48_PATCHES
            + CAVE_EARLY_Q48_PATCHES
            + (EARLY_Q48_HOOK_PATCH, rate_hook, activation_hook)
        )
    if profile == "experimental-enum7-early-q48-tdm12288-192-2xs32-dma":
        return (
            CAVE_RATE_PATCHES
            + CAVE_GUARD_Q48_PATCHES
            + CAVE_EARLY_Q48_PATCHES
            + CAVE_TDM_12288_192_2SLOT_PATCHES
            + (
                EARLY_Q48_HOOK_PATCH,
                rate_hook,
            )
            + SPEAKER_TDM_TWO_SLOT_DMA_PATCHES
            + (
                SPEAKER_TDM_TWO_SLOT_UNUSED_PATCH,
                tdm_hook,
                activation_hook,
            )
        )
    if profile == "experimental-enum7-early-q48-tdm12288-192-4xs16-dma":
        return (
            CAVE_RATE_PATCHES
            + CAVE_GUARD_Q48_PATCHES
            + CAVE_EARLY_Q48_PATCHES
            + CAVE_TDM_12288_192_PATCHES
            + SPEAKER_TDM_WIDTH16_PATCHES
            + SPEAKER_TDM_S16_CPU_Q48_LOOP_PATCHES
            + (SPEAKER_TDM_S16_DMA_Q48_FRAME_PATCH,)
            + SPEAKER_TDM_S16_DMA_PATCHES
            + (
                EARLY_Q48_HOOK_PATCH,
                rate_hook,
                tdm_hook,
                activation_hook,
            )
        )
    if profile == SOURCE5_PROFILE:
        return (
            CAVE_RATE_PATCHES
            + CAVE_GUARD_SOURCE5_Q48_PATCHES
            + CAVE_EARLY_Q48_PATCHES
            + CAVE_TDM_12288_192_PATCHES
            + SPEAKER_TDM_WIDTH16_PATCHES
            + SPEAKER_TDM_S16_CPU_Q48_LOOP_PATCHES
            + (SPEAKER_TDM_S16_DMA_Q48_FRAME_PATCH,)
            + SPEAKER_TDM_S16_DMA_PATCHES
            + (
                EARLY_Q48_HOOK_PATCH,
                rate_hook,
                tdm_hook,
                activation_hook,
            )
        )
    if profile == SOURCE5_Q192_2SLOT_PROFILE:
        # Same selected words as the boot helper: period1 scheduling,
        # complete source-copy/advance, packed stereo, balanced DMA bursts,
        # and both in-place endpoint getters. Boot-time dynamic allocation
        # and the TX block extent must already have been established.
        return tuple(
            Patch(name, address, bytes.fromhex(before), bytes.fromhex(after), kind)
            for name, address, before, after, kind in NATIVE_SOURCE5_Q192_WORDS
        )
    if profile == SOURCE0_PROFILE:
        return (
            CAVE_RATE_PATCHES
            + CAVE_GUARD_SOURCE0_Q48_PATCHES
            + CAVE_EARLY_Q48_PATCHES
            + CAVE_TDM_12288_192_PATCHES
            + SPEAKER_TDM_WIDTH16_PATCHES
            + SPEAKER_TDM_S16_CPU_Q48_LOOP_PATCHES
            + (SPEAKER_TDM_S16_DMA_Q48_FRAME_PATCH,)
            + SPEAKER_TDM_S16_DMA_PATCHES
            + (
                EARLY_Q48_HOOK_PATCH,
                rate_hook,
                tdm_hook,
                activation_hook,
            )
        )
    if profile == SOURCE0_2SLOT_PROFILE:
        return (
            CAVE_RATE_PATCHES
            + CAVE_GUARD_SOURCE0_Q48_PATCHES
            + CAVE_EARLY_Q48_PATCHES
            + CAVE_TDM_12288_192_2SLOT_PATCHES
            + SPEAKER_TDM_S16_CPU_Q48_LOOP_PATCHES
            + (SPEAKER_TDM_S16_DMA_Q48_FRAME_PATCH,)
            + (
                EARLY_Q48_HOOK_PATCH,
                rate_hook,
            )
            + SPEAKER_TDM_TWO_SLOT_DMA_PATCHES
            + (
                SPEAKER_TDM_TWO_SLOT_UNUSED_PATCH,
                tdm_hook,
                activation_hook,
            )
        )
    if profile == SOURCE0_4S32_PROFILE:
        return (
            CAVE_RATE_PATCHES
            + CAVE_GUARD_SOURCE0_Q48_PATCHES
            + CAVE_EARLY_Q48_PATCHES
            + CAVE_TDM_FIXED192_PATCHES
            + SPEAKER_TDM_S16_CPU_Q48_LOOP_PATCHES
            + (SPEAKER_TDM_S16_DMA_Q48_FRAME_PATCH,)
            + (
                EARLY_Q48_HOOK_PATCH,
                rate_hook,
                tdm_hook,
                activation_hook,
            )
        )
    if profile == SOURCE0_Q192_4S32_PROFILE:
        # Keep native 192-frame (one-millisecond) producer geometry and the
        # stock four-S32 speaker data path.  Cave C derives 192 kHz and a
        # 24.576 MHz bit clock directly from that quantum, so no q48 clamps,
        # S16 width conversions, or DMA frame-count rewrites belong here.
        return (
            CAVE_RATE_PATCHES
            + CAVE_GUARD_SOURCE0_Q192_PATCHES
            + CAVE_TDM_PATCHES
            + (
                rate_hook,
                tdm_hook,
                activation_hook,
            )
        )
    if profile == SOURCE0_Q192_2SLOT_PROFILE:
        # Keep native 192-frame (one-millisecond) producer geometry while
        # constraining the physical bus to two S32 slots.  Cave C forces the
        # 192 kHz frame rate, 12.288 MHz clock, and two-slot object field;
        # the paired DMA edits admit exactly two slots and derive one
        # two-channel group.  The paired CPU edits change the worker's
        # independent hard-coded x4 word count to x2; they do not clamp its
        # native 192-frame scalar.  No q48 allocation or descriptor-frame
        # clamp belongs in this native-q192 profile.
        return (
            CAVE_RATE_PATCHES
            + CAVE_GUARD_SOURCE0_Q192_PATCHES
            + CAVE_TDM_12288_192_2SLOT_PATCHES
            + SPEAKER_TDM_TWO_SLOT_CPU_X2_LOOP_PATCHES
            + SPEAKER_Q192_BUFFER_LENGTH_PATCHES
            + SPEAKER_Q192_COMMIT_BYTES_PATCHES
            + SPEAKER_Q192_SOURCE_READ_PATCHES
            + (rate_hook,)
            + SPEAKER_TDM_TWO_SLOT_DMA_PATCHES
            + (
                SPEAKER_TDM_TWO_SLOT_UNUSED_PATCH,
                tdm_hook,
                activation_hook,
            )
        )
    if profile == SOURCE0_Q192_4S16_PROFILE:
        # Keep the native one-millisecond producer and descriptor at 192
        # frames.  The two local CPU-copy bounds use 96 only because their
        # following x4 converts that scalar to 384 S32 words/0x600 bytes: the
        # complete stereo-S32 source block and complete four-S16 TDM block.
        return (
            CAVE_RATE_PATCHES
            + CAVE_GUARD_SOURCE0_Q192_PATCHES
            + CAVE_TDM_12288_192_PATCHES
            + SPEAKER_TDM_WIDTH16_PATCHES
            + SPEAKER_TDM_S16_CPU_Q96_LOOP_PATCHES
            + SPEAKER_TDM_S16_DMA_PATCHES
            + (
                rate_hook,
                tdm_hook,
                activation_hook,
            )
        )
    if profile == SOURCE0_Q192_4S16_FIFO32_PROFILE:
        # Native one-millisecond geometry remains exactly 0x600 bytes at
        # every boundary.  This profile keeps 32-bit DesignWare FIFO accesses
        # and uses inverse 1x8<->2x4 bursts.  It requires the guarded speaker
        # buffer helper to rebase all four banks to 0xc00 before Start, because
        # each RingBuffer is split into two 0x600 ping-pong halves.
        return (
            CAVE_RATE_PATCHES
            + CAVE_GUARD_SOURCE0_Q192_PATCHES
            + CAVE_TDM_12288_192_PATCHES
            + SPEAKER_TDM_WIDTH16_PATCHES
            + SPEAKER_TDM_S16_CPU_Q96_LOOP_PATCHES
            + SPEAKER_TDM_S16_DMA_FIFO32_PATCHES
            + (
                rate_hook,
                tdm_hook,
                activation_hook,
            )
        )
    if profile == "experimental-enum7-q192-tdm12288-192-4xs16-dma":
        # Historical source-14 evidence profile.  It intentionally preserves
        # the original unclamped copy loops: a live trial proved that they
        # copy 0xc00 bytes across 0x600-byte banks and corrupt the following
        # DMA objects/AHWSinkSPKR stack.  Do not select this as a candidate;
        # SOURCE0_Q192_4S16_PROFILE carries the paired CPU-Q96 correction.
        return (
            CAVE_RATE_PATCHES
            + CAVE_GUARD_PATCHES
            + CAVE_TDM_12288_192_PATCHES
            + SPEAKER_TDM_WIDTH16_PATCHES
            + SPEAKER_TDM_S16_DMA_PATCHES
            + (
                rate_hook,
                tdm_hook,
                activation_hook,
            )
        )
    if profile == "enum7-early-q48-tdm12288-192-s16":
        return (
            CAVE_RATE_PATCHES
            + CAVE_GUARD_Q48_PATCHES
            + CAVE_EARLY_Q48_PATCHES
            + CAVE_TDM_12288_192_PATCHES
            + SPEAKER_TDM_WIDTH16_PATCHES
            + (
                EARLY_Q48_HOOK_PATCH,
                rate_hook,
                tdm_hook,
                activation_hook,
            )
        )
    if profile == "enum7-q48-no-tdm":
        return (
            CAVE_RATE_PATCHES
            + CAVE_GUARD_Q48_PATCHES
            + (GENERIC_ENUM7_Q48_PATCH, rate_hook, activation_hook)
        )
    if profile == "enum7-q192-no-tdm":
        return CAVE_RATE_PATCHES + CAVE_GUARD_PATCHES + (rate_hook, activation_hook)
    raise AssertionError(profile)


def unselected_site_patches(selected: tuple[Patch, ...]) -> tuple[Patch, ...]:
    selected_addresses = {patch.address for patch in selected}
    checked: set[int] = set()
    result: list[Patch] = []
    optional_live_patches = (
        (GENERIC_ENUM7_Q48_PATCH, EARLY_Q48_HOOK_PATCH)
        + SPEAKER_TDM_WIDTH16_PATCHES
        + SPEAKER_TDM_S16_CPU_Q48_LOOP_PATCHES
        + SPEAKER_TDM_S16_CPU_Q96_LOOP_PATCHES
        + SPEAKER_TDM_TWO_SLOT_CPU_X2_LOOP_PATCHES
        + (SPEAKER_TDM_S16_DMA_Q48_FRAME_PATCH,)
        + SPEAKER_TDM_S16_DMA_PATCHES
        + SPEAKER_TDM_S16_DMA_FIFO32_PATCHES
        + SPEAKER_TDM_TWO_SLOT_DMA_PATCHES
        + (SPEAKER_TDM_TWO_SLOT_UNUSED_PATCH,)
    )
    generic_mapper_addresses = {GENERIC_ENUM7_Q48_PATCH.address}
    for patch in PATCHES + optional_live_patches:
        if patch.address in selected_addresses or patch.address in checked:
            continue
        # Unreachable code-cave contents do not alter execution.  Check every
        # unselected live hook and both always-reachable generic mapper words;
        # this preserves closure while avoiding dozens of two-second diag
        # round trips for disconnected zero-filled caves.
        if patch.kind != "hook" and patch.address not in generic_mapper_addresses:
            continue
        checked.add(patch.address)
        result.append(patch)
    return tuple(result)


def require_unselected_sites_stock(
    transport: AocFactoryDiag, selected: tuple[Patch, ...]
) -> None:
    for patch in unselected_site_patches(selected):
        actual = transport.dump(patch.address, 4)
        if actual != patch.before:
            raise ValueError(
                f"unselected speaker patch site is not stock at "
                f"0x{patch.address:08x}: {actual.hex()} (expected "
                f"{patch.before.hex()})"
            )


def write_patch(transport: AocFactoryDiag, patch: Patch, action: str) -> None:
    source = patch.before if action == "apply" else patch.after
    destination = patch.after if action == "apply" else patch.before
    actual = transport.dump(patch.address, 4)
    if actual == destination:
        return
    if actual != source:
        raise ValueError(
            f"{patch.name}: changed before write at 0x{patch.address:08x}: "
            f"{actual.hex()}"
        )
    transport.write(patch.address, int.from_bytes(destination, "little"), 32)
    verified = transport.dump(patch.address, 4)
    if verified != destination:
        raise RuntimeError(
            f"write verification failed at 0x{patch.address:08x}: "
            f"got {verified.hex()}, expected {destination.hex()}"
        )
    print(
        f"write   0x{patch.address:08x} {source.hex()}->{destination.hex()}  "
        f"{patch.name}"
    )


def flush_instruction_cache(transport: AocFactoryDiag) -> None:
    """Invoke the proven whole-F1-I-cache invalidator through CMD 0x016c."""

    dispatch = transport.dump(CACHE_FLUSH_DISPATCH.address, 4)
    if dispatch != CACHE_FLUSH_DISPATCH.before:
        raise ValueError(
            "refusing cache flush with non-stock HD Mic dispatch at "
            f"0x{CACHE_FLUSH_DISPATCH.address:08x}: {dispatch.hex()}"
        )

    invocation_error: BaseException | None = None
    restore_error: BaseException | None = None
    try:
        write_patch(transport, CACHE_FLUSH_DISPATCH, "apply")
        result = transport.run(
            "shell",
            "su",
            "0",
            "sh",
            input_data=(
                'exec /system/bin/tinymix -D 0 -- "HD Mic gain (cB)" 0\n'
            ).encode(),
            check=False,
        )
        if result.returncode not in (0, 1):
            stderr = result.stderr.decode(errors="replace").strip()
            raise RuntimeError(
                "HD Mic CMD 0x016c cache-flush trigger failed with status "
                f"{result.returncode}: {stderr}"
            )
        print(
            "invoked HD Mic CMD 0x016c whole-I-cache invalidator "
            f"(tinymix status {result.returncode}, expected F1 rc=64)"
        )
    except BaseException as error:
        invocation_error = error
    try:
        actual = transport.dump(CACHE_FLUSH_DISPATCH.address, 4)
        if actual == CACHE_FLUSH_DISPATCH.after:
            write_patch(transport, CACHE_FLUSH_DISPATCH, "revert")
        elif actual != CACHE_FLUSH_DISPATCH.before:
            raise RuntimeError(
                "cache-flush dispatch changed unexpectedly before restore: "
                f"{actual.hex()}"
            )
        verified = transport.dump(CACHE_FLUSH_DISPATCH.address, 4)
        if verified != CACHE_FLUSH_DISPATCH.before:
            raise RuntimeError(
                "cache-flush dispatch restore verification failed: "
                f"{verified.hex()}"
            )
    except BaseException as error:
        restore_error = error

    if restore_error is not None:
        if invocation_error is not None:
            raise RuntimeError(
                f"cache flush failed ({invocation_error}); additionally the "
                f"dispatch restore failed ({restore_error})"
            ) from invocation_error
        raise restore_error
    if invocation_error is not None:
        raise invocation_error
    print("restored and verified the stock HD Mic dispatch pointer")


def flush_instruction_cache_minimal(transport: AocFactoryDiag) -> None:
    """Flush F1's I-cache with two SETs and one final guard read."""

    dispatch = transport.dump(CACHE_FLUSH_DISPATCH.address, 4)
    if dispatch != CACHE_FLUSH_DISPATCH.before:
        raise ValueError(
            "refusing minimal cache flush with non-stock HD Mic dispatch at "
            f"0x{CACHE_FLUSH_DISPATCH.address:08x}: {dispatch.hex()}"
        )

    invocation_error: BaseException | None = None
    restore_error: BaseException | None = None
    redirected = False
    try:
        transport.write_unverified(
            CACHE_FLUSH_DISPATCH.address,
            int.from_bytes(CACHE_FLUSH_DISPATCH.after, "little"),
            32,
        )
        redirected = True
        result = transport.run(
            "shell",
            "su",
            "0",
            "sh",
            input_data=(
                'exec /system/bin/tinymix -D 0 -- "HD Mic gain (cB)" 0\n'
            ).encode(),
            check=False,
        )
        if result.returncode not in (0, 1):
            stderr = result.stderr.decode(errors="replace").strip()
            raise RuntimeError(
                "HD Mic CMD 0x016c cache-flush trigger failed with status "
                f"{result.returncode}: {stderr}"
            )
        print(
            "invoked HD Mic CMD 0x016c whole-I-cache invalidator "
            f"(tinymix status {result.returncode}, expected F1 rc=64)"
        )
    except BaseException as error:
        invocation_error = error
    if redirected:
        try:
            transport.write_unverified(
                CACHE_FLUSH_DISPATCH.address,
                int.from_bytes(CACHE_FLUSH_DISPATCH.before, "little"),
                32,
            )
            verified = transport.dump(CACHE_FLUSH_DISPATCH.address, 4)
            if verified != CACHE_FLUSH_DISPATCH.before:
                raise RuntimeError(
                    "minimal cache-flush dispatch restore verification failed: "
                    f"{verified.hex()}"
                )
        except BaseException as error:
            restore_error = error

    if restore_error is not None:
        if invocation_error is not None:
            raise RuntimeError(
                f"minimal cache flush failed ({invocation_error}); additionally "
                f"the dispatch restore failed ({restore_error})"
            ) from invocation_error
        raise restore_error
    if invocation_error is not None:
        raise invocation_error
    print("restored and verified the stock HD Mic dispatch pointer")


def run_minimal_traffic(
    transport: AocFactoryDiag,
    patches: tuple[Patch, ...],
    action: str,
    profile: str,
    set_delay_ms: int = 0,
) -> int:
    """Run one coherent guarded profile update with bounded AoC traffic."""

    unselected = unselected_site_patches(patches)
    snapshot_sites = patches + unselected
    snapshot_ranges = grouped_dump_ranges(snapshot_sites)
    snapshot = read_patch_words_grouped(transport, snapshot_sites)

    states: dict[Patch, str] = {}
    for patch in patches:
        actual = snapshot[patch.address]
        state = classify(actual, patch)
        states[patch] = state
        print(f"{state:7s} 0x{patch.address:08x} {actual.hex()}  {patch.name}")
    for patch in unselected:
        actual = snapshot[patch.address]
        if actual != patch.before:
            raise ValueError(
                f"unselected speaker patch site is not stock at "
                f"0x{patch.address:08x}: {actual.hex()} (expected "
                f"{patch.before.hex()})"
            )

    if action.startswith("check-"):
        wanted = action.removeprefix("check-")
        if any(state != wanted for state in states.values()):
            raise ValueError(f"AoC speaker patch is not uniformly {wanted}")
        print(
            f"minimal traffic: checked {len(snapshot_sites)} sites in "
            f"{len(snapshot_ranges)} grouped dump command(s)"
        )
        return 0

    caves = tuple(patch for patch in patches if patch.kind == "cave")
    hooks = tuple(patch for patch in patches if patch.kind == "hook")
    if (
        action != "revert"
        and any(states[patch] == "patched" for patch in hooks)
        and any(states[patch] != "patched" for patch in caves)
    ):
        raise ValueError("unsafe partial state: a live hook points at an incomplete cave")

    if action == "apply":
        order = caves + hooks
        destination_state = "patched"
    else:
        order = tuple(reversed(hooks)) + tuple(reversed(caves))
        destination_state = "stock"
    changed = tuple(
        patch for patch in order if states[patch] != destination_state
    )
    for patch in changed:
        source = patch.before if action == "apply" else patch.after
        destination = patch.after if action == "apply" else patch.before
        transport.write_unverified(
            patch.address, int.from_bytes(destination, "little"), 32
        )
        print(
            f"write   0x{patch.address:08x} {source.hex()}->{destination.hex()}  "
            f"{patch.name}"
        )
        if set_delay_ms:
            time.sleep(set_delay_ms / 1000.0)

    final_ranges = grouped_dump_ranges(patches)
    final_words = read_patch_words_grouped(transport, patches)
    for patch in patches:
        actual = final_words[patch.address]
        expected = patch.after if destination_state == "patched" else patch.before
        if actual != expected:
            raise RuntimeError(
                f"minimal profile verification failed at 0x{patch.address:08x}: "
                f"got {actual.hex()}, expected {expected.hex()}"
            )
    flush_instruction_cache_minimal(transport)
    print(
        f"minimal traffic: {len(snapshot_ranges)} before-dump command(s), "
        f"{len(changed)} profile SET command(s), {len(final_ranges)} "
        "after-dump command(s), plus the bounded cache flush"
    )
    print(
        f"verified {profile} uniformly {destination_state}; "
        "live changes disappear on AoC/device reboot"
    )
    return 0


def main() -> int:
    args = parse_args()
    transport = AocFactoryDiag(
        argparse.Namespace(
            adb=args.adb,
            adb_server_port=args.adb_server_port,
            serial=args.serial,
            core=2,
            counter=args.counter,
        )
    )
    preflight(
        transport,
        args.allow_active_playback,
        args.allow_incomplete_boot,
        playback_status_for_profile(args.profile),
    )
    patches = profile_patches(args.profile)
    if args.minimal_traffic:
        return run_minimal_traffic(
            transport,
            patches,
            args.action,
            args.profile,
            args.set_delay_ms,
        )
    caves = tuple(patch for patch in patches if patch.kind == "cave")
    hooks = tuple(patch for patch in patches if patch.kind == "hook")
    require_unselected_sites_stock(transport, patches)
    states = read_states(transport, patches)

    if args.action.startswith("check-"):
        wanted = args.action.removeprefix("check-")
        if any(state != wanted for state in states.values()):
            raise ValueError(f"AoC speaker patch is not uniformly {wanted}")
        return 0

    if (
        args.action != "revert"
        and any(states[patch] == "patched" for patch in hooks)
        and any(states[patch] != "patched" for patch in caves)
    ):
        raise ValueError("unsafe partial state: a live hook points at an incomplete cave")

    if args.action == "apply":
        order = caves + hooks
        destination_state = "patched"
    else:
        order = tuple(reversed(hooks)) + tuple(reversed(caves))
        destination_state = "stock"
    for patch in order:
        write_patch(transport, patch, args.action)

    final_states = read_states(transport, patches)
    if any(state != destination_state for state in final_states.values()):
        raise RuntimeError(f"AoC speaker patch did not reach {destination_state}")
    flush_instruction_cache(transport)
    print(
        f"verified {args.profile} uniformly {destination_state}; "
        "live changes disappear on AoC/device reboot"
    )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, RuntimeError, ValueError) as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(2)
