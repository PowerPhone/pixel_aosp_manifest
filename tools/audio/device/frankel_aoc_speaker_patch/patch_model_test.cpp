// SPDX-License-Identifier: Apache-2.0

#include "patch_model.h"

#include <algorithm>
#include <array>
#include <cstddef>
#include <cstdint>
#include <iostream>
#include <span>
#include <string>
#include <string_view>
#include <vector>

namespace frankel_aoc_speaker_patch {
namespace {

int failures = 0;

void Expect(bool condition, std::string_view description) {
  if (!condition) {
    std::cerr << "FAIL: " << description << '\n';
    ++failures;
  }
}

template <std::size_t Size>
void PutLe32(std::array<uint8_t, Size>* bytes, std::size_t offset,
             uint32_t value) {
  (*bytes)[offset] = static_cast<uint8_t>(value);
  (*bytes)[offset + 1] = static_cast<uint8_t>(value >> 8);
  (*bytes)[offset + 2] = static_cast<uint8_t>(value >> 16);
  (*bytes)[offset + 3] = static_cast<uint8_t>(value >> 24);
}

template <std::size_t Size>
void PutLe64(std::array<uint8_t, Size>* bytes, std::size_t offset,
             uint64_t value) {
  PutLe32(bytes, offset, static_cast<uint32_t>(value));
  PutLe32(bytes, offset + 4, static_cast<uint32_t>(value >> 32));
}

uint64_t PatchTableFingerprint() {
  uint64_t fingerprint = UINT64_C(14695981039346656037);
  const auto mix = [&fingerprint](uint8_t byte) {
    fingerprint ^= byte;
    fingerprint *= UINT64_C(1099511628211);
  };
  for (const Patch& patch : Patches()) {
    for (unsigned int shift = 0; shift < 32; shift += 8) {
      mix(static_cast<uint8_t>(patch.address >> shift));
    }
    for (uint8_t byte : patch.before) mix(byte);
    for (uint8_t byte : patch.after) mix(byte);
    mix(patch.kind == PatchKind::kCave ? 0 : 1);
    for (char byte : patch.name) mix(static_cast<uint8_t>(byte));
    mix(0);
  }
  return fingerprint;
}

void TestPatchTable() {
  const auto& patches = Patches();
  Expect(patches.size() == kPatchCount, "patch count");
  for (std::size_t index = 0; index < patches.size(); ++index) {
    Expect((patches[index].address & 3U) == 0, "word alignment");
    Expect(patches[index].kind ==
               (index < kCavePatchCount ? PatchKind::kCave : PatchKind::kHook),
           "caves precede hooks");
    Expect(std::none_of(patches.begin() + index + 1, patches.end(),
                        [&patches, index](const Patch& candidate) {
                          return candidate.address == patches[index].address;
                        }),
           "selected patch addresses are unique");
  }
  const uint64_t fingerprint = PatchTableFingerprint();
  Expect(fingerprint == UINT64_C(0x13d41657c485e908),
         "complete SOURCE0 native-q192 two-slot profile fingerprint");
  Expect(patches.front().address == 0x4038aee8, "first cave address");
  Expect(Hex(patches.front().after) == "924bfca2", "first cave bytes");
  Expect(patches[kCavePatchCount - 1].address == 0x403c9460,
         "source-read cave is the final cave word");
  Expect(Hex(patches[9].after) == "52076704",
         "guard selects source bitmap bit zero");
  Expect(Hex(patches[10].after) == "62a0c00c",
         "guard requests the 192-frame quantum");
  Expect(Hex(patches[13].after) == "8122a0c0", "TDM cave forces 192 kHz");
  Expect(Hex(patches[14].after) == "a0421142",
         "TDM cave uses shift six for 12.288 MHz");
  Expect(
      patches[24].address == 0x403d3c84 && Hex(patches[24].after) == "1b22f066",
      "source0 two-slot profile uses x2 primary copies");
  Expect(
      patches[29].address == 0x403d3e1c && Hex(patches[29].after) == "20c2a600",
      "source0 q192 profile commits 0x600 bytes");
  Expect(std::none_of(
             patches.begin(), patches.end(),
             [](const Patch& patch) { return patch.address == 0x403c8978; }),
         "SOURCE0 leaves the generic enum-7 mapper unselected");
  Expect(patches.back().address == 0x4038ba4c,
         "source-0 activation hook is last");
  Expect(std::none_of(patches.begin(), patches.end(), [](const Patch& patch) {
           return patch.address == 0x4026f03c || patch.address == 0x4026f040 ||
                  (patch.address >= 0x40341080 && patch.address <= 0x4034108c);
         }),
         "retired AudioEntrypoint redirect and cave remain unselected");
  Expect(patches[32].address == 0x403f03ac &&
             Hex(patches[32].after) == "36410022" &&
             patches[39].address == 0x403f03c8 &&
             Hex(patches[39].after) == "1df00000",
         "both executable AudioEntrypoint getters are replaced in place");

  const Patch& allocator = A32AllocatorFallbackPatch();
  Expect(allocator.address == 0x400a114c,
         "A32 allocator fallback aligned address");
  Expect(Hex(allocator.before) == "002870d0",
         "A32 allocator fallback stock word");
  Expect(Hex(allocator.after) == "002825d0",
         "A32 allocator fallback patched word");
  const StockWordRequirement& timer_assert = A32TimerAssertionStockWord();
  Expect(timer_assert.address == 0x4009e0cc,
         "A32 timer assertion aligned address");
  Expect(Hex(timer_assert.expected) == "8efd90bb",
         "A32 timer assertion remains stock");
  Expect(kA32OutputterTimerLayouts[0].pointer_address == 0x4016df48 &&
             kA32OutputterTimerLayouts[0].context == 0x4016df08,
         "first reviewed A32 OUTPUTTER runtime layout");
  Expect(kA32OutputterTimerLayouts[1].pointer_address == 0x4016e048 &&
             kA32OutputterTimerLayouts[1].context == 0x4016e008,
         "second reviewed A32 OUTPUTTER runtime layout");
}

void TestUnselectedStockWords() {
  const auto& requirements = UnselectedStockWords();
  Expect(requirements.size() == kUnselectedStockWordCount,
         "unselected stock word count");
  constexpr std::array<uint32_t, kUnselectedStockWordCount> kAddresses = {
      0x403c8978, 0x403c89a0, 0x403d4060, 0x403d406c, 0x403d3c80, 0x403d3d6c,
      0x403d4150, 0x403aa568, 0x403aa580, 0x403aa660, 0x403aa684, 0x403aa6a4,
      0x403aa6c8, 0x403aa6e8, 0x403aa70c, 0x403aa734, 0x403aa750, 0x403aa768,
      0x403aa77c, 0x403aa794, 0x403aa7ac, 0x403aa7c4, 0x403aa868, 0x403aa510,
      0x403aa520, 0x403aa82c, 0x403aa840, 0x403aaaf0, 0x403aabac, 0x403aa534,
      0x403aa84c, 0x403aa854};
  constexpr std::array<std::string_view, kUnselectedStockWordCount> kWords = {
      "18801446", "d20312d0", "2c0b4864", "2c0b4874", "04622da6", "08622da6",
      "5223a688", "ee11a997", "6e96b87f", "060c1be0", "1be0c811", "060c1be0",
      "1be0c811", "060c1be0", "1be0c811", "016e96b8", "1be0c811", "e0c81165",
      "060c1be0", "0c1be0c8", "1be0c811", "4eff7923", "7e41a81b", "a1130081",
      "f9213911", "02000be0", "2139117e", "5e93a913", "fe94a98f", "726100a5",
      "990dc972", "216901a5"};
  for (std::size_t index = 0; index < requirements.size(); ++index) {
    Expect(requirements[index].address == kAddresses[index],
           "unselected stock address");
    Expect(Hex(requirements[index].expected) == kWords[index],
           "unselected stock bytes");
  }
}

void TestClassificationAndPlans() {
  const Patch& patch = Patches().front();
  PatchState state = PatchState::kPatched;
  std::string error;
  Expect(ClassifyWord(patch, patch.before, &state, &error) &&
             state == PatchState::kStock,
         "classify stock");
  Expect(ClassifyWord(patch, patch.after, &state, &error) &&
             state == PatchState::kPatched,
         "classify patched");
  const std::array<uint8_t, 4> unknown = {1, 2, 3, 4};
  Expect(!ClassifyWord(patch, unknown, &state, &error), "reject unknown word");

  std::vector<PatchState> states(kPatchCount, PatchState::kStock);
  std::vector<std::size_t> order;
  bool already = false;
  Expect(PlanTransition(Action::kApply, states, &order, &already, &error),
         "plan apply");
  Expect(!already && order.size() == kPatchCount && order.front() == 0 &&
             order.back() == kPatchCount - 1,
         "apply is cave-first and activation-last");

  states.assign(kPatchCount, PatchState::kPatched);
  Expect(PlanTransition(Action::kRevert, states, &order, &already, &error),
         "plan revert");
  Expect(!already && order.size() == kPatchCount &&
             order.front() == kPatchCount - 1 &&
             order[kHookPatchCount - 1] == kCavePatchCount &&
             order[kHookPatchCount] == kCavePatchCount - 1 && order.back() == 0,
         "revert disconnects reversed hooks before reversed caves");

  Expect(PlanTransition(Action::kApply, states, &order, &already, &error) &&
             already && order.empty(),
         "already-patched apply is an idempotent no-op");
  states.front() = PatchState::kStock;
  Expect(!PlanTransition(Action::kApply, states, &order, &already, &error),
         "refuse a mixed apply state");
  Expect(!PlanTransition(Action::kRevert, states, &order, &already, &error),
         "refuse a mixed revert state");
}

void TestUniformStateSets() {
  std::array<PatchState, kPatchCount> f1{};
  f1.fill(PatchState::kPatched);
  Expect(Uniform(f1, PatchState::kPatched),
         "accept uniform 46-word F1 destination");
  f1.back() = PatchState::kStock;
  Expect(!Uniform(f1, PatchState::kPatched),
         "reject nonuniform 46-word F1 destination");

  // The H0 conditional-geometry profile has six words.  This different
  // cardinality is the regression case: uniformity must describe values, not
  // accidentally require the F1 table's kPatchCount cardinality.
  std::array<PatchState, 6> h0{};
  h0.fill(PatchState::kStock);
  Expect(Uniform(h0, PatchState::kStock),
         "accept uniform six-word H0 destination");
  h0.front() = PatchState::kPatched;
  Expect(!Uniform(h0, PatchState::kStock),
         "reject nonuniform six-word H0 destination");

  const std::span<const PatchState> empty;
  Expect(!Uniform(empty, PatchState::kStock),
         "reject an empty state set as uniform");
}

void TestA32CacheObjectGuards() {
  std::string error;
  std::array<uint8_t, kA32WorkPoolGuardSize> pool{};
  PutLe32(&pool, 0x1c, 0x40164190);
  PutLe32(&pool, 0x3c, 8);
  Expect(ValidateA32WorkPoolSnapshot(kA32WorkPoolAddress, pool, &error),
         "accept reviewed A32 work-pool state");
  Expect(!ValidateA32WorkPoolSnapshot(
             kA32WorkPoolAddress,
             std::span<const uint8_t>(pool).first(pool.size() - 1), &error),
         "reject truncated A32 work pool");
  Expect(!ValidateA32WorkPoolSnapshot(kA32WorkPoolAddress + 4, pool, &error),
         "reject moved A32 work pool");
  PutLe32(&pool, 0x1c, 0);
  Expect(!ValidateA32WorkPoolSnapshot(kA32WorkPoolAddress, pool, &error),
         "reject empty A32 work pool");
  PutLe32(&pool, 0x1c, 0x40164190);
  PutLe32(&pool, 0x3c, 9);
  Expect(!ValidateA32WorkPoolSnapshot(kA32WorkPoolAddress, pool, &error),
         "reject overcommitted A32 work pool");

  constexpr uint32_t kTimer = 0x40180000;
  std::array<uint8_t, kA32OutputterTimerGuardSize> timer{};
  PutLe32(&timer, 0x00, kA32OutputterTimerVtable);
  PutLe64(&timer, 0x10, kA32OutputterPeriodNs);
  PutLe32(&timer, 0x24, kA32OutputterWorker);
  PutLe32(&timer, 0x28, kA32OutputterCallback);
  PutLe32(&timer, 0x2c, kA32OutputterTimerLayouts[0].context);
  uint32_t callback = 0;
  Expect(ValidateA32OutputterTimerSnapshot(kA32OutputterTimerLayouts[0],
                                           kTimer, timer, &callback, &error) &&
             callback == kA32OutputterCallback,
         "accept first reviewed stock A32 OUTPUTTER timer layout");
  PutLe32(&timer, 0x2c, kA32OutputterTimerLayouts[1].context);
  Expect(ValidateA32OutputterTimerSnapshot(kA32OutputterTimerLayouts[1],
                                           kTimer, timer, &callback, &error) &&
             callback == kA32OutputterCallback,
         "accept second reviewed stock A32 OUTPUTTER timer layout");
  Expect(!ValidateA32OutputterTimerSnapshot(kA32OutputterTimerLayouts[0],
                                            kTimer, timer, &callback, &error),
         "reject a context paired with the wrong A32 owner slot");
  PutLe32(&timer, 0x2c, kA32OutputterTimerLayouts[0].context);
  Expect(!ValidateA32OutputterTimerSnapshot(
             kA32OutputterTimerLayouts[0], kTimer,
             std::span<const uint8_t>(timer).first(timer.size() - 1), &callback,
             &error),
         "reject truncated A32 OUTPUTTER timer");
  PutLe32(&timer, 0x00, kA32OutputterTimerVtable + 4);
  Expect(!ValidateA32OutputterTimerSnapshot(kA32OutputterTimerLayouts[0],
                                            kTimer, timer, &callback, &error),
         "reject wrong A32 OUTPUTTER vtable");
  PutLe32(&timer, 0x00, kA32OutputterTimerVtable);
  PutLe32(&timer, 0x24, kA32OutputterWorker + 4);
  Expect(!ValidateA32OutputterTimerSnapshot(kA32OutputterTimerLayouts[0],
                                            kTimer, timer, &callback, &error),
         "reject wrong A32 OUTPUTTER worker");
  PutLe32(&timer, 0x24, kA32OutputterWorker);
  PutLe32(&timer, 0x2c, kA32OutputterTimerLayouts[0].context + 4);
  Expect(!ValidateA32OutputterTimerSnapshot(kA32OutputterTimerLayouts[0],
                                            kTimer, timer, &callback, &error),
         "reject wrong A32 OUTPUTTER context");
  PutLe32(&timer, 0x2c, kA32OutputterTimerLayouts[0].context);
  PutLe32(&timer, 0x28, kA32WholeCacheInvalidator);
  Expect(ValidateA32OutputterTimerSnapshot(kA32OutputterTimerLayouts[0],
                                           kTimer, timer, &callback, &error) &&
             callback == kA32WholeCacheInvalidator,
         "accept transiently armed A32 OUTPUTTER timer");
  PutLe32(&timer, 0x28, 0x40000001);
  Expect(!ValidateA32OutputterTimerSnapshot(kA32OutputterTimerLayouts[0],
                                            kTimer, timer, &callback, &error),
         "reject unknown A32 OUTPUTTER callback");
  PutLe32(&timer, 0x28, kA32OutputterCallback);
  PutLe64(&timer, 0x10, kA32OutputterPeriodNs - 1);
  Expect(!ValidateA32OutputterTimerSnapshot(kA32OutputterTimerLayouts[0],
                                            kTimer, timer, &callback, &error),
         "reject wrong A32 OUTPUTTER timer period");
  PutLe64(&timer, 0x10, kA32OutputterPeriodNs);
  Expect(!ValidateA32OutputterTimerSnapshot(kA32OutputterTimerLayouts[0],
                                            kTimer + 4, timer, &callback,
                                            &error),
         "reject misaligned A32 OUTPUTTER timer");
  Expect(!ValidateA32OutputterTimerSnapshot(
             kA32OutputterTimerLayouts[0], kA32OutputterTimerMinimum - 8,
             timer, &callback, &error),
         "reject low A32 OUTPUTTER timer address");
  Expect(!ValidateA32OutputterTimerSnapshot(
             kA32OutputterTimerLayouts[0], kA32OutputterTimerMaximum + 8,
             timer, &callback, &error),
         "reject high A32 OUTPUTTER timer address");
}

void TestPacketsAndResponses() {
  const std::vector<uint8_t> dump =
      BuildDumpPacket(0x5a, kF1Core, 0x4038aee8, 4);
  Expect(Hex(dump) == "005a14002600000002000000e8ae384004000000",
         "CMD_DBG_MEM_DUMP packet bytes");
  const std::vector<uint8_t> set =
      BuildSetWordPacket(0x7f, kF1Core, 0x4038aee8, Patches().front().after);
  Expect(Hex(set) == "007f15002500000002000000e8ae3840924bfca200",
         "CMD_DBG_MEM_SET packet bytes");
  const std::vector<uint8_t> allocator =
      BuildSetWordPacket(0x80, kA32Core, A32AllocatorFallbackPatch().address,
                         A32AllocatorFallbackPatch().after);
  Expect(Hex(allocator) == "0080150025000000010000004c110a40002825d000",
         "A32 allocator fallback CMD_DBG_MEM_SET packet bytes");
  const std::array<uint8_t, 4> invalidator = {
      static_cast<uint8_t>(kA32WholeCacheInvalidator),
      static_cast<uint8_t>(kA32WholeCacheInvalidator >> 8),
      static_cast<uint8_t>(kA32WholeCacheInvalidator >> 16),
      static_cast<uint8_t>(kA32WholeCacheInvalidator >> 24),
  };
  const std::vector<uint8_t> callback =
      BuildSetWordPacket(0x81, kA32Core, 0x40180028, invalidator);
  Expect(Hex(callback) == "00811500250000000100000028001840e91b094000",
         "A32 cache callback CMD_DBG_MEM_SET packet bytes");

  std::string error;
  const std::array<uint8_t, 8> good = {0x00, 0x5a, 0x08, 0x00,
                                       0x26, 0x00, 0x00, 0x00};
  Expect(ParseCommandResponse(good, 0x5a, kCommandMemoryDump, &error),
         "accept correlated success response");
  auto bad = good;
  bad[1] = 0x5b;
  Expect(!ParseCommandResponse(bad, 0x5a, kCommandMemoryDump, &error),
         "reject wrong response counter");
  bad = good;
  bad[2] = 9;
  Expect(!ParseCommandResponse(bad, 0x5a, kCommandMemoryDump, &error),
         "reject wrong response length");
  bad = good;
  bad[6] = 0xff;
  bad[7] = 0xff;
  Expect(!ParseCommandResponse(bad, 0x5a, kCommandMemoryDump, &error),
         "reject negative AoC reply");
}

void TestDumpParser() {
  constexpr std::string_view debug =
      "noise 0x12345678: aa bb\n"
      "[F1] 0x4038aee8: 92 4b\n"
      "[F1] 0x4038aeea: fc a2 99 88\n";
  std::vector<uint8_t> result;
  std::string error;
  Expect(ParseMemoryDump(debug, 0x4038aee8, 4, &result, &error) &&
             Hex(result) == "924bfca2",
         "parse contiguous multi-line memory dump");
  Expect(!ParseMemoryDump(debug, 0x4038aef0, 4, &result, &error),
         "reject absent memory dump");
  Expect(!ParseMemoryDump("0x4038aee8: 924b fc a2\n", 0x4038aee8, 4, &result,
                          &error),
         "reject malformed byte tokens");
}

void TestGenerationParser() {
  uint64_t value = 99;
  std::string error;
  Expect(ParseUnsignedDecimal("0", &value, &error) && value == 0,
         "parse zero generation");
  Expect(ParseUnsignedDecimal("18446744073709551615", &value, &error) &&
             value == UINT64_MAX,
         "parse maximum generation");
  for (std::string_view invalid :
       {"", "+1", "-1", "1 ", " 1", "1x", "18446744073709551616"}) {
    value = 99;
    Expect(!ParseUnsignedDecimal(invalid, &value, &error) && value == 99,
           "reject malformed generation counter");
  }
}

void TestPlaybackPcmInventory() {
  constexpr std::string_view good =
      "00-00: EP1 playback (*) :  : playback 1\n"
      "00-01: EP2 playback (*) :  : playback 1\n";
  std::string error;
  Expect(ValidatePlaybackPcmInventory(good, &error),
         "accept exact PCM 0,0 inventory identity");
  Expect(ValidatePlaybackPcmInventory("00-00: EP1 playback (*) :  : playback 1",
                                      &error),
         "accept exact identity without a final newline");
  Expect(!ValidatePlaybackPcmInventory(
             "00-00: EP1 playback (*) :  : capture 1\n", &error),
         "reject wrong PCM direction");
  Expect(!ValidatePlaybackPcmInventory("00-00: renamed (*) :  : playback 1\n",
                                       &error),
         "reject wrong PCM name");
  Expect(!ValidatePlaybackPcmInventory(
             "00-00: EP1 playback (*) :  : playback 2\n", &error),
         "reject wrong PCM substream count");
  Expect(!ValidatePlaybackPcmInventory(
             "prefix 00-00: EP1 playback (*) :  : playback 1\n", &error),
         "reject embedded rather than exact PCM identity");
  Expect(
      !ValidatePlaybackPcmInventory("00-00: EP1 playback (*) :  : playback 1\n"
                                    "00-00: EP1 playback (*) :  : playback 1\n",
                                    &error),
      "reject duplicate PCM identity");
}

}  // namespace
}  // namespace frankel_aoc_speaker_patch

int main() {
  using namespace frankel_aoc_speaker_patch;
  TestPatchTable();
  TestUnselectedStockWords();
  TestClassificationAndPlans();
  TestUniformStateSets();
  TestA32CacheObjectGuards();
  TestPacketsAndResponses();
  TestDumpParser();
  TestGenerationParser();
  TestPlaybackPcmInventory();
  if (failures != 0) {
    std::cerr << failures << " test(s) failed\n";
    return 1;
  }
  std::cout << "all frankel_aoc_speaker_patch model tests passed\n";
  return 0;
}
