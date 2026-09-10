// SPDX-License-Identifier: Apache-2.0
/*
 * Probe Frankel's ultrasonic FE with explicit AoC prepare/start sequencing.
 */

#include <tinyalsa/asoundlib.h>

#include <sound/asound.h>
#include <sys/ioctl.h>

#include <cerrno>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <limits>
#include <string>
#include <unistd.h>
#include <vector>

namespace {

constexpr unsigned int kDefaultCard = 0;
constexpr unsigned int kDefaultDevice = 28;
constexpr unsigned int kDefaultRwEfaultRetries = 32;
constexpr unsigned int kDefaultRwEfaultSleepUs = 1000;
constexpr char kDefaultRouteControl[] = "TDM_0_RX Mixer US";

struct Options {
  unsigned int card = kDefaultCard;
  unsigned int device = kDefaultDevice;
  unsigned int rate = 192000;
  unsigned int channels = 4;
  unsigned int period_size = 512;
  unsigned int period_count = 4;
  unsigned int start_threshold = 0;
  enum pcm_format format = PCM_FORMAT_S32_LE;
  std::string format_name = "s32";
  std::string route_control = kDefaultRouteControl;
  std::string input_path;
  bool raw = false;
  bool mmap = true;
  bool unbind_for_prepare = false;
  bool rebind_after_prepare = false;
  bool start_before_write = false;
  unsigned int silence_ms = 0;
  unsigned int rw_efault_retries = kDefaultRwEfaultRetries;
  unsigned int rw_efault_sleep_us = kDefaultRwEfaultSleepUs;
  unsigned int post_write_sleep_us = 0;
};

struct Input {
  FILE* file = nullptr;
  uint64_t remaining = 0;
  bool bounded = false;
  bool silence = false;
};

struct RwTransferAccounting {
  bool enabled;
  uint64_t frame_bytes;
  uint64_t successful_ioctl_calls = 0;
  uint64_t returned_frames = 0;

  ~RwTransferAccounting() {
    if (enabled) {
      // Also report partial progress when Stream exits on an error. These
      // counts come only from valid snd_xferi.result values, never requests.
      std::printf("rw_successful_ioctl_calls=%llu rw_returned_frames=%llu "
                  "rw_returned_bytes=%llu\n",
                  static_cast<unsigned long long>(successful_ioctl_calls),
                  static_cast<unsigned long long>(returned_frames),
                  static_cast<unsigned long long>(returned_frames * frame_bytes));
      std::fflush(stdout);
    }
  }
};

[[noreturn]] void Usage(const char* program, const char* error = nullptr) {
  if (error != nullptr) {
    std::fprintf(stderr, "%s\n", error);
  }
  std::fprintf(
      stderr,
      "usage: %s [--card N] [--device N] [--rate N] [--channels N] "
      "[--format s16|s24|s24_3|s32] [--period-size N] "
      "[--period-count N] [--start-threshold FRAMES] "
      "[--route-control NAME] "
      "[--access mmap|rw] "
      "[--prepare-route bound|unbound] "
      "[--rebind-after-prepare] "
      "[--start-before-write] "
      "[--rw-efault-retries N] [--rw-efault-sleep-us N] "
      "[--post-write-sleep-us N] "
      "[--raw FILE | --silence-ms N | WAV_FILE]\n",
      program);
  std::exit(2);
}

unsigned int ParseUnsigned(const char* text, const char* name,
                           bool allow_zero = false) {
  char* end = nullptr;
  errno = 0;
  const unsigned long value = std::strtoul(text, &end, 0);
  if (errno != 0 || end == text || *end != '\0' ||
      (!allow_zero && value == 0) ||
      value > std::numeric_limits<unsigned int>::max()) {
    std::fprintf(stderr, "invalid %s: %s\n", name, text);
    std::exit(2);
  }
  return static_cast<unsigned int>(value);
}

uint16_t ReadLe16(const uint8_t* bytes) {
  return static_cast<uint16_t>(bytes[0]) |
         static_cast<uint16_t>(bytes[1] << 8);
}

uint32_t ReadLe32(const uint8_t* bytes) {
  return static_cast<uint32_t>(bytes[0]) |
         (static_cast<uint32_t>(bytes[1]) << 8) |
         (static_cast<uint32_t>(bytes[2]) << 16) |
         (static_cast<uint32_t>(bytes[3]) << 24);
}

bool ReadExact(FILE* file, void* destination, size_t size) {
  return std::fread(destination, 1, size, file) == size;
}

bool Skip(FILE* file, uint64_t size) {
  while (size != 0) {
    const long step = static_cast<long>(
        size > static_cast<uint64_t>(std::numeric_limits<long>::max())
            ? std::numeric_limits<long>::max()
            : size);
    if (std::fseek(file, step, SEEK_CUR) != 0) {
      return false;
    }
    size -= static_cast<uint64_t>(step);
  }
  return true;
}

unsigned int FormatBits(enum pcm_format format) {
  switch (format) {
    case PCM_FORMAT_S16_LE:
      return 16;
    case PCM_FORMAT_S24_3LE:
      return 24;
    case PCM_FORMAT_S24_LE:
      return 32;
    case PCM_FORMAT_S32_LE:
      return 32;
    default:
      return 0;
  }
}

bool ParseWave(Input* input, const Options& options) {
  uint8_t riff[12] = {};
  if (!ReadExact(input->file, riff, sizeof(riff)) ||
      std::memcmp(riff, "RIFF", 4) != 0 ||
      std::memcmp(riff + 8, "WAVE", 4) != 0) {
    std::fprintf(stderr, "input is not a RIFF/WAVE file\n");
    return false;
  }

  bool have_format = false;
  for (;;) {
    uint8_t chunk[8] = {};
    if (!ReadExact(input->file, chunk, sizeof(chunk))) {
      std::fprintf(stderr, "WAVE file has no usable data chunk\n");
      return false;
    }
    const uint32_t size = ReadLe32(chunk + 4);
    if (std::memcmp(chunk, "fmt ", 4) == 0) {
      uint8_t format[16] = {};
      if (size < sizeof(format) || !ReadExact(input->file, format, sizeof(format)) ||
          !Skip(input->file, static_cast<uint64_t>(size) - sizeof(format) +
                                (size & 1U))) {
        std::fprintf(stderr, "invalid WAVE fmt chunk\n");
        return false;
      }
      const unsigned int wav_format = ReadLe16(format);
      const unsigned int wav_channels = ReadLe16(format + 2);
      const unsigned int wav_rate = ReadLe32(format + 4);
      const unsigned int wav_bits = ReadLe16(format + 14);
      if (wav_format != 1 || wav_channels != options.channels ||
          wav_rate != options.rate || wav_bits != FormatBits(options.format)) {
        std::fprintf(stderr,
                     "WAVE format mismatch: pcm=%u rate=%u channels=%u bits=%u; "
                     "requested rate=%u channels=%u format=%s\n",
                     wav_format, wav_rate, wav_channels, wav_bits, options.rate,
                     options.channels, options.format_name.c_str());
        return false;
      }
      have_format = true;
      continue;
    }
    if (std::memcmp(chunk, "data", 4) == 0) {
      if (!have_format) {
        std::fprintf(stderr, "WAVE data chunk precedes fmt chunk\n");
        return false;
      }
      input->remaining = size;
      input->bounded = true;
      return true;
    }
    if (!Skip(input->file, static_cast<uint64_t>(size) + (size & 1U))) {
      std::fprintf(stderr, "cannot skip WAVE chunk\n");
      return false;
    }
  }
}

Options ParseOptions(int argc, char** argv) {
  Options options;
  for (int i = 1; i < argc; ++i) {
    const std::string argument(argv[i]);
    auto Value = [&](const char* name) -> const char* {
      if (++i >= argc) {
        Usage(argv[0], (std::string("missing value for ") + name).c_str());
      }
      return argv[i];
    };
    if (argument == "--card") {
      options.card = ParseUnsigned(Value("--card"), "card", true);
    } else if (argument == "--device") {
      options.device = ParseUnsigned(Value("--device"), "device", true);
    } else if (argument == "--rate") {
      options.rate = ParseUnsigned(Value("--rate"), "rate");
    } else if (argument == "--channels") {
      options.channels = ParseUnsigned(Value("--channels"), "channels");
    } else if (argument == "--period-size") {
      options.period_size =
          ParseUnsigned(Value("--period-size"), "period size");
    } else if (argument == "--period-count") {
      options.period_count =
          ParseUnsigned(Value("--period-count"), "period count");
    } else if (argument == "--start-threshold") {
      options.start_threshold = ParseUnsigned(
          Value("--start-threshold"), "start threshold", true);
    } else if (argument == "--route-control") {
      options.route_control = Value("--route-control");
    } else if (argument == "--format") {
      options.format_name = Value("--format");
      if (options.format_name == "s16") {
        options.format = PCM_FORMAT_S16_LE;
      } else if (options.format_name == "s24") {
        options.format = PCM_FORMAT_S24_LE;
      } else if (options.format_name == "s24_3") {
        options.format = PCM_FORMAT_S24_3LE;
      } else if (options.format_name == "s32") {
        options.format = PCM_FORMAT_S32_LE;
      } else {
        Usage(argv[0], "format must be s16, s24, s24_3, or s32");
      }
    } else if (argument == "--access") {
      const std::string access = Value("--access");
      if (access == "mmap") {
        options.mmap = true;
      } else if (access == "rw") {
        options.mmap = false;
      } else {
        Usage(argv[0], "access must be mmap or rw");
      }
    } else if (argument == "--prepare-route") {
      const std::string route_state = Value("--prepare-route");
      if (route_state == "bound") {
        options.unbind_for_prepare = false;
      } else if (route_state == "unbound") {
        options.unbind_for_prepare = true;
      } else {
        Usage(argv[0], "prepare route must be bound or unbound");
      }
    } else if (argument == "--rebind-after-prepare") {
      options.rebind_after_prepare = true;
    } else if (argument == "--start-before-write") {
      options.start_before_write = true;
    } else if (argument == "--rw-efault-retries") {
      options.rw_efault_retries = ParseUnsigned(
          Value("--rw-efault-retries"), "RW EFAULT retry count", true);
    } else if (argument == "--rw-efault-sleep-us") {
      options.rw_efault_sleep_us = ParseUnsigned(
          Value("--rw-efault-sleep-us"), "RW EFAULT retry delay");
    } else if (argument == "--post-write-sleep-us") {
      options.post_write_sleep_us = ParseUnsigned(
          Value("--post-write-sleep-us"), "post-write sleep", true);
    } else if (argument == "--raw") {
      if (!options.input_path.empty() || options.silence_ms != 0) {
        Usage(argv[0], "choose exactly one input source");
      }
      options.raw = true;
      options.input_path = Value("--raw");
    } else if (argument == "--silence-ms") {
      if (!options.input_path.empty() || options.silence_ms != 0) {
        Usage(argv[0], "choose exactly one input source");
      }
      options.silence_ms =
          ParseUnsigned(Value("--silence-ms"), "silence duration");
    } else if (!argument.empty() && argument[0] == '-') {
      Usage(argv[0], (std::string("unknown option: ") + argument).c_str());
    } else {
      if (!options.input_path.empty() || options.silence_ms != 0) {
        Usage(argv[0], "choose exactly one input source");
      }
      options.input_path = argument;
    }
  }
  if (options.input_path.empty() && options.silence_ms == 0) {
    Usage(argv[0], "missing WAV/raw input or --silence-ms");
  }
  if (options.unbind_for_prepare && options.rebind_after_prepare) {
    Usage(argv[0],
          "--rebind-after-prepare requires --prepare-route bound");
  }
  return options;
}

bool SetRoute(struct mixer_ctl* control, int value) {
  if (mixer_ctl_set_value(control, 0, value) != 0) {
    std::fprintf(stderr, "cannot set ultrasonic route to %d: %s\n", value,
                 std::strerror(errno));
    return false;
  }
  std::printf("stage route=%d\n", value);
  std::fflush(stdout);
  return true;
}

bool OpenInput(const Options& options, Input* input) {
  if (options.silence_ms != 0) {
    input->silence = true;
    input->bounded = true;
    const uint64_t bytes_per_frame =
        static_cast<uint64_t>(options.channels) * FormatBits(options.format) / 8;
    input->remaining =
        static_cast<uint64_t>(options.rate) * bytes_per_frame *
        options.silence_ms / 1000;
    return true;
  }
  input->file = std::fopen(options.input_path.c_str(), "rb");
  if (input->file == nullptr) {
    std::fprintf(stderr, "cannot open input %s: %s\n", options.input_path.c_str(),
                 std::strerror(errno));
    return false;
  }
  if (options.raw) {
    return true;
  }
  return ParseWave(input, options);
}

bool Stream(struct pcm* pcm, Input* input, const Options& options) {
  const uint64_t frame_bytes =
      static_cast<uint64_t>(options.channels) * FormatBits(options.format) / 8;
  const uint64_t chunk_bytes64 = frame_bytes * options.period_size;
  if (frame_bytes == 0 || chunk_bytes64 == 0 ||
      chunk_bytes64 > std::numeric_limits<unsigned int>::max()) {
    std::fprintf(stderr, "invalid transfer geometry\n");
    return false;
  }
  const unsigned int chunk_bytes = static_cast<unsigned int>(chunk_bytes64);
  RwTransferAccounting rw_accounting{!options.mmap, frame_bytes};
  std::vector<uint8_t> buffer(chunk_bytes, 0);
  uint64_t total = 0;
  int last_xruns = pcm_get_xruns(pcm);
  bool saw_xrun = last_xruns != 0;
  uint64_t total_efault_retries = 0;

  for (;;) {
    size_t wanted = buffer.size();
    if (input->bounded && input->remaining < wanted) {
      wanted = static_cast<size_t>(input->remaining);
    }
    if (wanted == 0) {
      break;
    }
    size_t obtained = wanted;
    if (!input->silence) {
      obtained = std::fread(buffer.data(), 1, wanted, input->file);
      if (obtained == 0) {
        if (std::ferror(input->file) != 0) {
          std::fprintf(stderr, "input read failed: %s\n", std::strerror(errno));
          return false;
        }
        break;
      }
    }
    if (input->bounded) {
      input->remaining -= obtained;
    }
    const size_t aligned = obtained - (obtained % frame_bytes);
    if (aligned == 0) {
      break;
    }
    if (aligned < buffer.size()) {
      std::memset(buffer.data() + aligned, 0, buffer.size() - aligned);
    }
    const unsigned int transfer = aligned < buffer.size()
                                      ? chunk_bytes
                                      : static_cast<unsigned int>(aligned);
    int write_result = 0;
    int write_errno = 0;
    unsigned int write_retries = 0;
    for (;;) {
      errno = 0;
      if (options.mmap) {
        write_result = pcm_mmap_write(pcm, buffer.data(), transfer);
      } else {
        // tinyalsa's pcm_write() marks its private prepared/running state false
        // after any WRITEI error. Frankel uses EFAULT as a transient
        // no-space result, so retry the owned kernel descriptor directly and
        // leave the already-started stream intact.
        struct snd_xferi transfer_request = {};
        transfer_request.result = -1;
        transfer_request.buf = buffer.data();
        transfer_request.frames = transfer / frame_bytes;
        write_result = ioctl(pcm_get_poll_fd(pcm),
                             SNDRV_PCM_IOCTL_WRITEI_FRAMES,
                             &transfer_request);
        if (write_result == 0) {
          ++rw_accounting.successful_ioctl_calls;
          const auto returned = transfer_request.result;
          const bool valid_result =
              returned >= 0 &&
              static_cast<uint64_t>(returned) <= transfer_request.frames;
          if (valid_result) {
            rw_accounting.returned_frames += static_cast<uint64_t>(returned);
          }
          if (!valid_result ||
              static_cast<uint64_t>(returned) != transfer_request.frames) {
            std::fprintf(
                stderr,
                "PCM RW incomplete transfer after %llu full-request bytes: "
                "requested_frames=%llu returned_frames=%lld ioctl_status=0 "
                "retries=%u; refusing to count or retry an untransferred tail\n",
                static_cast<unsigned long long>(total),
                static_cast<unsigned long long>(transfer_request.frames),
                static_cast<long long>(returned), write_retries);
            return false;
          }
        }
      }
      write_errno = errno;
      if (write_result == 0) {
        break;
      }
      const bool transient_rw_efault =
          !options.mmap &&
          (write_errno == EFAULT || write_result == -EFAULT);
      if (!transient_rw_efault ||
          write_retries >= options.rw_efault_retries) {
        break;
      }
      ++write_retries;
      ++total_efault_retries;
      usleep(options.rw_efault_sleep_us);
    }
    if (write_result != 0) {
      if (options.mmap) {
        std::fprintf(stderr,
                     "PCM MMAP write failed after %llu bytes (status %d): %s\n",
                     static_cast<unsigned long long>(total), write_result,
                     pcm_get_error(pcm));
      } else {
        std::fprintf(stderr,
                     "PCM RW ioctl failed after %llu bytes (status %d, "
                     "errno %d: %s, retries %u)\n",
                     static_cast<unsigned long long>(total), write_result,
                     write_errno, std::strerror(write_errno), write_retries);
      }
      return false;
    }
    if (write_retries != 0) {
      std::fprintf(stderr,
                   "PCM RW write resumed after %u EFAULT retries at %llu bytes\n",
                   write_retries, static_cast<unsigned long long>(total));
    }
    total += transfer;
    const int xruns = pcm_get_xruns(pcm);
    if (xruns != last_xruns) {
      std::fprintf(stderr,
                   "PCM xrun count changed %d -> %d after %llu bytes\n",
                   last_xruns, xruns,
                   static_cast<unsigned long long>(total));
      saw_xrun = true;
      last_xruns = xruns;
    }
    if (!input->bounded && obtained < wanted) {
      break;
    }
  }
  std::printf("rw_efault_retries=%llu\n",
              static_cast<unsigned long long>(total_efault_retries));
  std::printf("streamed=%llu bytes xruns=%d\n",
              static_cast<unsigned long long>(total), last_xruns);
  return total != 0 && !saw_xrun;
}

}  // namespace

int main(int argc, char** argv) {
  const Options options = ParseOptions(argc, argv);
  Input input;
  if (!OpenInput(options, &input)) {
    if (input.file != nullptr) {
      std::fclose(input.file);
    }
    return 1;
  }

  struct mixer* mixer = mixer_open(options.card);
  if (mixer == nullptr) {
    std::fprintf(stderr, "cannot open mixer card %u\n", options.card);
    if (input.file != nullptr) {
      std::fclose(input.file);
    }
    return 1;
  }
  struct mixer_ctl* route =
      mixer_get_ctl_by_name(mixer, options.route_control.c_str());
  if (route == nullptr || mixer_ctl_get_num_values(route) != 1) {
    std::fprintf(stderr, "missing scalar mixer control: %s\n",
                 options.route_control.c_str());
    mixer_close(mixer);
    if (input.file != nullptr) {
      std::fclose(input.file);
    }
    return 1;
  }
  if (mixer_ctl_get_value(route, 0) != 1) {
    std::fprintf(stderr, "%s must be on before PCM open\n",
                 options.route_control.c_str());
    mixer_close(mixer);
    if (input.file != nullptr) {
      std::fclose(input.file);
    }
    return 1;
  }

  struct pcm_config config = {};
  config.rate = options.rate;
  config.channels = options.channels;
  config.format = options.format;
  config.period_size = options.period_size;
  config.period_count = options.period_count;
  uint64_t automatic_start_threshold =
      static_cast<uint64_t>(options.period_size) *
      (static_cast<uint64_t>(options.period_count) - 1);
  if (options.start_threshold == 0 &&
      (automatic_start_threshold == 0 ||
       automatic_start_threshold >
           std::numeric_limits<unsigned int>::max())) {
    Usage(argv[0], "automatic start threshold is outside the valid range");
  }
  config.start_threshold =
      options.start_threshold != 0
          ? options.start_threshold
          : static_cast<unsigned int>(automatic_start_threshold);

  const unsigned int pcm_flags = PCM_OUT | (options.mmap ? PCM_MMAP : 0);
  struct pcm* pcm =
      pcm_open(options.card, options.device, pcm_flags, &config);
  if (pcm == nullptr || !pcm_is_ready(pcm)) {
    std::fprintf(stderr, "cannot HW_PARAMS PCM %u,%u: %s\n", options.card,
                 options.device, pcm_get_error(pcm));
    if (pcm != nullptr) {
      pcm_close(pcm);
    }
    mixer_close(mixer);
    if (input.file != nullptr) {
      std::fclose(input.file);
    }
    return 1;
  }
  std::printf("stage hw_params card=%u device=%u rate=%u channels=%u "
              "format=%s period_size=%u period_count=%u "
              "start_threshold=%u access=%s rw_efault_retries=%u "
              "rw_efault_sleep_us=%u post_write_sleep_us=%u\n",
              options.card, options.device, config.rate, config.channels,
              options.format_name.c_str(), config.period_size,
              config.period_count, config.start_threshold,
              options.mmap ? "mmap" : "rw", options.rw_efault_retries,
              options.rw_efault_sleep_us, options.post_write_sleep_us);
  std::fflush(stdout);

  bool route_on = true;
  bool started = false;
  int result = 1;
  if (options.unbind_for_prepare) {
    if (!SetRoute(route, 0)) {
      goto cleanup;
    }
    route_on = false;
  }
  if (pcm_prepare(pcm) != 0) {
    std::fprintf(stderr, "stage prepare failed: %s\n", pcm_get_error(pcm));
    goto cleanup;
  }
  std::printf("stage prepared-%s\n",
              options.unbind_for_prepare ? "unbound" : "bound");
  std::fflush(stdout);
  if (options.unbind_for_prepare) {
    if (!SetRoute(route, 1)) {
      goto cleanup;
    }
    route_on = true;
  }
  if (options.rebind_after_prepare) {
    if (!SetRoute(route, 0)) {
      goto cleanup;
    }
    route_on = false;
    if (!SetRoute(route, 1)) {
      goto cleanup;
    }
    route_on = true;
    std::printf("stage rebound-after-prepare\n");
    std::fflush(stdout);
  }
  if (options.start_before_write) {
    if (pcm_start(pcm) != 0) {
      std::fprintf(stderr, "stage explicit start failed: %s\n",
                   pcm_get_error(pcm));
      goto cleanup;
    }
    std::printf("stage explicitly-started-before-write\n");
    std::fflush(stdout);
  }
  started = true;
  if (!Stream(pcm, &input, options)) {
    goto cleanup;
  }
  if (options.post_write_sleep_us != 0) {
    std::printf("stage post-write-sleep-us=%u\n", options.post_write_sleep_us);
    std::fflush(stdout);
    usleep(options.post_write_sleep_us);
  }
  result = 0;

cleanup:
  if (started && pcm_stop(pcm) != 0) {
    std::fprintf(stderr, "PCM stop warning: %s\n", pcm_get_error(pcm));
    result = 1;
  }
  if (route_on && !SetRoute(route, 0)) {
    result = 1;
  }
  pcm_close(pcm);
  mixer_close(mixer);
  if (input.file != nullptr) {
    std::fclose(input.file);
  }
  return result;
}
