// SPDX-License-Identifier: Apache-2.0
// Reuse the already exercised native factory protocol, not a shell command
// per register. No Frankel firmware patch addresses enter this translation unit.
#define POWERPHONE_AOC_TARGET "cubs"
#define main cubs_embedded_diag_cli_unused
#include "factory_transport.inc"
#undef main
#include "profile_generated.h"

#include <sound/asound.h>
#include <sys/ioctl.h>

#include <cstdio>
#include <fstream>
#include <iterator>

namespace cubs_boot {
namespace wire = frankel_aoc_diag;
using wire::UniqueFd;
using wire::Clock;
using Bytes = std::vector<uint8_t>;
constexpr char kCaptureReady[] = "vendor.powerphone.cubs.capture.ready";
constexpr char kPlaybackReady[] = "vendor.powerphone.cubs.playback.ready";
constexpr char kProfileProperty[] = "vendor.powerphone.cubs.profile";
constexpr char kBootProperty[] = "vendor.powerphone.cubs.boot_id";
constexpr char kPhaseProperty[] = "vendor.powerphone.cubs.boot.phase";
constexpr char kAudioServerStopped[] = "vendor.powerphone.cubs.audioserver_stopped";
constexpr char kDirectory[] = "/data/vendor/powerphone";
constexpr char kStamp[] = "/data/vendor/powerphone/cubs-boot-generation.txt";
constexpr uint32_t kDispatch = 0x402392b4;
constexpr uint32_t kStockDispatch = 0x4027bf8c;
constexpr uint32_t kWrapper = 0x4027b24c;

std::string Property(const char* name) {
  std::array<char, PROP_VALUE_MAX> value{};
  int size = __system_property_get(name, value.data());
  return size > 0 ? std::string(value.data(), size) : std::string();
}

bool ReadText(const char* path, std::string* output) {
  std::ifstream stream(path);
  if (!stream) return false;
  *output = std::string(std::istreambuf_iterator<char>(stream), {});
  while (!output->empty() && (output->back() == '\n' || output->back() == '\r')) output->pop_back();
  return !stream.bad();
}

struct Generation {
  std::string boot, restart, coredump;
  bool operator==(const Generation&) const = default;
};

bool ReadGeneration(Generation* value) {
  return ReadText("/proc/sys/kernel/random/boot_id", &value->boot) &&
      ReadText("/sys/devices/platform/a800000.aoc/restart_count", &value->restart) &&
      ReadText("/sys/devices/platform/a800000.aoc/coredump_count", &value->coredump) &&
      value->boot.size() == 36;
}

Bytes Decode(const char* text) {
  Bytes value;
  const size_t length = std::strlen(text);
  for (size_t i = 0; i + 1 < length; i += 2) {
    value.push_back(static_cast<uint8_t>((wire::HexDigit(text[i]) << 4) | wire::HexDigit(text[i + 1])));
  }
  return value;
}

uint32_t Le32(const Bytes& data) {
  return uint32_t(data[0]) | uint32_t(data[1]) << 8 |
      uint32_t(data[2]) << 16 | uint32_t(data[3]) << 24;
}

bool StoppedOwners() {
  const std::string stock = Property("init.svc.vendor.audio-hal-aidl");
  // init.svc.audioserver is a private platform property. A system-side init
  // action mirrors stopped/running into this explicitly labelled vendor bool.
  return Property(kAudioServerStopped) == "1" &&
      (stock.empty() || stock == "stopped");
}

class Boot {
 public:
  std::string error;
  bool mutated = false;
  bool playback_marker = false, slots_marker = false;

  bool CheckIdle() {
    if (getuid() != 0 || Property("ro.product.device") != "cubs") return Fail("require root on Cubs");
    UniqueFd control(open("/dev/snd/controlC0", O_RDWR | O_CLOEXEC));
    if (!control.valid()) return Fail(wire::ErrnoText("open controlC0"));
    return NoPcmOwners(control.get());
  }

  void RemoveQualifiedMarkersOnFailure() {
    if (playback_marker) (void)unlink("/dev/powerphone-cubs-direct192");
    if (slots_marker) (void)unlink("/dev/powerphone-cubs-tdm-slots");
    // Keep the mono marker after a mutation: it is a quarantine, not success.
  }

  bool Apply() {
    if (getuid() != 0 || geteuid() != 0 || Property("ro.product.device") != "cubs")
      return Fail("require real/effective root on Cubs");
    if (!Set(kCaptureReady, "0") || !Set(kPlaybackReady, "0") ||
        !Set(kProfileProperty, "") || !Set(kBootProperty, "")) return false;
    if (!Set(kPhaseProperty, "applying")) return false;
    LogPhase("waiting-prerequisites");
    if (mkdir(kDirectory, 0750) != 0 && errno != EEXIST) return Fail(wire::ErrnoText("mkdir powerphone"));
    UniqueFd lock(open(wire::kTransactionLock, O_RDWR | O_CREAT | O_CLOEXEC, 0600));
    if (!lock.valid() || flock(lock.get(), LOCK_EX | LOCK_NB) != 0)
      return Fail("factory transaction lock is unavailable");
    const auto deadline = Clock::now() + std::chrono::seconds(60);
    // This is an observable cold-boot prerequisite, not a fixed warm-up delay.
    while (true) {
      std::string target_error;
      if (StoppedOwners() && wire::CheckTarget(&target_error) &&
          access("/dev/snd/controlC0", R_OK | W_OK) == 0 &&
          ReadGeneration(&initial_)) break;
      if (Clock::now() >= deadline) return Fail("boot prerequisites unavailable: " + target_error);
      usleep(100000);
    }
    if (initial_.restart != "0" || initial_.coredump != "0")
      return Fail("require fresh AoC restart/coredump0/0, not a recovered generation");
    LogPhase("prerequisites-ready");
    UniqueFd control(open("/dev/snd/controlC0", O_RDWR | O_CLOEXEC));
    if (!control.valid()) return Fail(wire::ErrnoText("open controlC0"));
    if (!NoPcmOwners(control.get()) || !IdleMixer(control.get())) return false;
    if (!Maps()) return false;
    uint32_t endpoint = 0;
    if (!ResolveEndpoint(deadline, &endpoint)) return false;
    std::cout << "CUBS_BOOT objects ready: endpoint=0x" << std::hex << endpoint << std::dec << '\n';

    struct ReadyPatch { std::string name; uint32_t address; Bytes before, after; };
    std::vector<ReadyPatch> patches;
    for (const auto& patch : cubs_boot_profile::kPatches) {
      ReadyPatch value{patch.name, patch.address, Decode(patch.before), Decode(patch.after)};
      if (value.name == "d5_payload") {
        for (unsigned i = 0; i < 4; ++i) value.after[4 + i] = static_cast<uint8_t>(endpoint >> (8 * i));
      }
      patches.push_back(std::move(value));
    }
    for (const auto& guard : cubs_boot_profile::kGuards)
      if (!Require(guard.address, Decode(guard.expected), "stock ABI guard")) return false;
    for (const auto& patch : patches)
      if (!Require(patch.address, patch.before, "uniform stock " + patch.name)) return false;
    LogPhase("stock-guards-complete");
    // Recheck ownership immediately before the first irreversible mutation.
    if (!StoppedOwners() || !NoPcmOwners(control.get()) || !IdleMixer(control.get()) || !SameGeneration())
      return FailIfEmpty("audio ownership changed before activation");
    if (!Marker("/dev/powerphone-cubs-mono192", "")) return false;
    std::cout << "CUBS_BOOT applying " << patches.size() << " guarded regions\n";
    for (const auto& patch : patches) {
      if (!Write(patch.address, patch.after)) return false;
    }
    LogPhase("patches-installed");
    if (!Flush(control.get())) return false;
    LogPhase("cache-complete");
    for (const auto& patch : patches)
      if (!Require(patch.address, patch.after, "applied " + patch.name)) return false;
    if (!WordIs(kDispatch, kStockDispatch) || !SameGeneration() || !StoppedOwners() || !NoPcmOwners(control.get()))
      return FailIfEmpty("final generation/owner guard failed");
    if (!Stamp()) return false;
    if (!Marker("/dev/powerphone-cubs-direct192", "")) return false;
    playback_marker = true;
    if (!Marker("/dev/powerphone-cubs-tdm-slots", "2\n")) return false;
    slots_marker = true;
    // The replacement HAL requires the entire contract, never one ready bit.
    if (!Set(kProfileProperty, cubs_boot_profile::kProfile) ||
        !Set(kBootProperty, initial_.boot) || !SameGeneration() ||
        !Set(kCaptureReady, "1") || !Set(kPlaybackReady, "1") ||
        !Set(kPhaseProperty, "ready")) return false;
    std::cout << "CUBS_BOOT_READY profile=" << cubs_boot_profile::kProfile
              << " boot_id=" << initial_.boot << " restart=0 coredump=0\n";
    LogPhase("ready");
    return true;
  }

 private:
  wire::FactoryDiag a32_{1}, f1_{2};
  Generation initial_;
  const Clock::time_point started_ = Clock::now();

  void LogPhase(const char* phase) {
    const auto now = Clock::now();
    std::cout << "CUBS_BOOT_TIMING phase=" << phase
              << " elapsed_ms=" << std::chrono::duration_cast<std::chrono::milliseconds>(now - started_).count()
              << " monotonic_ms=" << std::chrono::duration_cast<std::chrono::milliseconds>(now.time_since_epoch()).count()
              << '\n';
  }

  bool Fail(const std::string& value) { error = value; return false; }
  bool FailIfEmpty(const std::string& value) { if (error.empty()) error = value; return false; }
  bool Set(const char* name, const std::string& value) {
    return __system_property_set(name, value.c_str()) == 0 || Fail("cannot publish property " + std::string(name));
  }
  bool SameGeneration() {
    Generation now;
    return (ReadGeneration(&now) && now == initial_) || Fail("AoC/boot generation changed");
  }
  bool RawDump(wire::FactoryDiag* transport, uint32_t address, uint32_t size, Bytes* data) {
    return SameGeneration() && transport->Dump(address, size, data, &error) && SameGeneration();
  }
  bool Dump(uint32_t address, size_t size, Bytes* data) {
    if (address < 0x40200000 || uint64_t(address) + size > 0x40400000 || size == 0)
      return Fail("read outside independently mapped MB2/3");
    return RawDump(&f1_, address + 0x40000000, static_cast<uint32_t>(size), data);
  }
  bool Word(uint32_t address, uint32_t* value) {
    Bytes bytes;
    if (!Dump(address, 4, &bytes)) return false;
    *value = Le32(bytes);
    return true;
  }
  bool Require(uint32_t address, const Bytes& expected, const std::string& what) {
    Bytes actual;
    if (!Dump(address, expected.size(), &actual)) return false;
    if (actual == expected) return true;
    std::ostringstream text;
    text << what << " differs at0x" << std::hex << address
         << ": actual=" << wire::Hex(actual) << " expected=" << wire::Hex(expected);
    return Fail(text.str());
  }
  bool WordIs(uint32_t address, uint32_t expected) {
    Bytes bytes;
    wire::AppendLe32(&bytes, expected);
    return Require(address, bytes, "word guard");
  }
  bool Write(uint32_t address, const Bytes& data) {
    if (address < 0x40200000 || uint64_t(address) + data.size() > 0x40400000)
      return Fail("write outside independently mapped MB2/3");
    size_t offset = 0;
    while (offset < data.size()) {
      if (!SameGeneration() || !StoppedOwners()) return FailIfEmpty("audio owner started during transaction");
      const uint32_t at = address + static_cast<uint32_t>(offset);
      const unsigned width = at % 4 == 0 && data.size() - offset >= 4 ? 4 :
          at % 2 == 0 && data.size() - offset >= 2 ? 2 : 1;
      uint32_t value = 0;
      for (unsigned i = 0; i < width; ++i) value |= uint32_t(data[offset + i]) << (8 * i);
      mutated = true;
      if (!f1_.Write(at + 0x40000000, value, width * 8, &error)) return false;
      offset += width;
    }
    return SameGeneration();
  }
  bool WriteWord(uint32_t address, uint32_t value) {
    Bytes bytes;
    wire::AppendLe32(&bytes, value);
    return Write(address, bytes);
  }
  bool Maps() {
    for (const auto& pair : {std::pair{0x40009008u, 0x1c2eu}, std::pair{0x4000a008u, 0x1c32u}}) {
      Bytes actual, expected;
      for (uint32_t mb : {2u, 3u}) wire::AppendLe32(&expected, (mb << 20) | pair.second);
      if (!RawDump(&a32_, pair.first, 8, &actual)) return false;
      if (actual != expected) return Fail("A32 live MB2/3 cached/NC mapping differs");
    }
    return true;
  }
  bool ResolveEndpoint(Clock::time_point deadline, uint32_t* endpoint) {
    uint32_t root = 0, second = 0, output = 0;
    while (true) {
      if (!Word(0x4035ca84, &root) || !Word(0x4035d00c, &second)) return false;
      if (root != 0 && root == second) break;
      if (Clock::now() >= deadline) return Fail("AudioInCtrl roots not initialized before deadline");
      usleep(100000);
    }
    if (!WordIs(root, 0x401ee698) || !Word(root + 0x2c4, &output) ||
        !WordIs(output, 0x401ee700) || !Word(output + 0x1f4, endpoint) ||
        !WordIs(*endpoint, 0x401fdb24)) return false;
    uint32_t kind = 0, frame = 0, ring = 0, reader = 0;
    if (!Word(*endpoint + 0x338, &kind) || !Word(*endpoint + 0x33c, &frame) ||
        !Word(*endpoint + 0x250, &ring) || !Word(*endpoint + 0x254, &reader)) return false;
    // Unlike the late diagnostic path, early boot need not have opened D5.
    if (kind == 0 && frame == 0 && ring == 0 && reader == 0) return true;
    if (!((kind == 0 && frame == 0) || (kind == 4 && frame == 8)) || reader != ring + 0xe4)
      return Fail("D5 source geometry/reader differs");
    if (!WordIs(ring, 0x4021d118)) return false;
    Bytes name;
    if (!Dump(ring + 0x20, 16, &name)) return false;
    return std::memcmp(name.data(), "audio_playback5", 16) == 0 ||
        Fail("D5 service name differs");
  }
  bool NoPcmOwners(int control) {
    // PCM_INFO is serialized under pcm->open_mutex. Its availability is
    // substream_count - substream_opened, not merely the RUNNING count.
    // This works with verbose PCM procfs disabled and needs no ptrace/FD scan.
    bool saw_playback = false, saw_capture = false;
    int device = -1;
    unsigned devices = 0, streams = 0;
    for (unsigned iteration = 0; iteration < 1024; ++iteration) {
      const int previous = device;
      if (ioctl(control, SNDRV_CTL_IOCTL_PCM_NEXT_DEVICE, &device) != 0)
        return Fail(wire::ErrnoText("PCM_NEXT_DEVICE"));
      if (device < 0) {
        if (!saw_playback || !saw_capture) return Fail("required D5 playback/D10 capture absent");
        std::cout << "CUBS_PCM_IDLE devices=" << devices << " streams=" << streams
                  << " D5p=closed D10c=closed\n";
        return true;
      }
      if (device <= previous) return Fail("PCM enumeration did not advance");
      ++devices;
      for (int stream : {SNDRV_PCM_STREAM_PLAYBACK, SNDRV_PCM_STREAM_CAPTURE}) {
        unsigned count = 1;
        for (unsigned sub = 0; sub < count; ++sub) {
          snd_pcm_info info{};
          info.device = static_cast<unsigned>(device);
          info.stream = stream;
          info.subdevice = sub;
          if (ioctl(control, SNDRV_CTL_IOCTL_PCM_INFO, &info) != 0) {
            if (sub == 0 && errno == ENOENT) break;  // Device lacks this direction.
            return Fail(wire::ErrnoText("PCM_INFO"));
          }
          if (info.card != 0 || info.device != static_cast<unsigned>(device) ||
              info.stream != stream || info.subdevice != sub ||
              info.subdevices_count == 0 || info.subdevices_count > 64)
            return Fail("PCM_INFO returned unexpected identity/count");
          count = info.subdevices_count;
          if (sub == 0) ++streams;
          if (info.subdevices_avail != count) {
            std::ostringstream text;
            text << "PCM still open: D" << device << (stream == SNDRV_PCM_STREAM_PLAYBACK ? 'p' : 'c')
                 << " available=" << info.subdevices_avail << " total=" << count;
            return Fail(text.str());
          }
          saw_playback |= device == 5 && stream == SNDRV_PCM_STREAM_PLAYBACK;
          saw_capture |= device == 10 && stream == SNDRV_PCM_STREAM_CAPTURE;
        }
      }
    }
    return Fail("PCM enumeration exceeded the bound");
  }
  bool Info(int fd, const char* name, snd_ctl_elem_info* info) {
    *info = {};
    info->id.iface = SNDRV_CTL_ELEM_IFACE_MIXER;
    std::snprintf(reinterpret_cast<char*>(info->id.name), sizeof(info->id.name), "%s", name);
    return ioctl(fd, SNDRV_CTL_IOCTL_ELEM_INFO, info) == 0 || Fail("missing mixer control " + std::string(name));
  }
  bool IdleMixer(int fd) {
    for (const char* name : {"MIC0", "MIC1", "MIC2", "US Record Enable",
         "EP1 TX Mixer INTERNAL_MIC_TX", "EP2 TX Mixer INTERNAL_MIC_TX",
         "EP3 TX Mixer INTERNAL_MIC_TX", "EP4 TX Mixer INTERNAL_MIC_TX",
         "EP5 TX Mixer INTERNAL_MIC_TX", "EP5 TX Mixer INTERNAL_MIC_US_TX",
         "EP6 TX Mixer INTERNAL_MIC_TX"}) {
      snd_ctl_elem_info info{};
      if (!Info(fd, name, &info) || info.count != 1) return FailIfEmpty("idle control width differs");
      snd_ctl_elem_value value{};
      value.id = info.id;
      if (ioctl(fd, SNDRV_CTL_IOCTL_ELEM_READ, &value) != 0) return Fail("cannot read " + std::string(name));
      if (info.type == SNDRV_CTL_ELEM_TYPE_BOOLEAN) {
        if (value.value.integer.value[0] != 0) return Fail("active control " + std::string(name));
      } else if (info.type == SNDRV_CTL_ELEM_TYPE_ENUMERATED) {
        info.value.enumerated.item = value.value.enumerated.item[0];
        if (ioctl(fd, SNDRV_CTL_IOCTL_ELEM_INFO, &info) != 0 ||
            std::string(info.value.enumerated.name) != "Off") return Fail("active control " + std::string(name));
      } else return Fail("unexpected idle control type " + std::string(name));
    }
    snd_ctl_elem_info hd{};
    if (!Info(fd, "HD Mic gain (cB)", &hd)) return false;
    return (hd.type == SNDRV_CTL_ELEM_TYPE_INTEGER && hd.count == 1) || Fail("HD gain schema differs");
  }
  bool Drain(int fd) {
    const auto deadline = Clock::now() + std::chrono::milliseconds(100);
    size_t total = 0;
    std::array<char, 4096> data{};
    while (Clock::now() < deadline && total <= wire::kMaximumDebugOutput) {
      const ssize_t got = read(fd, data.data(), data.size());
      if (got > 0) { total += static_cast<size_t>(got); continue; }
      if (got == 0 || errno == EAGAIN || errno == EWOULDBLOCK) return true;
      if (errno == EINTR) continue;
      return Fail(wire::ErrnoText("drain debug"));
    }
    return Fail("cannot establish a fresh HD debug boundary");
  }
  bool Completion(int fd) {
    const auto deadline = Clock::now() + std::chrono::seconds(2);
    std::string pending;
    std::array<char, 4096> data{};
    size_t total = 0;
    while (Clock::now() < deadline && total <= wire::kMaximumDebugOutput) {
      const ssize_t got = read(fd, data.data(), data.size());
      if (got > 0) {
        total += static_cast<size_t>(got);
        pending.append(data.data(), static_cast<size_t>(got));
        size_t end = 0;
        while ((end = pending.find('\n')) != std::string::npos) {
          std::string line = pending.substr(0, end);
          pending.erase(0, end + 1);
          if (line.find("0x12a4") == std::string::npos) continue;
          std::cout << "CUBS_BOOT cache: " << line << '\n';
          if (line.find("F1:") == std::string::npos || line.find("AudioInCtrl:") == std::string::npos) continue;
          const auto status = line.find("rc:");
          if (status == std::string::npos) continue;
          int rc = 0;
          if (std::sscanf(line.c_str() + status, "rc: %d", &rc) != 1) return Fail("invalid fresh HD status");
          return rc == 64 || Fail("fresh HD completion was " + std::to_string(rc) + ", not64");
        }
        continue;
      }
      if (got < 0 && errno != EINTR && errno != EAGAIN && errno != EWOULDBLOCK)
        return Fail(wire::ErrnoText("read HD completion"));
      usleep(1000);
    }
    return Fail("no fresh F1 HD command0x12a4 completion64");
  }
  bool Flush(int control) {
    if (!WordIs(kDispatch, kStockDispatch)) return false;
    if (!WriteWord(kDispatch, kWrapper)) return false;
    bool okay = false;
    {
      // acd-debug permits only one reader. FactoryDiag::Write and Dump each
      // own a temporary reader internally. Arm first, then hold our reader
      // only across drain -> HD ioctl -> completion; release before restore.
      UniqueFd debug(open(wire::kDebugDevice, O_RDONLY | O_CLOEXEC | O_NONBLOCK));
      okay = debug.valid() || Fail(wire::ErrnoText("open cache-flush debug"));
      if (okay) okay = Drain(debug.get());
      if (okay) {
        snd_ctl_elem_info info{};
        okay = Info(control, "HD Mic gain (cB)", &info);
        if (okay) {
          snd_ctl_elem_value value{};
          value.id = info.id;
          value.value.integer.value[0] = 0;
          const int status = ioctl(control, SNDRV_CTL_IOCTL_ELEM_WRITE, &value);
          std::cout << "CUBS_BOOT HD ioctl=" << status << " errno=" << (status < 0 ? errno : 0) << '\n';
          // Kernel ioctl success is insufficient, and firmware64 is expected.
          // Only the fresh F1 completion establishes actual execution.
          okay = Completion(debug.get());
        }
      }
    }
    const std::string invocation_error = error;
    // Restore even after a missing reply, but never overwrite a new generation
    // or an unexpected dispatch word. No blind retry of the callable hook.
    if (!SameGeneration() || !WordIs(kDispatch, kWrapper) ||
        !WriteWord(kDispatch, kStockDispatch) || !WordIs(kDispatch, kStockDispatch)) return false;
    if (!okay) return Fail(invocation_error);
    return SameGeneration();
  }
  bool Stamp() {
    const std::string text = "profile=" + std::string(cubs_boot_profile::kProfile) +
        "\nboot_id=" + initial_.boot + "\nrestart_count=0\ncoredump_count=0\n";
    const std::string temporary = std::string(kStamp) + ".tmp." + std::to_string(getpid());
    UniqueFd fd(open(temporary.c_str(), O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0600));
    if (!fd.valid()) return Fail(wire::ErrnoText("create generation stamp"));
    size_t offset = 0;
    while (offset < text.size()) {
      const ssize_t count = write(fd.get(), text.data() + offset, text.size() - offset);
      if (count < 0 && errno == EINTR) continue;
      if (count <= 0) { unlink(temporary.c_str()); return Fail("generation stamp write failed"); }
      offset += static_cast<size_t>(count);
    }
    if (fsync(fd.get()) != 0 || rename(temporary.c_str(), kStamp) != 0) {
      unlink(temporary.c_str()); return Fail(wire::ErrnoText("publish generation stamp"));
    }
    return true;
  }
  bool Marker(const char* path, const char* text) {
    UniqueFd fd(open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0600));
    if (!fd.valid()) return Fail(wire::ErrnoText(std::string("create marker ") + path));
    const size_t length = std::strlen(text);
    if (length != 0 && write(fd.get(), text, length) != static_cast<ssize_t>(length)) {
      (void)unlink(path);
      return Fail("cannot write marker " + std::string(path));
    }
    return true;
  }
};
}  // namespace cubs_boot

int main(int argc, char** argv) {
  using namespace cubs_boot;
  std::setvbuf(stdout, nullptr, _IOLBF, BUFSIZ);
  if (argc != 2 || (std::string_view(argv[1]) != "--apply" && std::string_view(argv[1]) != "--status" &&
                    std::string_view(argv[1]) != "--check-idle")) {
    std::cerr << "usage: cubs_powerphone_boot --apply|--status|--check-idle\n"
                 "--apply requires stock firmware, fresh AoC0/0 and all ordinary audio owners stopped; no sys.boot_completed requirement.\n";
    return 64;
  }
  if (std::string_view(argv[1]) == "--status") {
    for (const char* name : {kCaptureReady, kPlaybackReady, kProfileProperty, kBootProperty, kPhaseProperty, kAudioServerStopped})
      std::cout << name << '=' << Property(name) << '\n';
    Generation value;
    if (!ReadGeneration(&value)) return 1;
    std::cout << "current_boot_id=" << value.boot << "\nrestart_count=" << value.restart
              << "\ncoredump_count=" << value.coredump << '\n';
    return 0;
  }
  if (std::string_view(argv[1]) == "--check-idle") {
    alarm(10);
    Boot check;
    if (check.CheckIdle()) return 0;
    std::cerr << "CUBS_PCM_NOT_IDLE: " << check.error << '\n';
    return 1;
  }
  alarm(120);  // Init must keep clients excluded if any native syscall hangs.
  Boot boot;
  if (boot.Apply()) { alarm(0); return 0; }
  (void)__system_property_set(kCaptureReady, "0");
  (void)__system_property_set(kPlaybackReady, "0");
  (void)__system_property_set(kProfileProperty, "");
  (void)__system_property_set(kBootProperty, "");
  (void)__system_property_set(kPhaseProperty, "failed");
  boot.RemoveQualifiedMarkersOnFailure();
  std::cerr << "CUBS_BOOT_FAILED mutated=" << boot.mutated << ": " << boot.error
            << "; keep audio closed" << (boot.mutated ? "; cold reboot required" : "") << '\n';
  return 1;
}
