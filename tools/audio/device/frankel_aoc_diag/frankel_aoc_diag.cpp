// SPDX-License-Identifier: Apache-2.0

#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <sys/system_properties.h>
#include <sys/types.h>
#include <time.h>
#include <unistd.h>

#include <algorithm>
#include <array>
#include <charconv>
#include <chrono>
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

namespace frankel_aoc_diag {
namespace {

constexpr std::string_view kExpectedDevice = "frankel";
constexpr char kFactoryDiag[] = "/dev/acd-factory_diag";
constexpr char kDebugDevice[] = "/dev/acd-debug";
// Share the existing speaker patcher's lock so the two native transports
// cannot consume one another's factory replies or debug output.
constexpr char kTransactionLock[] =
    "/data/vendor/powerphone/.aoc-patch.lock";
constexpr uint8_t kDataTypeCommand = 0;
constexpr uint16_t kCommandMemorySet = 0x25;
constexpr uint16_t kCommandMemoryDump = 0x26;
constexpr int32_t kDefaultCore = 2;  // F1.
constexpr std::size_t kHeaderSize = 8;
constexpr std::size_t kMaximumFactoryResponse = 4096;
constexpr std::size_t kMaximumDebugOutput = 64 * 1024;
constexpr uint32_t kMaximumDumpChunk = 256;
constexpr uint32_t kMaximumDumpRequest = 64 * 1024;
constexpr auto kFactoryWriteTimeout = std::chrono::seconds(2);
constexpr auto kFactoryRetryDelay = std::chrono::milliseconds(1);

using Clock = std::chrono::steady_clock;

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

std::string ErrnoText(std::string_view operation) {
  return std::string(operation) + ": " + std::strerror(errno);
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

std::string Hex(std::span<const uint8_t> bytes) {
  std::ostringstream stream;
  stream << std::hex << std::setfill('0');
  for (const uint8_t byte : bytes) {
    stream << std::setw(2) << static_cast<unsigned int>(byte);
  }
  return stream.str();
}

bool ParseU32(std::string_view text, uint32_t* result, std::string* error) {
  if (text.empty() || text.front() == '+' || text.front() == '-') {
    *error = "invalid unsigned integer: '" + std::string(text) + "'";
    return false;
  }
  int base = 10;
  if (text.size() > 2 && text[0] == '0' &&
      (text[1] == 'x' || text[1] == 'X')) {
    text.remove_prefix(2);
    base = 16;
  }
  if (text.empty()) {
    *error = "invalid unsigned integer";
    return false;
  }
  uint32_t value = 0;
  const auto parsed =
      std::from_chars(text.data(), text.data() + text.size(), value, base);
  if (parsed.ec != std::errc{} || parsed.ptr != text.data() + text.size()) {
    *error = "invalid u32: '" + std::string(text) + "'";
    return false;
  }
  *result = value;
  return true;
}

bool CheckTarget(std::string* error) {
  if (getuid() != 0 || geteuid() != 0) {
    *error = "real and effective uid must both be root";
    return false;
  }
  std::array<char, PROP_VALUE_MAX> device{};
  const int length = __system_property_get("ro.product.device", device.data());
  if (length <= 0) {
    *error = "missing Android property ro.product.device";
    return false;
  }
  const std::string_view actual(device.data(), static_cast<std::size_t>(length));
  if (actual != kExpectedDevice) {
    *error = "refusing ro.product.device=" + std::string(actual) +
             "; expected frankel";
    return false;
  }
  for (const char* path : {kFactoryDiag, kDebugDevice}) {
    struct stat status {};
    if (stat(path, &status) != 0) {
      *error = ErrnoText(std::string("stat ") + path);
      return false;
    }
    if (!S_ISCHR(status.st_mode)) {
      *error = std::string(path) + " is not a character device";
      return false;
    }
  }
  if (access(kFactoryDiag, R_OK | W_OK) != 0) {
    *error = ErrnoText(std::string("access ") + kFactoryDiag);
    return false;
  }
  if (access(kDebugDevice, R_OK) != 0) {
    *error = ErrnoText(std::string("access ") + kDebugDevice);
    return false;
  }
  return true;
}

int RemainingMilliseconds(Clock::time_point deadline) {
  const auto remaining = deadline - Clock::now();
  if (remaining <= Clock::duration::zero()) {
    return 0;
  }
  auto milliseconds =
      std::chrono::duration_cast<std::chrono::milliseconds>(remaining);
  if (milliseconds < remaining) {
    milliseconds += std::chrono::milliseconds(1);
  }
  return static_cast<int>(std::min<int64_t>(milliseconds.count(),
                                            std::numeric_limits<int>::max()));
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

bool PollForInput(int fd, Clock::time_point deadline, bool* ready,
                  std::string* error) {
  *ready = false;
  while (true) {
    const int timeout = RemainingMilliseconds(deadline);
    if (timeout == 0) {
      return true;
    }
    pollfd descriptor{.fd = fd, .events = POLLIN, .revents = 0};
    const int result = poll(&descriptor, 1, timeout);
    if (result == 0) {
      return true;
    }
    if (result < 0) {
      if (errno == EINTR) {
        continue;
      }
      *error = ErrnoText("poll");
      return false;
    }
    if ((descriptor.revents & (POLLERR | POLLNVAL)) != 0) {
      *error = "device poll reported an error";
      return false;
    }
    if ((descriptor.revents & POLLIN) != 0) {
      *ready = true;
      return true;
    }
    if ((descriptor.revents & POLLHUP) != 0) {
      return true;
    }
  }
}

bool ReadDebug(std::chrono::milliseconds hard_timeout,
               std::chrono::milliseconds quiet_timeout, std::string* output,
               std::string* error) {
  UniqueFd fd(open(kDebugDevice, O_RDONLY | O_CLOEXEC | O_NONBLOCK));
  if (!fd.valid()) {
    *error = ErrnoText(std::string("open ") + kDebugDevice);
    return false;
  }
  output->clear();
  const Clock::time_point hard_deadline = Clock::now() + hard_timeout;
  Clock::time_point deadline = hard_deadline;
  std::array<char, 4096> buffer{};
  while (Clock::now() < deadline) {
    bool ready = false;
    if (!PollForInput(fd.get(), deadline, &ready, error)) {
      return false;
    }
    if (!ready) {
      return true;
    }
    while (true) {
      const ssize_t count = read(fd.get(), buffer.data(), buffer.size());
      if (count > 0) {
        if (output->size() + static_cast<std::size_t>(count) >
            kMaximumDebugOutput) {
          *error = "acd-debug output exceeded the size limit";
          return false;
        }
        output->append(buffer.data(), static_cast<std::size_t>(count));
        deadline = std::min(hard_deadline, Clock::now() + quiet_timeout);
        continue;
      }
      if (count == 0) {
        return true;
      }
      if (errno == EINTR) {
        continue;
      }
      if (errno == EAGAIN || errno == EWOULDBLOCK) {
        break;
      }
      *error = ErrnoText(std::string("read ") + kDebugDevice);
      return false;
    }
  }
  return true;
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

std::vector<uint8_t> BuildSetPacket(uint8_t counter, int32_t core,
                                    uint32_t address, uint32_t value,
                                    uint32_t width) {
  constexpr uint16_t kLength = 8 + 4 + 4 + 4 + 1;
  const uint8_t mode = width == 32 ? 0 : width == 16 ? 1 : 2;
  std::vector<uint8_t> packet;
  packet.reserve(kLength);
  packet.push_back(kDataTypeCommand);
  packet.push_back(counter);
  AppendLe16(&packet, kLength);
  AppendLe16(&packet, kCommandMemorySet);
  AppendLe16(&packet, 0);
  AppendLe32(&packet, static_cast<uint32_t>(core));
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

bool ParseMemoryDump(std::string_view debug_output, uint32_t address,
                     std::size_t size, std::vector<uint8_t>* result,
                     std::string* error) {
  result->clear();
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

class FactoryDiag {
 public:
  explicit FactoryDiag(int32_t core) : core_(core) {
    timespec now{};
    if (clock_gettime(CLOCK_MONOTONIC, &now) == 0) {
      counter_ = static_cast<uint8_t>(now.tv_nsec);
    }
  }

  bool Dump(uint32_t address, uint32_t size, std::vector<uint8_t>* bytes,
            std::string* error) {
    bytes->clear();
    uint32_t offset = 0;
    while (offset < size) {
      const uint32_t chunk = std::min(kMaximumDumpChunk, size - offset);
      std::vector<uint8_t> part;
      if (!DumpChunk(address + offset, chunk, &part, error)) {
        return false;
      }
      bytes->insert(bytes->end(), part.begin(), part.end());
      offset += chunk;
    }
    return true;
  }

  bool Write(uint32_t address, uint32_t value, uint32_t width,
             std::string* error) {
    const uint8_t counter = counter_++;
    const std::vector<uint8_t> packet =
        BuildSetPacket(counter, core_, address, value, width);
    std::string ignored;
    return Transact(packet, counter, kCommandMemorySet, false, &ignored, error);
  }

 private:
  bool DumpChunk(uint32_t address, uint32_t size, std::vector<uint8_t>* bytes,
                 std::string* error) {
    const uint8_t counter = counter_++;
    const std::vector<uint8_t> packet =
        BuildDumpPacket(counter, core_, address, size);
    std::string debug;
    if (!Transact(packet, counter, kCommandMemoryDump, true, &debug, error)) {
      return false;
    }
    if (ParseMemoryDump(debug, address, size, bytes, error)) {
      return true;
    }
    // The command response and text channel are separate. Collect one delayed
    // tail without ever resending the command; this keeps reads idempotent and
    // writes strictly one-shot.
    std::string delayed;
    if (!ReadDebug(std::chrono::seconds(1), std::chrono::milliseconds(100),
                   &delayed, error)) {
      return false;
    }
    debug += delayed;
    if (!ParseMemoryDump(debug, address, size, bytes, error)) {
      *error += "; debug output: " + debug;
      return false;
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
      *error = ErrnoText(std::string("open ") + kFactoryDiag + " for read");
      return false;
    }
    response->clear();
    const Clock::time_point deadline = Clock::now() + std::chrono::seconds(2);
    std::array<uint8_t, kMaximumFactoryResponse> buffer{};
    while (Clock::now() < deadline) {
      const ssize_t count = read(fd.get(), buffer.data(), buffer.size());
      if (count > 0) {
        response->insert(response->end(), buffer.begin(),
                         buffer.begin() + count);
        if (response->size() > kMaximumFactoryResponse) {
          *error = "factory_diag response exceeded the size limit";
          return false;
        }
        if (response->size() >= 4) {
          const std::size_t expected_length =
              static_cast<std::size_t>((*response)[2]) |
              static_cast<std::size_t>((*response)[3]) << 8;
          if (expected_length < kHeaderSize ||
              expected_length > kMaximumFactoryResponse) {
            *error = "invalid factory_diag response length field";
            return false;
          }
          if (response->size() > expected_length) {
            *error = "factory_diag returned trailing or interleaved bytes";
            return false;
          }
          if (response->size() == expected_length) {
            return true;
          }
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
      // acd-factory_diag does not provide useful poll readiness on the
      // production Frankel driver.  A blocking dd succeeds against the same
      // command, while poll(POLLIN) times out.  Keep the descriptor owned by
      // this process and retry its nonblocking read instead; unlike a shell
      // timeout around dd this cannot leave an orphan reader behind.
      timespec pause{.tv_sec = 0, .tv_nsec = 1000000};
      while (nanosleep(&pause, &pause) != 0 && errno == EINTR) {
      }
    }
    *error = response->empty()
                 ? "timed out waiting for factory_diag response"
                 : "timed out assembling factory_diag response";
    return false;
  }

  bool Transact(std::span<const uint8_t> packet, uint8_t counter,
                uint16_t command, bool collect_debug, std::string* debug,
                std::string* error) {
    std::string discarded;
    if (!ReadDebug(std::chrono::milliseconds(100),
                   std::chrono::milliseconds(20), &discarded, error) ||
        !WriteOnePacket(packet, error)) {
      return false;
    }
    std::vector<uint8_t> response;
    if (!ReadResponse(&response, error) ||
        !ParseCommandResponse(response, counter, command, error)) {
      return false;
    }
    if (!collect_debug) {
      debug->clear();
      return true;
    }
    return ReadDebug(std::chrono::seconds(1), std::chrono::milliseconds(100),
                     debug, error);
  }

  int32_t core_;
  uint8_t counter_ = 0;
};

void Usage(const char* program) {
  std::cerr << "usage:\n"
            << "  " << program << " [--core 1..4] dump ADDRESS SIZE\n"
            << "  " << program
            << " [--core 1..4] write {8|16|32} ADDRESS EXPECTED VALUE\n"
            << "  " << program
            << " [--core 1..4] write-raw {8|16|32} ADDRESS VALUE\n";
}

int Run(int argc, char** argv, std::string* error) {
  int argument = 1;
  uint32_t core = kDefaultCore;
  if (argument < argc && std::string_view(argv[argument]) == "--core") {
    if (argument + 1 >= argc || !ParseU32(argv[argument + 1], &core, error) ||
        core < 1 || core > 4) {
      if (error->empty()) {
        *error = "core must be 1..4";
      }
      return 64;
    }
    argument += 2;
  }
  if (argument >= argc) {
    return 64;
  }
  const std::string_view operation(argv[argument++]);
  if (operation == "dump" && argc - argument != 2) {
    return 64;
  }
  if (operation == "write" && argc - argument != 4) {
    return 64;
  }
  if (operation == "write-raw" && argc - argument != 3) {
    return 64;
  }
  if (operation != "dump" && operation != "write" &&
      operation != "write-raw") {
    return 64;
  }

  uint32_t address = 0;
  uint32_t size_or_width = 0;
  uint32_t expected = 0;
  uint32_t value = 0;
  if (operation == "dump") {
    if (!ParseU32(argv[argument], &address, error) ||
        !ParseU32(argv[argument + 1], &size_or_width, error)) {
      return 64;
    }
    if (size_or_width == 0 || size_or_width > kMaximumDumpRequest ||
        address > std::numeric_limits<uint32_t>::max() -
                      (size_or_width - 1)) {
      *error = "dump must be 1..65536 bytes and must not wrap u32";
      return 64;
    }
  } else if (operation == "write") {
    if (!ParseU32(argv[argument], &size_or_width, error) ||
        !ParseU32(argv[argument + 1], &address, error) ||
        !ParseU32(argv[argument + 2], &expected, error) ||
        !ParseU32(argv[argument + 3], &value, error)) {
      return 64;
    }
    if (size_or_width != 8 && size_or_width != 16 &&
        size_or_width != 32) {
      *error = "write width must be 8, 16, or 32";
      return 64;
    }
    const uint32_t width_bytes = size_or_width / 8;
    if (address % width_bytes != 0 ||
        address > std::numeric_limits<uint32_t>::max() -
                      (width_bytes - 1)) {
      *error = "write address must be naturally aligned and must not wrap u32";
      return 64;
    }
    const uint32_t maximum = size_or_width == 32
                                 ? std::numeric_limits<uint32_t>::max()
                                 : (uint32_t{1} << size_or_width) - 1;
    if (expected > maximum || value > maximum) {
      *error = "expected/value does not fit the selected width";
      return 64;
    }
  } else {
    if (!ParseU32(argv[argument], &size_or_width, error) ||
        !ParseU32(argv[argument + 1], &address, error) ||
        !ParseU32(argv[argument + 2], &value, error)) {
      return 64;
    }
    if (size_or_width != 8 && size_or_width != 16 &&
        size_or_width != 32) {
      *error = "write width must be 8, 16, or 32";
      return 64;
    }
    const uint32_t width_bytes = size_or_width / 8;
    if (address % width_bytes != 0 ||
        address > std::numeric_limits<uint32_t>::max() -
                      (width_bytes - 1)) {
      *error = "write address must be naturally aligned and must not wrap u32";
      return 64;
    }
    const uint32_t maximum = size_or_width == 32
                                 ? std::numeric_limits<uint32_t>::max()
                                 : (uint32_t{1} << size_or_width) - 1;
    if (value > maximum) {
      *error = "value does not fit the selected width";
      return 64;
    }
  }

  UniqueFd lock(open(kTransactionLock, O_RDWR | O_CREAT | O_CLOEXEC, 0600));
  if (!lock.valid()) {
    *error = ErrnoText(std::string("open ") + kTransactionLock);
    return 2;
  }
  if (flock(lock.get(), LOCK_EX | LOCK_NB) != 0) {
    *error = ErrnoText(std::string("lock ") + kTransactionLock);
    return 2;
  }
  if (!CheckTarget(error)) {
    return 2;
  }

  FactoryDiag transport(static_cast<int32_t>(core));
  if (operation == "dump") {
    std::vector<uint8_t> bytes;
    if (!transport.Dump(address, size_or_width, &bytes, error)) {
      return 2;
    }
    std::cout << Hex(bytes) << '\n';
    return 0;
  }

  if (operation == "write-raw") {
    if (!transport.Write(address, value, size_or_width, error)) {
      return 2;
    }
    std::cout << "0x" << std::hex << std::setfill('0') << std::setw(8)
              << address << ": wrote 0x"
              << std::setw(static_cast<int>((size_or_width / 8) * 2))
              << value << " (unverified)\n";
    return 0;
  }

  const uint32_t width_bytes = size_or_width / 8;
  std::vector<uint8_t> before;
  if (!transport.Dump(address, width_bytes, &before, error)) {
    return 2;
  }
  uint32_t actual = 0;
  for (std::size_t index = 0; index < before.size(); ++index) {
    actual |= static_cast<uint32_t>(before[index]) << (8 * index);
  }
  if (actual != expected) {
    std::ostringstream message;
    message << "guard mismatch at 0x" << std::hex << std::setfill('0')
            << std::setw(8) << address << ": got 0x"
            << std::setw(static_cast<int>(width_bytes * 2)) << actual
            << ", expected 0x"
            << std::setw(static_cast<int>(width_bytes * 2)) << expected;
    *error = message.str();
    return 2;
  }
  if (!transport.Write(address, value, size_or_width, error)) {
    return 2;
  }
  std::vector<uint8_t> after;
  if (!transport.Dump(address, width_bytes, &after, error)) {
    return 2;
  }
  uint32_t verified = 0;
  for (std::size_t index = 0; index < after.size(); ++index) {
    verified |= static_cast<uint32_t>(after[index]) << (8 * index);
  }
  if (verified != value) {
    std::ostringstream message;
    message << "write verification failed at 0x" << std::hex
            << std::setfill('0') << std::setw(8) << address << ": got 0x"
            << std::setw(static_cast<int>(width_bytes * 2)) << verified
            << ", expected 0x"
            << std::setw(static_cast<int>(width_bytes * 2)) << value;
    *error = message.str();
    return 2;
  }
  std::cout << "0x" << std::hex << std::setfill('0') << std::setw(8)
            << address << ": 0x"
            << std::setw(static_cast<int>(width_bytes * 2)) << actual
            << " -> 0x" << std::setw(static_cast<int>(width_bytes * 2))
            << verified << '\n';
  return 0;
}

}  // namespace
}  // namespace frankel_aoc_diag

int main(int argc, char** argv) {
  using namespace frankel_aoc_diag;
  if (argc == 2 &&
      (std::string_view(argv[1]) == "--help" ||
       std::string_view(argv[1]) == "-h")) {
    Usage(argv[0]);
    return 0;
  }
  std::string error;
  const int result = Run(argc, argv, &error);
  if (result == 64) {
    Usage(argv[0]);
  }
  if (!error.empty()) {
    std::cerr << "error: " << error << '\n';
  }
  return result;
}
