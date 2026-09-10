// SPDX-License-Identifier: Apache-2.0

#include <errno.h>
#include <fcntl.h>
#include <sys/stat.h>
#if defined(__ANDROID__)
#include <sys/system_properties.h>
#else
#include <cstddef>
constexpr std::size_t PROP_VALUE_MAX = 92;
extern "C" int __system_property_get(const char*, char*);
extern "C" int __system_property_set(const char*, const char*);
#endif
#include <sys/types.h>
#include <sys/wait.h>
#include <tinyalsa/asoundlib.h>
#include <unistd.h>

#include <array>
#include <cstdio>
#include <cstring>
#include <memory>
#include <string>
#include <string_view>

namespace {

constexpr char kExpectedDevice[] = "frankel";
constexpr char kExpectedVendorBuildId[] = "CP2A.260805.005";
constexpr char kReadyProperty[] = "vendor.powerphone.pdm.ready";
constexpr char kSpeakerReadyProperty[] =
    "vendor.powerphone.aoc_speaker_192k.ready";
constexpr char kBootstrapAttemptedProperty[] =
    "vendor.powerphone.bootstrap.attempted";
constexpr char kWatchdogExpiredProperty[] =
    "vendor.powerphone.bootstrap.watchdog_expired";
constexpr char kD10PatchHelper[] = "/vendor/bin/frankel_aoc_d10_patch";
constexpr char kSpeakerPatchHelper[] = "/vendor/bin/frankel_aoc_speaker_patch";
constexpr char kMixerNode[] = "/dev/snd/controlC0";
constexpr int kWaitAttempts = 600;
constexpr useconds_t kWaitIntervalUs = 100000;
// aocd publishes "running" before the OUTPUTTER timer and the complete PCM
// inventory are initialized.  Require ten continuous seconds of the complete
// card so the stock HAL's one-shot D5 probe and startup debug traffic finish
// before any factory-diag read or temporary HD Mic dispatch is attempted.
constexpr int kPrerequisiteStableAttempts = 100;
constexpr int kA32PrerequisiteStableAttempts = 3;
constexpr int kA32PrerequisiteWaitAttempts = 30;
constexpr int kWatchdogAttempts = 600;
// Real Frankel traces show that AoC's F1 aligned allocator becomes usable
// only after the complete Android audio control plane has been alive for
// roughly thirty seconds.  Keep this separate from the patcher's ten-second
// card-stability test: audioserver must remain running across both intervals
// or its stock rc action cycles the vendor audio HAL and loses the initialized
// allocator/control state.
constexpr int kAudioWarmupAttempts = 300;

constexpr std::array<const char*, 41> kCaptureRoutes{{
    "EP1 TX Mixer I2S_0_TX",
    "EP1 TX Mixer I2S_1_TX",
    "EP1 TX Mixer I2S_2_TX",
    "EP1 TX Mixer TDM_0_TX",
    "EP1 TX Mixer TDM_1_TX",
    "EP1 TX Mixer INTERNAL_MIC_TX",
    "EP1 TX Mixer ERASER_TX",
    "EP1 TX Mixer BT_TX",
    "EP1 TX Mixer USB_TX",
    "EP1 TX Mixer INCALL_TX",
    "EP2 TX Mixer I2S_0_TX",
    "EP2 TX Mixer I2S_1_TX",
    "EP2 TX Mixer I2S_2_TX",
    "EP2 TX Mixer TDM_0_TX",
    "EP2 TX Mixer TDM_1_TX",
    "EP2 TX Mixer INTERNAL_MIC_TX",
    "EP2 TX Mixer ERASER_TX",
    "EP2 TX Mixer BT_TX",
    "EP2 TX Mixer USB_TX",
    "EP2 TX Mixer INCALL_TX",
    "EP3 TX Mixer I2S_0_TX",
    "EP3 TX Mixer I2S_1_TX",
    "EP3 TX Mixer I2S_2_TX",
    "EP3 TX Mixer TDM_0_TX",
    "EP3 TX Mixer TDM_1_TX",
    "EP3 TX Mixer INTERNAL_MIC_TX",
    "EP3 TX Mixer ERASER_TX",
    "EP3 TX Mixer BT_TX",
    "EP3 TX Mixer USB_TX",
    "EP3 TX Mixer INCALL_TX",
    "EP5 TX Mixer I2S_0_TX",
    "EP5 TX Mixer I2S_1_TX",
    "EP5 TX Mixer I2S_2_TX",
    "EP5 TX Mixer TDM_0_TX",
    "EP5 TX Mixer TDM_1_TX",
    "EP5 TX Mixer INTERNAL_MIC_TX",
    "EP5 TX Mixer ERASER_TX",
    "EP5 TX Mixer BT_TX",
    "EP5 TX Mixer USB_TX",
    "EP5 TX Mixer INCALL_TX",
    "EP5 TX Mixer INTERNAL_MIC_US_TX",
}};

constexpr std::array<const char*, 4> kPowerControls{{
    "US Record Enable",
    "MIC0",
    "MIC1",
    "MIC2",
}};

constexpr std::array<const char*, 4> kQuarantinedPcms{{
    "/dev/snd/pcmC0D8c",
    "/dev/snd/pcmC0D9c",
    "/dev/snd/pcmC0D12c",
    // AoC's device-31 playback frontend replaces live PDM microphone data.
    "/dev/snd/pcmC0D31p",
}};

struct MixerCloser {
  void operator()(mixer* value) const {
    if (value != nullptr) mixer_close(value);
  }
};
using UniqueMixer = std::unique_ptr<mixer, MixerCloser>;

void Log(const char* level, const std::string& message) {
  std::fprintf(stderr, "frankel_powerphone_d10_bootstrap: %s: %s\n", level,
               message.c_str());
}

std::string Property(const char* name) {
  std::array<char, PROP_VALUE_MAX> value{};
  const int length = __system_property_get(name, value.data());
  return length > 0 ? std::string(value.data(), static_cast<size_t>(length))
                    : std::string();
}

bool SetPropertyChecked(const char* name, const char* value) {
  if (__system_property_set(name, value) != 0) {
    Log("error", std::string("cannot set property ") + name + "=" + value);
    return false;
  }
  if (Property(name) != value) {
    Log("error", std::string("property readback failed: ") + name);
    return false;
  }
  return true;
}

bool IsCharacterDevice(const char* path) {
  struct stat status{};
  return stat(path, &status) == 0 && S_ISCHR(status.st_mode);
}

bool AudioPrerequisitesReady() {
  if (!IsCharacterDevice(kMixerNode) || access(kD10PatchHelper, X_OK) != 0 ||
      access(kSpeakerPatchHelper, X_OK) != 0 ||
      Property("init.svc.vendor.audio-hal-aidl") != "running") {
    return false;
  }
  for (const char* path : kQuarantinedPcms) {
    if (!IsCharacterDevice(path)) return false;
  }
  return true;
}

bool WaitForAudioPrerequisites() {
  int stable_attempts = 0;
  for (int attempt = 0; attempt < kWaitAttempts; ++attempt) {
    if (AudioPrerequisitesReady()) {
      ++stable_attempts;
      if (stable_attempts == kPrerequisiteStableAttempts) {
        Log("info", "complete AoC card and stock HAL remained stable for "
                    "ten seconds");
        return true;
      }
    } else {
      stable_attempts = 0;
    }
    usleep(kWaitIntervalUs);
  }
  Log("error",
      std::string("audio prerequisites timed out: controlC0=") +
          (IsCharacterDevice(kMixerNode) ? "ready" : "missing") +
          ", d10_helper=" +
          (access(kD10PatchHelper, X_OK) == 0 ? "ready" : "missing") +
          ", speaker_helper=" +
          (access(kSpeakerPatchHelper, X_OK) == 0 ? "ready" : "missing") +
          ", stock_audio_hal=" + Property("init.svc.vendor.audio-hal-aidl"));
  return false;
}

bool WaitForEarlyA32Prerequisites() {
  int stable_attempts = 0;
  for (int attempt = 0; attempt < kA32PrerequisiteWaitAttempts; ++attempt) {
    // The early A32 transaction does not touch capture PCMs. In particular,
    // do not wait for late D8/D9/D12/D31 registration: the reviewed OUTPUTTER
    // timer can be destroyed before those unrelated nodes appear.
    const bool ready =
        IsCharacterDevice(kMixerNode) &&
        IsCharacterDevice("/dev/snd/pcmC0D0p") &&
        IsCharacterDevice("/dev/acd-factory_diag") &&
        IsCharacterDevice("/dev/acd-debug") &&
        access(kSpeakerPatchHelper, X_OK) == 0 &&
        Property("init.svc.vendor.audio-hal-aidl") == "running";
    if (ready) {
      ++stable_attempts;
      if (stable_attempts == kA32PrerequisiteStableAttempts) {
        Log("info", "complete AoC card and stock HAL remained stable for "
                    "300 ms before the short-lived A32 timer transaction");
        return true;
      }
    } else {
      stable_attempts = 0;
    }
    usleep(kWaitIntervalUs);
  }
  Log("error", "early A32 prerequisites did not stabilize within 3 seconds");
  return false;
}

mixer_ctl* RequireControl(mixer* card, const char* name, unsigned int count) {
  mixer_ctl* control = mixer_get_ctl_by_name(card, name);
  if (control == nullptr) {
    Log("error", std::string("missing mixer control: ") + name);
    return nullptr;
  }
  if (mixer_ctl_get_num_values(control) != count) {
    Log("error", std::string("unexpected mixer width: ") + name);
    return nullptr;
  }
  return control;
}

bool SetInteger(mixer* card, const char* name, int wanted) {
  mixer_ctl* control = RequireControl(card, name, 1);
  if (control == nullptr || mixer_ctl_set_value(control, 0, wanted) != 0 ||
      mixer_ctl_get_value(control, 0) != wanted) {
    Log("error", std::string("cannot set/read mixer control ") + name + "=" +
                     std::to_string(wanted));
    return false;
  }
  return true;
}

bool SetEnum(mixer* card, const char* name, const char* wanted) {
  mixer_ctl* control = RequireControl(card, name, 1);
  if (control == nullptr ||
      mixer_ctl_set_enum_by_string(control, wanted) != 0) {
    Log("error", std::string("cannot set mixer enum ") + name + "=" + wanted);
    return false;
  }
  const int index = mixer_ctl_get_value(control, 0);
  const char* actual =
      index < 0 ? nullptr : mixer_ctl_get_enum_string(control, index);
  if (actual == nullptr || std::string_view(actual) != wanted) {
    Log("error", std::string("mixer enum readback failed: ") + name);
    return false;
  }
  return true;
}

bool SetCaptureList(mixer* card, int logical_mic) {
  if (logical_mic < 0 || logical_mic > 2) {
    Log("error", "logical microphone must be 0, 1, or 2");
    return false;
  }
  mixer_ctl* control = RequireControl(card, "BUILDIN MIC ID CAPTURE LIST", 4);
  if (control == nullptr) return false;
  const std::array<int, 4> wanted{{logical_mic, -1, -1, -1}};
  // Program each index explicitly so boot certification does not depend on
  // the userspace/kernel representation of INTEGER arrays. Clear the unused
  // selectors first so no transient state can power more than the reviewed
  // logical microphone.
  constexpr std::array<unsigned int, 4> order{{1, 2, 3, 0}};
  for (const unsigned int index : order) {
    if (mixer_ctl_set_value(control, index, wanted[index]) != 0) {
      Log("error", "cannot set BUILDIN MIC ID CAPTURE LIST index " +
                       std::to_string(index));
      return false;
    }
  }
  for (unsigned int index = 0; index < wanted.size(); ++index) {
    if (mixer_ctl_get_value(control, index) != wanted[index]) {
      Log("error", "BUILDIN MIC ID CAPTURE LIST readback failed at index " +
                       std::to_string(index));
      return false;
    }
  }
  if (mixer_ctl_get_num_values(control) != wanted.size()) {
    Log("error", "cannot establish bootstrap capture list for logical mic " +
                     std::to_string(logical_mic));
    return false;
  }
  return true;
}

bool PrimePatchedCaptureLists() {
  UniqueMixer card(mixer_open(0));
  if (!card) {
    Log("error", "cannot reopen mixer card 0 to prime patched PDM lanes");
    return false;
  }
  // BUILDIN MIC ID CAPTURE LIST materializes the selected logical microphone's
  // PdmV3 configuration immediately.  The D10 code profile must therefore be
  // resident before each logical ID is selected.  Keep a non-empty single-mic
  // list throughout (PdmV3 rejects an empty mask), force a real value change
  // for every command, and leave the certified boot default at logical mic 0.
  for (const int logical_mic : {1, 2, 0}) {
    if (!SetCaptureList(card.get(), logical_mic)) return false;
  }
  Log("info",
      "primed logical microphones 0/1/2 under the patched PdmV3 profile");
  return true;
}

bool EstablishStrictMixerState() {
  UniqueMixer card(mixer_open(0));
  if (!card) {
    Log("error", "cannot open mixer card 0");
    return false;
  }
  for (const char* control : kCaptureRoutes) {
    if (!SetInteger(card.get(), control, 0)) return false;
  }
  for (const char* control : kPowerControls) {
    if (!SetInteger(card.get(), control, 0)) return false;
  }
  return SetEnum(card.get(), "BUILTIN MIC Process Mode", "Raw") &&
         SetEnum(card.get(), "Audio Capture Mic Source", "Builtin_MIC") &&
         SetInteger(card.get(), "Mic Spatial Module Enable", 0) &&
         SetInteger(card.get(), "MIC DC Blocker", 0) &&
         SetInteger(card.get(), "MIC Record Soft Gain (dB)", 0) &&
         SetInteger(card.get(), "HD Mic gain (cB)", 0) &&
         SetEnum(card.get(), "INTERNAL_MIC_TX Sample Rate", "SR_192K") &&
         SetEnum(card.get(), "INTERNAL_MIC_TX Format", "S16_LE") &&
         SetEnum(card.get(), "INTERNAL_MIC_TX Chan", "One") &&
         SetCaptureList(card.get(), 0);
}

bool RunPatchHelper(const char* helper, const char* action,
                    bool skip_zero_validation = false) {
  if (skip_zero_validation &&
      (std::strcmp(helper, kSpeakerPatchHelper) != 0 ||
       std::strcmp(action, "apply") != 0)) {
    Log("error", "zero-validation bypass is restricted to speaker apply");
    return false;
  }
  const pid_t child = fork();
  if (child < 0) {
    Log("error", std::string("fork patch helper: ") + std::strerror(errno));
    return false;
  }
  if (child == 0) {
    if (skip_zero_validation) {
      execl(helper, helper, action, "--allow-incomplete-boot",
            "--skip-zero-validation", nullptr);
    } else if (std::strcmp(action, "apply") == 0 ||
               std::strcmp(action, "prepare-a32") == 0) {
      execl(helper, helper, action, "--allow-incomplete-boot", nullptr);
    } else {
      execl(helper, helper, action, nullptr);
    }
    std::fprintf(stderr, "exec %s: %s\n", helper, std::strerror(errno));
    _exit(127);
  }
  int status = 0;
  while (waitpid(child, &status, 0) < 0) {
    if (errno == EINTR) continue;
    Log("error", std::string("waitpid patch helper: ") + std::strerror(errno));
    return false;
  }
  if (!WIFEXITED(status) || WEXITSTATUS(status) != 0) {
    const std::string outcome =
        WIFEXITED(status) ? "exit=" + std::to_string(WEXITSTATUS(status))
                          : "terminated by signal";
    Log("error", std::string(helper) + " " + action + " failed: " + outcome);
    return false;
  }
  return true;
}

bool QuarantineUnadvertisedPcms() {
  for (const char* path : kQuarantinedPcms) {
    if (!IsCharacterDevice(path)) {
      Log("error", std::string("missing capture PCM: ") + path);
      return false;
    }
    if (chmod(path, 0000) != 0) {
      Log("error", std::string("chmod ") + path + ": " + std::strerror(errno));
      return false;
    }
    struct stat status{};
    if (stat(path, &status) != 0 || (status.st_mode & 0777) != 0) {
      Log("error", std::string("quarantine readback failed: ") + path);
      return false;
    }
  }
  return true;
}

bool RestoreQuarantinedPcms() {
  bool restored = true;
  for (const char* path : kQuarantinedPcms) {
    struct stat status{};
    if (stat(path, &status) != 0) {
      if (errno == ENOENT) {
        // A failed early-boot attempt may finish before AoC has registered
        // card 0. There is no quarantined inode to restore in that case, and
        // ueventd will assign the stock mode when the PCM is later created.
        Log("info", std::string("PCM absent; no mode to restore: ") + path);
        continue;
      }
      Log("error", std::string("stat ") + path + ": " + std::strerror(errno));
      restored = false;
      continue;
    }
    if (!S_ISCHR(status.st_mode)) {
      Log("error",
          std::string("refusing to restore non-character PCM path: ") + path);
      restored = false;
      continue;
    }
    if (chmod(path, 0660) != 0) {
      Log("error", std::string("chmod ") + path + ": " + std::strerror(errno));
      restored = false;
      continue;
    }
    if (stat(path, &status) != 0 || (status.st_mode & 0777) != 0660) {
      Log("error", std::string("fail-open mode readback failed: ") + path);
      restored = false;
    }
  }
  return restored;
}

int RunFailOpenWatchdog() {
  if (getuid() != 0 || geteuid() != 0) {
    Log("error", "watchdog real and effective uid must both be root");
    return 2;
  }
  // Bound the interval before the compound prerequisite trigger fires. Without
  // this asynchronous service, an aocd/HAL startup failure could leave the
  // early-init audioserver stop in force indefinitely. The main gate claims
  // the attempted latch and stops this service before launching asynchronous
  // attempt one; polling the latch also makes an already-claimed run inert if
  // stop delivery is delayed.
  for (int attempt = 0; attempt < kWatchdogAttempts; ++attempt) {
    // Only the exact, typed claimed value is inert. A missing/denied/malformed
    // read must not be mistaken for success and strand audioserver stopped.
    if (Property(kBootstrapAttemptedProperty) == "1") {
      Log("info", "bootstrap latch claimed; watchdog is no longer needed");
      return 0;
    }
    usleep(kWaitIntervalUs);
  }
  if (Property(kBootstrapAttemptedProperty) == "1") {
    Log("info", "bootstrap latch claimed at watchdog deadline");
    return 0;
  }
  if (!SetPropertyChecked(kWatchdogExpiredProperty, "1")) {
    return 2;
  }
  Log("error",
      "boot prerequisites did not converge within 60 seconds; requested "
      "fail-open");
  return 0;
}

int RunAudioWarmup() {
  if (getuid() != 0 || geteuid() != 0) {
    Log("error", "audio warm-up real and effective uid must both be root");
    return 2;
  }
  for (int attempt = 0; attempt < kAudioWarmupAttempts; ++attempt) {
    usleep(kWaitIntervalUs);
  }
  Log("info", "completed the bounded 30-second Android audio warm-up");
  return 0;
}

int RunA32Preparation() {
  if (getuid() != 0 || geteuid() != 0) {
    Log("error", "A32 preparation real and effective uid must both be root");
    return 2;
  }
  if (Property("ro.product.device") != kExpectedDevice ||
      Property("ro.vendor.build.id") != kExpectedVendorBuildId) {
    Log("error", "refusing A32 preparation on an unreviewed target");
    return 2;
  }
  if (!WaitForEarlyA32Prerequisites() ||
      !RunPatchHelper(kSpeakerPatchHelper, "prepare-a32")) {
    Log("error", "early-boot A32 allocator preparation failed");
    return 2;
  }
  Log("info", "early A32 allocation path is prepared; the late warmed "
              "transaction may retain the exact stock allocator");
  return 0;
}

int Main(bool finalize_fail_open) {
  if (getuid() != 0 || geteuid() != 0) {
    Log("error", "real and effective uid must both be root");
    return 2;
  }
  if (Property("ro.product.device") != kExpectedDevice ||
      Property("ro.vendor.build.id") != kExpectedVendorBuildId) {
    Log("error", "refusing an unreviewed device or vendor build");
    return 2;
  }
  // This mode runs after all three bounded certification services stop. It
  // must be a separate native finalizer rather than unconditional init chmods:
  // init also observes the retry services stop after a successful earlier
  // attempt, and restoring modes in that case would silently undo quarantine.
  if (finalize_fail_open) {
    if (Property(kReadyProperty) == "1" &&
        Property(kSpeakerReadyProperty) == "1") {
      Log("info", "certification succeeded; preserving PCM quarantine");
      return 0;
    }
    // A speaker attempt may have completed before D10 failed. Revoke both
    // composite certificates before restoring stock PCM access and releasing
    // audioserver; fail-open must never leave a partially certified sidecar
    // route visible.
    bool cleared = true;
    if (!SetPropertyChecked(kReadyProperty, "0")) cleared = false;
    if (!SetPropertyChecked(kSpeakerReadyProperty, "0")) cleared = false;
    const bool restored = RestoreQuarantinedPcms();
    Log(restored && cleared ? "info" : "error",
        restored && cleared ? "certification failed; revoked readiness and "
                              "restored stock PCM modes"
                            : "certification failed; readiness revocation or "
                              "stock PCM mode restoration was incomplete");
    return restored && cleared ? 0 : 2;
  }
  // The system-ext gate invokes up to three separately named oneshot services
  // because init has no bounded-restart primitive.  Once an earlier attempt
  // has certified both profiles, later invocations must be inert: clearing a
  // valid certificate merely to prove an idempotent patch again would create
  // a needless new boot failure window.
  if (Property(kReadyProperty) == "1" &&
      Property(kSpeakerReadyProperty) == "1") {
    Log("info", "both profiles were already certified by an earlier attempt");
    return 0;
  }
  // Vendor init is not a property writer for these typed, vendor-internal
  // certificates.  Clear both in this confined domain before touching mixer
  // or AoC state; only a fully verified helper may later raise its own flag.
  if (!SetPropertyChecked(kReadyProperty, "0") ||
      !SetPropertyChecked(kSpeakerReadyProperty, "0")) {
    Log("error", "cannot establish fail-closed readiness state");
    return 2;
  }
  // Certify the speaker profile before D10. Both helpers use the factory AoC
  // mailbox, and real Frankel boots show that the speaker transaction cannot
  // complete after D10 has installed its resident diagnostic profile. D10's
  // final cache synchronization covers the already-installed speaker edits.
  if (!WaitForAudioPrerequisites() || !EstablishStrictMixerState() ||
      !QuarantineUnadvertisedPcms() ||
      !RunPatchHelper(kSpeakerPatchHelper, "apply", true) ||
      Property(kSpeakerReadyProperty) != "1" ||
      // The stock AoC HAL can republish its multi-microphone defaults while
      // the comparatively long speaker mailbox transaction is running.  D10
      // deliberately validates the live mixer immediately before modifying
      // firmware, so restore the certified single-microphone RAW state at the
      // transaction boundary instead of treating that asynchronous default as
      // a firmware-patch failure.
      !EstablishStrictMixerState() ||
      !RunPatchHelper(kD10PatchHelper, "apply") ||
      Property(kReadyProperty) != "1") {
    Log("error",
        "PowerPhone bootstrap attempt failed; init will retry or "
        "release stock audio");
    return 2;
  }
  // The strict mixer geometry and logical-mic selection were initially sent
  // while the AoC still contained stock PdmV3 code.  Reissue all three logical
  // selections only after the helper has installed and synchronized the D10
  // profile.  If this post-activation certification fails, revoke readiness so
  // the next bounded bootstrap invocation cannot mistake the partial attempt
  // for a completed one; the helper accepts an already-uniform patched image.
  if (!PrimePatchedCaptureLists()) {
    if (!SetPropertyChecked(kReadyProperty, "0")) {
      Log("error", "could not revoke D10 readiness after PDM priming failure");
    }
    Log("error",
        "PowerPhone patched-PDM priming failed; init will retry or release "
        "stock audio");
    return 2;
  }
  if (Property(kReadyProperty) != "1" ||
      Property(kSpeakerReadyProperty) != "1") {
    Log("error",
        "patch helper exited successfully without both readiness readbacks");
    return 2;
  }
  Log("info",
      "qualified A32 allocation path/F1 speaker and D10 profiles ready; "
      "audioserver may start");
  return 0;
}

}  // namespace

int main(int argc, char** argv) {
  if (argc == 1) return Main(false);
  if (argc == 2 && std::string_view(argv[1]) == "--finalize-fail-open") {
    return Main(true);
  }
  if (argc == 2 && std::string_view(argv[1]) == "--watchdog-fail-open") {
    return RunFailOpenWatchdog();
  }
  if (argc == 2 && std::string_view(argv[1]) == "--audio-warmup") {
    return RunAudioWarmup();
  }
  if (argc == 2 && std::string_view(argv[1]) == "--prepare-a32") {
    return RunA32Preparation();
  }
  Log("error",
      "usage: frankel_powerphone_d10_bootstrap "
      "[--finalize-fail-open|--watchdog-fail-open|--audio-warmup|"
      "--prepare-a32]");
  return 2;
}
