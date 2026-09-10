// SPDX-License-Identifier: Apache-2.0

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <sys/sysmacros.h>

#include "patch_model.h"
#if defined(__ANDROID__)
#include <sys/system_properties.h>
#else
// Permit a host compiler to perform a warning-clean syntax check of the
// device-only translation unit without importing Bionic headers.
constexpr std::size_t PROP_VALUE_MAX = 92;
extern "C" int __system_property_get(const char*, char*);
extern "C" int __system_property_set(const char*, const char*);
#endif
#include <sys/types.h>
#include <time.h>
#include <tinyalsa/asoundlib.h>
#include <unistd.h>

#include <algorithm>
#include <array>
#include <chrono>
#include <cstdio>
#include <cstdint>
#include <cstring>
#include <iomanip>
#include <iostream>
#include <limits>
#include <optional>
#include <span>
#include <sstream>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

namespace frankel_aoc_speaker_patch {
namespace {

constexpr std::string_view kExpectedDevice = "frankel";
constexpr std::string_view kExpectedVendorBuildId = "CP2A.260805.005";
constexpr char kFactoryDiag[] = "/dev/acd-factory_diag";
constexpr char kDebugDevice[] = "/dev/acd-debug";
constexpr char kPcmInventory[] = "/proc/asound/pcm";
constexpr char kPlaybackDevice[] = "/dev/snd/pcmC0D0p";
constexpr char kPlaybackStatus[] = "/proc/asound/card0/pcm0p/sub0/status";
constexpr unsigned int kPlaybackDeviceMajor = 116;
// Frankel uses CONFIG_SND_DYNAMIC_MINORS. PCM D0 is the first playback node
// registered after controlC0 and therefore has dynamic minor 2.
constexpr unsigned int kPlaybackDeviceMinor = 2;
constexpr char kRestartCount[] =
    "/sys/devices/platform/9000000.aoc/restart_count";
constexpr char kCoredumpCount[] =
    "/sys/devices/platform/9000000.aoc/coredump_count";
constexpr char kTransactionLock[] = "/data/vendor/powerphone/.aoc-patch.lock";
constexpr char kReadyProperty[] = "vendor.powerphone.aoc_speaker_192k.ready";
constexpr char kA32ReadyProperty[] =
    "vendor.powerphone.aoc_a32_allocator.ready";
constexpr std::string_view kCacheFlushControl = "HD Mic gain (cB)";
constexpr std::size_t kMaximumFactoryResponse = 4096;
constexpr std::size_t kMaximumDebugOutput = 64 * 1024;
constexpr auto kFactoryWriteTimeout = std::chrono::seconds(2);
constexpr auto kFactoryResponseTimeout = std::chrono::seconds(5);
constexpr auto kFactoryRetryDelay = std::chrono::milliseconds(1);
// Establish a clean debug-stream boundary without imposing a quiet-period
// delay on every transaction. A successful factory_diag acknowledgement can
// precede its formatted acd-debug dump by substantially more than 100 ms, so
// wait longer only on the failure path and return as soon as the exact dump
// parses.
constexpr auto kDebugDrainTimeout = std::chrono::milliseconds(10);
constexpr auto kDumpDebugTimeout = std::chrono::seconds(2);
// The ALSA control write only proves that Linux accepted the command.  Keep
// the temporary F1 dispatch reachable until the AoC worker has exceeded the
// qualified 506--522 ms command latency with ample margin.
constexpr auto kF1ControlCompletionWait = std::chrono::milliseconds(1500);
// Waiting longer than one exact five-second OUTPUTTER period guarantees at
// least one opportunity for its temporary whole-cache callback to run. The
// callback invocation is timing-inferred; all surrounding object, generation,
// and restoration guards remain exact.
constexpr auto kA32CacheCallbackWait = std::chrono::seconds(7);
constexpr auto kA32PreparationWindow = std::chrono::seconds(9);
constexpr auto kA32PreparationPollInterval = std::chrono::milliseconds(50);
constexpr uint32_t kUsfDefaultWorkerTcb = 0x401658f8;
constexpr std::size_t kUsfDefaultWorkerTcbGuardSize = 0x50;
constexpr int kWorkerPrioritySettleAttempts = 21;
constexpr int kWorkerPriorityStableSamples = 2;
constexpr auto kWorkerPrioritySettleInterval = std::chrono::milliseconds(50);
constexpr auto kAllocatorPublishTimeout = std::chrono::seconds(2);
constexpr auto kAllocatorPublishPollInterval = std::chrono::milliseconds(25);
constexpr auto kAllocatorPublishConfirmInterval =
    std::chrono::milliseconds(50);

constexpr std::array<uint8_t, 4> ConstLe32Bytes(uint32_t value) {
  return {
      static_cast<uint8_t>(value),
      static_cast<uint8_t>(value >> 8),
      static_cast<uint8_t>(value >> 16),
      static_cast<uint8_t>(value >> 24),
  };
}

// Native-q192 speaker storage. One 0x3000-byte aligned allocation is split
// into four 0xc00-byte banks. A second allocation is forbidden: hardware
// proved that it exhausts HeapMicroAllocGenericInternal and restarts AoC.
constexpr uint32_t kSpeakerObject = 0x4051b0b8;
constexpr uint32_t kSpeakerVtable = 0x40275d00;
constexpr uint32_t kStockBankBytes = 0x600;
constexpr uint32_t kNativeBankBytes = 0xc00;
constexpr uint32_t kAllocationBytes = 0x3000;
constexpr uint32_t kDmaTxOffset = 0x1800;
constexpr uint32_t kHeapMinimum = 0x4051c800;
constexpr uint32_t kHeapLimit = 0x42000000;
constexpr std::size_t kZeroScanChunkBytes = 64;
constexpr uint32_t kTxSizeAddress = kSpeakerObject + 0x2b8;
constexpr uint32_t kSourceSizeAddress = kSpeakerObject + 0x2bc;
constexpr uint32_t kTxPointerAddress = kSpeakerObject + 0x2c4;
constexpr uint32_t kSourcePointerAddress = kSpeakerObject + 0x2c8;
constexpr uint32_t kStockTxPointer = 0x4051bbe0;
constexpr uint32_t kStockSourcePointer = 0x4051c1f0;
constexpr uint32_t kTxRingPointerAddress = kSpeakerObject + 0x200;
constexpr uint32_t kRxRingPointerAddress = kSpeakerObject + 0x204;
constexpr uint32_t kRingVtable = 0x40359c38;
constexpr uint32_t kAllocatorScratchLiteralAddress = 0x403e7814;
constexpr uint32_t kAllocatorScratchAddress = 0x403f64a0;
constexpr uint32_t kAllocatorBodyAddress = 0x403e87d0;
constexpr uint32_t kAlignedAllocLiteralAddress = 0x403c4030;
constexpr uint32_t kAlignedAllocLiteral = 0x4040bf40;
constexpr uint32_t kD12CallbackSlot = 0x4027c768;
constexpr uint32_t kStockD12Callback = 0x403e87d0;
constexpr uint32_t kWholeF1CacheInvalidator = 0x40486de0;

struct DmaRingLayout {
  std::string_view name;
  uint32_t address;
  uint32_t metadata;
  uint32_t inline_backing;
  uint32_t descriptor;
};

constexpr std::array<DmaRingLayout, 2> kDmaRings = {{
    {"SPKR_TX_DMA", 0x4051cd08, 0x4051cdd8, 0x4051ce80, 0x4051cda4},
    {"SPKR_RX_DMA", 0x4051d488, 0x4051d558, 0x4051d600, 0x4051d524},
}};

// AMixSPKR Configure receives its period in a3 and retains the packed config
// byte in a6.  Bits 4:2 of that byte are the sample-rate enum (7 = 192 kHz).
// The stock code at 0x403ea940 computes a15 = 3 * period, then the untouched
// bundles at 0x403ea946/0x403ea952 derive 48 * period frames and
// 384 * period bytes.  The cave multiplies a15 by four only for the reviewed
// enum-7, one-millisecond profile.  DeepBuffer's enum-5, ten-millisecond
// Configure therefore remains at its stock 480-frame/3840-byte geometry.
//
// The cave words must precede the one reachable hook.  Reversing this array
// disconnects the hook before any cave word is cleared.
constexpr std::size_t kH0GeometryPatchCount = 6;
constexpr std::array<Patch, kH0GeometryPatchCount> kH0GeometryPatches = {{
    {"H0 AMixSPKR conditional geometry cave word 0", 0x403f0c44,
     {0x00, 0x00, 0x00, 0x00}, {0x0b, 0xe3, 0x30, 0xf3},
     PatchKind::kCave},
    {"H0 AMixSPKR conditional geometry cave word 1", 0x403f0c48,
     {0x00, 0x00, 0x00, 0x00}, {0x90, 0xcc, 0x7e, 0x60},
     PatchKind::kCave},
    {"H0 AMixSPKR conditional geometry cave word 2", 0x403f0c4c,
     {0x00, 0x00, 0x00, 0x00}, {0xa2, 0x24, 0x66, 0x7a},
     PatchKind::kCave},
    {"H0 AMixSPKR conditional geometry cave word 3", 0x403f0c50,
     {0x00, 0x00, 0x00, 0x00}, {0x02, 0xe0, 0xff, 0x11},
     PatchKind::kCave},
    {"H0 AMixSPKR conditional geometry cave word 4", 0x403f0c54,
     {0x00, 0x00, 0x00, 0x00}, {0x86, 0x3b, 0xe7, 0x00},
     PatchKind::kCave},
    {"H0 AMixSPKR enum-7/period-1 geometry hook", 0x403ea940,
     {0xee, 0xe3, 0x3e, 0xcc}, {0x06, 0xc0, 0x18, 0xcc},
     PatchKind::kHook},
}};

// These are the stock multiplier bundles reached when the conditional cave
// returns to 0x403ea946.  Requiring them prevents a same-boot transition from
// a legacy/manual unconditional-x4 state, which would otherwise multiply the
// selected q192 geometry by sixteen.
constexpr std::array<StockWordRequirement, 2> kH0StockGeometryWords = {{
    {"H0 AMixSPKR stock frame multiplier", 0x403ea948,
     {0x40, 0xbf, 0xbc, 0x93}},
    {"H0 AMixSPKR stock byte multiplier", 0x403ea954,
     {0xb4, 0x3e, 0x0e, 0x93}},
}};

constexpr Patch kD12AllocatorQuarantine = {
    "D12 callback -> whole-cache invalidator", kD12CallbackSlot,
    ConstLe32Bytes(kStockD12Callback),
    ConstLe32Bytes(kWholeF1CacheInvalidator),
    PatchKind::kHook};
constexpr std::array<Patch, 2> kAllocatorScratchPatches = {{
    {"allocator result literal", kAllocatorScratchLiteralAddress,
     {0x00, 0x00, 0x00, 0x00}, {0xa0, 0x64, 0x3f, 0x40},
     PatchKind::kCave},
    {"allocator P192 marker", kAllocatorScratchLiteralAddress + 4,
     {0x00, 0x00, 0x00, 0x00}, {0x32, 0x39, 0x31, 0x50},
     PatchKind::kCave},
}};
constexpr std::array<Patch, 6> kAllocatorBodyPatches = {{
    {"pure allocator word 0", kAllocatorBodyAddress, {0x36, 0x41, 0x00, 0x5e},
     {0x36, 0x41, 0x00, 0x4c}, PatchKind::kCave},
    {"pure allocator word 1", kAllocatorBodyAddress + 4, {0x03, 0x08, 0x48, 0xdd},
     {0x0a, 0x3c, 0x0b, 0x80}, PatchKind::kCave},
    {"pure allocator word 2", kAllocatorBodyAddress + 8, {0xc8, 0x1d, 0xf0, 0x00},
     {0xbb, 0x11, 0x81, 0x15}, PatchKind::kCave},
    {"pure allocator word 3", kAllocatorBodyAddress + 12, {0xbd, 0x04, 0xe5, 0x01},
     {0x6e, 0xe0, 0x08, 0x00}, PatchKind::kCave},
    {"pure allocator word 4", kAllocatorBodyAddress + 16, {0x00, 0x1d, 0xf0, 0x00},
     {0x41, 0x0d, 0xfc, 0xa9}, PatchKind::kCave},
    {"pure allocator word 5", kAllocatorBodyAddress + 20, {0x00, 0x00, 0x00, 0x00},
     {0x04, 0x1d, 0xf0, 0x00}, PatchKind::kCave},
}};
constexpr Patch kAllocatorDispatch = {
    "HD Mic dispatch -> pure allocator", 0x4038ea50,
    {0xc0, 0xc8, 0x3d, 0x40}, ConstLe32Bytes(kAllocatorBodyAddress),
    PatchKind::kHook};

constexpr Patch kCacheFlushDispatch = {
    "HD Mic gain dispatch -> whole F1 I-cache invalidator",
    0x4038ea50,
    {0xc0, 0xc8, 0x3d, 0x40},
    {0xe0, 0x6d, 0x48, 0x40},
    PatchKind::kCave,
};

using Clock = std::chrono::steady_clock;

struct Generation {
  uint64_t restart_count;
  uint64_t coredump_count;

  bool operator==(const Generation&) const = default;
};

class UniqueFd {
 public:
  explicit UniqueFd(int fd = -1) : fd_(fd) {}
  ~UniqueFd() {
    if (fd_ >= 0) {
      close(fd_);
    }
  }
  UniqueFd(const UniqueFd&) = delete;
  UniqueFd& operator=(const UniqueFd&) = delete;
  int get() const { return fd_; }
  bool valid() const { return fd_ >= 0; }

 private:
  int fd_;
};

class UniqueDir {
 public:
  explicit UniqueDir(DIR* directory = nullptr) : directory_(directory) {}
  ~UniqueDir() {
    if (directory_ != nullptr) {
      closedir(directory_);
    }
  }
  UniqueDir(const UniqueDir&) = delete;
  UniqueDir& operator=(const UniqueDir&) = delete;
  DIR* get() const { return directory_; }
  bool valid() const { return directory_ != nullptr; }
  bool Close(std::string_view description, std::string* error) {
    if (directory_ == nullptr) {
      return true;
    }
    DIR* const directory = directory_;
    directory_ = nullptr;
    if (closedir(directory) != 0) {
      const int error_number = errno;
      *error = "close " + std::string(description) + ": " +
               std::strerror(error_number);
      return false;
    }
    return true;
  }

 private:
  DIR* directory_;
};

class UniqueMixer {
 public:
  explicit UniqueMixer(mixer* value = nullptr) : value_(value) {}
  ~UniqueMixer() {
    if (value_ != nullptr) {
      mixer_close(value_);
    }
  }
  UniqueMixer(const UniqueMixer&) = delete;
  UniqueMixer& operator=(const UniqueMixer&) = delete;
  mixer* get() const { return value_; }
  bool valid() const { return value_ != nullptr; }
  void Reset(mixer* value = nullptr) {
    if (value_ != nullptr) {
      mixer_close(value_);
    }
    value_ = value;
  }

 private:
  mixer* value_;
};

struct PlaybackIdentity {
  dev_t filesystem_device;
  ino_t inode;
  dev_t character_device;

  bool operator==(const PlaybackIdentity&) const = default;
};

std::string ErrnoText(std::string_view operation) {
  return std::string(operation) + ": " + std::strerror(errno);
}

std::string ErrnoText(std::string_view operation, int error_number) {
  return std::string(operation) + ": " + std::strerror(error_number);
}

std::string TrimAscii(std::string value) {
  constexpr std::string_view kWhitespace = " \t\r\n";
  const std::size_t first = value.find_first_not_of(kWhitespace);
  if (first == std::string::npos) {
    return {};
  }
  const std::size_t last = value.find_last_not_of(kWhitespace);
  return value.substr(first, last - first + 1);
}

bool ReadSmallFile(const char* path, std::string* contents,
                   std::string* error) {
  UniqueFd fd(open(path, O_RDONLY | O_CLOEXEC));
  if (!fd.valid()) {
    *error = ErrnoText(std::string("open ") + path);
    return false;
  }
  contents->clear();
  std::array<char, 4096> buffer{};
  while (true) {
    const ssize_t count = read(fd.get(), buffer.data(), buffer.size());
    if (count > 0) {
      if (contents->size() + static_cast<std::size_t>(count) > buffer.size()) {
        *error = std::string(path) + " is unexpectedly large";
        return false;
      }
      contents->append(buffer.data(), static_cast<std::size_t>(count));
      continue;
    }
    if (count == 0) {
      return true;
    }
    if (errno == EINTR) {
      continue;
    }
    *error = ErrnoText(std::string("read ") + path);
    return false;
  }
}

bool GetPropertyExact(const char* name, std::string_view expected,
                      std::string* error) {
  std::array<char, PROP_VALUE_MAX> value{};
  const int length = __system_property_get(name, value.data());
  if (length <= 0) {
    *error = std::string("missing Android property ") + name;
    return false;
  }
  const std::string_view actual(value.data(), static_cast<std::size_t>(length));
  if (actual != expected) {
    *error = std::string("refusing ") + name + '=' + std::string(actual) +
             "; expected " + std::string(expected);
    return false;
  }
  return true;
}

bool SetReady(bool ready, std::string* error) {
  const char* const wanted = ready ? "1" : "0";
  const int result = __system_property_set(kReadyProperty, wanted);
  std::string readback_error;
  if (GetPropertyExact(kReadyProperty, wanted, &readback_error)) {
    std::cout << kReadyProperty << '=' << wanted << '\n';
    return true;
  }
  *error = std::string("cannot set/read back ") + kReadyProperty + '=' +
           wanted + " (setter result " + std::to_string(result) +
           "): " + readback_error;
  return false;
}

bool SetA32Ready(bool ready, std::string* error) {
  const char* const wanted = ready ? "1" : "0";
  const int result = __system_property_set(kA32ReadyProperty, wanted);
  std::string readback_error;
  if (GetPropertyExact(kA32ReadyProperty, wanted, &readback_error)) {
    std::cout << kA32ReadyProperty << '=' << wanted << '\n';
    return true;
  }
  *error = std::string("cannot set/read back ") + kA32ReadyProperty + '=' +
           wanted + " (setter result " + std::to_string(result) +
           "): " + readback_error;
  return false;
}

bool GetCacheFlushControl(mixer* card, mixer_ctl** control,
                          std::string* error) {
  const std::string control_name(kCacheFlushControl);
  *control = mixer_get_ctl_by_name(card, control_name.c_str());
  if (*control == nullptr) {
    *error = "missing card0 mixer control: " + control_name;
    return false;
  }
  const unsigned int count = mixer_ctl_get_num_values(*control);
  if (count != 1) {
    *error =
        control_name + " has " + std::to_string(count) + " values; expected 1";
    return false;
  }
  return true;
}

bool TriggerCacheFlushControl(mixer* card, int* result, std::string* error) {
  mixer_ctl* control = nullptr;
  if (!GetCacheFlushControl(card, &control, error)) {
    return false;
  }
  *result = mixer_ctl_set_value(control, 0, 0);
  // The invalidator returns a2=64. The qualified tinyalsa path can surface
  // either ordinary success or a negative ALSA status; a positive value is
  // not a mixer-write result and is rejected.
  if (*result > 0) {
    *error = "HD Mic cache-flush mixer write returned unexpected positive " +
             std::to_string(*result);
    return false;
  }
  return true;
}

bool CheckCharDevice(const char* path, int access_mode, int open_flags,
                     std::string* error) {
  struct stat status{};
  if (stat(path, &status) != 0) {
    *error = ErrnoText(std::string("stat ") + path);
    return false;
  }
  if (!S_ISCHR(status.st_mode)) {
    *error = std::string(path) + " is not a character device";
    return false;
  }
  if (access(path, access_mode) != 0) {
    *error = ErrnoText(std::string("access ") + path);
    return false;
  }
  UniqueFd fd(open(path, open_flags | O_CLOEXEC | O_NONBLOCK));
  if (!fd.valid()) {
    *error = ErrnoText(std::string("open ") + path);
    return false;
  }
  return true;
}

bool IsDecimalName(const char* name) {
  if (*name == '\0') {
    return false;
  }
  for (const char* cursor = name; *cursor != '\0'; ++cursor) {
    if (*cursor < '0' || *cursor > '9') {
      return false;
    }
  }
  return true;
}

bool CheckPlaybackIdentity(PlaybackIdentity* identity, std::string* error) {
  std::string inventory;
  if (!ReadSmallFile(kPcmInventory, &inventory, error) ||
      !ValidatePlaybackPcmInventory(inventory, error)) {
    return false;
  }
  struct stat status{};
  if (lstat(kPlaybackDevice, &status) != 0) {
    *error = ErrnoText(std::string("lstat ") + kPlaybackDevice);
    return false;
  }
  if (!S_ISCHR(status.st_mode)) {
    *error =
        std::string(kPlaybackDevice) + " is not a direct character-device node";
    return false;
  }
  if (major(status.st_rdev) != kPlaybackDeviceMajor ||
      minor(status.st_rdev) != kPlaybackDeviceMinor) {
    std::ostringstream message;
    message << kPlaybackDevice << " has device " << major(status.st_rdev) << ':'
            << minor(status.st_rdev) << "; expected " << kPlaybackDeviceMajor
            << ':' << kPlaybackDeviceMinor;
    *error = message.str();
    return false;
  }
  *identity = PlaybackIdentity{
      .filesystem_device = status.st_dev,
      .inode = status.st_ino,
      .character_device = status.st_rdev,
  };
  return true;
}

bool CheckPlaybackStatus(std::string* error) {
  UniqueFd fd(open(kPlaybackStatus, O_RDONLY | O_CLOEXEC));
  if (!fd.valid()) {
    if (errno == ENOENT) {
      // ALSA removes PCM0's procfs substream directory while the device is
      // closed.  The exact character-node check plus the complete root fd
      // scan below establish idleness in that normal closed state.
      return true;
    }
    *error = ErrnoText(std::string("open ") + kPlaybackStatus);
    return false;
  }
  std::string status;
  std::array<char, 64> buffer{};
  while (true) {
    const ssize_t count = read(fd.get(), buffer.data(), buffer.size());
    if (count > 0) {
      if (status.size() + static_cast<std::size_t>(count) > buffer.size()) {
        *error = std::string(kPlaybackStatus) + " is unexpectedly large";
        return false;
      }
      status.append(buffer.data(), static_cast<std::size_t>(count));
      continue;
    }
    if (count == 0) {
      break;
    }
    if (errno == EINTR) {
      continue;
    }
    *error = ErrnoText(std::string("read ") + kPlaybackStatus);
    return false;
  }
  status = TrimAscii(std::move(status));
  if (status != "closed") {
    *error = "PCM 0,0 idleness is not established (status='" + status +
             "'); stop all speaker playback";
    return false;
  }
  return true;
}

bool CheckNoPlaybackFileDescriptor(dev_t playback_device, std::string* error) {
  if (getuid() != 0 || geteuid() != 0) {
    *error = "complete /proc fd ownership scan requires real/effective uid 0";
    return false;
  }
  UniqueDir proc(opendir("/proc"));
  if (!proc.valid()) {
    *error = ErrnoText("open /proc");
    return false;
  }
  while (true) {
    errno = 0;
    dirent* const process_entry = readdir(proc.get());
    if (process_entry == nullptr) {
      const int error_number = errno;
      if (error_number != 0) {
        *error = ErrnoText("read /proc", error_number);
        return false;
      }
      break;
    }
    if (!IsDecimalName(process_entry->d_name)) {
      continue;
    }
    const std::string fd_directory_path =
        std::string("/proc/") + process_entry->d_name + "/fd";
    UniqueDir descriptors(opendir(fd_directory_path.c_str()));
    if (!descriptors.valid()) {
      const int error_number = errno;
      if (error_number == ENOENT) {
        continue;
      }
      *error =
          ErrnoText(std::string("open ") + fd_directory_path, error_number);
      return false;
    }
    while (true) {
      errno = 0;
      dirent* const descriptor_entry = readdir(descriptors.get());
      if (descriptor_entry == nullptr) {
        const int error_number = errno;
        if (error_number != 0) {
          *error =
              ErrnoText(std::string("read ") + fd_directory_path, error_number);
          return false;
        }
        break;
      }
      if (std::strcmp(descriptor_entry->d_name, ".") == 0 ||
          std::strcmp(descriptor_entry->d_name, "..") == 0) {
        continue;
      }
      if (!IsDecimalName(descriptor_entry->d_name)) {
        *error = fd_directory_path + " contains unexpected entry '" +
                 descriptor_entry->d_name + "'";
        return false;
      }
      // Following every fd symlink with fstatat() requires this confined boot
      // service to getattr every object held by every process (binder,
      // io_uring, sockets, and many private device nodes).  That is both
      // unnecessary and deliberately forbidden by SELinux.  Read the procfs
      // link first and follow only the one canonical ALSA node whose ownership
      // this guard must exclude.
      std::array<char, 4096> target{};
      const ssize_t target_size =
          readlinkat(dirfd(descriptors.get()), descriptor_entry->d_name,
                     target.data(), target.size());
      if (target_size < 0) {
        const int error_number = errno;
        if (error_number == ENOENT) {
          continue;
        }
        *error = ErrnoText(fd_directory_path + "/" + descriptor_entry->d_name,
                           error_number);
        return false;
      }
      if (static_cast<std::size_t>(target_size) == target.size()) {
        *error = fd_directory_path + "/" + descriptor_entry->d_name +
                 " has an unexpectedly long link target";
        return false;
      }
      const std::string_view target_view(target.data(),
                                         static_cast<std::size_t>(target_size));
      constexpr std::string_view kDeletedSuffix = " (deleted)";
      const bool is_playback_target =
          target_view == kPlaybackDevice ||
          (target_view.starts_with(kPlaybackDevice) &&
           target_view.substr(sizeof(kPlaybackDevice) - 1) == kDeletedSuffix);
      if (!is_playback_target) {
        continue;
      }
      struct stat descriptor_status{};
      if (fstatat(dirfd(descriptors.get()), descriptor_entry->d_name,
                  &descriptor_status, 0) != 0) {
        const int error_number = errno;
        if (error_number == ENOENT) {
          continue;
        }
        *error = ErrnoText(fd_directory_path + "/" + descriptor_entry->d_name,
                           error_number);
        return false;
      }
      if (S_ISCHR(descriptor_status.st_mode) &&
          descriptor_status.st_rdev == playback_device) {
        *error = "PCM 0,0 is open at " + fd_directory_path + "/" +
                 descriptor_entry->d_name + "; stop all speaker playback";
        return false;
      }
    }
    if (!descriptors.Close(fd_directory_path, error)) {
      return false;
    }
  }
  return proc.Close("/proc", error);
}

bool CheckPlaybackClosed(std::string* error) {
  PlaybackIdentity before{};
  PlaybackIdentity after{};
  if (!CheckPlaybackIdentity(&before, error) ||
      !CheckPlaybackStatus(error) ||
      !CheckNoPlaybackFileDescriptor(before.character_device, error) ||
      !CheckPlaybackStatus(error) ||
      !CheckPlaybackIdentity(&after, error)) {
    return false;
  }
  if (!(before == after)) {
    *error = "PCM 0,0 character-device identity changed during fd scan";
    return false;
  }
  return true;
}

bool ReadGeneration(Generation* generation, std::string* error) {
  std::string restart;
  std::string coredump;
  if (!ReadSmallFile(kRestartCount, &restart, error) ||
      !ReadSmallFile(kCoredumpCount, &coredump, error) ||
      !ParseUnsignedDecimal(TrimAscii(std::move(restart)),
                            &generation->restart_count, error) ||
      !ParseUnsignedDecimal(TrimAscii(std::move(coredump)),
                            &generation->coredump_count, error)) {
    return false;
  }
  return true;
}

bool CheckGeneration(const Generation& expected, std::string* error) {
  Generation actual{};
  if (!ReadGeneration(&actual, error)) {
    return false;
  }
  if (!(actual == expected)) {
    std::ostringstream message;
    message << "AoC generation changed: restart " << expected.restart_count
            << "->" << actual.restart_count << ", coredump "
            << expected.coredump_count << "->" << actual.coredump_count
            << "; reboot the device before any further patch action";
    *error = message.str();
    return false;
  }
  return true;
}

bool CheckRuntimeGuards(const Generation& generation, std::string* error) {
  return CheckPlaybackClosed(error) && CheckGeneration(generation, error);
}

bool SleepFor(std::chrono::milliseconds duration, std::string* error) {
  timespec request{
      .tv_sec = static_cast<time_t>(duration.count() / 1000),
      .tv_nsec = static_cast<long>((duration.count() % 1000) * 1000000),
  };
  while (nanosleep(&request, &request) != 0) {
    if (errno == EINTR) {
      continue;
    }
    *error = ErrnoText("nanosleep");
    return false;
  }
  return true;
}

bool CheckTarget(bool allow_incomplete_boot, std::string* error) {
  if (getuid() != 0 || geteuid() != 0) {
    *error = "real and effective uid must both be root";
    return false;
  }
  if (!GetPropertyExact("ro.product.device", kExpectedDevice, error) ||
      !GetPropertyExact("ro.vendor.build.id", kExpectedVendorBuildId, error) ||
      (!allow_incomplete_boot &&
       !GetPropertyExact("sys.boot_completed", "1", error))) {
    return false;
  }
  std::string card_id;
  if (!ReadSmallFile("/proc/asound/card0/id", &card_id, error)) {
    return false;
  }
  card_id = TrimAscii(std::move(card_id));
  if (card_id != "googleaocsndcar") {
    *error =
        "refusing ALSA card0 id='" + card_id + "'; expected googleaocsndcar";
    return false;
  }
  return true;
}

bool Preflight(bool allow_incomplete_boot, Generation* generation,
               std::string* error) {
  if (!CheckTarget(allow_incomplete_boot, error)) {
    return false;
  }
  if (!CheckCharDevice(kFactoryDiag, R_OK, O_RDONLY, error) ||
      !CheckCharDevice(kFactoryDiag, W_OK, O_WRONLY, error) ||
      !CheckCharDevice(kDebugDevice, R_OK, O_RDONLY, error)) {
    return false;
  }
  Generation first{};
  Generation second{};
  if (!CheckPlaybackClosed(error) || !ReadGeneration(&first, error) ||
      !SleepFor(std::chrono::milliseconds(250), error) ||
      !CheckPlaybackClosed(error) || !ReadGeneration(&second, error)) {
    return false;
  }
  if (!(first == second)) {
    *error = "AoC restart/coredump generation is not stable across preflight";
    return false;
  }
  *generation = first;
  return true;
}

bool IsRetryableIoError(int error_number) {
  return error_number == EINTR || error_number == EAGAIN ||
         error_number == EWOULDBLOCK;
}

void PauseBeforeRetry(Clock::time_point deadline) {
  const auto remaining = deadline - Clock::now();
  if (remaining <= Clock::duration::zero()) {
    return;
  }
  const auto delay = std::min(remaining, Clock::duration(kFactoryRetryDelay));
  const auto nanoseconds =
      std::chrono::duration_cast<std::chrono::nanoseconds>(delay);
  timespec pause{
      .tv_sec = static_cast<time_t>(nanoseconds.count() / 1000000000),
      .tv_nsec = static_cast<long>(nanoseconds.count() % 1000000000),
  };
  // An interrupted pause is fine: the caller rechecks the absolute deadline
  // before attempting the nonblocking operation again.
  (void)nanosleep(&pause, nullptr);
}

bool DrainDebugNow(int fd, std::string* error) {
  const Clock::time_point deadline = Clock::now() + kDebugDrainTimeout;
  std::size_t discarded = 0;
  std::array<char, 4096> buffer{};
  while (Clock::now() < deadline && discarded <= kMaximumDebugOutput) {
    const ssize_t count = read(fd, buffer.data(), buffer.size());
    if (count > 0) {
      discarded += static_cast<std::size_t>(count);
      continue;
    }
    if (count == 0 || errno == EAGAIN || errno == EWOULDBLOCK) {
      return true;
    }
    if (errno == EINTR) {
      continue;
    }
    *error = ErrnoText(std::string("read ") + kDebugDevice);
    return false;
  }
  *error = "unable to establish a bounded clean acd-debug boundary";
  return false;
}

bool ReadDumpDebug(int fd, uint32_t address, std::size_t size,
                   std::vector<uint8_t>* bytes, std::string* output,
                   std::string* error) {
  output->clear();
  const Clock::time_point deadline = Clock::now() + kDumpDebugTimeout;
  std::array<char, 4096> buffer{};
  std::string parse_error;
  while (Clock::now() < deadline) {
    const ssize_t count = read(fd, buffer.data(), buffer.size());
    if (count > 0) {
      output->append(buffer.data(), static_cast<std::size_t>(count));
      if (ParseMemoryDump(*output, address, size, bytes, &parse_error)) {
        return true;
      }
      // Continuous unrelated AoC logging must not grow memory without bound.
      // Retain a tail large enough for any supported 256-byte memory dump.
      if (output->size() > kMaximumDebugOutput) {
        output->erase(0, output->size() - kMaximumDebugOutput);
      }
      continue;
    }
    if (count < 0 && errno == EINTR) {
      continue;
    }
    if (count < 0 && errno != EAGAIN && errno != EWOULDBLOCK) {
      *error = ErrnoText(std::string("read ") + kDebugDevice);
      return false;
    }
    // This service can transiently return either zero or EAGAIN while the
    // independently acknowledged dump is still being formatted. Polling has
    // not been reliable on every AoC service revision, so retry the owned
    // nonblocking descriptor against one absolute deadline.
    PauseBeforeRetry(deadline);
  }
  if (parse_error.empty()) {
    (void)ParseMemoryDump(*output, address, size, bytes, &parse_error);
  }
  *error = parse_error + "; debug output: " + *output;
  return false;
}

class FactoryDiag {
 public:
  FactoryDiag() {
    timespec now{};
    if (clock_gettime(CLOCK_MONOTONIC, &now) == 0) {
      counter_ = static_cast<uint8_t>(now.tv_nsec);
    }
  }

  bool Dump(int32_t core, uint32_t address, std::size_t size,
            std::vector<uint8_t>* bytes, std::string* error) {
    if (size == 0 || size > 256) {
      *error = "memory dump size must be 1..256 bytes";
      return false;
    }
    // Open and drain the debug service before issuing the command. The AoC
    // service is message-backed and exclusive-open, so retaining this exact
    // descriptor both establishes the request boundary and preserves a dump
    // line that is emitted before the factory acknowledgement is read.
    UniqueFd debug_fd(open(kDebugDevice, O_RDONLY | O_CLOEXEC | O_NONBLOCK));
    if (!debug_fd.valid()) {
      *error = ErrnoText(std::string("open ") + kDebugDevice);
      return false;
    }
    if (!DrainDebugNow(debug_fd.get(), error)) {
      return false;
    }
    const uint8_t counter = counter_++;
    const std::vector<uint8_t> packet =
        BuildDumpPacket(counter, core, address, static_cast<uint32_t>(size));
    if (!Transact(packet, counter, kCommandMemoryDump, error)) {
      return false;
    }
    std::string debug;
    return ReadDumpDebug(debug_fd.get(), address, size, bytes, &debug, error);
  }

  bool DumpWord(int32_t core, uint32_t address, std::array<uint8_t, 4>* word,
                std::string* error) {
    std::vector<uint8_t> bytes;
    if (!Dump(core, address, word->size(), &bytes, error)) {
      return false;
    }
    std::copy(bytes.begin(), bytes.end(), word->begin());
    return true;
  }

  bool DumpWord(uint32_t address, std::array<uint8_t, 4>* word,
                std::string* error) {
    return DumpWord(kF1Core, address, word, error);
  }

  bool SetWord(int32_t core, uint32_t address, std::span<const uint8_t, 4> word,
               std::string* error) {
    const uint8_t counter = counter_++;
    const std::vector<uint8_t> packet =
        BuildSetWordPacket(counter, core, address, word);
    return Transact(packet, counter, kCommandMemorySet, error);
  }

  bool SetWord(uint32_t address, std::span<const uint8_t, 4> word,
               std::string* error) {
    return SetWord(kF1Core, address, word, error);
  }

 private:
  bool WriteOnePacket(std::span<const uint8_t> packet, std::string* error) {
    const Clock::time_point deadline = Clock::now() + kFactoryWriteTimeout;
    int raw_fd = -1;
    while (Clock::now() < deadline) {
      raw_fd = open(kFactoryDiag, O_WRONLY | O_CLOEXEC | O_NONBLOCK);
      if (raw_fd >= 0) {
        break;
      }
      const int open_error = errno;
      if (!IsRetryableIoError(open_error)) {
        errno = open_error;
        *error = ErrnoText(std::string("open ") + kFactoryDiag + " for write");
        return false;
      }
      PauseBeforeRetry(deadline);
    }
    UniqueFd fd(raw_fd);
    if (!fd.valid()) {
      *error = std::string("timed out opening ") + kFactoryDiag +
               " for nonblocking write";
      return false;
    }

    while (Clock::now() < deadline) {
      const ssize_t count = write(fd.get(), packet.data(), packet.size());
      if (count >= 0) {
        if (static_cast<std::size_t>(count) != packet.size()) {
          // Never continue a short packet: the driver may already have acted
          // on its prefix, so a second write could duplicate the command.
          *error = "short factory_diag packet write; refusing to continue it";
          return false;
        }
        return true;
      }
      const int write_error = errno;
      if (!IsRetryableIoError(write_error)) {
        errno = write_error;
        *error = ErrnoText(std::string("write ") + kFactoryDiag);
        return false;
      }
      // A negative EAGAIN/EINTR write accepted no bytes. Retrying that same
      // complete packet is safe; any positive short write remains one-shot.
      PauseBeforeRetry(deadline);
    }
    *error = std::string("timed out writing one packet to ") + kFactoryDiag;
    return false;
  }

  bool ReadResponse(std::vector<uint8_t>* response, std::string* error) {
    UniqueFd fd(open(kFactoryDiag, O_RDONLY | O_CLOEXEC | O_NONBLOCK));
    if (!fd.valid()) {
      *error = ErrnoText(std::string("open ") + kFactoryDiag + " for read");
      return false;
    }
    response->clear();
    const Clock::time_point deadline = Clock::now() + kFactoryResponseTimeout;
    std::array<uint8_t, kMaximumFactoryResponse> buffer{};
    std::optional<std::size_t> expected_length;
    while (Clock::now() < deadline) {
      const ssize_t count = read(fd.get(), buffer.data(), buffer.size());
      if (count > 0) {
        response->insert(response->end(), buffer.begin(),
                         buffer.begin() + count);
        if (response->size() > kMaximumFactoryResponse) {
          *error = "factory_diag response exceeded the size limit";
          return false;
        }
        if (!expected_length.has_value() && response->size() >= 4) {
          expected_length = static_cast<std::size_t>((*response)[2]) |
                            static_cast<std::size_t>((*response)[3]) << 8;
          if (*expected_length < 8 ||
              *expected_length > kMaximumFactoryResponse) {
            *error = "invalid factory_diag response length field";
            return false;
          }
        }
        if (expected_length.has_value() &&
            response->size() >= *expected_length) {
          if (response->size() != *expected_length) {
            *error = "factory_diag returned trailing or interleaved bytes";
            return false;
          }
          return true;
        }
        continue;
      }
      if (count < 0 && errno == EINTR) {
        continue;
      }
      if (count < 0 && errno != EAGAIN && errno != EWOULDBLOCK) {
        *error = ErrnoText(std::string("read ") + kFactoryDiag);
        return false;
      }
      // Frankel's factory_diag returns EAGAIN and sometimes zero while a
      // reply is pending. Retry the owned nonblocking descriptor only until
      // the absolute response deadline; never resend the command.
      PauseBeforeRetry(deadline);
    }
    *error = response->empty() ? "timed out waiting for factory_diag response"
                               : "timed out assembling factory_diag response";
    return false;
  }

  bool Transact(std::span<const uint8_t> packet, uint8_t counter,
                uint16_t command, std::string* error) {
    if (!WriteOnePacket(packet, error)) {
      return false;
    }
    std::vector<uint8_t> response;
    return ReadResponse(&response, error) &&
           ParseCommandResponse(response, counter, command, error);
  }

  uint8_t counter_ = 0;
};

uint32_t ReadLe32(std::span<const uint8_t> bytes, std::size_t offset) {
  return static_cast<uint32_t>(bytes[offset]) |
         static_cast<uint32_t>(bytes[offset + 1]) << 8 |
         static_cast<uint32_t>(bytes[offset + 2]) << 16 |
         static_cast<uint32_t>(bytes[offset + 3]) << 24;
}

std::array<uint8_t, 4> Le32Bytes(uint32_t value) {
  return {
      static_cast<uint8_t>(value),
      static_cast<uint8_t>(value >> 8),
      static_cast<uint8_t>(value >> 16),
      static_cast<uint8_t>(value >> 24),
  };
}

bool DumpGuarded(FactoryDiag* transport, const Generation& generation,
                 int32_t core, uint32_t address, std::size_t size,
                 std::vector<uint8_t>* bytes, std::string* error) {
  return CheckRuntimeGuards(generation, error) &&
         transport->Dump(core, address, size, bytes, error) &&
         CheckRuntimeGuards(generation, error);
}

bool DumpWordGuarded(FactoryDiag* transport, const Generation& generation,
                     int32_t core, uint32_t address,
                     std::array<uint8_t, 4>* word, std::string* error) {
  return CheckRuntimeGuards(generation, error) &&
         transport->DumpWord(core, address, word, error) &&
         CheckRuntimeGuards(generation, error);
}

bool ReadU32Guarded(FactoryDiag* transport, const Generation& generation,
                    int32_t core, uint32_t address, uint32_t* value,
                    std::string* error) {
  std::array<uint8_t, 4> word{};
  if (!DumpWordGuarded(transport, generation, core, address, &word, error)) {
    return false;
  }
  *value = ReadLe32(word, 0);
  return true;
}

bool SetPatchExact(FactoryDiag* transport, const Generation& generation,
                   int32_t core, const Patch& patch, bool apply,
                   std::string* error) {
  const std::array<uint8_t, 4>& source = apply ? patch.before : patch.after;
  const std::array<uint8_t, 4>& destination =
      apply ? patch.after : patch.before;
  std::array<uint8_t, 4> actual{};
  if (!DumpWordGuarded(transport, generation, core, patch.address, &actual,
                       error)) {
    return false;
  }
  if (actual == destination) {
    return true;
  }
  if (actual != source) {
    std::ostringstream message;
    message << patch.name << " is unknown at 0x" << std::hex
            << std::setfill('0') << std::setw(8) << patch.address << ": "
            << Hex(actual) << " (expected " << Hex(source) << ')';
    *error = message.str();
    return false;
  }
  if (!CheckRuntimeGuards(generation, error) ||
      !transport->SetWord(core, patch.address, destination, error) ||
      !CheckRuntimeGuards(generation, error) ||
      !transport->DumpWord(core, patch.address, &actual, error) ||
      !CheckRuntimeGuards(generation, error) || actual != destination) {
    if (error->empty()) {
      *error = std::string("write verification failed for ") +
               std::string(patch.name);
    }
    return false;
  }
  std::cout << "write   core=" << core << " 0x" << std::hex
            << std::setfill('0') << std::setw(8) << patch.address << ' '
            << Hex(source) << "->" << Hex(destination) << "  " << patch.name
            << std::dec << '\n';
  return true;
}

bool SetU32Exact(FactoryDiag* transport, const Generation& generation,
                 uint32_t address, uint32_t source, uint32_t destination,
                 std::string_view name, std::string* error) {
  const Patch patch{name, address, Le32Bytes(source), Le32Bytes(destination),
                    PatchKind::kHook};
  return SetPatchExact(transport, generation, kF1Core, patch, true, error);
}

bool RequireU32(FactoryDiag* transport, const Generation& generation,
                uint32_t address, uint32_t expected, std::string_view name,
                std::string* error) {
  uint32_t actual = 0;
  if (!ReadU32Guarded(transport, generation, kF1Core, address, &actual,
                      error)) {
    return false;
  }
  if (actual != expected) {
    std::ostringstream message;
    message << name << " at 0x" << std::hex << std::setfill('0')
            << std::setw(8) << address << " is 0x" << std::setw(8) << actual
            << ", expected 0x" << std::setw(8) << expected;
    *error = message.str();
    return false;
  }
  return true;
}

bool ValidateAllocation(FactoryDiag* transport, const Generation& generation,
                        uint32_t allocation, std::string* error) {
  if (allocation == 0 || (allocation & 0x3fU) != 0 ||
      allocation < kHeapMinimum ||
      allocation > kHeapLimit - kAllocationBytes) {
    std::ostringstream message;
    message << "invalid speaker allocation 0x" << std::hex
            << std::setfill('0') << std::setw(8) << allocation;
    *error = message.str();
    return false;
  }
  std::array<uint8_t, 4> ignored{};
  return DumpWordGuarded(transport, generation, kF1Core, allocation, &ignored,
                         error) &&
         DumpWordGuarded(transport, generation, kF1Core,
                         allocation + kAllocationBytes - 4, &ignored, error);
}

bool RequireFixedSpeaker(FactoryDiag* transport,
                         const Generation& generation, std::string* error) {
  constexpr std::array<std::pair<uint32_t, uint32_t>, 16> kFields = {{
      {0x280, 0x00010000}, {0x284, 0x4051c7f8}, {0x288, 0x00001800},
      {0x28c, 4},          {0x290, 2},          {0x294, 3},
      {0x298, 0x30},       {0x29c, 0x300},      {0x2a0, 0xc0},
      {0x2a4, 0x300},      {0x2a8, 0x300},      {0x2ac, 0},
      {0x2b0, 0},          {0x2b4, 0x300},      {0x2c0, 0x4051b8d0},
      {0x2cc, 0x4051b800},
  }};
  if (!RequireU32(transport, generation, kSpeakerObject, kSpeakerVtable,
                  "AudioHardwareSinkSpeaker vtable", error)) {
    return false;
  }
  for (const auto& [offset, expected] : kFields) {
    if (!RequireU32(transport, generation, kSpeakerObject + offset, expected,
                    "idle speaker object field", error)) {
      return false;
    }
  }
  return RequireU32(transport, generation, kSpeakerObject + 0x2d0,
                    0x4051b880, "idle speaker object tail", error);
}

bool RequireDmaRingCommon(FactoryDiag* transport,
                          const Generation& generation,
                          const DmaRingLayout& ring, uint32_t* backing,
                          std::array<uint32_t, 7>* descriptor,
                          std::string* error) {
  const std::array<std::pair<uint32_t, uint32_t>, 12> fields = {{
      {0x00, kRingVtable}, {0x04, 0x28},        {0x14, 3},
      {0x18, kSpeakerObject}, {0x3c, ring.metadata}, {0x44, ring.descriptor},
      {0xe8, 0xffffffff}, {0xfc, 0xffffffff}, {0x108, 5},
      {0x10c, 5},         {0x110, 4},         {0x114, 0x0000ffff},
  }};
  for (const auto& [offset, expected] : fields) {
    if (!RequireU32(transport, generation, ring.address + offset, expected,
                    ring.name, error)) {
      return false;
    }
  }
  if (!RequireU32(transport, generation, ring.address + 0x170, 0xac060040,
                  ring.name, error)) {
    return false;
  }
  const std::string expected_name = std::string(ring.name) + '\0';
  std::vector<uint8_t> name;
  if (!DumpGuarded(transport, generation, kF1Core, ring.address + 0x20,
                   expected_name.size(), &name, error) ||
      !std::equal(name.begin(), name.end(), expected_name.begin())) {
    if (error->empty()) {
      *error = std::string(ring.name) + " name/layout guard failed";
    }
    return false;
  }
  std::vector<uint8_t> readers;
  if (!DumpGuarded(transport, generation, kF1Core, ring.address + 0x48,
                   0x54, &readers, error) ||
      std::any_of(readers.begin(), readers.end(),
                  [](uint8_t byte) { return byte != 0; })) {
    if (error->empty()) {
      *error = std::string(ring.name) + " has an active reader descriptor";
    }
    return false;
  }
  std::vector<uint8_t> descriptor_bytes;
  if (!DumpGuarded(transport, generation, kF1Core, ring.descriptor, 28,
                   &descriptor_bytes, error)) {
    return false;
  }
  for (std::size_t index = 0; index < descriptor->size(); ++index) {
    (*descriptor)[index] = ReadLe32(descriptor_bytes, index * 4);
  }
  return ReadU32Guarded(transport, generation, kF1Core, ring.address + 0x40,
                        backing, error);
}

enum class SpeakerBufferState { kStock, kRebased };

bool ReadSpeakerBufferState(FactoryDiag* transport,
                            const Generation& generation,
                            SpeakerBufferState* state,
                            uint32_t* cpu_allocation,
                            std::string* error) {
  if (!RequireFixedSpeaker(transport, generation, error) ||
      !RequireU32(transport, generation, kTxRingPointerAddress,
                  kDmaRings[0].address, "speaker TX DMA ring pointer", error) ||
      !RequireU32(transport, generation, kRxRingPointerAddress,
                  kDmaRings[1].address, "speaker RX DMA ring pointer", error)) {
    return false;
  }
  uint32_t tx_size = 0;
  uint32_t source_size = 0;
  uint32_t tx_pointer = 0;
  uint32_t source_pointer = 0;
  if (!ReadU32Guarded(transport, generation, kF1Core, kTxSizeAddress,
                      &tx_size, error) ||
      !ReadU32Guarded(transport, generation, kF1Core, kSourceSizeAddress,
                      &source_size, error) ||
      !ReadU32Guarded(transport, generation, kF1Core, kTxPointerAddress,
                      &tx_pointer, error) ||
      !ReadU32Guarded(transport, generation, kF1Core, kSourcePointerAddress,
                      &source_pointer, error)) {
    return false;
  }
  const bool stock = tx_size == kStockBankBytes &&
                     source_size == kStockBankBytes &&
                     tx_pointer == kStockTxPointer &&
                     source_pointer == kStockSourcePointer;
  const bool rebased = tx_size == kNativeBankBytes &&
                       source_size == kNativeBankBytes &&
                       source_pointer == tx_pointer + kNativeBankBytes;
  if (!stock && !rebased) {
    *error = "speaker CPU buffer layout is neither exact stock nor exact "
             "native-q192 rebase; cold reboot required";
    return false;
  }
  if (rebased && !ValidateAllocation(transport, generation, tx_pointer,
                                     error)) {
    return false;
  }
  for (std::size_t index = 0; index < kDmaRings.size(); ++index) {
    uint32_t backing = 0;
    std::array<uint32_t, 7> descriptor{};
    if (!RequireDmaRingCommon(transport, generation, kDmaRings[index],
                              &backing, &descriptor, error)) {
      return false;
    }
    const uint32_t expected_size = stock ? kStockBankBytes : kNativeBankBytes;
    const uint32_t expected_backing =
        stock ? kDmaRings[index].inline_backing
              : tx_pointer + kDmaTxOffset +
                    static_cast<uint32_t>(index) * kNativeBankBytes;
    if (backing != expected_backing || descriptor[0] != 0 ||
        descriptor[1] != expected_size || descriptor[2] != 0 ||
        descriptor[3] != expected_size || descriptor[4] != 0 ||
        descriptor[5] != 0 || descriptor[6] == 0) {
      *error = std::string(kDmaRings[index].name) +
               " is not an empty ring with the selected backing/capacity";
      return false;
    }
  }
  *state = stock ? SpeakerBufferState::kStock : SpeakerBufferState::kRebased;
  *cpu_allocation = stock ? 0 : tx_pointer;
  std::cout << (stock ? "verified exact stock 0x600 speaker banks\n"
                      : "verified exact rebased 0xc00 speaker banks at 0x") ;
  if (rebased) {
    std::cout << std::hex << tx_pointer << std::dec << '\n';
  }
  return true;
}

using H0GeometryStates = std::array<PatchState, kH0GeometryPatchCount>;

bool ReadH0GeometryStates(FactoryDiag* transport,
                          const Generation& generation,
                          H0GeometryStates* states, std::string* error) {
  for (const StockWordRequirement& requirement : kH0StockGeometryWords) {
    std::array<uint8_t, 4> actual{};
    if (!DumpWordGuarded(transport, generation, kH0Core,
                         requirement.address, &actual, error)) {
      return false;
    }
    if (actual != requirement.expected) {
      std::ostringstream message;
      message << requirement.name << " is not stock at 0x" << std::hex
              << std::setfill('0') << std::setw(8) << requirement.address
              << ": got " << Hex(actual) << ", expected "
              << Hex(requirement.expected)
              << "; cold reboot required before conditional geometry apply";
      *error = message.str();
      return false;
    }
  }
  for (std::size_t index = 0; index < kH0GeometryPatches.size(); ++index) {
    const Patch& patch = kH0GeometryPatches[index];
    std::array<uint8_t, 4> actual{};
    if (!DumpWordGuarded(transport, generation, kH0Core, patch.address,
                         &actual, error) ||
        !ClassifyWord(patch, actual, &(*states)[index], error)) {
      return false;
    }
    std::cout << ((*states)[index] == PatchState::kStock ? "stock   "
                                                         : "patched ")
              << "H0 0x" << std::hex << std::setfill('0') << std::setw(8)
              << patch.address << ' ' << Hex(actual) << "  " << patch.name
              << std::dec << '\n';
  }
  const PatchState first = states->front();
  if (!std::all_of(states->begin(), states->end(),
                   [first](PatchState state) { return state == first; })) {
    *error = "H0 conditional speaker geometry is partially patched; cold "
             "reboot required";
    return false;
  }
  return true;
}

bool TransitionH0Geometry(FactoryDiag* transport,
                          const Generation& generation, bool apply,
                          std::string* error) {
  H0GeometryStates states{};
  if (!ReadH0GeometryStates(transport, generation, &states, error)) {
    return false;
  }
  const PatchState destination =
      apply ? PatchState::kPatched : PatchState::kStock;
  if (states[0] == destination) {
    return true;
  }
  if (apply) {
    for (const Patch& patch : kH0GeometryPatches) {
      if (!SetPatchExact(transport, generation, kH0Core, patch, true, error)) {
        return false;
      }
    }
  } else {
    for (auto iterator = kH0GeometryPatches.rbegin();
         iterator != kH0GeometryPatches.rend(); ++iterator) {
      if (!SetPatchExact(transport, generation, kH0Core, *iterator, false,
                         error)) {
        return false;
      }
    }
  }
  if (!ReadH0GeometryStates(transport, generation, &states, error) ||
      states.front() != destination) {
    if (error->empty()) {
      *error = "H0 speaker geometry did not reach a uniform destination";
    }
    return false;
  }
  std::cout << "H0 speaker geometry is now "
            << (apply ? "conditional native-q192; no speaker activation may "
                        "have preceded this cold-boot transaction\n"
                      : "stock; dynamic F1 banks still require reboot to "
                        "roll back\n");
  return true;
}

bool CheckUsfDefaultWorkerIdentity(std::span<const uint8_t> tcb,
                                   std::string* error) {
  constexpr std::array<uint8_t, 16> kName = {0x55, 0x73, 0x66, 0x44, 0x65, 0x66,
                                             0x61, 0x75, 0x6c, 0x74, 0x57, 0x6f,
                                             0x72, 0x6b, 0x65, 0x00};
  if (tcb.size() != kUsfDefaultWorkerTcbGuardSize ||
      ReadLe32(tcb, 0x10) != kUsfDefaultWorkerTcb ||
      ReadLe32(tcb, 0x24) != kUsfDefaultWorkerTcb ||
      ReadLe32(tcb, 0x30) != 0x40165a48 ||
      !std::equal(kName.begin(), kName.end(), tcb.begin() + 0x34) ||
      ReadLe32(tcb, 0x44) != 13 || ReadLe32(tcb, 0x48) != 0) {
    *error = "A32 0x401658f8 is not the reviewed UsfDefaultWorker TCB";
    return false;
  }
  return true;
}

bool ReadUsfDefaultWorkerTcb(FactoryDiag* transport,
                             const Generation& generation,
                             std::vector<uint8_t>* tcb, std::string* error) {
  return CheckRuntimeGuards(generation, error) &&
         transport->Dump(kA32Core, kUsfDefaultWorkerTcb,
                         kUsfDefaultWorkerTcbGuardSize, tcb, error) &&
         CheckRuntimeGuards(generation, error) &&
         CheckUsfDefaultWorkerIdentity(*tcb, error);
}

bool RequireUsfDefaultWorkerStockPriority(FactoryDiag* transport,
                                          const Generation& generation,
                                          std::string* error) {
  uint32_t current = 0;
  uint32_t base = 0;
  int stable_samples = 0;
  for (int attempt = 0; attempt < kWorkerPrioritySettleAttempts; ++attempt) {
    std::vector<uint8_t> tcb;
    if (!ReadUsfDefaultWorkerTcb(transport, generation, &tcb, error)) {
      return false;
    }
    current = ReadLe32(tcb, 0x2c);
    base = ReadLe32(tcb, 0x4c);
    if (current == kUsfDefaultWorkerStockPriority &&
        base == kUsfDefaultWorkerStockPriority) {
      ++stable_samples;
      if (stable_samples == kWorkerPriorityStableSamples) {
        std::cout << "verified stable A32 UsfDefaultWorker current/base "
                     "priority 7; no scheduler field was changed\n";
        return true;
      }
    } else {
      stable_samples = 0;
    }
    // Current priority 8 with an unchanged base priority is the bounded
    // priority-inheritance state observed while an earlier callback drains.
    // It is safe only as a transient read condition; never write either field.
    if (base != kUsfDefaultWorkerStockPriority ||
        (current != kUsfDefaultWorkerStockPriority &&
         current != kUsfDefaultWorkerStockPriority + 1)) {
      *error = "UsfDefaultWorker must remain at stock base priority 7 and "
               "current priority 7 (or transient 8); got " +
               std::to_string(current) + '/' + std::to_string(base) +
               "; reboot to restore stock scheduler state";
      return false;
    }
    if (attempt + 1 < kWorkerPrioritySettleAttempts &&
        !SleepFor(std::chrono::duration_cast<std::chrono::milliseconds>(
                      kWorkerPrioritySettleInterval),
                  error)) {
      return false;
    }
  }
  *error = "UsfDefaultWorker remained at transient priority " +
           std::to_string(current) + '/' + std::to_string(base) +
           " for the one-second settle window; no scheduler field was changed";
  return false;
}

bool ReadA32AllocatorFallbackState(FactoryDiag* transport,
                                   const Generation& generation,
                                   PatchState* state, std::string* error) {
  const Patch& allocator = A32AllocatorFallbackPatch();
  std::array<uint8_t, 4> actual{};
  if (!CheckRuntimeGuards(generation, error) ||
      !transport->DumpWord(kA32Core, allocator.address, &actual, error) ||
      !CheckRuntimeGuards(generation, error) ||
      !ClassifyWord(allocator, actual, state, error)) {
    return false;
  }

  const StockWordRequirement& timer_assert = A32TimerAssertionStockWord();
  std::array<uint8_t, 4> assertion{};
  if (!transport->DumpWord(kA32Core, timer_assert.address, &assertion, error) ||
      !CheckRuntimeGuards(generation, error)) {
    return false;
  }
  if (assertion != timer_assert.expected) {
    std::ostringstream message;
    message << timer_assert.name << " is not stock at 0x" << std::hex
            << std::setfill('0') << std::setw(8) << timer_assert.address << ": "
            << Hex(assertion) << " (expected " << Hex(timer_assert.expected)
            << ')';
    *error = message.str();
    return false;
  }
  std::cout << (*state == PatchState::kStock ? "stock   " : "patched ") << "0x"
            << std::hex << std::setfill('0') << std::setw(8)
            << allocator.address << ' ' << Hex(actual) << "  " << allocator.name
            << std::dec << '\n';
  return true;
}

bool RequireA32AllocatorFallbackApplied(FactoryDiag* transport,
                                        const Generation& generation,
                                        std::string* error) {
  PatchState state;
  if (!ReadA32AllocatorFallbackState(transport, generation, &state, error)) {
    return false;
  }
  if (state != PatchState::kPatched) {
    *error =
        "A32 allocator fallback is stock; run guarded live apply before "
        "certifying the speaker profile";
    return false;
  }
  return true;
}

bool RequireKnownA32AllocatorFallback(FactoryDiag* transport,
                                      const Generation& generation,
                                      std::string* error) {
  PatchState state;
  return ReadA32AllocatorFallbackState(transport, generation, &state, error);
}

struct A32OutputterTimerSnapshot {
  uint32_t pointer_address;
  uint32_t context;
  uint32_t address;
  uint32_t callback;
};

bool SameA32OutputterTimer(const A32OutputterTimerSnapshot& left,
                           const A32OutputterTimerSnapshot& right) {
  return left.pointer_address == right.pointer_address &&
         left.context == right.context && left.address == right.address;
}

bool RequireA32WorkPoolSafe(FactoryDiag* transport,
                            const Generation& generation, std::string* error) {
  std::array<uint8_t, 4> pointer_word{};
  std::vector<uint8_t> body;
  if (!CheckRuntimeGuards(generation, error) ||
      !transport->DumpWord(kA32Core, kA32WorkPoolPointerAddress, &pointer_word,
                           error) ||
      !CheckRuntimeGuards(generation, error)) {
    return false;
  }
  const uint32_t pointer = ReadLe32(pointer_word, 0);
  if (pointer != kA32WorkPoolAddress) {
    std::ostringstream message;
    message << "A32 work-pool pointer is 0x" << std::hex << std::setfill('0')
            << std::setw(8) << pointer << "; expected 0x" << std::setw(8)
            << kA32WorkPoolAddress;
    *error = message.str();
    return false;
  }
  if (!transport->Dump(kA32Core, pointer, kA32WorkPoolGuardSize, &body,
                       error) ||
      !CheckRuntimeGuards(generation, error) ||
      !ValidateA32WorkPoolSnapshot(pointer, body, error)) {
    return false;
  }
  std::cout << "verified A32 work pool 0x" << std::hex << pointer << std::dec
            << " has a nonempty freelist and at most 8 users\n";
  return true;
}

bool ReadA32OutputterTimer(FactoryDiag* transport, const Generation& generation,
                           A32OutputterTimerSnapshot* snapshot,
                           std::string* error) {
  std::array<A32OutputterTimerSnapshot, kA32OutputterTimerLayouts.size()>
      matches{};
  std::vector<std::string> failures;
  std::size_t match_count = 0;
  for (const A32OutputterTimerLayout& layout : kA32OutputterTimerLayouts) {
    std::array<uint8_t, 4> pointer_word{};
    if (!CheckRuntimeGuards(generation, error) ||
        !transport->DumpWord(kA32Core, layout.pointer_address, &pointer_word,
                             error) ||
        !CheckRuntimeGuards(generation, error)) {
      return false;
    }
    const uint32_t timer = ReadLe32(pointer_word, 0);
    if (timer == 0) {
      continue;
    }
    if (timer < kA32OutputterTimerMinimum ||
        timer > kA32OutputterTimerMaximum || (timer & 7U) != 0) {
      std::ostringstream message;
      message << "owner 0x" << std::hex << std::setfill('0') << std::setw(8)
              << layout.pointer_address << " contains implausible pointer 0x"
              << std::setw(8) << timer;
      failures.push_back(message.str());
      continue;
    }

    std::vector<uint8_t> body;
    if (!transport->Dump(kA32Core, timer, kA32OutputterTimerGuardSize, &body,
                         error) ||
        !CheckRuntimeGuards(generation, error)) {
      return false;
    }
    uint32_t callback = 0;
    std::string validation_error;
    if (!ValidateA32OutputterTimerSnapshot(layout, timer, body, &callback,
                                           &validation_error)) {
      std::ostringstream message;
      message << "owner 0x" << std::hex << std::setfill('0') << std::setw(8)
              << layout.pointer_address << ": " << validation_error;
      failures.push_back(message.str());
      continue;
    }
    if (match_count < matches.size()) {
      matches[match_count] = {
          .pointer_address = layout.pointer_address,
          .context = layout.context,
          .address = timer,
          .callback = callback,
      };
    }
    ++match_count;
  }

  if (match_count != 1) {
    std::ostringstream message;
    message << "expected exactly one guarded A32 OUTPUTTER timer, found "
            << match_count;
    if (failures.empty()) {
      message << (match_count == 0 ? "; both reviewed owner slots are null"
                                  : "; both reviewed layouts validated");
    } else {
      message << ": ";
      for (std::size_t index = 0; index < failures.size(); ++index) {
        if (index != 0) {
          message << "; ";
        }
        message << failures[index];
      }
    }
    *error = message.str();
    return false;
  }
  *snapshot = matches[0];
  return true;
}

bool RestoreA32OutputterCallback(FactoryDiag* transport,
                                 const Generation& generation,
                                 const A32OutputterTimerSnapshot& expected,
                                 std::string* error) {
  A32OutputterTimerSnapshot current{};
  if (!ReadA32OutputterTimer(transport, generation, &current, error)) {
    return false;
  }
  if (!SameA32OutputterTimer(current, expected)) {
    std::ostringstream message;
    message << "A32 OUTPUTTER layout/timer changed from owner 0x" << std::hex
            << expected.pointer_address << " timer 0x" << expected.address
            << " to owner 0x" << current.pointer_address << " timer 0x"
            << current.address << "; refusing a blind callback restore";
    *error = message.str();
    return false;
  }
  if (current.callback == kA32WholeCacheInvalidator) {
    const std::array<uint8_t, 4> stock_callback =
        Le32Bytes(kA32OutputterCallback);
    if (!CheckRuntimeGuards(generation, error) ||
        !transport->SetWord(kA32Core, expected.address + 0x28, stock_callback,
                            error) ||
        !CheckRuntimeGuards(generation, error)) {
      return false;
    }
  } else if (current.callback != kA32OutputterCallback) {
    // Validation above already rejects this case; keep the condition explicit
    // so this recovery routine can never gain an implicit third state.
    *error = "A32 OUTPUTTER callback has an unrecognized restore source";
    return false;
  }

  A32OutputterTimerSnapshot restored{};
  if (!ReadA32OutputterTimer(transport, generation, &restored, error) ||
      !SameA32OutputterTimer(restored, expected) ||
      restored.callback != kA32OutputterCallback) {
    if (error->empty()) {
      *error = "A32 OUTPUTTER callback restore readback failed";
    }
    return false;
  }
  std::cout << "restored and verified the stock A32 OUTPUTTER callback\n";
  return true;
}

bool FlushA32InstructionCacheViaOutputter(FactoryDiag* transport,
                                          const Generation& generation,
                                          const A32OutputterTimerSnapshot& expected,
                                          std::string* error) {
  std::string invocation_error;
  A32OutputterTimerSnapshot before{};
  bool invocation_ok =
      RequireUsfDefaultWorkerStockPriority(transport, generation,
                                           &invocation_error) &&
      RequireA32WorkPoolSafe(transport, generation, &invocation_error) &&
      ReadA32OutputterTimer(transport, generation, &before, &invocation_error);
  if (invocation_ok && !SameA32OutputterTimer(before, expected)) {
    std::ostringstream message;
    message << "A32 OUTPUTTER layout/timer changed from owner 0x" << std::hex
            << expected.pointer_address << " timer 0x" << expected.address
            << " to owner 0x" << before.pointer_address << " timer 0x"
            << before.address << " before callback arm";
    invocation_error = message.str();
    invocation_ok = false;
  }
  if (invocation_ok && before.callback != kA32OutputterCallback) {
    invocation_error =
        "A32 OUTPUTTER callback is not stock before cache synchronization; "
        "reboot before retrying";
    invocation_ok = false;
  }

  // Once the command write is attempted, its response can be lost after AoC
  // has already changed memory. Always enter the exact inspect/restore path.
  bool callback_write_attempted = false;
  if (invocation_ok) {
    callback_write_attempted = true;
    const std::array<uint8_t, 4> invalidator =
        Le32Bytes(kA32WholeCacheInvalidator);
    invocation_ok = CheckRuntimeGuards(generation, &invocation_error) &&
                    transport->SetWord(kA32Core, expected.address + 0x28,
                                       invalidator, &invocation_error) &&
                    CheckRuntimeGuards(generation, &invocation_error);
  }

  A32OutputterTimerSnapshot armed{};
  if (invocation_ok && (!ReadA32OutputterTimer(transport, generation, &armed,
                                               &invocation_error) ||
                        !SameA32OutputterTimer(armed, expected) ||
                        armed.callback != kA32WholeCacheInvalidator)) {
    if (invocation_error.empty()) {
      invocation_error = "A32 OUTPUTTER cache callback arm readback failed";
    }
    invocation_ok = false;
  }
  if (invocation_ok) {
    std::cout << "armed A32 OUTPUTTER whole-cache callback at 0x" << std::hex
              << expected.address + 0x28 << std::dec << "; waiting "
              << std::chrono::duration_cast<std::chrono::seconds>(
                     kA32CacheCallbackWait)
                     .count()
              << " seconds\n";
    invocation_ok =
        SleepFor(std::chrono::duration_cast<std::chrono::milliseconds>(
                     kA32CacheCallbackWait),
                 &invocation_error);
  }

  A32OutputterTimerSnapshot after_wait{};
  if (invocation_ok &&
      (!ReadA32OutputterTimer(transport, generation, &after_wait,
                              &invocation_error) ||
       !SameA32OutputterTimer(after_wait, expected) ||
       after_wait.callback != kA32WholeCacheInvalidator)) {
    if (invocation_error.empty()) {
      invocation_error =
          "A32 OUTPUTTER timer changed during cache synchronization";
    }
    invocation_ok = false;
  }

  std::string restore_error;
  const bool restore_ok =
      !callback_write_attempted ||
      RestoreA32OutputterCallback(transport, generation, expected,
                                  &restore_error);
  if (!restore_ok) {
    *error =
        invocation_ok
            ? "A32 OUTPUTTER callback restoration failed: " + restore_error +
                  "; reboot immediately"
            : "A32 cache synchronization failed (" + invocation_error +
                  "); additionally callback restoration failed (" +
                  restore_error + "); reboot immediately";
    return false;
  }
  if (!invocation_ok) {
    *error = invocation_error;
    return false;
  }
  if (!RequireA32WorkPoolSafe(transport, generation, error) ||
      !RequireUsfDefaultWorkerStockPriority(transport, generation, error)) {
    return false;
  }
  std::cout << "A32 whole-cache invocation completed its guarded timing "
               "window; UsfDefaultWorker remains stock priority 7\n";
  return true;
}

bool WaitForA32PreparationWindow(FactoryDiag* transport,
                                 const Generation& generation,
                                 A32OutputterTimerSnapshot* timer,
                                 std::string* error) {
  const Clock::time_point deadline = Clock::now() + kA32PreparationWindow;
  bool saw_guarded_timer = false;
  std::string last_transient_error;
  while (Clock::now() < deadline) {
    A32OutputterTimerSnapshot candidate{};
    std::string timer_error;
    if (!ReadA32OutputterTimer(transport, generation, &candidate,
                               &timer_error)) {
      if (saw_guarded_timer) {
        *error = "guarded A32 OUTPUTTER timer disappeared while waiting for "
                 "the work pool: " +
                 timer_error;
        return false;
      }
      last_transient_error = timer_error;
    } else {
      saw_guarded_timer = true;
      if (candidate.callback != kA32OutputterCallback) {
        *error = "A32 OUTPUTTER callback is not stock while waiting for the "
                 "preparation window; cold reboot required";
        return false;
      }
      std::string pool_error;
      if (RequireA32WorkPoolSafe(transport, generation, &pool_error)) {
        *timer = candidate;
        std::cout << "qualified simultaneous guarded OUTPUTTER timer and "
                     "safe A32 work-pool window\n";
        return true;
      }
      if (!std::string_view(pool_error).starts_with(
              "unsafe A32 work-pool state:")) {
        *error = pool_error;
        return false;
      }
      last_transient_error = pool_error;
    }
    if (!SleepFor(kA32PreparationPollInterval, error)) {
      return false;
    }
  }
  *error = "timed out waiting for simultaneous guarded A32 timer and safe "
           "work pool";
  if (!last_transient_error.empty()) {
    *error += ": " + last_transient_error;
  }
  return false;
}

bool EnsureA32AllocatorFallbackApplied(FactoryDiag* transport,
                                       const Generation& generation,
                                       bool attempt_live_patch,
                                       std::string* error) {
  PatchState state;
  if (!ReadA32AllocatorFallbackState(transport, generation, &state, error) ||
      !RequireUsfDefaultWorkerStockPriority(transport, generation, error)) {
    return false;
  }
  const Patch& allocator = A32AllocatorFallbackPatch();
  if (state == PatchState::kStock) {
    if (!attempt_live_patch) {
      std::cout << "retaining the exact stock A32 allocator for the late "
                   "warmed F1 allocation\n";
      return SetA32Ready(false, error);
    }
    A32OutputterTimerSnapshot timer{};
    if (!WaitForA32PreparationWindow(transport, generation, &timer, error)) {
      std::cout << "warning: bounded A32 cache-sync window unavailable ("
                << *error << "); retaining the exact stock allocator for the "
                   "late warmed F1 transaction\n";
      error->clear();
      return SetA32Ready(false, error);
    }
    std::array<uint8_t, 4> source{};
    if (!CheckRuntimeGuards(generation, error) ||
        !transport->DumpWord(kA32Core, allocator.address, &source, error) ||
        !CheckRuntimeGuards(generation, error) || source != allocator.before) {
      if (error->empty()) {
        *error = "A32 allocator changed after its stock-state guard";
      }
      return false;
    }
    if (!transport->SetWord(kA32Core, allocator.address, allocator.after,
                            error) ||
        !CheckRuntimeGuards(generation, error)) {
      return false;
    }
    if (!ReadA32AllocatorFallbackState(transport, generation, &state, error) ||
        state != PatchState::kPatched) {
      if (error->empty()) {
        *error = "A32 allocator fallback write did not verify";
      }
      return false;
    }
    std::cout << "write   0x" << std::hex << std::setfill('0') << std::setw(8)
              << allocator.address << ' ' << Hex(allocator.before) << "->"
              << Hex(allocator.after) << "  " << allocator.name << std::dec
              << '\n';
    if (!FlushA32InstructionCacheViaOutputter(transport, generation, timer,
                                              error) ||
        !RequireA32AllocatorFallbackApplied(transport, generation, error) ||
        !RequireUsfDefaultWorkerStockPriority(transport, generation, error) ||
        !SetA32Ready(true, error)) {
      return false;
    }
    return true;
  }
  if (!RequireA32WorkPoolSafe(transport, generation, error) ||
      !GetPropertyExact(kA32ReadyProperty, "1", error)) {
    *error = "A32 allocator word is patched without a successful cache-sync "
             "certificate; cold reboot required: " +
             *error;
    return false;
  }
  std::cout << "A32 allocator fallback is already live-patched and carries "
               "this boot's cache-sync certificate\n";
  return true;
}

bool RequireA32RuntimeProfileApplied(FactoryDiag* transport,
                                     const Generation& generation,
                                     std::string* error) {
  PatchState state;
  if (!ReadA32AllocatorFallbackState(transport, generation, &state, error) ||
      !RequireUsfDefaultWorkerStockPriority(transport, generation, error) ||
      !RequireA32WorkPoolSafe(transport, generation, error)) {
    return false;
  }
  if (state == PatchState::kStock) {
    if (!GetPropertyExact(kA32ReadyProperty, "0", error)) {
      return false;
    }
    std::cout << "verified exact stock A32 allocator after the warmed F1 "
                 "allocation and complete speaker rebase succeeded\n";
    return true;
  }
  if (!GetPropertyExact(kA32ReadyProperty, "1", error)) {
    return false;
  }
  std::cout << "verified live A32 allocator profile with its boot-local "
               "cache-sync certificate and stock worker priority\n";
  return true;
}

bool ReadStates(FactoryDiag* transport, const Generation& generation,
                std::vector<PatchState>* states, std::string* error) {
  states->clear();
  for (const Patch& patch : Patches()) {
    if (!CheckRuntimeGuards(generation, error)) {
      return false;
    }
    std::array<uint8_t, 4> actual{};
    if (!transport->DumpWord(patch.address, &actual, error) ||
        !CheckRuntimeGuards(generation, error)) {
      return false;
    }
    PatchState state;
    if (!ClassifyWord(patch, actual, &state, error)) {
      return false;
    }
    states->push_back(state);
    std::cout << (state == PatchState::kStock ? "stock   " : "patched ") << "0x"
              << std::hex << std::setfill('0') << std::setw(8) << patch.address
              << ' ' << Hex(actual) << "  " << patch.name << std::dec << '\n';
  }
  return true;
}

bool RequireUnselectedSitesStock(FactoryDiag* transport,
                                 const Generation& generation,
                                 std::string* error) {
  for (const StockWordRequirement& requirement : UnselectedStockWords()) {
    if (!CheckRuntimeGuards(generation, error)) {
      return false;
    }
    std::array<uint8_t, 4> actual{};
    if (!transport->DumpWord(requirement.address, &actual, error) ||
        !CheckRuntimeGuards(generation, error)) {
      return false;
    }
    if (actual != requirement.expected) {
      std::ostringstream message;
      message << "unselected speaker patch site is not stock at 0x" << std::hex
              << std::setfill('0') << std::setw(8) << requirement.address
              << ": " << Hex(actual) << " (expected "
              << Hex(requirement.expected) << ")";
      *error = message.str();
      return false;
    }
  }
  return true;
}

bool RequireStockCacheDispatch(FactoryDiag* transport,
                               const Generation& generation,
                               std::string* error) {
  if (!CheckRuntimeGuards(generation, error)) {
    return false;
  }
  std::array<uint8_t, 4> actual{};
  if (!transport->DumpWord(kCacheFlushDispatch.address, &actual, error) ||
      !CheckRuntimeGuards(generation, error)) {
    return false;
  }
  if (actual != kCacheFlushDispatch.before) {
    std::ostringstream message;
    message << "whole-I-cache dispatch is not stock at 0x" << std::hex
            << std::setfill('0') << std::setw(8) << kCacheFlushDispatch.address
            << ": " << Hex(actual) << " (required "
            << Hex(kCacheFlushDispatch.before) << ')';
    *error = message.str();
    return false;
  }
  return true;
}

bool FlushInstructionCache(FactoryDiag* transport, const Generation& generation,
                           mixer* card, std::string* error) {
  if (!RequireStockCacheDispatch(transport, generation, error)) {
    return false;
  }

  std::string invocation_error;
  bool invocation_ok =
      CheckRuntimeGuards(generation, &invocation_error) &&
      transport->SetWord(kCacheFlushDispatch.address, kCacheFlushDispatch.after,
                         &invocation_error) &&
      CheckRuntimeGuards(generation, &invocation_error);
  std::array<uint8_t, 4> installed{};
  if (invocation_ok && (!transport->DumpWord(kCacheFlushDispatch.address,
                                             &installed, &invocation_error) ||
                        installed != kCacheFlushDispatch.after ||
                        !CheckRuntimeGuards(generation, &invocation_error))) {
    if (invocation_error.empty()) {
      invocation_error =
          "cache-flush dispatch install readback failed: " + Hex(installed);
    }
    invocation_ok = false;
  }

  int mixer_result = 1;
  if (invocation_ok) {
    const bool trigger_ok =
        TriggerCacheFlushControl(card, &mixer_result, &invocation_error);
    const bool dwell_ok =
        SleepFor(std::chrono::duration_cast<std::chrono::milliseconds>(
                     kF1ControlCompletionWait),
                 &invocation_error);
    const bool worker_idle =
        RequireUsfDefaultWorkerStockPriority(transport, generation,
                                             &invocation_error);
    invocation_ok = trigger_ok && dwell_ok && worker_idle;
  }
  if (invocation_ok) {
    std::cout << "invoked HD Mic CMD 0x016c whole-I-cache invalidator "
                 "(libtinyalsa result "
              << mixer_result << ", expected F1 rc=64)\n";
  }

  // Always try to restore this transient function pointer. The source word
  // is re-read first so an AoC reset or third-party mutation cannot be
  // overwritten blindly.
  std::string restore_error;
  std::array<uint8_t, 4> current{};
  bool restore_ok = transport->DumpWord(kCacheFlushDispatch.address, &current,
                                        &restore_error);
  if (restore_ok && current == kCacheFlushDispatch.after) {
    restore_ok = transport->SetWord(kCacheFlushDispatch.address,
                                    kCacheFlushDispatch.before, &restore_error);
  } else if (restore_ok && current != kCacheFlushDispatch.before) {
    restore_error =
        "cache-flush dispatch changed unexpectedly before "
        "restore: " +
        Hex(current);
    restore_ok = false;
  }
  std::array<uint8_t, 4> restored{};
  if (restore_ok && (!transport->DumpWord(kCacheFlushDispatch.address,
                                          &restored, &restore_error) ||
                     restored != kCacheFlushDispatch.before)) {
    if (restore_error.empty()) {
      restore_error =
          "cache-flush dispatch restore readback failed: " + Hex(restored);
    }
    restore_ok = false;
  }
  if (!restore_ok) {
    *error = invocation_ok ? restore_error
                           : "cache flush failed (" + invocation_error +
                                 "); additionally dispatch restore failed (" +
                                 restore_error + ')';
    return false;
  }
  if (!invocation_ok) {
    *error = invocation_error;
    return false;
  }
  if (!RequireStockCacheDispatch(transport, generation, error)) {
    return false;
  }
  std::cout << "restored and verified the stock HD Mic dispatch pointer\n";
  return true;
}

bool ReadTemporaryAllocatorScaffold(
    FactoryDiag* transport, const Generation& generation,
    uint32_t* scratch_value, std::string* error) {
  const auto require_stock = [&](const Patch& patch) {
    std::array<uint8_t, 4> actual{};
    if (!DumpWordGuarded(transport, generation, kF1Core, patch.address,
                         &actual, error)) {
      return false;
    }
    if (actual != patch.before) {
      std::ostringstream message;
      message << "temporary allocator site is not stock at 0x" << std::hex
              << std::setfill('0') << std::setw(8) << patch.address << ": "
              << Hex(actual) << " (expected " << Hex(patch.before) << "; "
              << patch.name << "); cold reboot required";
      *error = message.str();
      return false;
    }
    return true;
  };
  if (!require_stock(kD12AllocatorQuarantine)) {
    return false;
  }
  for (const Patch& patch : kAllocatorScratchPatches) {
    if (!require_stock(patch)) {
      return false;
    }
  }
  for (const Patch& patch : kAllocatorBodyPatches) {
    if (!require_stock(patch)) {
      return false;
    }
  }
  if (!require_stock(kAllocatorDispatch) ||
      !RequireU32(transport, generation, kAlignedAllocLiteralAddress,
                  kAlignedAllocLiteral, "aligned_alloc literal", error) ||
      !ReadU32Guarded(transport, generation, kF1Core,
                      kAllocatorScratchAddress, scratch_value, error)) {
    return false;
  }
  return true;
}

bool RestoreTemporaryAllocator(FactoryDiag* transport,
                               const Generation& generation, mixer* card,
                               std::string* error) {
  // First make the temporary allocator unreachable from the HD Mic command.
  std::array<uint8_t, 4> dispatch{};
  if (!DumpWordGuarded(transport, generation, kF1Core,
                       kAllocatorDispatch.address, &dispatch, error)) {
    return false;
  }
  if (dispatch == kAllocatorDispatch.after) {
    if (!SetPatchExact(transport, generation, kF1Core, kAllocatorDispatch,
                       false, error)) {
      return false;
    }
  } else if (dispatch != kAllocatorDispatch.before) {
    *error = "temporary allocator dispatch changed unexpectedly; cold reboot "
             "required";
    return false;
  }

  std::array<uint8_t, 4> callback{};
  if (!DumpWordGuarded(transport, generation, kF1Core,
                       kD12AllocatorQuarantine.address, &callback, error)) {
    return false;
  }
  if (callback == kD12AllocatorQuarantine.before) {
    // Executable restoration is safe only while the stock D12 callback is
    // disconnected. If it is already reachable, every body word must still
    // be stock; otherwise only a cold reset is a defensible recovery.
    for (const Patch& patch : kAllocatorBodyPatches) {
      std::array<uint8_t, 4> actual{};
      if (!DumpWordGuarded(transport, generation, kF1Core, patch.address,
                           &actual, error)) {
        return false;
      }
      if (actual != patch.before) {
        *error = "temporary allocator body is reachable through the stock D12 "
                 "callback; cold reboot required";
        return false;
      }
    }
    return true;
  }
  if (callback != kD12AllocatorQuarantine.after) {
    *error = "D12 callback quarantine changed unexpectedly; cold reboot "
             "required";
    return false;
  }

  // A redirected control callback may still be unwinding after the host sees
  // its result. Do not rewrite code that worker could still be executing.
  // The bounded reader accepts only the observed transient 8/7 state and
  // performs no scheduler writes.
  if (!RequireUsfDefaultWorkerStockPriority(transport, generation, error)) {
    *error += "; temporary allocator remains quarantined; cold reboot required";
    return false;
  }

  bool body_changed = false;
  for (auto iterator = kAllocatorBodyPatches.rbegin();
       iterator != kAllocatorBodyPatches.rend(); ++iterator) {
    std::array<uint8_t, 4> actual{};
    if (!DumpWordGuarded(transport, generation, kF1Core, iterator->address,
                         &actual, error)) {
      return false;
    }
    if (actual == iterator->after) {
      if (!SetPatchExact(transport, generation, kF1Core, *iterator, false,
                         error)) {
        return false;
      }
      body_changed = true;
    } else if (actual != iterator->before) {
      *error = "temporary allocator body changed unexpectedly; cold reboot "
               "required";
      return false;
    }
  }
  if (body_changed &&
      !FlushInstructionCache(transport, generation, card, error)) {
    *error += "; D12 remains quarantined; cold reboot required";
    return false;
  }
  for (auto iterator = kAllocatorScratchPatches.rbegin();
       iterator != kAllocatorScratchPatches.rend(); ++iterator) {
    std::array<uint8_t, 4> actual{};
    if (!DumpWordGuarded(transport, generation, kF1Core, iterator->address,
                         &actual, error)) {
      return false;
    }
    if (actual == iterator->after) {
      if (!SetPatchExact(transport, generation, kF1Core, *iterator, false,
                         error)) {
        return false;
      }
    } else if (actual != iterator->before) {
      *error = "temporary allocator literal changed unexpectedly; cold reboot "
               "required";
      return false;
    }
  }
  if (!SetPatchExact(transport, generation, kF1Core,
                     kD12AllocatorQuarantine, false, error)) {
    return false;
  }
  return CheckRuntimeGuards(generation, error);
}

bool AllocateSpeakerStorage(FactoryDiag* transport,
                            const Generation& generation, mixer* card,
                            uint32_t* allocation, std::string* error) {
  uint32_t scratch = 0;
  if (!ReadTemporaryAllocatorScaffold(transport, generation, &scratch,
                                      error)) {
    return false;
  }
  if (scratch != 0) {
    *error = "allocator scratch is already nonzero; refusing a second 0x3000 "
             "allocation";
    return false;
  }

  std::string operation_error;
  const auto fail_with_cleanup = [&](std::string failure) {
    std::string cleanup_error;
    if (!RestoreTemporaryAllocator(transport, generation, card,
                                   &cleanup_error)) {
      *error = std::move(failure) + "; temporary allocator cleanup failed: " +
               cleanup_error;
    } else {
      *error = std::move(failure);
    }
    return false;
  };

  if (!SetPatchExact(transport, generation, kF1Core,
                     kD12AllocatorQuarantine, true, &operation_error)) {
    return fail_with_cleanup(operation_error);
  }
  for (const Patch& patch : kAllocatorScratchPatches) {
    if (!SetPatchExact(transport, generation, kF1Core, patch, true,
                       &operation_error)) {
      return fail_with_cleanup(operation_error);
    }
  }
  for (const Patch& patch : kAllocatorBodyPatches) {
    if (!SetPatchExact(transport, generation, kF1Core, patch, true,
                       &operation_error)) {
      return fail_with_cleanup(operation_error);
    }
  }
  if (!FlushInstructionCache(transport, generation, card, &operation_error) ||
      !SetPatchExact(transport, generation, kF1Core, kAllocatorDispatch, true,
                     &operation_error)) {
    return fail_with_cleanup(operation_error);
  }

  int mixer_result = 1;
  const bool invoked =
      TriggerCacheFlushControl(card, &mixer_result, &operation_error);
  bool publication_read_ok = true;
  bool publication_observed = false;
  uint32_t first_allocation = 0;
  uint32_t second_allocation = 0;
  // The allocator is deliberately one-shot. Poll its result cookie while the
  // dispatch is armed and disconnect immediately on the first plausible
  // publication, so an unrelated second HD Mic write cannot allocate twice.
  const Clock::time_point publish_deadline =
      Clock::now() + kAllocatorPublishTimeout;
  while (Clock::now() < publish_deadline) {
    uint32_t candidate = 0;
    if (!ReadU32Guarded(transport, generation, kF1Core,
                        kAllocatorScratchAddress, &candidate,
                        &operation_error)) {
      publication_read_ok = false;
      break;
    }
    if (candidate != 0) {
      first_allocation = candidate;
      publication_observed = true;
      if ((candidate & 0x3fU) != 0 || candidate < kHeapMinimum ||
          candidate > kHeapLimit - kAllocationBytes) {
        std::ostringstream message;
        message << "allocator published implausible speaker address 0x"
                << std::hex << std::setfill('0') << std::setw(8) << candidate;
        operation_error = message.str();
        publication_read_ok = false;
      }
      break;
    }
    const auto remaining = publish_deadline - Clock::now();
    if (remaining <= Clock::duration::zero()) {
      break;
    }
    const auto delay = std::min(
        std::chrono::duration_cast<std::chrono::milliseconds>(remaining),
        std::chrono::duration_cast<std::chrono::milliseconds>(
            kAllocatorPublishPollInterval));
    if (!SleepFor(delay, &operation_error)) {
      publication_read_ok = false;
      break;
    }
  }
  if (!publication_observed && operation_error.empty()) {
    operation_error =
        "timed out waiting for the one-shot allocator result cookie";
  }
  bool allocation_verified =
      invoked && publication_read_ok && publication_observed;

  // Always disconnect the one-shot dispatch, including every failed or
  // ambiguous invocation. Only a stable, twice-observed pointer permits the
  // temporary body to be restored in this boot.
  std::string disconnect_error;
  if (!SetPatchExact(transport, generation, kF1Core, kAllocatorDispatch, false,
                     &disconnect_error)) {
    *error = (operation_error.empty() ? std::string()
                                      : operation_error + "; ") +
             "allocator dispatch restore failed: " + disconnect_error +
             "; temporary allocator may remain reachable; cold reboot required";
    return false;
  }
  if (!allocation_verified) {
    *error = (operation_error.empty()
                  ? "allocator command did not publish a stable pointer"
                  : operation_error) +
             "; allocator dispatch disconnected but temporary body/literals "
             "were deliberately retained; cold reboot required";
    return false;
  }

  if (!SleepFor(std::chrono::duration_cast<std::chrono::milliseconds>(
                    kAllocatorPublishConfirmInterval),
                &operation_error) ||
      !ReadU32Guarded(transport, generation, kF1Core,
                      kAllocatorScratchAddress, &second_allocation,
                      &operation_error) ||
      second_allocation != first_allocation ||
      !ValidateAllocation(transport, generation, second_allocation,
                          &operation_error) ||
      !RequireUsfDefaultWorkerStockPriority(transport, generation,
                                            &operation_error)) {
    if (operation_error.empty()) {
      std::ostringstream message;
      message << "speaker allocator publication was not stable after "
                 "disconnect: 0x"
              << std::hex << std::setfill('0') << std::setw(8)
              << first_allocation << " -> 0x" << std::setw(8)
              << second_allocation;
      operation_error = message.str();
    }
    *error = operation_error +
             "; temporary allocator body/literals were deliberately "
             "retained; cold reboot required";
    return false;
  }
  std::cout << "invoked one-shot F1 aligned allocator (libtinyalsa result "
            << mixer_result << ")\n";
  *allocation = second_allocation;
  if (!RestoreTemporaryAllocator(transport, generation, card,
                                 &operation_error)) {
    *error = operation_error;
    return false;
  }
  std::cout << "allocated one zero-candidate 0x3000 speaker region at 0x"
            << std::hex << *allocation << std::dec << '\n';
  return true;
}

bool RequireZeroAllocation(FactoryDiag* transport,
                           const Generation& generation, uint32_t allocation,
                           std::string* error) {
  if (!ValidateAllocation(transport, generation, allocation, error)) {
    return false;
  }
  for (uint32_t offset = 0; offset < kAllocationBytes;
       offset += kZeroScanChunkBytes) {
    const std::size_t size = std::min<std::size_t>(
        kZeroScanChunkBytes, kAllocationBytes - offset);
    std::vector<uint8_t> bytes;
    if (!DumpGuarded(transport, generation, kF1Core, allocation + offset, size,
                     &bytes, error)) {
      return false;
    }
    const auto nonzero =
        std::find_if(bytes.begin(), bytes.end(), [](uint8_t byte) {
          return byte != 0;
        });
    if (nonzero != bytes.end()) {
      const uint32_t bad_address =
          allocation + offset +
          static_cast<uint32_t>(std::distance(bytes.begin(), nonzero));
      std::ostringstream message;
      message << "new speaker allocation is nonzero at 0x" << std::hex
              << std::setfill('0') << std::setw(8) << bad_address;
      *error = message.str();
      return false;
    }
  }
  std::cout << "verified all 0x3000 freshly allocated speaker bytes are zero\n";
  return true;
}

bool CommitSpeakerBufferRebase(FactoryDiag* transport,
                               const Generation& generation,
                               uint32_t allocation, std::string* error) {
  if (!ValidateAllocation(transport, generation, allocation, error)) {
    return false;
  }
  // Publish capacities before pointers. Once the first object word changes,
  // rollback is deliberately reboot-only because the second CPU bank and both
  // DMA banks are interior pointers into one allocation.
  if (!SetU32Exact(transport, generation, kTxSizeAddress, kStockBankBytes,
                   kNativeBankBytes, "TX bank capacity", error) ||
      !SetU32Exact(transport, generation, kSourceSizeAddress, kStockBankBytes,
                   kNativeBankBytes, "source bank capacity", error)) {
    return false;
  }
  for (const DmaRingLayout& ring : kDmaRings) {
    if (!SetU32Exact(transport, generation, ring.descriptor + 4,
                     kStockBankBytes, kNativeBankBytes,
                     std::string(ring.name) + " descriptor end", error) ||
        !SetU32Exact(transport, generation, ring.descriptor + 12,
                     kStockBankBytes, kNativeBankBytes,
                     std::string(ring.name) + " descriptor size", error)) {
      return false;
    }
  }
  if (!SetU32Exact(transport, generation, kTxPointerAddress, kStockTxPointer,
                   allocation, "TX bank backing", error) ||
      !SetU32Exact(transport, generation, kSourcePointerAddress,
                   kStockSourcePointer, allocation + kNativeBankBytes,
                   "source bank backing", error)) {
    return false;
  }
  for (std::size_t index = 0; index < kDmaRings.size(); ++index) {
    if (!SetU32Exact(transport, generation, kDmaRings[index].address + 0x40,
                     kDmaRings[index].inline_backing,
                     allocation + kDmaTxOffset +
                         static_cast<uint32_t>(index) * kNativeBankBytes,
                     std::string(kDmaRings[index].name) + " backing", error)) {
      return false;
    }
  }
  return true;
}

bool EnsureSpeakerBuffersRebased(FactoryDiag* transport,
                                 const Generation& generation, mixer* card,
                                 bool skip_zero_validation,
                                 std::string* error) {
  SpeakerBufferState state{};
  uint32_t published_allocation = 0;
  if (!ReadSpeakerBufferState(transport, generation, &state,
                              &published_allocation, error)) {
    return false;
  }
  uint32_t scratch = 0;
  if (!ReadTemporaryAllocatorScaffold(transport, generation, &scratch,
                                      error)) {
    return false;
  }
  if (state == SpeakerBufferState::kRebased) {
    if (scratch != 0 && scratch != published_allocation) {
      *error = "rebased speaker layout has an unrelated allocator scratch "
               "pointer; cold reboot required";
      return false;
    }
    if (scratch == published_allocation &&
        !SetU32Exact(transport, generation, kAllocatorScratchAddress, scratch,
                     0, "clear recovered allocation scratch", error)) {
      return false;
    }
    std::cout << "speaker buffers are already rebased; no allocation issued\n";
    return true;
  }

  uint32_t allocation = scratch;
  if (allocation == 0) {
    if (!AllocateSpeakerStorage(transport, generation, card, &allocation,
                                error)) {
      return false;
    }
  } else {
    // A bounded boot retry can land after allocation and temporary-code
    // restoration but before object publication. Reuse the scratch pointer;
    // allocating twice is known to exhaust the F1 micro-heap and restart AoC.
    if (!ValidateAllocation(transport, generation, allocation, error)) {
      *error += "; refusing a second allocation; cold reboot required";
      return false;
    }
    std::cout << "reusing uncommitted speaker allocation from scratch at 0x"
              << std::hex << allocation << std::dec << '\n';
  }
  if (!skip_zero_validation &&
      !RequireZeroAllocation(transport, generation, allocation, error)) {
    return false;
  }
  if (skip_zero_validation) {
    std::cout << "WARNING: skipped only the 0x3000 full zero scan; allocation "
                 "range/alignment and first/last accessibility remain "
                 "validated\n";
  }

  SpeakerBufferState before_commit{};
  uint32_t ignored_allocation = 0;
  if (!ReadSpeakerBufferState(transport, generation, &before_commit,
                              &ignored_allocation, error) ||
      before_commit != SpeakerBufferState::kStock ||
      !CheckRuntimeGuards(generation, error)) {
    if (error->empty()) {
      *error = "speaker buffers changed before rebase commit";
    }
    return false;
  }
  if (!CommitSpeakerBufferRebase(transport, generation, allocation, error)) {
    *error += "; speaker object mutation began; cold reboot required";
    return false;
  }
  SpeakerBufferState after_commit{};
  uint32_t verified_allocation = 0;
  if (!ReadSpeakerBufferState(transport, generation, &after_commit,
                              &verified_allocation, error) ||
      after_commit != SpeakerBufferState::kRebased ||
      verified_allocation != allocation) {
    if (error->empty()) {
      *error = "speaker rebase verification failed; cold reboot required";
    } else {
      *error += "; cold reboot required";
    }
    return false;
  }
  if (!SetU32Exact(transport, generation, kAllocatorScratchAddress, allocation,
                   0, "clear allocation scratch", error)) {
    *error += "; speaker rebase is committed; cold reboot required on failure";
    return false;
  }
  uint32_t final_scratch = 1;
  if (!ReadTemporaryAllocatorScaffold(transport, generation, &final_scratch,
                                      error) ||
      final_scratch != 0) {
    if (error->empty()) {
      *error = "temporary allocator did not return to exact stock/zero state";
    }
    return false;
  }
  std::cout << "committed CPU speaker banks at 0x" << std::hex << allocation
            << "/0x" << allocation + kNativeBankBytes << " and DMA banks at 0x"
            << allocation + kDmaTxOffset << "/0x"
            << allocation + kDmaTxOffset + kNativeBankBytes << std::dec
            << "; rollback requires a cold AoC reset\n";
  return true;
}

int Run(std::string_view action_text, bool allow_incomplete_boot,
        bool skip_zero_validation, std::string* error) {
  UniqueFd transaction_lock(
      open(kTransactionLock, O_RDWR | O_CREAT | O_CLOEXEC, 0600));
  if (!transaction_lock.valid()) {
    *error = ErrnoText(std::string("open ") + kTransactionLock);
    return 2;
  }
  if (flock(transaction_lock.get(), LOCK_EX | LOCK_NB) != 0) {
    *error = ErrnoText(std::string("lock ") + kTransactionLock);
    return 2;
  }
  const bool apply = action_text == "apply";
  const bool revert = action_text == "revert";
  const bool prepare_a32 = action_text == "prepare-a32";
  const bool mutation = apply || revert || prepare_a32;
  if (action_text == "check-playback-closed") {
    if (!CheckTarget(false, error) || !CheckPlaybackClosed(error) ||
        !SleepFor(std::chrono::milliseconds(250), error) ||
        !CheckPlaybackClosed(error)) {
      return 2;
    }
    std::cout << "verified exact PCM 0,0 closed: inventory, character node, "
                 "and complete root fd scan\n";
    return 0;
  }
  // Clear certification after target identity but before A32/F1 profile
  // attestation. Every later mutation failure therefore leaves zero.
  if (mutation &&
      (!CheckTarget(allow_incomplete_boot, error) || !SetReady(false, error) ||
       (prepare_a32 && !SetA32Ready(false, error)))) {
    return 2;
  }
  Generation generation{};
  if (!Preflight(allow_incomplete_boot, &generation, error)) {
    return 2;
  }
  FactoryDiag transport;
  // Every action rejects stale raised scheduler state. Apply starts from the
  // stock signed AoC image. Its optional allocator fallback can be installed
  // only through the separately guarded early cache-sync window; the final
  // hardware-qualified path retains stock. The timer assertion remains stock.
  if (!RequireKnownA32AllocatorFallback(&transport, generation, error) ||
      !RequireUsfDefaultWorkerStockPriority(&transport, generation, error)) {
    return 2;
  }

  // The reviewed OUTPUTTER timer is deliberately short-lived. This action
  // mutates only the independently guarded A32 allocator word, so enter its
  // exact timer/work-pool transaction before spending that lifetime auditing
  // the unrelated F1/H0 speaker table. The later full apply performs the
  // complete F1/H0 source-state and buffer provenance audit before any of
  // those regions can be changed.
  if (prepare_a32) {
    if (!EnsureA32AllocatorFallbackApplied(&transport, generation, false,
                                            error)) {
      return 2;
    }
    std::cout << "prepared and certified the early-boot A32 allocator "
                 "fallback; F1/H0 remain untouched\n";
    return 0;
  }

  std::vector<PatchState> states;
  if (!RequireStockCacheDispatch(&transport, generation, error) ||
      !RequireUnselectedSitesStock(&transport, generation, error) ||
      !ReadStates(&transport, generation, &states, error) ||
      !RequireStockCacheDispatch(&transport, generation, error) ||
      !RequireUnselectedSitesStock(&transport, generation, error)) {
    return 2;
  }
  H0GeometryStates h0_states{};
  SpeakerBufferState buffer_state{};
  uint32_t speaker_allocation = 0;
  uint32_t allocator_scratch = 0;
  if (!ReadH0GeometryStates(&transport, generation, &h0_states, error) ||
      !ReadSpeakerBufferState(&transport, generation, &buffer_state,
                              &speaker_allocation, error) ||
      !ReadTemporaryAllocatorScaffold(&transport, generation,
                                      &allocator_scratch, error)) {
    return 2;
  }

  if (action_text == "check-stock" || action_text == "check-patched") {
    const PatchState wanted = action_text == "check-stock"
                                  ? PatchState::kStock
                                  : PatchState::kPatched;
    if (!Uniform(states, wanted) || !Uniform(h0_states, wanted)) {
      *error = "AoC speaker patch is not uniformly " +
               std::string(wanted == PatchState::kStock ? "stock" : "patched");
      return 2;
    }
    if (allocator_scratch != 0) {
      *error = "temporary speaker allocator scratch is nonzero; a boot "
               "transaction did not finish";
      return 2;
    }
    if (wanted == PatchState::kPatched &&
        (buffer_state != SpeakerBufferState::kRebased ||
         !RequireA32RuntimeProfileApplied(&transport, generation, error))) {
      if (error->empty()) {
        *error = "native-q192 code is patched but speaker buffers are not "
                 "rebased";
      }
      return 2;
    }
    if (wanted == PatchState::kStock &&
        buffer_state == SpeakerBufferState::kRebased) {
      std::cout << "F1/H0 code is stock; reboot-volatile speaker banks remain "
                   "rebased until the next cold AoC reset\n";
    }
    return 0;
  }

  // Reject mixed F1 state before the A32 allocator, F1 heap, H0, or object
  // layout can be modified. This ordering is what makes a bounded boot retry
  // safe only at explicitly modeled idempotent boundaries.
  const Action action = apply ? Action::kApply : Action::kRevert;
  std::vector<std::size_t> order;
  bool already_complete = false;
  if (!PlanTransition(action, states, &order, &already_complete, error)) {
    return 2;
  }

  UniqueMixer card(mixer_open(0));
  if (!card.valid()) {
    *error = "mixer_open(0) failed for googleaocsndcar";
    return 2;
  }
  mixer_ctl* cache_control = nullptr;
  if (!GetCacheFlushControl(card.get(), &cache_control, error)) {
    return 2;
  }
  const int cache_control_value = mixer_ctl_get_value(cache_control, 0);
  if (cache_control_value != 0) {
    *error = std::string(kCacheFlushControl) + '=' +
             std::to_string(cache_control_value) + "; expected 0";
    return 2;
  }

  // A native-q192 apply first validates stock-or-certified A32 allocator
  // state, then performs exactly one F1 0x3000 allocation and publishes four
  // 0xc00 banks. H0 geometry is changed while the exact idle speaker object still
  // proves that its first Configure has not run. Only then may any reachable
  // q192 F1 hook be connected.
  if (apply &&
      (!EnsureA32AllocatorFallbackApplied(&transport, generation, false,
                                           error) ||
       !EnsureSpeakerBuffersRebased(&transport, generation, card.get(),
                                    skip_zero_validation, error) ||
       !TransitionH0Geometry(&transport, generation, true, error))) {
    return 2;
  }
  const PatchState destination =
      action == Action::kApply ? PatchState::kPatched : PatchState::kStock;
  if (already_complete) {
    if (!FlushInstructionCache(&transport, generation, card.get(), error)) {
      return 2;
    }
    std::vector<PatchState> synchronized;
    if (!ReadStates(&transport, generation, &synchronized, error) ||
        !Uniform(synchronized, destination) ||
        !RequireStockCacheDispatch(&transport, generation, error) ||
        !RequireUnselectedSitesStock(&transport, generation, error)) {
      if (error->empty()) {
        *error = "destination state changed during I-cache synchronization";
      }
      return 2;
    }
    if (revert &&
        !TransitionH0Geometry(&transport, generation, false, error)) {
      return 2;
    }
    H0GeometryStates synchronized_h0{};
    SpeakerBufferState synchronized_buffers{};
    uint32_t synchronized_allocation = 0;
    if (!ReadH0GeometryStates(&transport, generation, &synchronized_h0,
                              error) ||
        !Uniform(synchronized_h0, destination) ||
        !ReadSpeakerBufferState(&transport, generation, &synchronized_buffers,
                                &synchronized_allocation, error) ||
        (apply && synchronized_buffers != SpeakerBufferState::kRebased)) {
      if (error->empty()) {
        *error = "auxiliary speaker geometry changed during synchronization";
      }
      return 2;
    }
    std::cout << "verified uniformly "
              << (destination == PatchState::kStock ? "stock" : "patched")
              << " across F1/H0 with synchronized F1 instruction cache\n";
    card.Reset();
    if (apply &&
        (!RequireA32RuntimeProfileApplied(&transport, generation, error) ||
         !SetReady(true, error))) {
      std::string ignored;
      SetReady(false, &ignored);
      return 2;
    }
    return 0;
  }

  for (const std::size_t index : order) {
    const Patch& patch = Patches()[index];
    const std::array<uint8_t, 4>& source =
        action == Action::kApply ? patch.before : patch.after;
    const std::array<uint8_t, 4>& destination_word =
        action == Action::kApply ? patch.after : patch.before;
    if (!CheckRuntimeGuards(generation, error)) {
      return 2;
    }
    std::array<uint8_t, 4> actual{};
    if (!transport.DumpWord(patch.address, &actual, error) ||
        !CheckRuntimeGuards(generation, error)) {
      return 2;
    }
    if (actual != source) {
      *error = std::string(patch.name) +
               ": changed after the uniform-state guard at 0x" +
               [&patch]() {
                 std::ostringstream stream;
                 stream << std::hex << std::setfill('0') << std::setw(8)
                        << patch.address;
                 return stream.str();
               }() +
               ": " + Hex(actual);
      return 2;
    }
    // The sysfs generation and PCM checks cannot be atomic with the AoC
    // diagnostic write, but checking immediately on both sides narrows the
    // unavoidable race and guarantees that no later word is attempted after
    // a reset, crash, or playback transition.
    if (!CheckRuntimeGuards(generation, error) ||
        !transport.SetWord(patch.address, destination_word, error) ||
        !CheckRuntimeGuards(generation, error)) {
      return 2;
    }
    std::array<uint8_t, 4> verified{};
    if (!transport.DumpWord(patch.address, &verified, error) ||
        !CheckRuntimeGuards(generation, error)) {
      return 2;
    }
    if (verified != destination_word) {
      *error = std::string("write verification failed at 0x") +
               [&patch]() {
                 std::ostringstream stream;
                 stream << std::hex << std::setfill('0') << std::setw(8)
                        << patch.address;
                 return stream.str();
               }() +
               ": got " + Hex(verified) + ", expected " + Hex(destination_word);
      return 2;
    }
    std::cout << "write   0x" << std::hex << std::setfill('0') << std::setw(8)
              << patch.address << ' ' << Hex(source) << "->"
              << Hex(destination_word) << "  " << patch.name << std::dec
              << '\n';
  }

  if (!CheckRuntimeGuards(generation, error)) {
    return 2;
  }
  std::vector<PatchState> final_states;
  if (!ReadStates(&transport, generation, &final_states, error) ||
      !Uniform(final_states, destination)) {
    if (error->empty()) {
      *error = "AoC speaker patch did not reach a uniform destination state";
    }
    return 2;
  }
  if (!RequireStockCacheDispatch(&transport, generation, error) ||
      !RequireUnselectedSitesStock(&transport, generation, error) ||
      !FlushInstructionCache(&transport, generation, card.get(), error) ||
      !ReadStates(&transport, generation, &final_states, error) ||
      !Uniform(final_states, destination) ||
      !RequireStockCacheDispatch(&transport, generation, error) ||
      !RequireUnselectedSitesStock(&transport, generation, error)) {
    if (error->empty()) {
      *error = "speaker state changed during I-cache synchronization";
    }
    return 2;
  }
  if (revert &&
      !TransitionH0Geometry(&transport, generation, false, error)) {
    return 2;
  }
  H0GeometryStates final_h0{};
  SpeakerBufferState final_buffers{};
  uint32_t final_allocation = 0;
  if (!ReadH0GeometryStates(&transport, generation, &final_h0, error)) {
    return 2;
  }
  if (!Uniform(final_h0, destination)) {
    *error = "H0 speaker geometry did not reach the requested destination";
    return 2;
  }
  if (!ReadSpeakerBufferState(&transport, generation, &final_buffers,
                              &final_allocation, error)) {
    return 2;
  }
  if (apply && final_buffers != SpeakerBufferState::kRebased) {
    *error = "speaker buffers did not reach the requested rebased destination";
    return 2;
  }
  std::cout << "verified uniformly "
            << (destination == PatchState::kStock ? "stock" : "patched")
            << " across F1/H0; F1, H0, A32, and dynamic buffer changes "
               "disappear on AoC/device reboot\n";
  card.Reset();
  if (apply &&
      (!RequireA32RuntimeProfileApplied(&transport, generation, error) ||
       !SetReady(true, error))) {
    std::string ignored;
    SetReady(false, &ignored);
    return 2;
  }
  return 0;
}

void Usage(const char* program) {
  std::cerr << "usage: " << program
            << " {prepare-a32|apply|revert|check-stock|check-patched|"
               "check-playback-closed}\n"
            << "       " << program
            << " {prepare-a32|apply} [--allow-incomplete-boot] "
               "[--skip-zero-validation (apply only)]\n";
}

}  // namespace
}  // namespace frankel_aoc_speaker_patch

int main(int argc, char** argv) {
  using namespace frankel_aoc_speaker_patch;
  if (argc == 2 && (std::string_view(argv[1]) == "--help" ||
                    std::string_view(argv[1]) == "-h")) {
    Usage(argv[0]);
    return 0;
  }
  if (argc < 2 || argc > 4) {
    Usage(argv[0]);
    return 64;
  }
  const std::string_view action(argv[1]);
  if (action != "prepare-a32" && action != "apply" && action != "revert" &&
      action != "check-stock" && action != "check-patched" &&
      action != "check-playback-closed") {
    Usage(argv[0]);
    return 64;
  }
  bool allow_incomplete_boot = false;
  bool skip_zero_validation = false;
  for (int index = 2; index < argc; ++index) {
    const std::string_view option(argv[index]);
    if (option == "--allow-incomplete-boot" && !allow_incomplete_boot) {
      allow_incomplete_boot = true;
    } else if (option == "--skip-zero-validation" &&
               !skip_zero_validation) {
      skip_zero_validation = true;
    } else {
      Usage(argv[0]);
      return 64;
    }
  }
  if ((allow_incomplete_boot && action != "apply" &&
       action != "prepare-a32") ||
      (skip_zero_validation && action != "apply")) {
    Usage(argv[0]);
    return 64;
  }
  std::string error;
  const int result =
      Run(action, allow_incomplete_boot, skip_zero_validation, &error);
  if (result != 0) {
    std::fprintf(stderr, "error: %s\n",
                 error.empty() ? "unspecified internal failure" : error.c_str());
  }
  return result;
}
