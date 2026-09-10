// SPDX-License-Identifier: Apache-2.0
//
// Minimal, header-free harness for the private Pixel libusf spectral API.
// The ABI below was reconstructed from the Frankel CP2A.260805.005 binaries.

#include <dlfcn.h>
#include <getopt.h>
#include <signal.h>

#include <atomic>
#include <cerrno>
#include <chrono>
#include <condition_variable>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <limits>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

namespace {

constexpr char kDefaultLibrary[] = "/vendor/lib64/libusf.so";
constexpr char kCreateSymbol[] =
    "_ZN3usf14UsfSpectralApi6CreateEPPS0_"
    "PNS_31UsfSpectralApiCallbackInterfaceENS_11UsfLogLevelE";
constexpr char kDestroySymbol[] =
    "_ZN3usf14UsfSpectralApi7DestroyEPPS0_";

volatile sig_atomic_t g_stop_requested = 0;

void HandleSignal(int) {
  g_stop_requested = 1;
}

// Only the address of this reference is passed through the ABI. Its layout is
// deliberately left opaque because the harness does not consume ALS events.
struct OpaqueUsfFloatVector {};

// Stack object assembled by UsfSpectralImpl::FlickerDataMsg immediately before
// callback vtable slot +0x18 is invoked. Only the fields used by this harness
// are named. Unknown format/quality metadata remains explicit padding.
struct FlickerDataView {
  uint8_t flag0;                 // +0x00
  uint8_t metadata1;             // +0x01
  uint8_t metadata2;             // +0x02
  uint8_t reserved03;            // +0x03
  uint16_t metadata4;            // +0x04
  uint16_t metadata6;            // +0x06
  uint16_t metadata8;            // +0x08
  uint16_t reserved0a;           // +0x0a
  uint32_t sample_count;         // +0x0c
  uint32_t sequence;             // +0x10
  uint32_t sample_rate_hz;       // +0x14
  float metadata18;              // +0x18
  float metadata1c;              // +0x1c
  float metadata20;              // +0x20
  float metadata24;              // +0x24
  const int32_t* samples;        // +0x28
};

static_assert(offsetof(FlickerDataView, sample_count) == 0x0c);
static_assert(offsetof(FlickerDataView, sequence) == 0x10);
static_assert(offsetof(FlickerDataView, sample_rate_hz) == 0x14);
static_assert(offsetof(FlickerDataView, samples) == 0x28);
static_assert(sizeof(FlickerDataView) == 0x30);

class SpectralCallbackShim {
 public:
  SpectralCallbackShim(std::vector<int32_t>* capture, size_t lib_buffer_capacity)
      : capture_(capture), lib_buffer_capacity_(lib_buffer_capacity) {}

  virtual ~SpectralCallbackShim() = default;

  // Callback interface vtable +0x10. The exact vector type is private, but a
  // C++ reference and an opaque reference have the same AArch64 calling ABI.
  virtual void SensorEvent(uint32_t /*sensor_type*/, uint32_t /*sampling_id*/,
                           const OpaqueUsfFloatVector& /*values*/,
                           uint64_t /*timestamp_ns*/) {}

  // Callback interface vtable +0x18.
  virtual void FlickerData(uint64_t stream_id, const FlickerDataView& block) {
    callback_count_.fetch_add(1, std::memory_order_relaxed);
    last_stream_id_.store(stream_id, std::memory_order_relaxed);
    sample_rate_hz_.store(block.sample_rate_hz, std::memory_order_relaxed);
    last_sequence_.store(block.sequence, std::memory_order_relaxed);

    size_t count = block.sample_count;
    if (block.samples == nullptr || count > lib_buffer_capacity_) {
      invalid_blocks_.fetch_add(1, std::memory_order_relaxed);
      return;
    }

    const size_t start = reserved_samples_.fetch_add(count,
                                                      std::memory_order_relaxed);
    if (start >= capture_->size()) {
      dropped_samples_.fetch_add(count, std::memory_order_relaxed);
      return;
    }
    const size_t available = capture_->size() - start;
    const size_t copy_count = count < available ? count : available;
    std::memcpy(capture_->data() + start, block.samples,
                copy_count * sizeof(int32_t));
    committed_samples_.fetch_add(copy_count, std::memory_order_release);
    if (copy_count != count) {
      dropped_samples_.fetch_add(count - copy_count,
                                 std::memory_order_relaxed);
    }
  }

  // Callback interface vtable +0x20. No arguments beyond |this| are supplied.
  virtual void Connected() {
    {
      std::lock_guard<std::mutex> lock(connection_mutex_);
      connected_ = true;
    }
    connection_cv_.notify_all();
  }

  bool WaitForConnection(std::chrono::milliseconds timeout) {
    std::unique_lock<std::mutex> lock(connection_mutex_);
    return connection_cv_.wait_for(lock, timeout,
                                   [this] { return connected_; });
  }

  size_t committed_samples() const {
    return committed_samples_.load(std::memory_order_acquire);
  }
  size_t dropped_samples() const {
    return dropped_samples_.load(std::memory_order_relaxed);
  }
  size_t callback_count() const {
    return callback_count_.load(std::memory_order_relaxed);
  }
  size_t invalid_blocks() const {
    return invalid_blocks_.load(std::memory_order_relaxed);
  }
  uint32_t sample_rate_hz() const {
    return sample_rate_hz_.load(std::memory_order_relaxed);
  }
  uint32_t last_sequence() const {
    return last_sequence_.load(std::memory_order_relaxed);
  }
  uint64_t last_stream_id() const {
    return last_stream_id_.load(std::memory_order_relaxed);
  }

 private:
  std::vector<int32_t>* capture_;
  size_t lib_buffer_capacity_;
  std::mutex connection_mutex_;
  std::condition_variable connection_cv_;
  bool connected_ = false;
  std::atomic<size_t> reserved_samples_{0};
  std::atomic<size_t> committed_samples_{0};
  std::atomic<size_t> dropped_samples_{0};
  std::atomic<size_t> callback_count_{0};
  std::atomic<size_t> invalid_blocks_{0};
  std::atomic<uint32_t> sample_rate_hz_{0};
  std::atomic<uint32_t> last_sequence_{0};
  std::atomic<uint64_t> last_stream_id_{0};
};

using CreateFn = int (*)(void**, SpectralCallbackShim*, int);
using DestroyFn = void (*)(void**);
using EnableFlickerFn = int (*)(void*, const char*, int32_t*, unsigned long,
                                uint8_t, uint32_t*);
using DisableFlickerFn = int (*)(void*, uint32_t);
using SetFlickerChannelFn = int (*)(void*, const char*, uint8_t, uint8_t);

struct Options {
  bool probe = false;
  bool enable = false;
  bool allow_missing_connect_callback = false;
  bool set_channel = false;
  int channel = 0;
  int fallback_channel = 0;
  int acknowledged_pdm = -1;
  uint64_t duration_ms = 2000;
  uint64_t max_samples = 0;
  uint64_t buffer_samples = 8192;
  uint64_t connect_timeout_ms = 5000;
  uint64_t output_bits = 24;
  std::string library = kDefaultLibrary;
  std::string sensor;
  std::string output;
};

void Usage(const char* argv0) {
  std::fprintf(
      stderr,
      "Usage:\n"
      "  %s --probe [--library PATH]\n"
      "  %s --enable --sensor NAME --output FILE [options]\n\n"
      "No arguments and --probe never create a USF client or start sampling.\n"
      "Sampling options:\n"
      "  --duration-ms N          Capture time (default 2000)\n"
      "  --buffer-samples N       libusf callback buffer capacity (default 8192)\n"
      "  --max-samples N          In-memory output capacity (default 384kHz headroom)\n"
      "  --output-bits N          Converter output width (default 24; stock camera value)\n"
      "  --connect-timeout-ms N   Wait for USF connect callback (default 5000)\n"
      "  --allow-missing-connect-callback\n"
      "                           After that full timeout, try the normal vendor\n"
      "                           enable call even if this libusf omitted the\n"
      "                           client callback (explicit Frankel ABI quirk)\n"
      "  --set-channel A:B        Explicitly call SetFlickerChannel before enable\n"
      "  --ack-pdm-reroute N      Acknowledge an external registry reroute to PDM 0..3\n"
      "  --library PATH           Private spectral library (default %s)\n\n"
      "Output is headerless little-endian signed int32 PCM. This tool never edits\n"
      "registry, firmware, mixer, or PDM routing state. --ack-pdm-reroute is a\n"
      "safety annotation only; rerouting must be performed separately.\n",
      argv0, argv0, kDefaultLibrary);
}

bool ParseUnsigned(const char* text, uint64_t* value) {
  if (text == nullptr || *text == '\0' || *text == '-') return false;
  char* end = nullptr;
  errno = 0;
  const unsigned long long parsed = std::strtoull(text, &end, 0);
  if (errno != 0 || end == text || *end != '\0') return false;
  *value = parsed;
  return true;
}

bool ParseChannelPair(const char* text, int* first, int* second) {
  if (text == nullptr) return false;
  const char* separator = std::strchr(text, ':');
  if (separator == nullptr || separator == text || separator[1] == '\0') {
    return false;
  }
  const std::string left(text, static_cast<size_t>(separator - text));
  uint64_t a = 0;
  uint64_t b = 0;
  if (!ParseUnsigned(left.c_str(), &a) ||
      !ParseUnsigned(separator + 1, &b) || a > 255 || b > 255) {
    return false;
  }
  *first = static_cast<int>(a);
  *second = static_cast<int>(b);
  return true;
}

bool ParseOptions(int argc, char** argv, Options* options) {
  enum {
    kOptProbe = 1000,
    kOptEnable,
    kOptSensor,
    kOptOutput,
    kOptDuration,
    kOptBufferSamples,
    kOptMaxSamples,
    kOptOutputBits,
    kOptConnectTimeout,
    kOptAllowMissingConnectCallback,
    kOptSetChannel,
    kOptAckPdmReroute,
    kOptLibrary,
    kOptHelp,
  };
  const option long_options[] = {
      {"probe", no_argument, nullptr, kOptProbe},
      {"enable", no_argument, nullptr, kOptEnable},
      {"sensor", required_argument, nullptr, kOptSensor},
      {"output", required_argument, nullptr, kOptOutput},
      {"duration-ms", required_argument, nullptr, kOptDuration},
      {"buffer-samples", required_argument, nullptr, kOptBufferSamples},
      {"max-samples", required_argument, nullptr, kOptMaxSamples},
      {"output-bits", required_argument, nullptr, kOptOutputBits},
      {"connect-timeout-ms", required_argument, nullptr, kOptConnectTimeout},
      {"allow-missing-connect-callback", no_argument, nullptr,
       kOptAllowMissingConnectCallback},
      {"set-channel", required_argument, nullptr, kOptSetChannel},
      {"ack-pdm-reroute", required_argument, nullptr, kOptAckPdmReroute},
      {"library", required_argument, nullptr, kOptLibrary},
      {"help", no_argument, nullptr, kOptHelp},
      {nullptr, 0, nullptr, 0},
  };

  while (true) {
    const int parsed = getopt_long(argc, argv, "", long_options, nullptr);
    if (parsed == -1) break;
    uint64_t value = 0;
    switch (parsed) {
      case kOptProbe:
        options->probe = true;
        break;
      case kOptEnable:
        options->enable = true;
        break;
      case kOptSensor:
        options->sensor = optarg;
        break;
      case kOptOutput:
        options->output = optarg;
        break;
      case kOptDuration:
        if (!ParseUnsigned(optarg, &options->duration_ms)) return false;
        break;
      case kOptBufferSamples:
        if (!ParseUnsigned(optarg, &options->buffer_samples)) return false;
        break;
      case kOptMaxSamples:
        if (!ParseUnsigned(optarg, &options->max_samples)) return false;
        break;
      case kOptOutputBits:
        if (!ParseUnsigned(optarg, &options->output_bits)) return false;
        break;
      case kOptConnectTimeout:
        if (!ParseUnsigned(optarg, &options->connect_timeout_ms)) return false;
        break;
      case kOptAllowMissingConnectCallback:
        options->allow_missing_connect_callback = true;
        break;
      case kOptSetChannel:
        if (!ParseChannelPair(optarg, &options->channel,
                              &options->fallback_channel)) {
          return false;
        }
        options->set_channel = true;
        break;
      case kOptAckPdmReroute:
        if (!ParseUnsigned(optarg, &value) || value > 3) return false;
        options->acknowledged_pdm = static_cast<int>(value);
        break;
      case kOptLibrary:
        options->library = optarg;
        break;
      case kOptHelp:
        Usage(argv[0]);
        std::exit(0);
      default:
        return false;
    }
  }
  if (optind != argc) return false;

  if (!options->enable) {
    return options->probe && options->sensor.empty() && options->output.empty() &&
           !options->allow_missing_connect_callback && !options->set_channel &&
           options->acknowledged_pdm < 0;
  }
  if (options->sensor.empty() || options->output.empty()) return false;
  if (options->duration_ms == 0 || options->duration_ms > 600000) return false;
  if (options->buffer_samples == 0 || options->buffer_samples > (1u << 20)) {
    return false;
  }
  if (options->output_bits == 0 || options->output_bits > 32) return false;
  if (options->connect_timeout_ms == 0 ||
      options->connect_timeout_ms > 60000) {
    return false;
  }
  return true;
}

template <typename Function>
Function Resolve(void* library, const char* symbol) {
  dlerror();
  void* address = dlsym(library, symbol);
  const char* error = dlerror();
  if (error != nullptr) {
    std::fprintf(stderr, "dlsym(%s): %s\n", symbol, error);
    return nullptr;
  }
  return reinterpret_cast<Function>(address);
}

bool WriteCapture(const std::string& path, const std::vector<int32_t>& capture,
                  size_t sample_count) {
  FILE* output = std::fopen(path.c_str(), "wb");
  if (output == nullptr) {
    std::perror(("fopen(" + path + ")").c_str());
    return false;
  }
  const size_t written =
      std::fwrite(capture.data(), sizeof(int32_t), sample_count, output);
  const bool close_ok = std::fclose(output) == 0;
  if (written != sample_count || !close_ok) {
    std::fprintf(stderr, "short/error write: %zu of %zu samples\n", written,
                 sample_count);
    return false;
  }
  return true;
}

}  // namespace

int main(int argc, char** argv) {
  Options options;
  if (argc == 1) {
    Usage(argv[0]);
    return 0;
  }
  if (!ParseOptions(argc, argv, &options)) {
    Usage(argv[0]);
    return 2;
  }

  void* library = dlopen(options.library.c_str(), RTLD_NOW | RTLD_LOCAL);
  if (library == nullptr) {
    std::fprintf(stderr, "dlopen(%s): %s\n", options.library.c_str(), dlerror());
    return 3;
  }
  const CreateFn create = Resolve<CreateFn>(library, kCreateSymbol);
  const DestroyFn destroy = Resolve<DestroyFn>(library, kDestroySymbol);
  if (create == nullptr || destroy == nullptr) {
    dlclose(library);
    return 4;
  }
  std::fprintf(stderr, "resolved Frankel UsfSpectralApi ABI in %s\n",
               options.library.c_str());
  if (!options.enable) {
    dlclose(library);
    return 0;
  }

  if (options.acknowledged_pdm >= 0) {
    std::fprintf(stderr,
                 "WARNING: proceeding with externally rerouted built-in PDM%d; "
                 "this utility did not create or verify that reroute\n",
                 options.acknowledged_pdm);
  }

  if (options.max_samples == 0) {
    constexpr uint64_t kHeadroomRate = 384000;
    options.max_samples =
        (options.duration_ms * kHeadroomRate) / 1000 + options.buffer_samples;
  }
  if (options.max_samples == 0 ||
      options.max_samples > std::numeric_limits<size_t>::max() /
                                sizeof(int32_t)) {
    std::fprintf(stderr, "invalid --max-samples\n");
    dlclose(library);
    return 2;
  }

  std::vector<int32_t> capture(static_cast<size_t>(options.max_samples));
  std::vector<int32_t> lib_buffer(
      static_cast<size_t>(options.buffer_samples));
  SpectralCallbackShim callback(&capture, lib_buffer.size());
  void* api = nullptr;
  // Camera HAL uses log level 2 for this exact API.
  int status = create(&api, &callback, 2);
  if (status != 0 || api == nullptr) {
    std::fprintf(stderr, "UsfSpectralApi::Create failed: %d, api=%p\n", status,
                 api);
    if (api != nullptr) destroy(&api);
    dlclose(library);
    return 5;
  }

  bool enabled = false;
  uint32_t sampling_id = 0;
  int result = 0;
  const bool connection_callback_seen = callback.WaitForConnection(
      std::chrono::milliseconds(options.connect_timeout_ms));
  if (!connection_callback_seen &&
      !options.allow_missing_connect_callback) {
    std::fprintf(stderr, "timed out waiting for USF ConnectCallback\n");
    result = 6;
  } else {
    if (!connection_callback_seen) {
      std::fprintf(
          stderr,
          "WARNING: USF ConnectCallback was not observed after the full "
          "timeout; explicitly attempting the normal vendor enable call\n");
    }
    void** vtable = *reinterpret_cast<void***>(api);
    if (vtable == nullptr) {
      std::fprintf(stderr, "null UsfSpectralApi vtable\n");
      result = 7;
    } else {
      // Frankel UsfSpectralApi vtable offsets: Enable +0x28, Disable +0x38,
      // SetFlickerChannel +0x98.
      const auto enable = reinterpret_cast<EnableFlickerFn>(vtable[0x28 / 8]);
      const auto disable = reinterpret_cast<DisableFlickerFn>(vtable[0x38 / 8]);
      const auto set_channel =
          reinterpret_cast<SetFlickerChannelFn>(vtable[0x98 / 8]);
      if (enable == nullptr || disable == nullptr || set_channel == nullptr) {
        std::fprintf(stderr, "missing expected UsfSpectralApi vtable slots\n");
        result = 7;
      } else {
        if (options.set_channel) {
          status = set_channel(api, options.sensor.c_str(),
                               static_cast<uint8_t>(options.channel),
                               static_cast<uint8_t>(options.fallback_channel));
          if (status != 0) {
            std::fprintf(stderr, "SetFlickerChannel failed: %d\n", status);
            result = 8;
          }
        }
        if (result == 0) {
          status = enable(api, options.sensor.c_str(), lib_buffer.data(),
                          static_cast<unsigned long>(lib_buffer.size()),
                          static_cast<uint8_t>(options.output_bits),
                          &sampling_id);
          if (status != 0) {
            std::fprintf(stderr, "EnableFlickerSensor failed: %d\n", status);
            result = 9;
          } else {
            enabled = true;
            std::fprintf(stderr,
                         "sampling id=%u sensor=%s for up to %llu ms\n",
                         sampling_id, options.sensor.c_str(),
                         static_cast<unsigned long long>(options.duration_ms));
            struct sigaction action = {};
            action.sa_handler = HandleSignal;
            sigemptyset(&action.sa_mask);
            sigaction(SIGINT, &action, nullptr);
            sigaction(SIGTERM, &action, nullptr);
            const auto deadline = std::chrono::steady_clock::now() +
                                  std::chrono::milliseconds(options.duration_ms);
            while (!g_stop_requested &&
                   std::chrono::steady_clock::now() < deadline) {
              std::this_thread::sleep_for(std::chrono::milliseconds(10));
            }
          }
        }

        if (enabled) {
          status = disable(api, sampling_id);
          if (status != 0) {
            std::fprintf(stderr, "DisableFlickerSensor failed: %d\n", status);
            if (result == 0) result = 10;
          }
          enabled = false;
          // Let an already-dispatched callback leave the shim before teardown.
          std::this_thread::sleep_for(std::chrono::milliseconds(100));
        }
      }
    }
  }

  destroy(&api);
  dlclose(library);

  const size_t sample_count = callback.committed_samples();
  std::fprintf(
      stderr,
      "callbacks=%zu samples=%zu dropped=%zu invalid_blocks=%zu "
      "reported_rate=%u last_sequence=%u stream=%llu\n",
      callback.callback_count(), sample_count, callback.dropped_samples(),
      callback.invalid_blocks(), callback.sample_rate_hz(),
      callback.last_sequence(),
      static_cast<unsigned long long>(callback.last_stream_id()));
  if (sample_count != 0 &&
      !WriteCapture(options.output, capture, sample_count) && result == 0) {
    result = 11;
  } else if (sample_count == 0 && result == 0) {
    std::fprintf(stderr, "capture completed with zero samples\n");
    result = 12;
  }
  return result;
}
