// SPDX-License-Identifier: Apache-2.0

#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

namespace {

constexpr char kAocDevice[] = "/dev/aoc";
constexpr char kForceReload[] =
    "/sys/devices/platform/9000000.aoc/force_reload";
constexpr unsigned long kForceSpeakerUltrasonic =
    _IOW(0xac, 209, uint32_t);

bool WriteAll(int fd, const char* value) {
  const size_t size = strlen(value);
  size_t done = 0;
  while (done != size) {
    const ssize_t result = write(fd, value + done, size - done);
    if (result < 0) {
      if (errno == EINTR) continue;
      return false;
    }
    done += static_cast<size_t>(result);
  }
  return true;
}

int SetSpeakerUltrasonic(uint32_t enabled) {
  const int fd = open(kAocDevice, O_RDWR | O_CLOEXEC);
  if (fd < 0) {
    fprintf(stderr, "open %s: %s\n", kAocDevice, strerror(errno));
    return 1;
  }
  if (ioctl(fd, kForceSpeakerUltrasonic, &enabled) < 0) {
    fprintf(stderr, "ioctl 0x%lx: %s\n", kForceSpeakerUltrasonic,
            strerror(errno));
    close(fd);
    return 1;
  }
  close(fd);
  printf("force_speaker_ultrasonic=%u\n", enabled);
  return 0;
}

int ForceReload() {
  const int fd = open(kForceReload, O_WRONLY | O_CLOEXEC);
  if (fd < 0) {
    fprintf(stderr, "open %s: %s\n", kForceReload, strerror(errno));
    return 1;
  }
  constexpr char kReason[] = "PowerPhone speaker ultrasonic\n";
  if (!WriteAll(fd, kReason)) {
    fprintf(stderr, "write %s: %s\n", kForceReload, strerror(errno));
    close(fd);
    return 1;
  }
  close(fd);
  puts("AoC force_reload requested");
  return 0;
}

void Usage(const char* argv0) {
  fprintf(stderr,
          "usage: %s set-speaker-ultrasonic <0|1> [--reload]\n",
          argv0);
}

}  // namespace

int main(int argc, char** argv) {
  if (argc < 3 || argc > 4 ||
      strcmp(argv[1], "set-speaker-ultrasonic") != 0 ||
      (strcmp(argv[2], "0") != 0 && strcmp(argv[2], "1") != 0) ||
      (argc == 4 && strcmp(argv[3], "--reload") != 0)) {
    Usage(argv[0]);
    return 2;
  }
  const uint32_t enabled = argv[2][0] == '1' ? 1 : 0;
  if (SetSpeakerUltrasonic(enabled) != 0) return 1;
  if (argc == 4) return ForceReload();
  return 0;
}
