// SPDX-License-Identifier: Apache-2.0
// Read-only, selected-register diagnostic for the Cubs tas25xx misc ABI.
#define _POSIX_C_SOURCE 200809L
#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

static int number(const char *s, long low, long high, long *out) {
    char *end;
    errno = 0;
    long n = strtol(s, &end, 10);
    if (errno || !*s || *end || n < low || n > high) return -1;
    *out = n;
    return 0;
}

static int reg_read(int fd, uint8_t channel, uint8_t reg, uint8_t *value) {
    // Binary command lives IN the read buffer: ordinary dd/cat cannot do this.
    // Driver returns count even on I2C errors. Distinct sentinels detect its
    // unchanged-buffer error path; changing values are reported, not hidden.
    uint8_t first = 0;
    for (unsigned i = 0; i < 2; ++i) {
        uint8_t q[7] = {2, channel, 0, 0, 0, reg, i ? 0x5a : 0xa5};
        uint8_t header[6];
        memcpy(header, q, sizeof(header));
        ssize_t n;
        do { n = read(fd, q, sizeof(q)); } while (n < 0 && errno == EINTR);
        if (n != (ssize_t)sizeof(q) || memcmp(q, header, sizeof(header))) {
            fprintf(stderr, "READ_ERROR ch=%u reg=0x%02x count=%zd errno=%d\n",
                    channel, reg, n, n < 0 ? errno : 0);
            return -1;
        }
        if (!i) first = q[6];
        else if (q[6] != first) {
            fprintf(stderr, "UNSTABLE_OR_READ_ERROR ch=%u reg=0x%02x values=%02x,%02x\n",
                    channel, reg, first, q[6]);
            return -1;
        }
    }
    *value = first;
    return 0;
}

int main(int argc, char **argv) {
    long channel = -1, samples = 1, interval_ms = 200;
    int detect_only = 0;
    for (int i = 1; i < argc; ++i) {
        if (!strcmp(argv[i], "--detect-only")) { detect_only = 1; continue; }
        if (i + 1 >= argc) goto usage;
        const char *option = argv[i++];
        if (!strcmp(option, "--channel")) {
            if (number(argv[i], 0, 1, &channel)) goto usage;
        } else if (!strcmp(option, "--samples")) {
            if (number(argv[i], 1, 100, &samples)) goto usage;
        } else if (!strcmp(option, "--interval-ms")) {
            if (number(argv[i], 20, 1000, &interval_ms)) goto usage;
        } else goto usage;
    }
    if (channel < 0) goto usage;
    const char *node = "/dev/tas_audio_dev";
    int fd = open(node, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
    if (fd < 0) { perror(node); return 1; }
    struct stat st;
    if (fstat(fd, &st) || !S_ISCHR(st.st_mode)) {
        fprintf(stderr, "Expected character device %s\n", node);
        close(fd);
        return 1;
    }
    setvbuf(stdout, NULL, _IOLBF, 0);
    int failed = 0;
    const uint8_t regs[] = {0x07, 0x08, 0x09, 0x0a, 0x14};
    const unsigned ratios[] = {16,24,32,48,64,96,128,192,256,384,512,250,0,500,0,0};
    for (long s = 0; s < samples; ++s) {
        struct timespec now;
        if (clock_gettime(CLOCK_MONOTONIC, &now)) { perror("clock_gettime"); failed = 1; break; }
        printf("sample=%ld monotonic_ns=%" PRId64 " channel=%ld", s,
               (int64_t)now.tv_sec * 1000000000 + now.tv_nsec, channel);
        uint8_t values[5] = {0};
        int valid[5] = {0};
        for (unsigned r = detect_only ? 4 : 0; r < 5; ++r) {
            if (reg_read(fd, (uint8_t)channel, regs[r], &values[r])) {
                printf(" reg_%02x=ERROR", regs[r]); failed = 1;
            } else { printf(" reg_%02x=0x%02x", regs[r], values[r]); valid[r] = 1; }
        }
        if (valid[4]) {
            unsigned ratio = (values[4] >> 3) & 15, rate = values[4] & 7;
            printf(" ratio_code=%u ratio=%u rate_code=%u", ratio, ratios[ratio], rate);
            // Actual Hz depends on 0x07 family; never assume from rate code.
            if (valid[0]) {
                const unsigned rate48[] = {0,16000,24000,32000,48000,96000,192000,0};
                const unsigned rate44[] = {0,14700,22050,29400,44100,88200,176400,0};
                printf(" detected_hz=%u", (values[0] & 0x40 ? rate44 : rate48)[rate]);
            }
        }
        putchar('\n');
        if (s + 1 < samples) {
            struct timespec delay = {interval_ms / 1000, (interval_ms % 1000) * 1000000};
            while (nanosleep(&delay, &delay) && errno == EINTR) {}
        }
    }
    if (close(fd)) { perror("close"); failed = 1; }
    return failed;
usage:
    fprintf(stderr, "Usage: %s --channel 0|1 [--samples 1..100] [--interval-ms 20..1000] [--detect-only]\n", argv[0]);
    return 2;
}
