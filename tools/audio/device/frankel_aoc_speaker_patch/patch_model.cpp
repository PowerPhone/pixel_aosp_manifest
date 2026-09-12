// SPDX-License-Identifier: Apache-2.0

#include "patch_model.h"

#include <algorithm>
#include <charconv>
#include <iomanip>
#include <limits>
#include <sstream>
#include <utility>

namespace frankel_aoc_speaker_patch {
namespace {

constexpr uint8_t kDataTypeCommand = 0;
constexpr std::size_t kHeaderSize = 8;
constexpr std::string_view kPlaybackPcmPrefix = "00-05:";
constexpr std::string_view kExpectedPlaybackPcm =
    "00-05: EP6 playback (*) :  : playback 1";

void AppendLe16(std::vector<uint8_t>* output, uint16_t value) {
  output->push_back(static_cast<uint8_t>(value));
  output->push_back(static_cast<uint8_t>(value >> 8));
}

void AppendLe32(std::vector<uint8_t>* output, uint32_t value) {
  output->push_back(static_cast<uint8_t>(value));
  output->push_back(static_cast<uint8_t>(value >> 8));
  output->push_back(static_cast<uint8_t>(value >> 16));
  output->push_back(static_cast<uint8_t>(value >> 24));
}

uint16_t ReadLe16(std::span<const uint8_t> bytes, std::size_t offset) {
  return static_cast<uint16_t>(bytes[offset]) |
         static_cast<uint16_t>(bytes[offset + 1]) << 8;
}

uint32_t ReadLe32(std::span<const uint8_t> bytes, std::size_t offset) {
  return static_cast<uint32_t>(bytes[offset]) |
         static_cast<uint32_t>(bytes[offset + 1]) << 8 |
         static_cast<uint32_t>(bytes[offset + 2]) << 16 |
         static_cast<uint32_t>(bytes[offset + 3]) << 24;
}

uint64_t ReadLe64(std::span<const uint8_t> bytes, std::size_t offset) {
  return static_cast<uint64_t>(ReadLe32(bytes, offset)) |
         static_cast<uint64_t>(ReadLe32(bytes, offset + 4)) << 32;
}

int HexDigit(char character) {
  if (character >= '0' && character <= '9') {
    return character - '0';
  }
  if (character >= 'a' && character <= 'f') {
    return character - 'a' + 10;
  }
  if (character >= 'A' && character <= 'F') {
    return character - 'A' + 10;
  }
  return -1;
}

bool IsHorizontalSpace(char character) {
  return character == ' ' || character == '\t' || character == '\r';
}

}  // namespace

const std::array<Patch, kPatchCount>& Patches() {
  // These are the complete aligned words reviewed for exactly
  // ro.vendor.build.id=CP2A.260805.005. Their order is part of the safety
  // contract: every cave precedes every live hook. This is the native-q192,
  // source-5, two-S32-slot, one-millisecond profile, including both in-place AudioEntrypoint
  // getter replacements. Do not add the retired
  // getter vtable redirects: real boot integration reached their zero-filled
  // cave as an illegal instruction during D0 PREPARE.
  static constexpr std::array<Patch, kPatchCount> kPatches = {{
      {"speaker rate cave A word 0",
       0x4038aee8,
       {0x00, 0x00, 0x00, 0x00},
       {0x92, 0x4b, 0xfc, 0xa2},
       PatchKind::kCave},
      {"speaker rate cave A word 1",
       0x4038aeec,
       {0x00, 0x00, 0x00, 0x00},
       {0x25, 0x71, 0x88, 0x41},
       PatchKind::kCave},
      {"speaker rate cave A word 2",
       0x4038aef0,
       {0x00, 0x00, 0x00, 0x00},
       {0x0c, 0x5b, 0x56, 0x28},
       PatchKind::kCave},
      {"speaker rate cave A word 3",
       0x4038aef4,
       {0x00, 0x00, 0x00, 0x00},
       {0x00, 0xb2, 0x0c, 0x8a},
       PatchKind::kCave},
      {"speaker rate cave A word 4",
       0x4038aef8,
       {0x00, 0x00, 0x00, 0x00},
       {0x62, 0x5c, 0x39, 0x46},
       PatchKind::kCave},
      {"speaker rate cave A word 5",
       0x4038aefc,
       {0x00, 0x00, 0x00, 0x00},
       {0xe1, 0x02, 0x00, 0x00},
       PatchKind::kCave},
      {"speaker source-5 q192 guard cave B word 0",
       0x4039d520,
       {0x6b, 0x00, 0x00, 0x00},
       {0x6b, 0x82, 0x14, 0x32},
       PatchKind::kCave},
      {"speaker source-5 q192 guard cave B word 1",
       0x4039d524,
       {0x00, 0x00, 0x00, 0x00},
       {0x72, 0x23, 0xda, 0x28},
       PatchKind::kCave},
      {"speaker source-5 q192 guard cave B word 2",
       0x4039d528,
       {0x00, 0x00, 0x00, 0x00},
       {0x41, 0xdc, 0x02, 0x0c},
       PatchKind::kCave},
      {"speaker source-5 q192 guard cave B word 3",
       0x4039d52c,
       {0x00, 0x00, 0x00, 0x00},
       {0x52, 0x57, 0x67, 0x09},
       PatchKind::kCave},
      {"speaker source-5 q192 guard cave B word 4",
       0x4039d530,
       {0x00, 0x00, 0x00, 0x00},
       {0x62, 0xa0, 0xc0, 0x0c},
       PatchKind::kCave},
      {"speaker source-5 q192 guard cave B word 5",
       0x4039d534,
       {0x00, 0x00, 0x00, 0x00},
       {0x12, 0x22, 0x44, 0x88},
       PatchKind::kCave},
      {"speaker source-5 q192 guard cave B word 6",
       0x4039d538,
       {0x00, 0x00, 0x00, 0x00},
       {0x0c, 0x72, 0x22, 0x44},
       PatchKind::kCave},
      {"speaker source-5 q192 period1 guard cave B word 7",
       0x4039d53c,
       {0x00, 0x00, 0x00, 0x00},
       {0x8a, 0x46, 0x44, 0xb9},
       PatchKind::kCave},
      {"speaker two-slot TDM cave C word 0",
       0x403d36f0,
       {0x81, 0x00, 0x00, 0x00},
       {0x81, 0x22, 0xa0, 0xc0},
       PatchKind::kCave},
      {"speaker two-slot TDM cave C word 1",
       0x403d36f4,
       {0x00, 0x00, 0x00, 0x00},
       {0xa0, 0x42, 0x11, 0x42},
       PatchKind::kCave},
      {"speaker two-slot TDM cave C word 2",
       0x403d36f8,
       {0x00, 0x00, 0x00, 0x00},
       {0x63, 0xa2, 0x22, 0x63},
       PatchKind::kCave},
      {"speaker two-slot TDM cave C word 3",
       0x403d36fc,
       {0x00, 0x00, 0x00, 0x00},
       {0xa6, 0x0c, 0x24, 0x42},
       PatchKind::kCave},
      {"speaker two-slot TDM cave C word 4",
       0x403d3700,
       {0x00, 0x00, 0x00, 0x00},
       {0x63, 0xa3, 0xa2, 0x23},
       PatchKind::kCave},
      {"speaker two-slot TDM cave C word 5",
       0x403d3704,
       {0x00, 0x00, 0x00, 0x00},
       {0x6f, 0x0c, 0x0b, 0xc6},
       PatchKind::kCave},
      {"speaker two-slot TDM cave C word 6",
       0x403d3708,
       {0x00, 0x00, 0x00, 0x00},
       {0x44, 0x02, 0x00, 0x00},
       PatchKind::kCave},
      {"speaker q192 source-read cave word 0",
       0x403c9454,
       {0x00, 0x00, 0x00, 0x00},
       {0x36, 0x81, 0x00, 0x82},
       PatchKind::kCave},
      {"speaker q192 source-read cave word 1",
       0x403c9458,
       {0x00, 0x00, 0x00, 0x00},
       {0xa0, 0x30, 0x87, 0x93},
       PatchKind::kCave},
      {"speaker q192 source-read cave word 2",
       0x403c945c,
       {0x00, 0x00, 0x00, 0x00},
       {0x02, 0xe0, 0x33, 0x11},
       PatchKind::kCave},
      {"speaker q192 source-read cave word 3",
       0x403c9460,
       {0x00, 0x00, 0x00, 0x00},
       {0xc6, 0x97, 0x00, 0x00},
       PatchKind::kCave},
      // The enclosing source-copy wrapper must retain 192 frames for both
      // its copy and read-pointer advance, not only its nested SRAM read.
      {"speaker source-copy q192 cave word 0", 0x403d3878,
       {0x00, 0x00, 0x00, 0x00}, {0xa2, 0x21, 0x04, 0x16}, PatchKind::kCave},
      {"speaker source-copy q192 cave word 1", 0x403d387c,
       {0x00, 0x00, 0x00, 0x00}, {0xa3, 0x0c, 0xc2, 0xa0}, PatchKind::kCave},
      {"speaker source-copy q192 cave word 2", 0x403d3880,
       {0x00, 0x00, 0x00, 0x00}, {0xc0, 0xc6, 0x2e, 0x00}, PatchKind::kCave},
      // Scoped source-5/sink-0/enum-7 accounting accompanies period1 mode.
      {"period1 expected block cave word 0", 0x40371500,
       {0x00, 0x00, 0x00, 0x00}, {0x5e, 0x15, 0xb0, 0x02}, PatchKind::kCave},
      {"period1 expected block cave word 1", 0x40371504,
       {0x00, 0x00, 0x00, 0x00}, {0x2c, 0x81, 0x56, 0x13}, PatchKind::kCave},
      {"period1 expected block cave word 2", 0x40371508,
       {0x00, 0x00, 0x00, 0x00}, {0x01, 0x92, 0xd4, 0x03}, PatchKind::kCave},
      {"period1 expected block cave word 3", 0x4037150c,
       {0x00, 0x00, 0x00, 0x00}, {0x92, 0x09, 0x8a, 0x66}, PatchKind::kCave},
      {"period1 expected block cave word 4", 0x40371510,
       {0x00, 0x00, 0x00, 0x00}, {0x79, 0x08, 0x92, 0x24}, PatchKind::kCave},
      {"period1 expected block cave word 5", 0x40371514,
       {0x00, 0x00, 0x00, 0x00}, {0xda, 0x57, 0x69, 0x02}, PatchKind::kCave},
      {"period1 expected block cave word 6", 0x40371518,
       {0x00, 0x00, 0x00, 0x00}, {0x82, 0xa6, 0x00, 0xc6}, PatchKind::kCave},
      {"period1 expected block cave word 7", 0x4037151c,
       {0x00, 0x00, 0x00, 0x00}, {0x56, 0x6d, 0x00, 0x00}, PatchKind::kCave},
      {"period1 accounting block cave word 0", 0x40371540,
       {0x00, 0x00, 0x00, 0x00}, {0x8e, 0x05, 0xa4, 0x02}, PatchKind::kCave},
      {"period1 accounting block cave word 1", 0x40371544,
       {0x00, 0x00, 0x00, 0x00}, {0x0c, 0x81, 0xb8, 0x31}, PatchKind::kCave},
      {"period1 accounting block cave word 2", 0x40371548,
       {0x00, 0x00, 0x00, 0x00}, {0x56, 0x1b, 0x01, 0xb2}, PatchKind::kCave},
      {"period1 accounting block cave word 3", 0x4037154c,
       {0x00, 0x00, 0x00, 0x00}, {0xd3, 0x03, 0xb2, 0x0b}, PatchKind::kCave},
      {"period1 accounting block cave word 4", 0x40371550,
       {0x00, 0x00, 0x00, 0x00}, {0x8a, 0x66, 0x7b, 0x08}, PatchKind::kCave},
      {"period1 accounting block cave word 5", 0x40371554,
       {0x00, 0x00, 0x00, 0x00}, {0xb2, 0x23, 0xda, 0x57}, PatchKind::kCave},
      {"period1 accounting block cave word 6", 0x40371558,
       {0x00, 0x00, 0x00, 0x00}, {0x6b, 0x02, 0x92, 0xa6}, PatchKind::kCave},
      {"period1 accounting block cave word 7", 0x4037155c,
       {0x00, 0x00, 0x00, 0x00}, {0x00, 0x86, 0x78, 0x6d}, PatchKind::kCave},
      {"speaker primary mixer frames 48 -> 192 low word", 0x403d3a78,
       {0xfe, 0x91, 0xb5, 0x83}, {0xfe, 0x91, 0xb5, 0x03}, PatchKind::kHook},
      {"speaker primary mixer frames 48 -> 192 high word", 0x403d3a7c,
       {0x01, 0x81, 0xbf, 0x0a}, {0x06, 0x81, 0xbf, 0x0a}, PatchKind::kHook},
      {"speaker primary mixer stereo stride 16 -> 8", 0x403d3b08,
       {0xae, 0x0a, 0x26, 0x39}, {0xae, 0x0a, 0x34, 0x39}, PatchKind::kHook},
      {"speaker source-copy caller 48 -> 192", 0x403d3938,
       {0xde, 0x03, 0x08, 0x46}, {0x06, 0xcf, 0xff, 0x46}, PatchKind::kHook},
      {"speaker two-slot DMA memory burst width 16 -> 8 bytes", 0x403aa510,
       {0xa1, 0x13, 0x00, 0x81}, {0xa1, 0x0f, 0x00, 0x81}, PatchKind::kHook},
      {"period1 expected-block hook word 0", 0x4038ca74,
       {0x5e, 0x15, 0xb0, 0x02}, {0x06, 0xa2, 0x92, 0xf0}, PatchKind::kHook},
      {"period1 expected-block hook word 1", 0x4038ca78,
       {0x2c, 0x81, 0xde, 0xfb}, {0x20, 0x00, 0xde, 0xfb}, PatchKind::kHook},
      {"period1 accounting-block hook word 0", 0x4038cb3c,
       {0x00, 0x8e, 0x05, 0xa4}, {0x00, 0xc6, 0x7f, 0x92}, PatchKind::kHook},
      {"period1 accounting-block hook word 1", 0x4038cb40,
       {0x02, 0x0c, 0x81, 0x3f}, {0xf0, 0x20, 0x00, 0x3f}, PatchKind::kHook},
      {"speaker two-slot primary format-copy words x4 -> x2",
       0x403d3c84,
       {0x1b, 0x22, 0xe0, 0x66},
       {0x1b, 0x22, 0xf0, 0x66},
       PatchKind::kHook},
      {"speaker two-slot alternate format-copy words x4 -> x2",
       0x403d3d70,
       {0x1b, 0x33, 0xe0, 0x66},
       {0x1b, 0x33, 0xf0, 0x66},
       PatchKind::kHook},
      {"speaker q192 primary buffer bytes 0x180 -> 0x600",
       0x403d3a34,
       {0xa1, 0x80, 0x81, 0x98},
       {0xa6, 0x00, 0x81, 0x98},
       PatchKind::kHook},
      {"speaker q192 alternate buffer bytes low word",
       0x403d3a40,
       {0x38, 0x6b, 0xc2, 0xa1},
       {0x38, 0x6b, 0xc2, 0xa6},
       PatchKind::kHook},
      {"speaker q192 alternate buffer bytes high word",
       0x403d3a44,
       {0x80, 0x81, 0x95, 0xee},
       {0x00, 0x81, 0x95, 0xee},
       PatchKind::kHook},
      {"speaker q192 ring commit bytes 0x180 -> 0x600",
       0x403d3e1c,
       {0x20, 0xc2, 0xa1, 0x80},
       {0x20, 0xc2, 0xa6, 0x00},
       PatchKind::kHook},
      {"speaker q192 downstream notify bytes 0x180 -> 0x600",
       0x403d3e2c,
       {0x61, 0xc2, 0xa1, 0x80},
       {0x61, 0xc2, 0xa6, 0x00},
       PatchKind::kHook},
      {"speaker q192 source-read 48 -> 192 trampoline",
       0x403c96c0,
       {0x36, 0x81, 0x00, 0x5e},
       {0x06, 0x64, 0xff, 0x5e},
       PatchKind::kHook},
      {"AudioEntrypoint getter A in-place word 0",
       0x403f03ac,
       {0x36, 0x41, 0x00, 0x2e},
       {0x36, 0x41, 0x00, 0x22},
       PatchKind::kHook},
      {"AudioEntrypoint getter A in-place word 1",
       0x403f03b0,
       {0x30, 0x60, 0x81, 0xe1},
       {0xa7, 0x80, 0x42, 0xa0},
       PatchKind::kHook},
      {"AudioEntrypoint getter A in-place word 2",
       0x403f03b4,
       {0x80, 0xee, 0x60, 0x5d},
       {0xc0, 0x30, 0x24, 0x93},
       PatchKind::kHook},
      {"AudioEntrypoint getter A in-place word 3",
       0x403f03b8,
       {0x10, 0xb1, 0xc9, 0x00},
       {0x1d, 0xf0, 0x00, 0x00},
       PatchKind::kHook},
      {"AudioEntrypoint getter B in-place word 0",
       0x403f03bc,
       {0x36, 0x41, 0x00, 0x2e},
       {0x36, 0x41, 0x00, 0x22},
       PatchKind::kHook},
      {"AudioEntrypoint getter B in-place word 1",
       0x403f03c0,
       {0x30, 0x60, 0x81, 0xe1},
       {0xa7, 0x80, 0x42, 0xa0},
       PatchKind::kHook},
      {"AudioEntrypoint getter B in-place word 2",
       0x403f03c4,
       {0x80, 0xee, 0x60, 0x5d},
       {0xc0, 0x30, 0x24, 0x93},
       PatchKind::kHook},
      {"AudioEntrypoint getter B in-place word 3",
       0x403f03c8,
       {0x10, 0xb1, 0xc9, 0x00},
       {0x1d, 0xf0, 0x00, 0x00},
       PatchKind::kHook},
      {"route rate/quantum store through cave A",
       0x4038ba78,
       {0x9e, 0x8b, 0xda, 0xd6},
       {0x06, 0x1b, 0xfd, 0xd6},
       PatchKind::kHook},
      {"experimental speaker DMA enabled-slot guard 4 -> 2",
       0x403aa4c8,
       {0x47, 0x07, 0x3f, 0x86},
       {0x27, 0x07, 0x3f, 0x86},
       PatchKind::kHook},
      {"experimental speaker DMA group divisor 4 -> 2",
       0x403aa4fc,
       {0xbe, 0x31, 0xbf, 0xc9},
       {0xbe, 0x31, 0xbf, 0xc5},
       PatchKind::kHook},
      {"speaker DMA unused-slot basis 4 -> 2",
       0x403d4170,
       {0x97, 0xd1, 0xae, 0x8d},
       {0x97, 0xd1, 0xae, 0xcd},
       PatchKind::kHook},
      {"derive speaker TDM rate and clock from quantum in cave C",
       0x403d4018,
       {0xae, 0xe3, 0xbc, 0x42},
       {0x46, 0xb5, 0xfd, 0x42},
       PatchKind::kHook},
      {"route configureMixer guard through cave B",
       0x4038ba4c,
       {0x8e, 0x54, 0x8f, 0x4d},
       {0x46, 0xb4, 0x46, 0x4d},
       PatchKind::kHook},
  }};
  return kPatches;
}

const Patch& A32AllocatorFallbackPatch() {
  // Aligned word at A32 0x400a114c contains `cmp r0, #0` followed by the
  // conditional branch at 0x400a114e. Only the branch displacement changes:
  // dynamic-allocation failure falls back to the existing static-freelist
  // path at 0x400a119c instead of returning error 6 immediately.
  static constexpr Patch kPatch = {
      "A32 work allocator dynamic-failure static fallback",
      0x400a114c,
      {0x00, 0x28, 0x70, 0xd0},
      {0x00, 0x28, 0x25, 0xd0},
      PatchKind::kHook,
  };
  return kPatch;
}

const StockWordRequirement& A32TimerAssertionStockWord() {
  // Retain the stock CBNZ-to-assert at 0x4009e0ce. The allocator fallback is
  // deliberately not the historical global UsfTimer callback-drop patch.
  static constexpr StockWordRequirement kRequirement = {
      "A32 UsfTimer allocation-failure assertion",
      0x4009e0cc,
      {0x8e, 0xfd, 0x90, 0xbb},
  };
  return kRequirement;
}

const std::array<StockWordRequirement, kUnselectedStockWordCount>&
UnselectedStockWords() {
  // Python require_unselected_sites_stock() checks these reachable
  // alternatives for the native-q192 two-S32-slot profile. They are closure
  // requirements, never members of the selected mutation transaction.
  static constexpr std::array<StockWordRequirement, kUnselectedStockWordCount>
      kRequirements = {{
          {"stock cache extent word 0; TX block field supplies 0x600",
           0x403d3de8, {0x55, 0x2d, 0xc9, 0x81}},
          {"stock cache extent word 1", 0x403d3dec,
           {0x5f, 0x9a, 0xe0, 0x08}},
          {"stock cache extent word 2", 0x403d3df0,
           {0x00, 0x68, 0x41, 0xc0}},
          {"literal immediately after source-5 period1 guard cave",
           0x4039d540, {0x48, 0x47, 0x00, 0x41}},
          {"stock interrupt-context cache path word 0",
           0x403d3e44,
           {0x9c, 0x81, 0x81, 0x48}},
          {"stock interrupt-context cache path word 1",
           0x403d3e48,
           {0x9a, 0xe0, 0x08, 0x00}},
          {"generic enum-7 block-frame mapper",
           0x403c8978,
           {0x18, 0x80, 0x14, 0x46}},
          {"generic early-q48 geometry clamp",
           0x403c89a0,
           {0xd2, 0x03, 0x12, 0xd0}},
          {"speaker TDM RX slot width 32 -> 16",
           0x403d4060,
           {0x2c, 0x0b, 0x48, 0x64}},
          {"speaker TDM TX slot width 32 -> 16",
           0x403d406c,
           {0x2c, 0x0b, 0x48, 0x74}},
          {"speaker S16 primary format-copy loop frames 192 -> 48",
           0x403d3c80,
           {0x04, 0x62, 0x2d, 0xa6}},
          {"speaker S16 alternate format-copy loop frames 192 -> 48",
           0x403d3d6c,
           {0x08, 0x62, 0x2d, 0xa6}},
          {"speaker S16 DMA descriptor frame count 192 -> 48",
           0x403d4150,
           {0x52, 0x23, 0xa6, 0x88}},
          {"speaker S16 DMA common initial byte count",
           0x403aa568,
           {0xee, 0x11, 0xa9, 0x97}},
          {"speaker S16 DMA common loop byte count",
           0x403aa580,
           {0x6e, 0x96, 0xb8, 0x7f}},
          {"speaker S16 DMA nonzero path byte count 0",
           0x403aa660,
           {0x06, 0x0c, 0x1b, 0xe0}},
          {"speaker S16 DMA nonzero path byte count 1",
           0x403aa684,
           {0x1b, 0xe0, 0xc8, 0x11}},
          {"speaker S16 DMA nonzero path byte count 2",
           0x403aa6a4,
           {0x06, 0x0c, 0x1b, 0xe0}},
          {"speaker S16 DMA nonzero path byte count 3",
           0x403aa6c8,
           {0x1b, 0xe0, 0xc8, 0x11}},
          {"speaker S16 DMA nonzero path byte count 4",
           0x403aa6e8,
           {0x06, 0x0c, 0x1b, 0xe0}},
          {"speaker S16 DMA nonzero path byte count 5",
           0x403aa70c,
           {0x1b, 0xe0, 0xc8, 0x11}},
          {"speaker S16 DMA zero-path setup byte count",
           0x403aa734,
           {0x01, 0x6e, 0x96, 0xb8}},
          {"speaker S16 DMA zero path byte count 0",
           0x403aa750,
           {0x1b, 0xe0, 0xc8, 0x11}},
          {"speaker S16 DMA zero path byte count 1",
           0x403aa768,
           {0xe0, 0xc8, 0x11, 0x65}},
          {"speaker S16 DMA zero path byte count 2",
           0x403aa77c,
           {0x06, 0x0c, 0x1b, 0xe0}},
          {"speaker S16 DMA zero path byte count 3",
           0x403aa794,
           {0x0c, 0x1b, 0xe0, 0xc8}},
          {"speaker S16 DMA zero path byte count 4",
           0x403aa7ac,
           {0x1b, 0xe0, 0xc8, 0x11}},
          {"speaker S16 DMA common final byte count",
           0x403aa7c4,
           {0x4e, 0xff, 0x79, 0x23}},
          {"speaker S16 DMA effective-slot byte stride",
           0x403aa868,
           {0x7e, 0x41, 0xa8, 0x1b}},
          {"speaker S16 DMA TX destination slot width",
           0x403aa520,
           {0xf9, 0x21, 0x39, 0x11}},
          {"speaker S16 DMA RX source slot width",
           0x403aa82c,
           {0x02, 0x00, 0x0b, 0xe0}},
          {"speaker S16 DMA RX destination slot width",
           0x403aa840,
           {0x21, 0x39, 0x11, 0x7e}},
          {"speaker S16 DMA TX descriptor length",
           0x403aaaf0,
           {0x5e, 0x93, 0xa9, 0x13}},
          {"speaker S16 DMA RX descriptor length",
           0x403aabac,
           {0xfe, 0x94, 0xa9, 0x8f}},
          {"speaker S16 DMA TX FIFO burst length 4 -> 2",
           0x403aa534,
           {0x72, 0x61, 0x00, 0xa5}},
          {"speaker S16 DMA RX FIFO burst length 4 -> 2",
           0x403aa84c,
           {0x99, 0x0d, 0xc9, 0x72}},
          {"speaker S16 DMA RX memory burst length 4 -> 1",
           0x403aa854,
           {0x21, 0x69, 0x01, 0xa5}},
      }};
  return kRequirements;
}

std::string Hex(std::span<const uint8_t> bytes) {
  std::ostringstream stream;
  stream << std::hex << std::setfill('0');
  for (const uint8_t byte : bytes) {
    stream << std::setw(2) << static_cast<unsigned int>(byte);
  }
  return stream.str();
}

bool ClassifyWord(const Patch& patch, std::span<const uint8_t> actual,
                  PatchState* state, std::string* error) {
  if (actual.size() != patch.before.size()) {
    *error = std::string(patch.name) + ": expected a four-byte aligned word";
    return false;
  }
  if (std::equal(actual.begin(), actual.end(), patch.before.begin())) {
    *state = PatchState::kStock;
    return true;
  }
  if (std::equal(actual.begin(), actual.end(), patch.after.begin())) {
    *state = PatchState::kPatched;
    return true;
  }
  std::ostringstream stream;
  stream << patch.name << ": unexpected bytes at 0x" << std::hex
         << std::setfill('0') << std::setw(8) << patch.address << ": "
         << Hex(actual) << " (stock " << Hex(patch.before) << ", patched "
         << Hex(patch.after) << ')';
  *error = stream.str();
  return false;
}

bool ValidateA32WorkPoolSnapshot(uint32_t pointer,
                                 std::span<const uint8_t> body,
                                 std::string* error) {
  if (pointer != kA32WorkPoolAddress) {
    std::ostringstream stream;
    stream << "A32 work-pool pointer is 0x" << std::hex << std::setfill('0')
           << std::setw(8) << pointer << "; expected 0x" << std::setw(8)
           << kA32WorkPoolAddress;
    *error = stream.str();
    return false;
  }
  if (body.size() != kA32WorkPoolGuardSize) {
    *error = "A32 work-pool snapshot has unexpected size " +
             std::to_string(body.size());
    return false;
  }
  const uint32_t free_head = ReadLe32(body, 0x1c);
  const uint32_t current = ReadLe32(body, 0x3c);
  if (free_head == 0 || current > 8) {
    std::ostringstream stream;
    stream << "unsafe A32 work-pool state: free_head=0x" << std::hex
           << std::setfill('0') << std::setw(8) << free_head << std::dec
           << ", current=" << current;
    *error = stream.str();
    return false;
  }
  return true;
}

bool ValidateA32OutputterTimerSnapshot(const A32OutputterTimerLayout& layout,
                                       uint32_t timer,
                                       std::span<const uint8_t> body,
                                       uint32_t* callback, std::string* error) {
  if (timer < kA32OutputterTimerMinimum || timer > kA32OutputterTimerMaximum ||
      (timer & 7U) != 0) {
    std::ostringstream stream;
    stream << "implausible A32 OUTPUTTER timer pointer 0x" << std::hex
           << std::setfill('0') << std::setw(8) << timer;
    *error = stream.str();
    return false;
  }
  if (body.size() != kA32OutputterTimerGuardSize) {
    *error = "A32 OUTPUTTER timer snapshot has unexpected size " +
             std::to_string(body.size());
    return false;
  }
  const std::array<std::pair<std::size_t, uint32_t>, 3> kExact = {{
      {0x00, kA32OutputterTimerVtable},
      {0x24, kA32OutputterWorker},
      {0x2c, layout.context},
  }};
  for (const auto& [offset, expected] : kExact) {
    const uint32_t actual = ReadLe32(body, offset);
    if (actual != expected) {
      std::ostringstream stream;
      stream << "A32 OUTPUTTER timer guard mismatch at 0x" << std::hex
             << std::setfill('0') << std::setw(8) << timer + offset
             << ": got 0x" << std::setw(8) << actual << ", expected 0x"
             << std::setw(8) << expected;
      *error = stream.str();
      return false;
    }
  }
  const uint64_t period = ReadLe64(body, 0x10);
  if (period != kA32OutputterPeriodNs) {
    *error = "A32 OUTPUTTER timer period is " + std::to_string(period) +
             " ns; expected " + std::to_string(kA32OutputterPeriodNs);
    return false;
  }
  *callback = ReadLe32(body, 0x28);
  if (*callback != kA32OutputterCallback &&
      *callback != kA32WholeCacheInvalidator) {
    std::ostringstream stream;
    stream << "unknown A32 OUTPUTTER callback 0x" << std::hex
           << std::setfill('0') << std::setw(8) << *callback;
    *error = stream.str();
    return false;
  }
  return true;
}

bool PlanTransition(Action action, std::span<const PatchState> states,
                    std::vector<std::size_t>* order, bool* already_complete,
                    std::string* error) {
  order->clear();
  *already_complete = false;
  if (states.size() != kPatchCount) {
    *error = "state vector has the wrong number of patch words";
    return false;
  }
  const PatchState source =
      action == Action::kApply ? PatchState::kStock : PatchState::kPatched;
  const PatchState destination =
      action == Action::kApply ? PatchState::kPatched : PatchState::kStock;
  const bool uniformly_source =
      std::all_of(states.begin(), states.end(),
                  [source](PatchState state) { return state == source; });
  const bool uniformly_destination = std::all_of(
      states.begin(), states.end(),
      [destination](PatchState state) { return state == destination; });
  if (uniformly_destination) {
    *already_complete = true;
    return true;
  }
  if (!uniformly_source) {
    *error =
        "refusing a partial patch state; reboot AoC/device to recover stock";
    return false;
  }

  if (action == Action::kApply) {
    for (std::size_t index = 0; index < kPatchCount; ++index) {
      order->push_back(index);
    }
  } else {
    // Disconnect all live hooks before erasing any cave. Reverse order
    // disconnects the source-5 activation hook before every data-path hook.
    for (std::size_t index = kPatchCount; index > kCavePatchCount; --index) {
      order->push_back(index - 1);
    }
    for (std::size_t index = kCavePatchCount; index > 0; --index) {
      order->push_back(index - 1);
    }
  }
  return true;
}

bool Uniform(std::span<const PatchState> states, PatchState wanted) {
  return !states.empty() &&
         std::all_of(states.begin(), states.end(),
                     [wanted](PatchState state) { return state == wanted; });
}

std::vector<uint8_t> BuildDumpPacket(uint8_t counter, int32_t core,
                                     uint32_t address, uint32_t size) {
  constexpr uint16_t kLength = 8 + 4 + 4 + 4;
  std::vector<uint8_t> packet;
  packet.reserve(kLength);
  packet.push_back(kDataTypeCommand);
  packet.push_back(counter);
  AppendLe16(&packet, kLength);
  AppendLe16(&packet, kCommandMemoryDump);
  AppendLe16(&packet, 0);
  AppendLe32(&packet, static_cast<uint32_t>(core));
  AppendLe32(&packet, address);
  AppendLe32(&packet, size);
  return packet;
}

std::vector<uint8_t> BuildSetWordPacket(uint8_t counter, int32_t core,
                                        uint32_t address,
                                        std::span<const uint8_t, 4> word) {
  constexpr uint16_t kLength = 8 + 4 + 4 + 4 + 1;
  std::vector<uint8_t> packet;
  packet.reserve(kLength);
  packet.push_back(kDataTypeCommand);
  packet.push_back(counter);
  AppendLe16(&packet, kLength);
  AppendLe16(&packet, kCommandMemorySet);
  AppendLe16(&packet, 0);
  AppendLe32(&packet, static_cast<uint32_t>(core));
  AppendLe32(&packet, address);
  packet.insert(packet.end(), word.begin(), word.end());
  packet.push_back(0);  // CMD_DBG_MEM_SET mode 0 is a 32-bit word.
  return packet;
}

bool ParseCommandResponse(std::span<const uint8_t> response,
                          uint8_t expected_counter, uint16_t expected_command,
                          std::string* error) {
  if (response.size() < kHeaderSize) {
    *error = "short factory_diag response: " + Hex(response);
    return false;
  }
  const uint8_t response_type = response[0];
  const uint8_t response_counter = response[1];
  const uint16_t response_length = ReadLe16(response, 2);
  const uint16_t response_command = ReadLe16(response, 4);
  const uint16_t raw_reply = ReadLe16(response, 6);
  const int32_t reply = raw_reply < 0x8000
                            ? static_cast<int32_t>(raw_reply)
                            : static_cast<int32_t>(raw_reply) - 0x10000;
  if (response_type != kDataTypeCommand ||
      response_counter != expected_counter) {
    *error = "unexpected factory_diag response type/counter: " +
             Hex(response.first(kHeaderSize));
    return false;
  }
  if (response_command != expected_command ||
      response_length != response.size()) {
    *error = "unexpected factory_diag response command/length: " +
             Hex(response.first(kHeaderSize));
    return false;
  }
  if (reply != 0) {
    std::ostringstream stream;
    stream << "AoC command 0x" << std::hex << std::setfill('0') << std::setw(4)
           << expected_command << " failed with reply " << std::dec << reply;
    *error = stream.str();
    return false;
  }
  return true;
}

bool ParseMemoryDump(std::string_view debug_output, uint32_t address,
                     std::size_t size, std::vector<uint8_t>* result,
                     std::string* error) {
  result->clear();
  if (size == 0 || size > 256) {
    *error = "memory dump size must be 1..256 bytes";
    return false;
  }
  uint32_t wanted = address;
  std::size_t cursor = 0;
  while (cursor < debug_output.size()) {
    const std::size_t prefix = debug_output.find("0x", cursor);
    if (prefix == std::string_view::npos) {
      break;
    }
    std::size_t position = prefix + 2;
    uint64_t line_address = 0;
    std::size_t address_digits = 0;
    while (position < debug_output.size()) {
      const int digit = HexDigit(debug_output[position]);
      if (digit < 0) {
        break;
      }
      if (address_digits == 8) {
        line_address = std::numeric_limits<uint64_t>::max();
        break;
      }
      line_address = (line_address << 4) | static_cast<unsigned int>(digit);
      ++address_digits;
      ++position;
    }
    if (address_digits == 0 || position >= debug_output.size() ||
        debug_output[position] != ':' ||
        line_address > std::numeric_limits<uint32_t>::max()) {
      cursor = prefix + 2;
      continue;
    }
    ++position;
    std::vector<uint8_t> line;
    while (position < debug_output.size()) {
      while (position < debug_output.size() &&
             IsHorizontalSpace(debug_output[position])) {
        ++position;
      }
      if (position >= debug_output.size() || debug_output[position] == '\n') {
        break;
      }
      const int high = HexDigit(debug_output[position]);
      const int low = position + 1 < debug_output.size()
                          ? HexDigit(debug_output[position + 1])
                          : -1;
      if (high < 0 || low < 0) {
        break;
      }
      if (position + 2 < debug_output.size() &&
          !IsHorizontalSpace(debug_output[position + 2]) &&
          debug_output[position + 2] != '\n') {
        break;
      }
      line.push_back(static_cast<uint8_t>((high << 4) | low));
      position += 2;
    }
    if (static_cast<uint32_t>(line_address) == wanted && !line.empty()) {
      result->insert(result->end(), line.begin(), line.end());
      if (result->size() >= size) {
        result->resize(size);
        return true;
      }
      if (line.size() > std::numeric_limits<uint32_t>::max() - wanted) {
        break;
      }
      wanted += static_cast<uint32_t>(line.size());
    }
    cursor = std::max(position, prefix + 2);
  }
  std::ostringstream stream;
  stream << "AoC dump output did not contain 0x" << std::hex
         << std::setfill('0') << std::setw(8) << address << '+' << std::dec
         << size;
  *error = stream.str();
  result->clear();
  return false;
}

bool ParseUnsignedDecimal(std::string_view value, uint64_t* result,
                          std::string* error) {
  if (value.empty() || value.front() == '+' || value.front() == '-') {
    *error = "AoC generation counter is not strict unsigned decimal";
    return false;
  }
  uint64_t parsed_value = 0;
  const char* begin = value.data();
  const char* end = begin + value.size();
  const auto parsed = std::from_chars(begin, end, parsed_value, 10);
  if (parsed.ec != std::errc{} || parsed.ptr != end) {
    *error = "AoC generation counter is not strict unsigned decimal: '" +
             std::string(value) + "'";
    return false;
  }
  *result = parsed_value;
  return true;
}

bool ValidatePlaybackPcmInventory(std::string_view inventory,
                                  std::string* error) {
  std::size_t matches = 0;
  std::size_t offset = 0;
  while (offset < inventory.size()) {
    const std::size_t newline = inventory.find('\n', offset);
    const std::size_t end =
        newline == std::string_view::npos ? inventory.size() : newline;
    const std::string_view line = inventory.substr(offset, end - offset);
    if (line.starts_with(kPlaybackPcmPrefix)) {
      if (line != kExpectedPlaybackPcm) {
        *error = "unexpected ALSA PCM 0,5 inventory entry: '" +
                 std::string(line) + "'";
        return false;
      }
      ++matches;
    }
    if (newline == std::string_view::npos) {
      break;
    }
    offset = newline + 1;
  }
  if (matches != 1) {
    *error = "expected exactly one ALSA inventory entry '" +
             std::string(kExpectedPlaybackPcm) + "'; found " +
             std::to_string(matches);
    return false;
  }
  return true;
}

}  // namespace frankel_aoc_speaker_patch
