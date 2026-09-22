/*
 * Copyright (C) 2026 The Android Open Source Project
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <sound/asound.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/system_properties.h>
#include <sys/utsname.h>
#include <unistd.h>

#include <array>
#include <cctype>
#include <cstdarg>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <optional>
#include <string>
#include <string_view>
#include <vector>

#include <tinyalsa/asoundlib.h>

namespace {

constexpr char kTopologyReadyProperty[] =
        "vendor.powerphone.pdm.topology_ready";
constexpr char kModuleName[] = "frankel_pdm_alsa";
constexpr char kModulePath[] =
        "/vendor_dlkm/lib/modules/frankel_pdm_alsa.ko";
constexpr char kModuleDirectory[] = "/sys/module/frankel_pdm_alsa";
constexpr char kParameterDirectory[] =
        "/sys/module/frankel_pdm_alsa/parameters";
constexpr char kExpectedKernelRelease[] =
        "6.6.118-android15-8-g1831c2a45d9b-ab15739706-4k";
constexpr char kExpectedAocCardId[] = "googleaocsndcar";
constexpr char kExpectedRawCardId[] = "FrankelPDM";
constexpr unsigned int kCard = 1;
constexpr unsigned int kRate = 192000;
constexpr unsigned int kChannels = 1;
constexpr unsigned int kSampleBits = 32;
constexpr unsigned long kProjectionAck = 0x0ac0a000UL;
constexpr unsigned int kControllerMask = 0x0dU;
constexpr std::array<unsigned int, 3> kDevices = {0, 2, 3};
constexpr std::array<unsigned int, 3> kPdmIds = {0, 2, 3};
constexpr int kWaitAttempts = 300;
constexpr useconds_t kWaitIntervalUs = 100000;

bool gLoadedModule = false;

bool ValidateZeroStats();

void Log(const char* level, const char* format, ...) {
    std::fprintf(stderr, "powerphone_pdm_loader: %s: ", level);
    va_list args;
    va_start(args, format);
    std::vfprintf(stderr, format, args);
    va_end(args);
    std::fputc('\n', stderr);
}

bool Exists(const char* path) {
    struct stat status {};
    return lstat(path, &status) == 0;
}

std::optional<std::string> ReadFile(const std::string& path) {
    int fd;
    do {
        fd = open(path.c_str(), O_RDONLY | O_CLOEXEC);
    } while (fd < 0 && errno == EINTR);
    if (fd < 0) return std::nullopt;

    std::string result;
    std::array<char, 4096> buffer {};
    for (;;) {
        ssize_t count;
        do {
            count = read(fd, buffer.data(), buffer.size());
        } while (count < 0 && errno == EINTR);
        if (count < 0) {
            close(fd);
            return std::nullopt;
        }
        if (count == 0) break;
        if (result.size() + static_cast<size_t>(count) > 65536U) {
            close(fd);
            errno = EFBIG;
            return std::nullopt;
        }
        result.append(buffer.data(), static_cast<size_t>(count));
    }
    close(fd);
    return result;
}

std::string TrimValue(std::string value) {
    while (!value.empty()) {
        const unsigned char last = static_cast<unsigned char>(value.back());
        if (last != '\0' && !std::isspace(last)) break;
        value.pop_back();
    }
    return value;
}

bool ReadExact(const std::string& path, std::string_view expected) {
    const auto value = ReadFile(path);
    if (!value.has_value()) {
        Log("error", "cannot read %s: %s", path.c_str(), std::strerror(errno));
        return false;
    }
    const std::string normalized = TrimValue(*value);
    if (normalized != expected) {
        Log("error", "%s: expected '%.*s', got '%s'", path.c_str(),
            static_cast<int>(expected.size()), expected.data(), normalized.c_str());
        return false;
    }
    return true;
}

bool ReadContains(const std::string& path, std::string_view expected) {
    const auto value = ReadFile(path);
    if (!value.has_value()) {
        Log("error", "cannot read %s: %s", path.c_str(), std::strerror(errno));
        return false;
    }
    if (value->find(expected) == std::string::npos) {
        Log("error", "%s does not contain expected PCM identity '%.*s'",
            path.c_str(), static_cast<int>(expected.size()), expected.data());
        return false;
    }
    return true;
}

std::optional<unsigned long long> ParseUnsigned(const std::string& path) {
    const auto text = ReadFile(path);
    if (!text.has_value()) {
        Log("error", "cannot read %s: %s", path.c_str(), std::strerror(errno));
        return std::nullopt;
    }
    const std::string normalized = TrimValue(*text);
    if (normalized.empty() || normalized.front() == '-') {
        Log("error", "%s is not an unsigned integer: '%s'", path.c_str(),
            normalized.c_str());
        return std::nullopt;
    }
    errno = 0;
    char* end = nullptr;
    const unsigned long long value = std::strtoull(normalized.c_str(), &end, 0);
    if (errno != 0 || end == normalized.c_str() || *end != '\0') {
        Log("error", "%s is not an unsigned integer: '%s'", path.c_str(),
            normalized.c_str());
        return std::nullopt;
    }
    return value;
}

bool RequireUnsignedParameter(std::string_view name,
                              unsigned long long expected) {
    const std::string path = std::string(kParameterDirectory) + "/" +
            std::string(name);
    const auto value = ParseUnsigned(path);
    if (!value.has_value()) return false;
    if (*value != expected) {
        Log("error", "%s: expected %llu, got %llu", path.c_str(), expected,
            *value);
        return false;
    }
    return true;
}

bool RequireBooleanParameter(std::string_view name, bool expected) {
    const std::string path = std::string(kParameterDirectory) + "/" +
            std::string(name);
    const auto text = ReadFile(path);
    if (!text.has_value()) {
        Log("error", "cannot read %s: %s", path.c_str(), std::strerror(errno));
        return false;
    }
    const std::string value = TrimValue(*text);
    bool parsed;
    if (value == "1" || value == "Y" || value == "y" || value == "true") {
        parsed = true;
    } else if (value == "0" || value == "N" || value == "n" ||
               value == "false") {
        parsed = false;
    } else {
        Log("error", "%s is not Boolean: '%s'", path.c_str(), value.c_str());
        return false;
    }
    if (parsed != expected) {
        Log("error", "%s: expected %d, got '%s'", path.c_str(), expected ? 1 : 0,
            value.c_str());
        return false;
    }
    return true;
}

bool SetTopologyReady(bool ready) {
    const char* value = ready ? "1" : "0";
    if (__system_property_set(kTopologyReadyProperty, value) != 0) {
        Log("error", "cannot set %s=%s: %s", kTopologyReadyProperty, value,
            std::strerror(errno));
        return false;
    }
    return true;
}

bool WaitForAocCard0() {
    const std::string cardId = "/proc/asound/card0/id";
    for (int attempt = 0; attempt < kWaitAttempts; ++attempt) {
        const auto idValue = ReadFile(cardId);
        if (idValue.has_value() && TrimValue(*idValue) == kExpectedAocCardId) {
            return true;
        }
        usleep(kWaitIntervalUs);
    }
    Log("error", "card0 did not become the exact Frankel AoC card within 30 seconds");
    return false;
}

bool CheckKernelRelease() {
    struct utsname info {};
    if (uname(&info) != 0) {
        Log("error", "uname failed: %s", std::strerror(errno));
        return false;
    }
    if (std::string_view(info.release) != kExpectedKernelRelease) {
        Log("error", "expected kernel %s, got %s", kExpectedKernelRelease,
            info.release);
        return false;
    }
    return true;
}

bool LoadModule() {
    int fd;
    do {
        fd = open(kModulePath, O_RDONLY | O_CLOEXEC);
    } while (fd < 0 && errno == EINTR);
    if (fd < 0) {
        Log("error", "cannot open %s: %s", kModulePath, std::strerror(errno));
        return false;
    }
    constexpr char parameters[] =
            "map_controllers=1 projection_ack=0x0ac0a000 "
            "controller_mask=0x0d decimator_order=3 "
            "pdm_msb_first=0 pdm_reverse_bytes=0 pdm_invert=0 "
            "status_probe=0 polling_enabled=0";
    long result;
    do {
        result = syscall(SYS_finit_module, fd, parameters, 0);
    } while (result < 0 && errno == EINTR);
    const int savedErrno = errno;
    close(fd);
    if (result != 0) {
        Log("error", "finit_module(%s) failed: %s", kModuleName,
            std::strerror(savedErrno));
        return false;
    }
    gLoadedModule = true;
    return true;
}

void UnloadModuleAfterFailure() {
    if (!gLoadedModule) return;
    if (!RequireBooleanParameter("polling_enabled", false)) {
        Log("error",
            "cannot prove polling=0; refusing an unsafe module unload (system suspend remains blocked)");
        return;
    }
    long result;
    do {
        result = syscall(SYS_delete_module, kModuleName, O_NONBLOCK);
    } while (result < 0 && errno == EINTR);
    if (result != 0) {
        Log("error", "failure cleanup could not unload %s: %s", kModuleName,
            std::strerror(errno));
    } else {
        for (int attempt = 0; attempt < 50; ++attempt) {
            if (!Exists(kModuleDirectory) && !Exists("/proc/asound/card1")) {
                Log("info", "unloaded %s after validation failure", kModuleName);
                gLoadedModule = false;
                return;
            }
            usleep(kWaitIntervalUs);
        }
        Log("error",
            "%s unload returned success but module/card1 remained for five seconds",
            kModuleName);
    }
}

bool WaitForRawCard() {
    for (int attempt = 0; attempt < kWaitAttempts; ++attempt) {
        if (Exists("/sys/class/sound/card1") &&
            Exists("/dev/snd/controlC1") &&
            Exists("/dev/snd/pcmC1D0c") &&
            Exists("/dev/snd/pcmC1D2c") &&
            Exists("/dev/snd/pcmC1D3c")) {
            return true;
        }
        usleep(kWaitIntervalUs);
    }
    Log("error", "FrankelPDM card1 nodes did not appear within 30 seconds");
    return false;
}

bool ValidatePcmNodeSet() {
    DIR* directory = opendir("/dev/snd");
    if (directory == nullptr) {
        Log("error", "cannot open /dev/snd: %s", std::strerror(errno));
        return false;
    }
    std::vector<std::string> actual;
    errno = 0;
    while (dirent* entry = readdir(directory)) {
        const std::string_view name(entry->d_name);
        if (name.starts_with("pcmC1")) actual.emplace_back(name);
    }
    const int savedErrno = errno;
    closedir(directory);
    if (savedErrno != 0) {
        Log("error", "cannot enumerate /dev/snd: %s", std::strerror(savedErrno));
        return false;
    }
    constexpr std::array<std::string_view, 3> expected = {
            "pcmC1D0c", "pcmC1D2c", "pcmC1D3c"};
    if (actual.size() != expected.size()) {
        Log("error", "expected exactly three card1 PCM nodes, found %zu",
            actual.size());
        return false;
    }
    for (const auto name : expected) {
        bool found = false;
        for (const auto& candidate : actual) {
            if (candidate == name) found = true;
        }
        if (!found) {
            Log("error", "missing /dev/snd/%.*s", static_cast<int>(name.size()),
                name.data());
            return false;
        }
    }
    return true;
}

bool ValidatePcmParameters(unsigned int device) {
    pcm_params* parameters = pcm_params_get(kCard, device, PCM_IN);
    if (parameters == nullptr) {
        Log("error", "cannot query card %u device %u capture constraints", kCard,
            device);
        return false;
    }
    const unsigned int rateMin = pcm_params_get_min(parameters, PCM_PARAM_RATE);
    const unsigned int rateMax = pcm_params_get_max(parameters, PCM_PARAM_RATE);
    const unsigned int channelsMin =
            pcm_params_get_min(parameters, PCM_PARAM_CHANNELS);
    const unsigned int channelsMax =
            pcm_params_get_max(parameters, PCM_PARAM_CHANNELS);
    const unsigned int bitsMin =
            pcm_params_get_min(parameters, PCM_PARAM_SAMPLE_BITS);
    const unsigned int bitsMax =
            pcm_params_get_max(parameters, PCM_PARAM_SAMPLE_BITS);
    const pcm_mask* formatMask =
            pcm_params_get_mask(parameters, PCM_PARAM_FORMAT);
    unsigned int formatCount = 0;
    bool onlyS32 = formatMask != nullptr;
    if (formatMask != nullptr) {
        for (unsigned int bit = 0; bit < 256; ++bit) {
            const bool present =
                    (formatMask->bits[bit / 32] & (1U << (bit % 32))) != 0;
            if (!present) continue;
            ++formatCount;
            if (bit != static_cast<unsigned int>(SNDRV_PCM_FORMAT_S32_LE)) {
                onlyS32 = false;
            }
        }
    }
    onlyS32 = onlyS32 && formatCount == 1 &&
            pcm_params_format_test(parameters, PCM_FORMAT_S32_LE) == 1;
    pcm_params_free(parameters);

    if (rateMin != kRate || rateMax != kRate || channelsMin != kChannels ||
        channelsMax != kChannels || bitsMin != kSampleBits ||
        bitsMax != kSampleBits || !onlyS32) {
        Log("error",
            "card %u device %u is not exact mono S32_LE/192000 "
            "(rate=%u..%u channels=%u..%u bits=%u..%u s32=%d)",
            kCard, device, rateMin, rateMax, channelsMin, channelsMax, bitsMin,
            bitsMax, onlyS32 ? 1 : 0);
        return false;
    }
    return true;
}

bool ValidateZeroStats() {
    const std::string path = std::string(kParameterDirectory) + "/stats";
    const auto text = ReadFile(path);
    if (!text.has_value()) {
        Log("error", "cannot read %s: %s", path.c_str(), std::strerror(errno));
        return false;
    }
    const char* cursor = text->c_str();
    for (const unsigned int expectedPdm : kPdmIds) {
        unsigned int pdm = 0;
        long long status = -1;
        long long probeReads = -1;
        long long empty = -1;
        long long words = -1;
        long long bits = -1;
        long long frames = -1;
        long long delivered = -1;
        long long discarded = -1;
        long long periods = -1;
        long long overruns = -1;
        long long clips = -1;
        unsigned int lastStatus = 1;
        int consumed = 0;
        const int fields = std::sscanf(
                cursor,
                "pdm%u status=%lld probe_reads=%lld empty=%lld words=%lld bits=%lld "
                "frames=%lld delivered=%lld discarded=%lld periods=%lld "
                "overruns=%lld clips=%lld last_status=0x%x%n",
                &pdm, &status, &probeReads, &empty, &words, &bits, &frames, &delivered,
                &discarded, &periods, &overruns, &clips, &lastStatus, &consumed);
        if (fields != 13 || consumed <= 0 || pdm != expectedPdm || status != 0 ||
            probeReads != 0 || empty != 0 || words != 0 || bits != 0 || frames != 0 ||
            delivered != 0 || discarded != 0 || periods != 0 || overruns != 0 ||
            clips != 0 || lastStatus != 0) {
            Log("error", "nonzero or malformed pre-read stats for expected PDM%u",
                expectedPdm);
            return false;
        }
        cursor += consumed;
        while (*cursor == '\n' || *cursor == '\r') ++cursor;
    }
    while (*cursor != '\0' && std::isspace(static_cast<unsigned char>(*cursor))) {
        ++cursor;
    }
    if (*cursor != '\0') {
        Log("error", "unexpected trailing raw-PDM statistics");
        return false;
    }
    return true;
}

bool ValidateResidentState() {
    if (!Exists(kModuleDirectory) || !Exists("/proc/asound/card1")) {
        Log("error", "raw-PDM module or card1 disappeared");
        return false;
    }
    if (!ReadExact("/proc/asound/card1/id", kExpectedRawCardId)) return false;
    if (!RequireBooleanParameter("map_controllers", true) ||
        !RequireUnsignedParameter("projection_ack", kProjectionAck) ||
        !RequireUnsignedParameter("controller_mask", kControllerMask) ||
        !RequireUnsignedParameter("decimator_order", 3) ||
        !RequireBooleanParameter("pdm_msb_first", false) ||
        !RequireBooleanParameter("pdm_reverse_bytes", false) ||
        !RequireBooleanParameter("pdm_invert", false)) {
        return false;
    }
    return ValidatePcmNodeSet();
}

bool ValidateModuleAndCard() {
    if (!WaitForRawCard() || !ValidateResidentState() ||
        !RequireBooleanParameter("status_probe", false) ||
        !RequireBooleanParameter("polling_enabled", false) ||
        !ValidateZeroStats()) {
        return false;
    }
    constexpr std::array<std::string_view, 3> pcmNames = {
            "Frankel raw PDM0", "Frankel raw PDM2", "Frankel raw PDM3"};
    for (size_t index = 0; index < kDevices.size(); ++index) {
        const std::string infoPath = "/proc/asound/card1/pcm" +
                std::to_string(kDevices[index]) + "c/info";
        if (!ReadContains(infoPath, pcmNames[index])) return false;
    }
    for (const unsigned int device : kDevices) {
        if (!ValidatePcmParameters(device)) return false;
    }
    // Querying HW_REFINE must not have activated the polling worker or touched
    // a FIFO. Re-read both gates after all ALSA probes.
    return RequireBooleanParameter("polling_enabled", false) &&
            ValidateZeroStats();
}

bool TopologyReadyPropertyIsOne() {
    std::array<char, PROP_VALUE_MAX> value {};
    const int length =
            __system_property_get(kTopologyReadyProperty, value.data());
    return length == 1 && value[0] == '1';
}

int MonitorResidentState() {
    for (;;) {
        sleep(2);
        if (!ValidateResidentState()) {
            SetTopologyReady(false);
            Log("error",
                "resident-state monitor failed; topology readiness cleared");
            return EXIT_FAILURE;
        }
        if (!TopologyReadyPropertyIsOne() && !SetTopologyReady(true)) {
            Log("error",
                "could not maintain the loader-owned topology property");
            return EXIT_FAILURE;
        }
    }
}

int Run() {
    // A retry never inherits a stale topology claim. This loader deliberately
    // cannot set the separate data-ready gate consumed by the audio HAL.
    if (!SetTopologyReady(false)) return EXIT_FAILURE;
    if (!CheckKernelRelease() || !WaitForAocCard0()) return EXIT_FAILURE;

    if (Exists(kModuleDirectory)) {
        Log("error", "%s was already loaded; refusing unknown provenance",
            kModuleName);
        return EXIT_FAILURE;
    }
    if (Exists("/proc/asound/card1")) {
        Log("error", "card1 is already occupied before loading %s", kModuleName);
        return EXIT_FAILURE;
    }
    if (!LoadModule()) return EXIT_FAILURE;
    if (!ValidateModuleAndCard()) {
        UnloadModuleAfterFailure();
        return EXIT_FAILURE;
    }
    if (!SetTopologyReady(true)) {
        UnloadModuleAfterFailure();
        return EXIT_FAILURE;
    }
    Log("info",
        "validated card0 AoC plus card1 PDM0/PDM2/PDM3; polling=0, stats=0, topology_ready=1; data_ready remains broker-owned; suspend veto active");
    return MonitorResidentState();
}

}  // namespace

int main() {
    return Run();
}
