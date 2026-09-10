/* SPDX-License-Identifier: Apache-2.0 */
/* Normal AoC tuning commands, restricted to known speaker PCM source 0 gain. */
#define _POSIX_C_SOURCE 200809L
#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <poll.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

/* Public google-modules-aoc aoc-interface-zuma.h wire ABI. */
struct __attribute__((packed)) parameter {
    uint8_t type, counter;
    uint16_t length, id;
    int16_t reply;
    uint8_t block, component;
    uint32_t key, value;
};
_Static_assert(sizeof(struct parameter) == 18, "AoC parameter ABI");
enum { GET_PARAMETER = 211, SET_PARAMETER = 209, TIMEOUT_MS = 2000 };
static const char tuning_device[] = "/dev/acd-audio_output_tuning";
static uint8_t command_counter;

static int64_t monotonic_ms(void) {
    struct timespec now;
    if (clock_gettime(CLOCK_MONOTONIC, &now) != 0) return -1;
    return (int64_t)now.tv_sec * 1000 + now.tv_nsec / 1000000;
}

static int exchange(int fd, uint16_t id, uint32_t *value) {
    struct parameter request = {
        .type = 0, /* DATA_TYPE_CMD, identical to public AocCmdHdrSet(). */
        .counter = command_counter++, .length = sizeof(request), .id = id,
        .reply = 0, .block = 16, .component = 0, .key = 0,
        .value = id == SET_PARAMETER ? *value : 0,
    };
    uint8_t buffer[1024];
    /* This is the dedicated, exclusively opened userspace tuning channel. */
    for (unsigned i = 0; i < 8; ++i) {
        ssize_t count = read(fd, buffer, sizeof(buffer));
        if (count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) break;
        if (count == 0) break;
        if (count < 0) { perror("drain tuning response"); return -1; }
        if (i == 7) { fprintf(stderr, "Too many pending tuning responses\n"); return -1; }
    }
    ssize_t written = write(fd, &request, sizeof(request));
    if (written != (ssize_t)sizeof(request)) {
        if (written < 0) perror("write tuning request");
        else fprintf(stderr, "Short tuning request: %zd bytes\n", written);
        return -1;
    }
    int64_t started = monotonic_ms();
    if (started < 0) { perror("clock_gettime"); return -1; }
    for (;;) {
        int64_t now = monotonic_ms();
        if (now < 0) { perror("clock_gettime"); return -1; }
        int64_t remaining = started + TIMEOUT_MS - now;
        if (remaining <= 0) { fprintf(stderr, "Tuning response timeout\n"); return -1; }
        struct pollfd ready = { .fd = fd, .events = POLLIN };
        int result = poll(&ready, 1, (int)remaining);
        if (result < 0 && errno == EINTR) continue;
        if (result < 0) { perror("poll tuning response"); return -1; }
        if (result == 0) continue;
        if (!(ready.revents & POLLIN)) {
            fprintf(stderr, "Tuning poll error: 0x%x\n", ready.revents); return -1;
        }
        ssize_t count = read(fd, buffer, sizeof(buffer));
        if (count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR)) continue;
        if (count < 0) { perror("read tuning response"); return -1; }
        if (count != (ssize_t)sizeof(struct parameter)) {
            fprintf(stderr, "Unexpected response size: %zd (expected 18)\n", count);
            return -1;
        }
        struct parameter response;
        memcpy(&response, buffer, sizeof(response));
        /* Frankel assigns a firmware response counter rather than echoing the
         * request counter. Exclusive open and one outstanding fixed-key request
         * provide pairing; retain the response opcode, length and key checks. */
        if (response.type != request.type ||
            response.length != sizeof(response) || response.id != request.id ||
            response.block != request.block || response.component != request.component ||
            response.key != request.key) {
            fprintf(stderr, "Unexpected tuning response: type=%u counter=%u length=%u "
                    "id=%u reply=%d block=%u component=%u key=%" PRIu32 "\n",
                    response.type, response.counter, response.length, response.id,
                    response.reply, response.block, response.component, response.key);
            return -1;
        }
        if (response.reply != 0) {
            fprintf(stderr, "AoC rejected normal tuning command: reply=%d\n", response.reply);
            return -1;
        }
        *value = response.value;
        return 0;
    }
}

int main(int argc, char **argv) {
    uint32_t requested = 0;
    int setting = argc == 3 &&
        (!strcmp(argv[1], "set") || !strcmp(argv[1], "restore"));
    if (!(argc == 1 || (argc == 2 && !strcmp(argv[1], "get")) || setting)) {
        fprintf(stderr, "Usage: %s [get | set 0..1000 | restore 0..1000]\n", argv[0]);
        return 2;
    }
    if (setting) {
        char *end;
        errno = 0;
        unsigned long parsed = strtoul(argv[2], &end, 10);
        if (errno || !argv[2][0] || *end || argv[2][0] == '-' || parsed > 1000) {
            fprintf(stderr, "Gain must be an integer from 0 through 1000\n"); return 2;
        }
        requested = (uint32_t)parsed;
    }
    int fd = open(tuning_device, O_RDWR | O_NONBLOCK | O_CLOEXEC);
    if (fd < 0) { perror(tuning_device); return 1; }
    uint32_t original = 0;
    if (exchange(fd, GET_PARAMETER, &original) != 0) { close(fd); return 1; }
    printf("source0_gain=%" PRIu32 " block=16 component=0 key=0\n", original);
    fflush(stdout);
    if (setting) {
        printf("original_gain=%" PRIu32 " requested_gain=%" PRIu32 "\n", original, requested);
        fflush(stdout);
        uint32_t value = requested;
        if (exchange(fd, SET_PARAMETER, &value) != 0) { close(fd); return 1; }
        if (exchange(fd, GET_PARAMETER, &value) != 0) { close(fd); return 1; }
        printf("readback_gain=%" PRIu32 "\n", value);
        if (value != requested) {
            fprintf(stderr, "Gain readback does not match request\n"); close(fd); return 1;
        }
        printf("Restore explicitly with: %s restore %" PRIu32 "\n", argv[0], original);
    }
    close(fd);
    return 0;
}
