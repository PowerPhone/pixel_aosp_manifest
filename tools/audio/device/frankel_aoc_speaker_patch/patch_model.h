// SPDX-License-Identifier: Apache-2.0

#pragma once

#include <array>
#include <cstddef>
#include <cstdint>
#include <span>
#include <string>
#include <string_view>
#include <vector>

namespace frankel_aoc_speaker_patch {

constexpr std::size_t kPatchCount = 75;
// The native-q192 SOURCE5 profile begins with every unreachable code-cave
// word. All reachable hooks follow and the source-5 activation hook is last.
constexpr std::size_t kCavePatchCount = 44;
constexpr std::size_t kHookPatchCount = 31;
constexpr std::size_t kUnselectedStockWordCount = 37;
constexpr uint16_t kCommandMemorySet = 0x25;
constexpr uint16_t kCommandMemoryDump = 0x26;
constexpr int32_t kF1Core = 2;
constexpr int32_t kA32Core = 1;
constexpr int32_t kH0Core = 3;
constexpr uint32_t kUsfDefaultWorkerStockPriority = 7;

// The live allocator fallback uses the exact, already-running TMD3743
// OUTPUTTER timer to invoke AoC's own whole-cache maintenance routine from
// UsfDefaultWorker context. CP2A.260805.005 has produced either of these two
// mutually exclusive runtime construction layouts on real hardware. Each
// owner slot and its matching context are treated as one inseparable layout;
// exactly one complete timer object must validate before any mutation.
struct A32OutputterTimerLayout {
  uint32_t pointer_address;
  uint32_t context;
};

constexpr uint32_t kA32WorkPoolPointerAddress = 0x40131094;
constexpr uint32_t kA32WorkPoolAddress = 0x40164110;
constexpr std::size_t kA32WorkPoolGuardSize = 0x60;
constexpr std::array<A32OutputterTimerLayout, 2> kA32OutputterTimerLayouts = {{
    {0x4016df48, 0x4016df08},
    {0x4016e048, 0x4016e008},
}};
constexpr uint32_t kA32OutputterTimerMinimum = 0x40178000;
constexpr uint32_t kA32OutputterTimerMaximum = 0x40190000;
constexpr std::size_t kA32OutputterTimerGuardSize = 0x38;
constexpr uint32_t kA32OutputterTimerVtable = 0x4010a330;
constexpr uint32_t kA32OutputterWorker = 0x40165730;
constexpr uint32_t kA32OutputterCallback = 0x400a7a2d;
constexpr uint64_t kA32OutputterPeriodNs = UINT64_C(5000000000);
constexpr uint32_t kA32WholeCacheInvalidator = 0x40091be9;

enum class PatchKind {
  kCave,
  kHook,
};

enum class PatchState {
  kStock,
  kPatched,
};

enum class Action {
  kApply,
  kRevert,
};

struct Patch {
  std::string_view name;
  uint32_t address;
  std::array<uint8_t, 4> before;
  std::array<uint8_t, 4> after;
  PatchKind kind;
};

struct StockWordRequirement {
  std::string_view name;
  uint32_t address;
  std::array<uint8_t, 4> expected;
};

const std::array<Patch, kPatchCount>& Patches();
const std::array<StockWordRequirement, kUnselectedStockWordCount>&
UnselectedStockWords();

// The PowerPhone helper installs this exact aligned A32 instruction word into
// stock, reboot-volatile SRAM and then invokes the firmware-native whole-cache
// invalidator through the guarded OUTPUTTER timer. The older global
// timer-assertion bypass must remain stock.
const Patch& A32AllocatorFallbackPatch();
const StockWordRequirement& A32TimerAssertionStockWord();

bool ClassifyWord(const Patch& patch, std::span<const uint8_t> actual,
                  PatchState* state, std::string* error);

// Test whether one already-size-validated state set is non-empty and entirely
// in the requested state.  The caller owns the set's cardinality: the F1
// program has kPatchCount words, while auxiliary profiles such as H0 have a
// different, compile-time cardinality.
bool Uniform(std::span<const PatchState> states, PatchState wanted);

// Validate the two A32 objects used by the live I-cache synchronization path.
// The callback may be either its exact stock value or the transient invalidator
// value so the caller can safely inspect and restore an armed transaction.
bool ValidateA32WorkPoolSnapshot(uint32_t pointer,
                                 std::span<const uint8_t> body,
                                 std::string* error);
bool ValidateA32OutputterTimerSnapshot(const A32OutputterTimerLayout& layout,
                                       uint32_t timer,
                                       std::span<const uint8_t> body,
                                       uint32_t* callback, std::string* error);

// A transition is accepted only from a uniform source or destination state.
// Mixed state is deliberately not resumed: an AoC/device reboot is the safe
// recovery for an interrupted volatile patch transaction.
bool PlanTransition(Action action, std::span<const PatchState> states,
                    std::vector<std::size_t>* order, bool* already_complete,
                    std::string* error);

std::vector<uint8_t> BuildDumpPacket(uint8_t counter, int32_t core,
                                     uint32_t address, uint32_t size);
std::vector<uint8_t> BuildSetWordPacket(uint8_t counter, int32_t core,
                                        uint32_t address,
                                        std::span<const uint8_t, 4> word);

bool ParseCommandResponse(std::span<const uint8_t> response,
                          uint8_t expected_counter, uint16_t expected_command,
                          std::string* error);

bool ParseMemoryDump(std::string_view debug_output, uint32_t address,
                     std::size_t size, std::vector<uint8_t>* result,
                     std::string* error);

bool ParseUnsignedDecimal(std::string_view value, uint64_t* result,
                          std::string* error);

// Require the one exact ALSA inventory entry reviewed for Frankel's EP6
// source-5 playback PCM. A same-numbered entry with a different name,
// direction, or substream count is not an acceptable ownership target.
bool ValidatePlaybackPcmInventory(std::string_view inventory,
                                  std::string* error);

std::string Hex(std::span<const uint8_t> bytes);

}  // namespace frankel_aoc_speaker_patch
