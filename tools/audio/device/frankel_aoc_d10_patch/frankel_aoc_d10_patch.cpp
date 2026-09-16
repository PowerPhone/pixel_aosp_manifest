// SPDX-License-Identifier: Apache-2.0

#include <cstddef>

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <sys/file.h>
#include <sys/stat.h>
#if defined(__ANDROID__)
#include <sys/system_properties.h>
#else
// Keep the complete device translation unit warning-clean under a host syntax
// build. The host binary is not functional and is never an installation
// artifact.
constexpr std::size_t PROP_VALUE_MAX = 92;
extern "C" int __system_property_get(const char*, char*) { return 0; }
extern "C" int __system_property_set(const char*, const char*) { return -1; }
#endif
#include <sys/types.h>
#include <time.h>
#include <unistd.h>

#include <algorithm>
#include <array>
#include <charconv>
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
#include <vector>

#include <tinyalsa/asoundlib.h>

namespace frankel_aoc_d10_patch {
namespace {

constexpr std::string_view kExpectedDevice = "frankel";
constexpr std::string_view kExpectedVendorBuildId = "CP2A.260805.005";
constexpr char kFactoryDiag[] = "/dev/acd-factory_diag";
constexpr char kDebugDevice[] = "/dev/acd-debug";
// Shared vendor-data lock created and labeled by the boot orchestrator.
constexpr char kTransactionLock[] =
    "/data/vendor/powerphone/.aoc-patch.lock";
constexpr uint8_t kDataTypeCommand = 0;
constexpr uint16_t kCommandMemorySet = 0x25;
constexpr uint16_t kCommandMemoryDump = 0x26;
constexpr int32_t kF1Core = 2;
constexpr int32_t kA32Core = 1;
// Only shared RAM MB1..9 has the live-verified section alias. MB0 uses
// coarse L2 mappings and must never be translated by this transport.
constexpr uint32_t kSharedRamBegin = 0x40100000;
constexpr uint32_t kSharedRamEnd = 0x40a00000;
constexpr uint32_t kSharedRamAliasOffset = 0x40000000;
constexpr std::size_t kHeaderSize = 8;
constexpr std::size_t kMaximumFactoryResponse = 4096;
constexpr std::size_t kMaximumDebugOutput = 64 * 1024;
constexpr auto kFactoryWriteTimeout = std::chrono::seconds(2);
constexpr auto kFactoryResponseTimeout = std::chrono::seconds(5);
constexpr auto kFactoryRetryDelay = std::chrono::milliseconds(1);
constexpr auto kDebugDrainTimeout = std::chrono::milliseconds(10);
constexpr auto kDumpDebugTimeout = std::chrono::seconds(2);
// mixer_ctl_set_value() proves host acceptance, not completion on F1.  Keep
// the temporary dispatch installed for the hardware-qualified completion
// window before restoring it.
constexpr auto kF1ControlCompletionWait = std::chrono::milliseconds(1500);
constexpr char kReadyProperty[] = "vendor.powerphone.pdm.ready";

using Clock = std::chrono::steady_clock;

enum class PatchKind {
  kCave,
  kSupport,
  kActivation,
};

enum class PatchState {
  kStock,
  kPatched,
};

enum class Action {
  kApply,
  kRevert,
};

struct PatchSpec {
  std::string_view name;
  uint32_t address;
  std::string_view before_hex;
  std::string_view after_hex;
  PatchKind kind;
};

struct StockGuard {
  std::string_view name;
  uint32_t address;
  std::string_view expected_hex;
};

struct WriteChunk {
  std::string_view patch_name;
  uint32_t address;
  std::vector<uint8_t> before;
  std::vector<uint8_t> after;
  uint32_t width_bits;
};

// This table is a literal native transcription of PATCHES in
// patch_frankel_aoc_live_d10_raw_192k.py. The one cave is tagged separately so
// apply fills it first, while the Stream-2 selector remains the last write.
constexpr std::array<PatchSpec, 22> kPatches = {{
    {"D10 source fill 48 -> 96 frames", 0x403daf5d,
     "3e44282ee992", "3e44242ee992", PatchKind::kSupport},
    {"D10 force the direct/raw staging branch", 0x403db6a2,
     "2e12b2d11dc9", "2e000091edc8", PatchKind::kSupport},
    {"D10 direct/raw loop 48 -> 96 S32 samples", 0x403db7a0,
     "2ee0108fea92", "2ee01c8eea92", PatchKind::kSupport},
    {"D10 common-path reload/frame-count cave", 0x403db863,
     "000000000000000000000000", "3e41a885016152a06086d9ff",
     PatchKind::kCave},
    {"D10 route common path through 96-frame cave", 0x403db7d0,
     "3e41a8850161", "c62300f02000", PatchKind::kSupport},
    {"D10 raw staging publish bytes 0xc0 -> 0x180", 0x403db7eb,
     "fec7a94e9e93", "fec7a54e9e93", PatchKind::kSupport},
    {"D10 preserve 96-frame direct-path descriptor", 0x403db81a,
     "3c05", "3df0", PatchKind::kSupport},
    {"D10 strict-mono converter 48 -> 96 frames", 0x403dbc4f,
     "fe00290fe992", "fe00680fe992", PatchKind::kSupport},
    {"D10 strict-mono reported bytes 0x60 -> 0xc0", 0x403dbce2,
     "b02f11", "a02f11", PatchKind::kSupport},
    {"D10 main caller frame geometry 48 -> 96", 0x403dac3b,
     "ae9248d196cf", "9e9248d196cf", PatchKind::kSupport},
    {"D10 main caller staging geometry 48 -> 96", 0x403dac9b,
     "ff0a291c56248317", "ff0a291c5d248317", PatchKind::kSupport},
    {"D10 shared caller staging geometry 48 -> 96", 0x403dae28,
     "2eff71afe992", "2eff7daee992", PatchKind::kSupport},
    {"admit enum 7 in both stream-validator comparisons", 0x403b75c9,
     "bf78b8084c0c8014", "bf88b8084c1c8014", PatchKind::kSupport},
    {"classify sample-rate enums 6 and 7 as high-rate streams", 0x403b7670,
     "bf60b5002c088413", "bf68b5002c088413", PatchKind::kSupport},
    {"notify downstream filters for sample-rate enums 6 and 7", 0x403b9eac,
     "bf60411a04448617", "bf68411a04448617", PatchKind::kSupport},
    {"native PDM clock 3.2 MHz -> 6.4 MHz", 0x403b84b0,
     "00d43000", "00a86100", PatchKind::kSupport},
    {"select the existing disabled-HPF branch at 192 kHz", 0x403b85f6,
     "820580", "82a000", PatchKind::kSupport},
    {"native PDM output rate 96000 -> 192000", 0x403b88dd,
     "8e9444ee9d93", "7e9444ee9d93", PatchKind::kSupport},
    {"native timestamp interval 1 ms -> 0.5 ms", 0x403ba544,
     "8e046c91eb92", "8e046092eb92", PatchKind::kSupport},
    {"native timestamp diagnostic 1 ms -> 0.5 ms", 0x403ba585,
     "ee48acfd0f93", "ee48a0fe0f93", PatchKind::kSupport},
    {"route sample-rate enums 6 and 7 through the 96-frame DMA/fanout body",
     0x403baa7b, "ff608414163c8413", "ff688414163c8413",
     PatchKind::kSupport},
    {"Stream 2 sample-rate enum 5 -> enum 7", 0x4038faf4,
     "4eb3b8150081", "4eb3b81d0081", PatchKind::kActivation},
}};

constexpr std::array<StockGuard, 3> kNative96StockGuards = {{
    {"native PDM callback remains 96 frames", 0x403b8880,
     "eef3d3431380"},
    {"native PDM bookkeeping remains 96 frames", 0x403b88fe, "3df0"},
    {"native enum-6/7 fanout body remains 96 frames", 0x403baad5,
     "9e61b4870461fe61ae010381ed04"},
}};

constexpr PatchSpec kCacheFlushDispatch = {
    "HD Mic gain dispatch -> whole F1 I-cache invalidator", 0x4038ea50,
    "c0c83d40", "e06d4840", PatchKind::kSupport};
constexpr char kSpeakerReadyProperty[] =
    "vendor.powerphone.aoc_speaker_192k.ready";
constexpr PatchSpec kResidentCacheFlushDispatch = {
    "HD Mic gain dispatch -> resident coherent F1 cache wrapper", 0x4038ea50,
    "c0c83d40", "a4643f40", PatchKind::kSupport};
// Exact resident bytes from frankel_aoc_speaker_coherence.S/.ld. The wrapper
// invokes the same whole-I invalidator, then DHU/DHI/MEMW on the HD dispatch line
// before returning 64. Host restoration therefore cannot leave a stale F1
// dispatch pointer for the next speaker/D10 transaction. The allocation cookie
// at 0x403f64a0 is data and deliberately excluded from these code guards.
constexpr std::array<StockGuard, 2> kResidentCacheFlushGuards = {{
    {"resident coherent-cache literals", 0x403f6490,
     "e06d484050ea3840"},
    {"resident coherent-cache wrapper", 0x403f64a4,
     "36410081faffe0080041f9ff827402627400c020004c021df0000000"},
}};
constexpr std::string_view kCacheFlushControl = "HD Mic gain (cB)";

constexpr std::array<const char*, 4> kCapturePaths = {{
    "/dev/snd/pcmC0D8c",
    "/dev/snd/pcmC0D9c",
    "/dev/snd/pcmC0D10c",
    "/dev/snd/pcmC0D12c",
}};

constexpr std::array<std::string_view, 10> kCommonTxSources = {{
    "I2S_0_TX", "I2S_1_TX", "I2S_2_TX", "TDM_0_TX", "TDM_1_TX",
    "INTERNAL_MIC_TX", "ERASER_TX", "BT_TX", "USB_TX", "INCALL_TX",
}};

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
  UniqueFd(UniqueFd&& other) noexcept : fd_(other.Release()) {}
  UniqueFd& operator=(UniqueFd&& other) noexcept {
    if (this != &other) {
      Reset(other.Release());
    }
    return *this;
  }
  int get() const { return fd_; }
  bool valid() const { return fd_ >= 0; }
  int Release() {
    const int result = fd_;
    fd_ = -1;
    return result;
  }
  void Reset(int fd = -1) {
    if (fd_ >= 0) {
      close(fd_);
    }
    fd_ = fd;
  }

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
      *error = ErrnoText("close " + std::string(description));
      return false;
    }
    return true;
  }

 private:
  static std::string ErrnoText(std::string operation) {
    return operation + ": " + std::strerror(errno);
  }
  DIR* directory_;
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

std::string Hex(std::span<const uint8_t> bytes) {
  std::ostringstream stream;
  stream << std::hex << std::setfill('0');
  for (const uint8_t byte : bytes) {
    stream << std::setw(2) << static_cast<unsigned int>(byte);
  }
  return stream.str();
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

bool DecodeHex(std::string_view text, std::vector<uint8_t>* bytes,
               std::string* error) {
  bytes->clear();
  if (text.empty() || text.size() % 2 != 0) {
    *error = "invalid internal patch hex length";
    return false;
  }
  bytes->reserve(text.size() / 2);
  for (std::size_t offset = 0; offset < text.size(); offset += 2) {
    const int high = HexDigit(text[offset]);
    const int low = HexDigit(text[offset + 1]);
    if (high < 0 || low < 0) {
      *error = "invalid internal patch hex byte";
      bytes->clear();
      return false;
    }
    bytes->push_back(static_cast<uint8_t>((high << 4) | low));
  }
  return true;
}

uint32_t BytesToLe32(std::span<const uint8_t> bytes) {
  uint32_t value = 0;
  for (std::size_t index = 0; index < bytes.size(); ++index) {
    value |= static_cast<uint32_t>(bytes[index]) << (index * 8);
  }
  return value;
}

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

bool ReadSmallFile(const char* path, std::string* contents,
                   std::string* error) {
  UniqueFd fd(open(path, O_RDONLY | O_CLOEXEC));
  if (!fd.valid()) {
    *error = ErrnoText("open " + std::string(path));
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
    *error = ErrnoText("read " + std::string(path));
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

bool CheckCharDevice(const char* path, int access_mode, int open_flags,
                     std::string* error) {
  struct stat status {};
  if (lstat(path, &status) != 0) {
    *error = ErrnoText("lstat " + std::string(path));
    return false;
  }
  if (!S_ISCHR(status.st_mode)) {
    *error = std::string(path) + " is not a direct character-device node";
    return false;
  }
  if (access(path, access_mode) != 0) {
    *error = ErrnoText("access " + std::string(path));
    return false;
  }
  UniqueFd fd(open(path, open_flags | O_CLOEXEC | O_NONBLOCK));
  if (!fd.valid()) {
    *error = ErrnoText("open " + std::string(path));
    return false;
  }
  return true;
}

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

bool GetControl(mixer* card, std::string_view name, unsigned int count,
                mixer_ctl** control, std::string* error) {
  const std::string owned_name(name);
  *control = mixer_get_ctl_by_name(card, owned_name.c_str());
  if (*control == nullptr) {
    *error = "missing card0 mixer control: " + owned_name;
    return false;
  }
  const unsigned int actual_count = mixer_ctl_get_num_values(*control);
  if (actual_count != count) {
    *error = owned_name + " has " + std::to_string(actual_count) +
             " values; expected " + std::to_string(count);
    return false;
  }
  return true;
}

bool RequireScalarValue(mixer* card, std::string_view name, int expected,
                        std::string* error) {
  mixer_ctl* control = nullptr;
  if (!GetControl(card, name, 1, &control, error)) {
    return false;
  }
  const int actual = mixer_ctl_get_value(control, 0);
  if (actual != expected) {
    *error = std::string(name) + '=' + std::to_string(actual) +
             "; expected " + std::to_string(expected);
    return false;
  }
  return true;
}

bool RequireScalarEnum(mixer* card, std::string_view name,
                       std::string_view expected, std::string* error) {
  mixer_ctl* control = nullptr;
  if (!GetControl(card, name, 1, &control, error)) {
    return false;
  }
  if (mixer_ctl_get_type(control) != MIXER_CTL_TYPE_ENUM) {
    *error = std::string(name) + " is not an enum mixer control";
    return false;
  }
  const int index = mixer_ctl_get_value(control, 0);
  const char* actual =
      index < 0 ? nullptr : mixer_ctl_get_enum_string(control, index);
  if (actual == nullptr || std::string_view(actual) != expected) {
    *error = std::string(name) + '=' +
             (actual == nullptr ? "<read-error>" : actual) + "; expected " +
             std::string(expected);
    return false;
  }
  return true;
}

bool TriggerCacheFlushControl(mixer* card, int* result, std::string* error) {
  mixer_ctl* control = nullptr;
  if (!GetControl(card, kCacheFlushControl, 1, &control, error)) {
    return false;
  }
  *result = mixer_ctl_set_value(control, 0, 0);
  // The invalidator deliberately leaves a2=64. The old tinymix transport
  // surfaced the corresponding ALSA write as either success or its generic
  // failure status, so any normal libtinyalsa return (0 or a negative errno)
  // is the same qualified invocation. A positive value is not a tinyalsa
  // mixer-write result and fails closed.
  if (*result > 0) {
    *error = "HD Mic cache-flush mixer write returned unexpected positive " +
             std::to_string(*result);
    return false;
  }
  return true;
}

struct CaptureNodeState {
  const char* path = nullptr;
  mode_t permissions = 0;
  dev_t character_device = 0;
  bool changed = false;
};

class CaptureQuarantine {
 public:
  CaptureQuarantine() {
    for (std::size_t index = 0; index < nodes_.size(); ++index) {
      nodes_[index].path = kCapturePaths[index];
    }
  }
  ~CaptureQuarantine() {
    std::string ignored;
    Restore(&ignored);
  }
  CaptureQuarantine(const CaptureQuarantine&) = delete;
  CaptureQuarantine& operator=(const CaptureQuarantine&) = delete;

  bool Apply(std::string* error) {
    for (CaptureNodeState& node : nodes_) {
      struct stat status {};
      if (lstat(node.path, &status) != 0) {
        *error = ErrnoText("lstat " + std::string(node.path));
        return false;
      }
      if (!S_ISCHR(status.st_mode)) {
        *error = std::string(node.path) +
                 " is not a direct character-device node";
        return false;
      }
      node.permissions = status.st_mode & 07777;
      node.character_device = status.st_rdev;
    }
    for (CaptureNodeState& node : nodes_) {
      if (chmod(node.path, 0000) != 0) {
        *error = ErrnoText("chmod 000 " + std::string(node.path));
        return false;
      }
      node.changed = true;
    }
    if (!CheckIdentity(true, error)) {
      return false;
    }
    std::cout << "blocked new opens on PCM 0,8/9/10/12\n";
    return true;
  }

  bool Restore(std::string* error) {
    std::vector<std::string> failures;
    for (CaptureNodeState& node : nodes_) {
      if (!node.changed) {
        continue;
      }
      if (chmod(node.path, node.permissions) != 0) {
        failures.push_back(node.path);
        continue;
      }
      node.changed = false;
    }
    if (!failures.empty()) {
      std::ostringstream message;
      message << "failed to restore capture PCM modes:";
      for (const std::string& path : failures) {
        message << ' ' << path;
      }
      *error = message.str();
      return false;
    }
    if (restored_once_) {
      return true;
    }
    restored_once_ = true;
    std::cout << "restored capture modes on PCM 0,8/9/10/12\n";
    return true;
  }

  bool CheckIdentity(bool require_mode_zero, std::string* error) const {
    for (const CaptureNodeState& node : nodes_) {
      struct stat status {};
      if (lstat(node.path, &status) != 0) {
        *error = ErrnoText("lstat " + std::string(node.path));
        return false;
      }
      if (!S_ISCHR(status.st_mode) ||
          status.st_rdev != node.character_device) {
        *error = std::string(node.path) +
                 " identity changed during the transaction";
        return false;
      }
      if (require_mode_zero && (status.st_mode & 07777) != 0) {
        *error = std::string(node.path) + " is no longer quarantined";
        return false;
      }
    }
    return true;
  }

  bool Matches(dev_t device) const {
    return std::any_of(nodes_.begin(), nodes_.end(),
                       [device](const CaptureNodeState& node) {
                         return node.character_device == device;
                       });
  }

 private:
  std::array<CaptureNodeState, 4> nodes_{};
  bool restored_once_ = false;
};

bool CheckCaptureIdle(const CaptureQuarantine& quarantine,
                      std::string* error) {
  if (getuid() != 0 || geteuid() != 0) {
    *error = "complete /proc fd ownership scan requires real/effective uid 0";
    return false;
  }
  if (!quarantine.CheckIdentity(true, error)) {
    return false;
  }
  UniqueDir proc(opendir("/proc"));
  if (!proc.valid()) {
    *error = ErrnoText("open /proc");
    return false;
  }
  while (true) {
    errno = 0;
    dirent* const process = readdir(proc.get());
    if (process == nullptr) {
      const int error_number = errno;
      if (error_number != 0) {
        *error = ErrnoText("read /proc", error_number);
        return false;
      }
      break;
    }
    if (!IsDecimalName(process->d_name)) {
      continue;
    }
    const std::string fd_path =
        std::string("/proc/") + process->d_name + "/fd";
    UniqueDir descriptors(opendir(fd_path.c_str()));
    if (!descriptors.valid()) {
      const int error_number = errno;
      if (error_number == ENOENT) {
        continue;
      }
      *error = ErrnoText("open " + fd_path, error_number);
      return false;
    }
    while (true) {
      errno = 0;
      dirent* const descriptor = readdir(descriptors.get());
      if (descriptor == nullptr) {
        const int error_number = errno;
        if (error_number != 0) {
          *error = ErrnoText("read " + fd_path, error_number);
          return false;
        }
        break;
      }
      if (!IsDecimalName(descriptor->d_name)) {
        continue;
      }
      struct stat status {};
      if (fstatat(dirfd(descriptors.get()), descriptor->d_name, &status, 0) !=
          0) {
        const int error_number = errno;
        if (error_number == ENOENT) {
          continue;
        }
        *error = ErrnoText(fd_path + '/' + descriptor->d_name, error_number);
        return false;
      }
      if (S_ISCHR(status.st_mode) && quarantine.Matches(status.st_rdev)) {
        *error = fd_path + '/' + descriptor->d_name +
                 " owns a quarantined D8/D9/D10/D12 capture PCM";
        return false;
      }
    }
    if (!descriptors.Close(fd_path, error)) {
      return false;
    }
  }
  if (!proc.Close("/proc", error) || !quarantine.CheckIdentity(true, error)) {
    return false;
  }
  std::cout << "verified PCM 0,8/9/10/12 closed\n";
  return true;
}

bool RequireStrictRuntime(mixer* card, std::string* error) {
  for (const int endpoint : {1, 2, 3, 5}) {
    for (const std::string_view source : kCommonTxSources) {
      const std::string control = "EP" + std::to_string(endpoint) +
                                  " TX Mixer " + std::string(source);
      if (!RequireScalarValue(card, control, 0, error)) {
        *error = "capture route/control is not off: " + *error;
        return false;
      }
    }
  }
  for (const std::string_view control : {
           std::string_view("EP5 TX Mixer INTERNAL_MIC_US_TX"),
           std::string_view("US Record Enable"), std::string_view("MIC0"),
           std::string_view("MIC1"), std::string_view("MIC2")}) {
    if (!RequireScalarValue(card, control, 0, error)) {
      *error = "capture route/control is not off: " + *error;
      return false;
    }
  }

  mixer_ctl* capture_control = nullptr;
  if (!GetControl(card, "BUILDIN MIC ID CAPTURE LIST", 4, &capture_control,
                  error)) {
    return false;
  }
  std::array<int, 4> ids{};
  for (std::size_t index = 0; index < ids.size(); ++index) {
    ids[index] = mixer_ctl_get_value(capture_control, index);
  }
  const bool exact_single_mic =
      (ids[0] == 0 || ids[0] == 1 || ids[0] == 2) && ids[1] == -1 &&
      ids[2] == -1 && ids[3] == -1;
  // The stock AoC HAL can asynchronously republish this exact dormant list
  // while all microphone power controls and TX routes checked above remain
  // off.  It is the firmware's canonical idle inventory, not an active
  // three-microphone capture.  Accept no other multi-ID shape.
  const bool exact_firmware_idle =
      ids[0] == 0 && ids[1] == 1 && ids[2] == 2 && ids[3] == -1;
  if (!exact_single_mic && !exact_firmware_idle) {
    *error = "BUILDIN MIC ID CAPTURE LIST must be an exact single-mic list "
             "or firmware idle list 0 1 2 -1, got " +
             std::to_string(ids[0]) + ' ' + std::to_string(ids[1]) + ' ' +
             std::to_string(ids[2]) + ' ' + std::to_string(ids[3]);
    return false;
  }

  if (!RequireScalarEnum(card, "BUILTIN MIC Process Mode", "Raw", error) ||
      !RequireScalarEnum(card, "Audio Capture Mic Source", "Builtin_MIC",
                         error) ||
      !RequireScalarValue(card, "Mic Spatial Module Enable", 0, error) ||
      !RequireScalarValue(card, "MIC DC Blocker", 0, error) ||
      !RequireScalarValue(card, kCacheFlushControl, 0, error) ||
      !RequireScalarEnum(card, "INTERNAL_MIC_TX Sample Rate", "SR_192K",
                         error) ||
      !RequireScalarEnum(card, "INTERNAL_MIC_TX Format", "S16_LE", error) ||
      !RequireScalarEnum(card, "INTERNAL_MIC_TX Chan", "One", error)) {
    *error = "strict RAW runtime mismatch: " + *error;
    return false;
  }
  std::cout << "strict runtime=RAW/S16_LE/mono/192000 capture_list="
            << ids[0] << ' ' << ids[1] << ' ' << ids[2] << ' ' << ids[3]
            << (exact_firmware_idle ? " (firmware-idle)" : " (single-mic)")
            << '\n';
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
    *error = ErrnoText("read " + std::string(kDebugDevice));
    return false;
  }
  *error = "unable to establish a bounded clean acd-debug boundary";
  return false;
}

std::vector<uint8_t> BuildDumpPacket(uint8_t counter, uint32_t address,
                                     uint32_t size, int32_t core = kF1Core) {
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

std::vector<uint8_t> BuildSetPacket(uint8_t counter, uint32_t address,
                                    uint32_t value, uint32_t width_bits) {
  constexpr uint16_t kLength = 8 + 4 + 4 + 4 + 1;
  const uint8_t mode = width_bits == 32 ? 0 : width_bits == 16 ? 1 : 2;
  std::vector<uint8_t> packet;
  packet.reserve(kLength);
  packet.push_back(kDataTypeCommand);
  packet.push_back(counter);
  AppendLe16(&packet, kLength);
  AppendLe16(&packet, kCommandMemorySet);
  AppendLe16(&packet, 0);
  AppendLe32(&packet, static_cast<uint32_t>(kF1Core));
  AppendLe32(&packet, address);
  AppendLe32(&packet, value);
  packet.push_back(mode);
  return packet;
}

bool ParseCommandResponse(std::span<const uint8_t> response,
                          uint8_t expected_counter,
                          uint16_t expected_command, std::string* error) {
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
    std::ostringstream message;
    message << "AoC command 0x" << std::hex << std::setfill('0')
            << std::setw(4) << expected_command << " failed with reply "
            << std::dec << reply;
    *error = message.str();
    return false;
  }
  return true;
}

bool IsHorizontalSpace(char character) {
  return character == ' ' || character == '\t' || character == '\r';
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
      wanted += static_cast<uint32_t>(line.size());
    }
    cursor = std::max(position, prefix + 2);
  }
  std::ostringstream message;
  message << "AoC dump output did not contain 0x" << std::hex
          << std::setfill('0') << std::setw(8) << address << '+' << std::dec
          << size;
  *error = message.str();
  result->clear();
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
      if (output->size() > kMaximumDebugOutput) {
        output->erase(0, output->size() - kMaximumDebugOutput);
      }
      continue;
    }
    if (count < 0 && errno == EINTR) {
      continue;
    }
    if (count < 0 && errno != EAGAIN && errno != EWOULDBLOCK) {
      *error = ErrnoText("read " + std::string(kDebugDevice));
      return false;
    }
    // The formatted line is carried by a service independent from the
    // correlated factory acknowledgement. Treat both zero and EAGAIN as
    // pending and retry this owned nonblocking descriptor. A single absolute
    // deadline remains effective even under continuous unrelated logging.
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

  bool Dump(uint32_t address, uint32_t size, std::vector<uint8_t>* bytes,
            std::string* error) {
    if (size == 0 || size > 256) {
      *error = "memory dump size must be 1..256 bytes";
      return false;
    }
    uint32_t wire_address;
    if (!SharedRamWireAddress(address, size, &wire_address, error)) {
      return false;
    }
    return DumpRaw(kF1Core, wire_address, size, bytes, error);
  }

  bool Write(uint32_t address, uint32_t value, uint32_t width_bits,
             std::string* error) {
    if ((width_bits != 8 && width_bits != 16 && width_bits != 32) ||
        address % (width_bits / 8) != 0) {
      *error = "internal unaligned factory_diag write";
      return false;
    }
    uint32_t wire_address;
    if (!SharedRamWireAddress(address, width_bits / 8, &wire_address, error)) {
      return false;
    }
    const uint8_t counter = counter_++;
    // Only the transport address changes: values and embedded F1 pointers
    // retain their logical 0x40... representation.
    const std::vector<uint8_t> packet =
        BuildSetPacket(counter, wire_address, value, width_bits);
    return Transact(packet, counter, kCommandMemorySet, error);
  }

 private:
  bool DumpRaw(int32_t core, uint32_t address, uint32_t size,
               std::vector<uint8_t>* bytes, std::string* error) {
    UniqueFd debug_fd(open(kDebugDevice, O_RDONLY | O_CLOEXEC | O_NONBLOCK));
    if (!debug_fd.valid()) {
      *error = ErrnoText("open " + std::string(kDebugDevice));
      return false;
    }
    if (!DrainDebugNow(debug_fd.get(), error)) {
      return false;
    }
    const uint8_t counter = counter_++;
    const std::vector<uint8_t> packet =
        BuildDumpPacket(counter, address, size, core);
    if (!Transact(packet, counter, kCommandMemoryDump, error)) {
      return false;
    }
    std::string debug;
    // Factory diagnostics prints the wire address, including the NC alias.
    return ReadDumpDebug(debug_fd.get(), address, size, bytes, &debug, error);
  }

  bool RequireSharedRamAlias(std::string* error) {
    if (shared_ram_alias_guarded_) {
      return true;
    }
    std::vector<uint8_t> cached;
    std::vector<uint8_t> noncacheable;
    // Read the actual A32 L1 descriptors via RAW core1; this bypasses the
    // F1 alias selector, cannot recurse, and never aliases A32-owned objects.
    if (!DumpRaw(kA32Core, 0x40009004, 36, &cached, error) ||
        !DumpRaw(kA32Core, 0x4000a004, 36, &noncacheable, error)) {
      return false;
    }
    for (uint32_t mb = 1; mb <= 9; ++mb) {
      const std::size_t offset = (mb - 1) * 4;
      if (BytesToLe32(std::span<const uint8_t>(cached).subspan(offset, 4)) !=
              ((mb << 20) | 0x1c0e) ||
          BytesToLe32(std::span<const uint8_t>(noncacheable).subspan(offset, 4)) !=
              ((mb << 20) | 0x1c12)) {
        *error = "A32 shared-RAM alias descriptors differ at MB" +
                 std::to_string(mb) + "; cached=" + Hex(cached) +
                 "; noncacheable=" + Hex(noncacheable);
        return false;
      }
    }
    shared_ram_alias_guarded_ = true;
    std::cout << "guarded A32 MB1..9 cached/noncacheable section mappings; "
                 "F1 shared-RAM wire addresses use the 0x80... alias\n";
    return true;
  }

  bool SharedRamWireAddress(uint32_t address, uint32_t size,
                            uint32_t* wire_address, std::string* error) {
    const uint64_t end = static_cast<uint64_t>(address) + size;
    const bool overlaps = address < kSharedRamEnd && end > kSharedRamBegin;
    if (overlaps && (address < kSharedRamBegin || end > kSharedRamEnd)) {
      *error = "factory_diag range crosses the guarded shared-RAM alias boundary";
      return false;
    }
    *wire_address = address;
    if (overlaps) {
      if (!RequireSharedRamAlias(error)) {
        return false;
      }
      *wire_address += kSharedRamAliasOffset;
    }
    return true;
  }

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
        *error = ErrnoText(std::string("open ") + kFactoryDiag +
                           " for write");
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
      *error = ErrnoText("open " + std::string(kFactoryDiag) + " for read");
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
          if (*expected_length < kHeaderSize ||
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
        *error = ErrnoText("read " + std::string(kFactoryDiag));
        return false;
      }
      // Frankel's factory_diag returns EAGAIN and sometimes zero while a
      // reply is pending. Retry the owned nonblocking descriptor only until
      // the absolute response deadline; never resend the command.
      PauseBeforeRetry(deadline);
    }
    *error = response->empty()
                 ? "timed out waiting for factory_diag response"
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
  bool shared_ram_alias_guarded_ = false;
};

bool PatchBytes(const PatchSpec& patch, bool after, std::vector<uint8_t>* bytes,
                std::string* error) {
  if (!DecodeHex(after ? patch.after_hex : patch.before_hex, bytes, error)) {
    *error = std::string(patch.name) + ": " + *error;
    return false;
  }
  const std::string_view other = after ? patch.before_hex : patch.after_hex;
  if (other.size() != bytes->size() * 2) {
    *error = std::string(patch.name) +
             ": stock/patched byte lengths do not match";
    return false;
  }
  return true;
}

bool Classify(const PatchSpec& patch, std::span<const uint8_t> actual,
              PatchState* state, std::string* error) {
  std::vector<uint8_t> before;
  std::vector<uint8_t> after;
  if (!PatchBytes(patch, false, &before, error) ||
      !PatchBytes(patch, true, &after, error)) {
    return false;
  }
  if (std::equal(actual.begin(), actual.end(), before.begin(), before.end())) {
    *state = PatchState::kStock;
    return true;
  }
  if (std::equal(actual.begin(), actual.end(), after.begin(), after.end())) {
    *state = PatchState::kPatched;
    return true;
  }
  std::ostringstream message;
  message << patch.name << ": unexpected bytes at 0x" << std::hex
          << std::setfill('0') << std::setw(8) << patch.address << ": "
          << Hex(actual) << " (stock " << Hex(before) << ", patched "
          << Hex(after) << ')';
  *error = message.str();
  return false;
}

bool ReadStates(FactoryDiag* transport, std::vector<PatchState>* states,
                std::string* error) {
  states->clear();
  for (const PatchSpec& patch : kPatches) {
    std::vector<uint8_t> expected;
    if (!PatchBytes(patch, false, &expected, error)) {
      return false;
    }
    std::vector<uint8_t> actual;
    if (!transport->Dump(patch.address, expected.size(), &actual, error)) {
      return false;
    }
    PatchState state;
    if (!Classify(patch, actual, &state, error)) {
      return false;
    }
    states->push_back(state);
    std::cout << (state == PatchState::kStock ? "stock   " : "patched ")
              << "0x" << std::hex << std::setfill('0') << std::setw(8)
              << patch.address << ' ' << Hex(actual) << "  " << patch.name
              << std::dec << '\n';
  }
  return true;
}

bool Uniform(std::span<const PatchState> states, PatchState wanted) {
  return states.size() == kPatches.size() &&
         std::all_of(states.begin(), states.end(),
                     [wanted](PatchState state) { return state == wanted; });
}

bool RequireStockGuards(FactoryDiag* transport, std::string* error) {
  for (const StockGuard& guard : kNative96StockGuards) {
    std::vector<uint8_t> expected;
    if (!DecodeHex(guard.expected_hex, &expected, error)) {
      *error = std::string(guard.name) + ": " + *error;
      return false;
    }
    std::vector<uint8_t> actual;
    if (!transport->Dump(guard.address, expected.size(), &actual, error)) {
      return false;
    }
    if (actual != expected) {
      std::ostringstream message;
      message << guard.name << ": unexpected bytes at 0x" << std::hex
              << std::setfill('0') << std::setw(8) << guard.address << ": "
              << Hex(actual) << " (required stock " << Hex(expected) << ')';
      *error = message.str();
      return false;
    }
    std::cout << "guard   0x" << std::hex << std::setfill('0') << std::setw(8)
              << guard.address << ' ' << Hex(actual) << "  " << guard.name
              << std::dec << '\n';
  }
  std::vector<uint8_t> expected;
  if (!PatchBytes(kCacheFlushDispatch, false, &expected, error)) {
    return false;
  }
  std::vector<uint8_t> actual;
  if (!transport->Dump(kCacheFlushDispatch.address, expected.size(), &actual,
                       error)) {
    return false;
  }
  if (actual != expected) {
    std::ostringstream message;
    message << "whole-I-cache flush dispatch is not restored at 0x" << std::hex
            << std::setfill('0') << std::setw(8)
            << kCacheFlushDispatch.address << ": " << Hex(actual)
            << " (required " << Hex(expected) << ')';
    *error = message.str();
    return false;
  }
  std::cout << "guard   0x" << std::hex << std::setfill('0') << std::setw(8)
            << kCacheFlushDispatch.address << ' ' << Hex(actual)
            << "  whole-I-cache flush dispatch restored" << std::dec << '\n';
  return true;
}

bool ChangedChunks(const PatchSpec& patch, Action action,
                   std::vector<WriteChunk>* chunks, std::string* error) {
  std::vector<uint8_t> before;
  std::vector<uint8_t> after;
  if (!PatchBytes(patch, false, &before, error) ||
      !PatchBytes(patch, true, &after, error)) {
    return false;
  }
  const std::vector<uint8_t>& source =
      action == Action::kApply ? before : after;
  const std::vector<uint8_t>& destination =
      action == Action::kApply ? after : before;
  chunks->clear();
  std::size_t offset = 0;
  while (offset < source.size()) {
    const uint32_t address = patch.address + static_cast<uint32_t>(offset);
    const std::size_t remaining = source.size() - offset;
    std::size_t width = 1;
    for (const std::size_t candidate : {std::size_t(4), std::size_t(2),
                                        std::size_t(1)}) {
      if (remaining >= candidate && address % candidate == 0) {
        width = candidate;
        break;
      }
    }
    const auto source_begin = source.begin() + offset;
    const auto destination_begin = destination.begin() + offset;
    if (!std::equal(source_begin, source_begin + width, destination_begin)) {
      chunks->push_back(WriteChunk{
          .patch_name = patch.name,
          .address = address,
          .before = std::vector<uint8_t>(source_begin, source_begin + width),
          .after = std::vector<uint8_t>(destination_begin,
                                        destination_begin + width),
          .width_bits = static_cast<uint32_t>(width * 8),
      });
    }
    offset += width;
  }
  return true;
}

bool WriteOneChunk(FactoryDiag* transport, const WriteChunk& chunk,
                   std::string* error) {
  std::vector<uint8_t> actual;
  if (!transport->Dump(chunk.address, chunk.before.size(), &actual, error)) {
    return false;
  }
  if (actual != chunk.before) {
    std::ostringstream message;
    message << chunk.patch_name << ": changed before write at 0x" << std::hex
            << std::setfill('0') << std::setw(8) << chunk.address << ": "
            << Hex(actual) << ", expected " << Hex(chunk.before);
    *error = message.str();
    return false;
  }
  if (!transport->Write(chunk.address, BytesToLe32(chunk.after),
                        chunk.width_bits, error)) {
    return false;
  }
  std::vector<uint8_t> verified;
  if (!transport->Dump(chunk.address, chunk.after.size(), &verified, error)) {
    return false;
  }
  if (verified != chunk.after) {
    std::ostringstream message;
    message << "write verification failed at 0x" << std::hex
            << std::setfill('0') << std::setw(8) << chunk.address << ": got "
            << Hex(verified) << ", expected " << Hex(chunk.after);
    *error = message.str();
    return false;
  }
  std::cout << "write" << std::left << std::setw(2) << chunk.width_bits
            << std::right << " 0x" << std::hex << std::setfill('0')
            << std::setw(8) << chunk.address << std::setfill(' ') << ' '
            << Hex(chunk.before) << "->" << Hex(chunk.after) << "  "
            << chunk.patch_name << std::dec << '\n';
  return true;
}

bool FlushInstructionCache(FactoryDiag* transport, mixer* card,
                           std::string* error) {
  std::array<char, PROP_VALUE_MAX> speaker_ready{};
  const int speaker_ready_length =
      __system_property_get(kSpeakerReadyProperty, speaker_ready.data());
  const std::string_view speaker_state(
      speaker_ready.data(),
      speaker_ready_length > 0 ? static_cast<std::size_t>(speaker_ready_length)
                               : 0);
  if (!speaker_state.empty() && speaker_state != "0" && speaker_state != "1") {
    *error = std::string("unexpected ") + kSpeakerReadyProperty + '=' +
             std::string(speaker_state);
    return false;
  }
  const bool resident_coherence = speaker_state == "1";
  if (resident_coherence) {
    for (const StockGuard& guard : kResidentCacheFlushGuards) {
      std::vector<uint8_t> expected;
      std::vector<uint8_t> actual;
      if (!DecodeHex(guard.expected_hex, &expected, error) ||
          !transport->Dump(guard.address, expected.size(), &actual, error)) {
        return false;
      }
      if (actual != expected) {
        *error = std::string(guard.name) + ": unexpected bytes " + Hex(actual) +
                 "; refusing ready speaker profile without coherent wrapper";
        return false;
      }
    }
  }
  // Missing/zero speaker readiness retains standalone stock-speaker D10 mode.
  // Never fall back to the I-only routine after a ready-profile guard failure.
  const PatchSpec& dispatch =
      resident_coherence ? kResidentCacheFlushDispatch : kCacheFlushDispatch;
  std::vector<WriteChunk> install_chunks;
  if (!ChangedChunks(dispatch, Action::kApply, &install_chunks,
                     error) ||
      install_chunks.size() != 1) {
    if (error->empty()) {
      *error = "cache-flush dispatch must be one atomic changed word";
    }
    return false;
  }
  const WriteChunk& install = install_chunks.front();
  std::vector<uint8_t> initial;
  if (!transport->Dump(install.address, install.before.size(), &initial,
                       error)) {
    return false;
  }
  if (initial != install.before) {
    *error = "refusing cache flush with non-stock HD Mic dispatch at 0x" +
             [&install]() {
               std::ostringstream address;
               address << std::hex << std::setfill('0') << std::setw(8)
                       << install.address;
               return address.str();
             }() +
             ": " + Hex(initial);
    return false;
  }

  std::string invocation_error;
  bool invocation_ok = WriteOneChunk(transport, install, &invocation_error);
  int mixer_result = 1;
  if (invocation_ok) {
    const bool trigger_ok =
        TriggerCacheFlushControl(card, &mixer_result, &invocation_error);
    // A non-success mixer return can still mean that Linux queued the AoC
    // request. Preserve the temporary dispatch for the complete measured
    // latency margin before inspecting and restoring it.
    const bool dwell_ok =
        SleepFor(std::chrono::duration_cast<std::chrono::milliseconds>(
                     kF1ControlCompletionWait),
                 &invocation_error);
    invocation_ok = trigger_ok && dwell_ok;
  }
  if (invocation_ok) {
    std::cout << "invoked HD Mic CMD 0x016c "
              << (resident_coherence
                      ? "resident coherent I-cache/dispatch-line wrapper "
                      : "whole-I-cache invalidator ")
              << "(libtinyalsa result "
              << mixer_result << ", expected F1 rc=64)\n";
  }

  const WriteChunk restore{
      .patch_name = dispatch.name,
      .address = install.address,
      .before = install.after,
      .after = install.before,
      .width_bits = install.width_bits,
  };
  std::string restore_error;
  std::vector<uint8_t> actual;
  bool restore_ok = transport->Dump(restore.address, restore.before.size(),
                                    &actual, &restore_error);
  if (restore_ok && actual == restore.before) {
    restore_ok = WriteOneChunk(transport, restore, &restore_error);
  } else if (restore_ok && actual != restore.after) {
    restore_error = "cache-flush dispatch changed unexpectedly before "
                    "restore: " +
                    Hex(actual);
    restore_ok = false;
  }
  std::vector<uint8_t> verified;
  if (restore_ok &&
      (!transport->Dump(restore.address, restore.after.size(), &verified,
                        &restore_error) ||
       verified != restore.after)) {
    if (restore_error.empty()) {
      restore_error = "cache-flush dispatch restore verification failed: " +
                      Hex(verified);
    }
    restore_ok = false;
  }
  if (!restore_ok) {
    *error = invocation_ok
                 ? restore_error
                 : "cache flush failed (" + invocation_error +
                       "); additionally dispatch restore failed (" +
                       restore_error + ')';
    return false;
  }
  if (!invocation_ok) {
    *error = invocation_error;
    return false;
  }
  std::cout << "restored and verified the stock HD Mic dispatch pointer\n";
  return true;
}

std::vector<std::size_t> TransitionOrder(Action action) {
  std::vector<std::size_t> order;
  const auto append_kind = [&order](PatchKind kind, bool reverse) {
    if (!reverse) {
      for (std::size_t index = 0; index < kPatches.size(); ++index) {
        if (kPatches[index].kind == kind) {
          order.push_back(index);
        }
      }
    } else {
      for (std::size_t index = kPatches.size(); index > 0; --index) {
        if (kPatches[index - 1].kind == kind) {
          order.push_back(index - 1);
        }
      }
    }
  };
  if (action == Action::kApply) {
    append_kind(PatchKind::kCave, false);
    append_kind(PatchKind::kSupport, false);
    append_kind(PatchKind::kActivation, false);
  } else {
    append_kind(PatchKind::kActivation, true);
    append_kind(PatchKind::kSupport, true);
    append_kind(PatchKind::kCave, true);
  }
  return order;
}

std::vector<std::string> RollbackChunks(FactoryDiag* transport,
                                        std::span<const WriteChunk> attempted) {
  std::vector<std::string> failures;
  for (auto iterator = attempted.rbegin(); iterator != attempted.rend();
       ++iterator) {
    const WriteChunk& chunk = *iterator;
    std::string error;
    std::vector<uint8_t> actual;
    if (!transport->Dump(chunk.address, chunk.after.size(), &actual, &error)) {
      failures.push_back(error);
      continue;
    }
    if (actual == chunk.before) {
      continue;
    }
    if (actual != chunk.after) {
      std::ostringstream message;
      message << "0x" << std::hex << std::setfill('0') << std::setw(8)
              << chunk.address << "=unknown:" << Hex(actual);
      failures.push_back(message.str());
      continue;
    }
    if (!transport->Write(chunk.address, BytesToLe32(chunk.before),
                          chunk.width_bits, &error)) {
      failures.push_back(error);
      continue;
    }
    std::vector<uint8_t> verified;
    if (!transport->Dump(chunk.address, chunk.before.size(), &verified,
                         &error)) {
      failures.push_back(error);
      continue;
    }
    if (verified != chunk.before) {
      std::ostringstream message;
      message << "0x" << std::hex << std::setfill('0') << std::setw(8)
              << chunk.address << "=verify:" << Hex(verified);
      failures.push_back(message.str());
    }
  }
  return failures;
}

bool Mutate(FactoryDiag* transport, mixer* card, Action action,
            std::span<const PatchState> states, std::string* error) {
  const PatchState source =
      action == Action::kApply ? PatchState::kStock : PatchState::kPatched;
  const PatchState destination =
      action == Action::kApply ? PatchState::kPatched : PatchState::kStock;
  const std::string_view source_name =
      source == PatchState::kStock ? "stock" : "patched";
  const std::string_view destination_name =
      destination == PatchState::kStock ? "stock" : "patched";
  if (Uniform(states, destination)) {
    std::vector<PatchState> synchronized;
    if (!RequireStockGuards(transport, error) ||
        !FlushInstructionCache(transport, card, error) ||
        !ReadStates(transport, &synchronized, error) ||
        !Uniform(synchronized, destination) ||
        !RequireStockGuards(transport, error)) {
      if (error->empty()) {
        *error = "destination state changed during I-cache synchronization";
      }
      return false;
    }
    std::cout << "AoC memory was already uniformly " << destination_name
              << "; synchronized the F1 instruction cache\n";
    return true;
  }
  if (!Uniform(states, source)) {
    *error = "refusing mixed D10 profile; expected uniformly " +
             std::string(source_name) + " or " +
             std::string(destination_name);
    return false;
  }

  std::vector<WriteChunk> attempted;
  std::string operation_error;
  bool operation_ok = true;
  for (const std::size_t index : TransitionOrder(action)) {
    std::vector<WriteChunk> chunks;
    if (!ChangedChunks(kPatches[index], action, &chunks, &operation_error)) {
      operation_ok = false;
      break;
    }
    for (const WriteChunk& chunk : chunks) {
      attempted.push_back(chunk);
      if (!WriteOneChunk(transport, chunk, &operation_error)) {
        operation_ok = false;
        break;
      }
    }
    if (!operation_ok) {
      break;
    }
  }
  std::vector<PatchState> final_states;
  if (operation_ok &&
      (!ReadStates(transport, &final_states, &operation_error) ||
       !Uniform(final_states, destination))) {
    if (operation_error.empty()) {
      operation_error = "final D10 state was not uniformly " +
                        std::string(destination_name);
    }
    operation_ok = false;
  }
  if (operation_ok &&
      (!RequireStockGuards(transport, &operation_error) ||
       !FlushInstructionCache(transport, card, &operation_error) ||
       !ReadStates(transport, &final_states, &operation_error) ||
       !Uniform(final_states, destination) ||
       !RequireStockGuards(transport, &operation_error))) {
    if (operation_error.empty()) {
      operation_error =
          "D10 state changed while synchronizing the F1 instruction cache";
    }
    operation_ok = false;
  }
  if (operation_ok) {
    std::cout << "verified uniformly " << destination_name
              << "; live changes disappear on AoC/device reboot\n";
    return true;
  }

  std::vector<std::string> failures = RollbackChunks(transport, attempted);
  if (failures.empty()) {
    std::string sync_error;
    std::vector<PatchState> restored;
    if (!ReadStates(transport, &restored, &sync_error) ||
        !Uniform(restored, source) ||
        !RequireStockGuards(transport, &sync_error) ||
        !FlushInstructionCache(transport, card, &sync_error) ||
        !RequireStockGuards(transport, &sync_error)) {
      if (sync_error.empty()) {
        sync_error = "rollback did not restore the uniform source state";
      }
      failures.push_back("I-cache rollback sync=" + sync_error);
    }
  }
  if (!failures.empty()) {
    std::ostringstream message;
    message << "transaction failed (" << operation_error
            << "); rollback was incomplete:";
    for (const std::string& failure : failures) {
      message << ' ' << failure << ';';
    }
    *error = message.str();
    return false;
  }
  *error = "transaction failed (" + operation_error +
           "); restored the complete initial profile";
  return false;
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
           wanted + " (setter result " + std::to_string(result) + "): " +
           readback_error;
  return false;
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
    *error = "refusing ALSA card0 id='" + card_id +
             "'; expected googleaocsndcar";
    return false;
  }
  if (!CheckCharDevice(kFactoryDiag, R_OK, O_RDONLY, error) ||
      !CheckCharDevice(kFactoryDiag, W_OK, O_WRONLY, error) ||
      !CheckCharDevice(kDebugDevice, R_OK, O_RDONLY, error)) {
    return false;
  }
  return true;
}

int Run(std::string_view action_text, bool allow_incomplete_boot,
        std::string* error) {
  UniqueFd transaction_lock(
      open(kTransactionLock, O_RDWR | O_CREAT | O_CLOEXEC, 0600));
  if (!transaction_lock.valid()) {
    *error = ErrnoText("open " + std::string(kTransactionLock));
    return 2;
  }
  if (flock(transaction_lock.get(), LOCK_EX | LOCK_NB) != 0) {
    *error = ErrnoText("lock " + std::string(kTransactionLock));
    return 2;
  }
  if (!CheckTarget(allow_incomplete_boot, error)) {
    return 2;
  }

  const bool apply = action_text == "apply";
  const bool revert = action_text == "revert";
  const bool mutation = apply || revert;
  if (mutation && !SetReady(false, error)) {
    return 2;
  }

  CaptureQuarantine quarantine;
  bool operation_ok = quarantine.Apply(error);
  UniqueMixer card;
  if (operation_ok) {
    card.Reset(mixer_open(0));
    if (!card.valid()) {
      *error = "mixer_open(0) failed for googleaocsndcar";
      operation_ok = false;
    }
  }

  FactoryDiag transport;
  std::vector<PatchState> states;
  if (operation_ok &&
      (!CheckCaptureIdle(quarantine, error) ||
       !RequireStrictRuntime(card.get(), error) ||
       !RequireStockGuards(&transport, error) ||
       !ReadStates(&transport, &states, error) ||
       !CheckCaptureIdle(quarantine, error) ||
       !RequireStrictRuntime(card.get(), error) ||
       !RequireStockGuards(&transport, error))) {
    operation_ok = false;
  }

  if (operation_ok && !mutation) {
    const PatchState wanted = action_text == "check-stock"
                                  ? PatchState::kStock
                                  : PatchState::kPatched;
    if (!Uniform(states, wanted)) {
      *error = "AoC D10 profile is not uniformly " +
               std::string(wanted == PatchState::kStock ? "stock" :
                                                             "patched");
      operation_ok = false;
    }
  }
  if (operation_ok && mutation &&
      !Mutate(&transport, card.get(),
              apply ? Action::kApply : Action::kRevert, states, error)) {
    operation_ok = false;
  }

  // Reprove every external guard before readiness can be raised. Mutate has
  // already proved the uniform destination and restored the dispatch; this
  // second read closes the handoff around the final mixer/PCM checks.
  if (operation_ok && mutation) {
    std::vector<PatchState> final_states;
    const PatchState destination =
        apply ? PatchState::kPatched : PatchState::kStock;
    if (!CheckCaptureIdle(quarantine, error) ||
        !RequireStrictRuntime(card.get(), error) ||
        !RequireStockGuards(&transport, error) ||
        !ReadStates(&transport, &final_states, error) ||
        !Uniform(final_states, destination) ||
        !RequireStockGuards(&transport, error)) {
      if (error->empty()) {
        *error = "final D10 readiness handoff was not uniformly " +
                 std::string(apply ? "patched" : "stock");
      }
      operation_ok = false;
    }
  }

  // Release controlC0 before the readiness property can start audioserver.
  card.Reset();
  std::string restore_error;
  if (!quarantine.Restore(&restore_error)) {
    if (operation_ok) {
      *error = restore_error;
    } else {
      *error += "; additionally " + restore_error;
    }
    operation_ok = false;
  }

  if (operation_ok && apply && !SetReady(true, error)) {
    operation_ok = false;
  }
  if (!operation_ok && mutation) {
    std::string clear_error;
    if (!SetReady(false, &clear_error)) {
      *error += "; additionally readiness clear failed: " + clear_error;
    }
  }
  return operation_ok ? 0 : 2;
}

void Usage(const char* program) {
  std::cerr << "usage: " << program
            << " {apply|revert|check-stock|check-patched}\n"
            << "       " << program << " apply --allow-incomplete-boot\n";
}

}  // namespace
}  // namespace frankel_aoc_d10_patch

int main(int argc, char** argv) {
  using namespace frankel_aoc_d10_patch;
  if (argc == 2 &&
      (std::string_view(argv[1]) == "--help" ||
       std::string_view(argv[1]) == "-h")) {
    Usage(argv[0]);
    return 0;
  }
  if (argc != 2 && argc != 3) {
    Usage(argv[0]);
    return 64;
  }
  const std::string_view action(argv[1]);
  if (action != "apply" && action != "revert" &&
      action != "check-stock" && action != "check-patched") {
    Usage(argv[0]);
    return 64;
  }
  const bool allow_incomplete_boot =
      argc == 3 &&
      std::string_view(argv[2]) == "--allow-incomplete-boot";
  if (argc == 3 && (!allow_incomplete_boot || action != "apply")) {
    Usage(argv[0]);
    return 64;
  }
  std::string error;
  const int result = Run(action, allow_incomplete_boot, &error);
  if (result != 0) {
    std::fprintf(stderr, "error: %s\n",
                 error.empty() ? "unspecified internal failure" : error.c_str());
  }
  return result;
}
