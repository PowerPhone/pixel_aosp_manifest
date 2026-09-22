// SPDX-License-Identifier: Apache-2.0
/*
 * Keep a configured Frankel capture PCM prepared but not started.
 *
 * pcm_open() performs ALSA HW_PARAMS and pcm_prepare() performs PREPARE.  No
 * read or START ioctl is issued.  This lets the stock AoC driver execute its
 * complete PDM open/reset/configuration lifecycle while a separate guarded
 * AP FIFO experiment owns the decision to start raw production.
 */

#include <tinyalsa/asoundlib.h>

#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static volatile sig_atomic_t stop_requested;

static void request_stop(int signal_number)
{
    (void)signal_number;
    stop_requested = 1;
}

static unsigned int parse_unsigned(const char *text, const char *name)
{
    char *end = NULL;
    unsigned long value;

    errno = 0;
    value = strtoul(text, &end, 0);
    if (errno || !end || *end || value > 0xffffffffUL) {
        fprintf(stderr, "invalid %s: %s\n", name, text);
        exit(2);
    }
    return (unsigned int)value;
}

static enum pcm_format parse_format(const char *text)
{
    if (!strcmp(text, "s16"))
        return PCM_FORMAT_S16_LE;
    if (!strcmp(text, "s24"))
        return PCM_FORMAT_S24_LE;
    if (!strcmp(text, "s32"))
        return PCM_FORMAT_S32_LE;
    fprintf(stderr, "format must be s16, s24, or s32\n");
    exit(2);
}

static int publish_ready(const char *path, const struct pcm_config *config)
{
    char record[256];
    int descriptor;
    int length;

    descriptor = open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0600);
    if (descriptor < 0) {
        fprintf(stderr, "cannot create ready file %s: %s\n", path,
                strerror(errno));
        return -1;
    }
    length = snprintf(record, sizeof(record),
                      "pid=%ld state=prepared-not-started card=0 device=8 "
                      "rate=%u channels=%u format=%u period_size=%u "
                      "period_count=%u\n",
                      (long)getpid(), config->rate, config->channels,
                      (unsigned int)config->format, config->period_size,
                      config->period_count);
    if (length <= 0 || length >= (int)sizeof(record) ||
        write(descriptor, record, (size_t)length) != length ||
        fsync(descriptor) < 0) {
        fprintf(stderr, "cannot publish ready record: %s\n", strerror(errno));
        close(descriptor);
        unlink(path);
        return -1;
    }
    if (close(descriptor) < 0) {
        fprintf(stderr, "cannot close ready record: %s\n", strerror(errno));
        unlink(path);
        return -1;
    }
    return 0;
}

int main(int argc, char **argv)
{
    struct pcm_config config = {0};
    struct sigaction action = {0};
    struct pcm *pcm;
    const char *ready_path;
    int result = 1;

    if (argc != 7) {
        fprintf(stderr,
                "usage: %s READY_FILE RATE CHANNELS FORMAT PERIOD_SIZE "
                "PERIOD_COUNT\n",
                argv[0]);
        return 2;
    }
    ready_path = argv[1];
    config.rate = parse_unsigned(argv[2], "rate");
    config.channels = parse_unsigned(argv[3], "channels");
    config.format = parse_format(argv[4]);
    config.period_size = parse_unsigned(argv[5], "period size");
    config.period_count = parse_unsigned(argv[6], "period count");
    config.start_threshold = 0;
    config.stop_threshold = 0;
    config.silence_threshold = 0;

    action.sa_handler = request_stop;
    sigemptyset(&action.sa_mask);
    if (sigaction(SIGINT, &action, NULL) ||
        sigaction(SIGTERM, &action, NULL) ||
        sigaction(SIGHUP, &action, NULL)) {
        fprintf(stderr, "cannot install signal handlers: %s\n", strerror(errno));
        return 1;
    }

    pcm = pcm_open(0, 8, PCM_IN, &config);
    if (!pcm || !pcm_is_ready(pcm)) {
        fprintf(stderr, "cannot open card 0 device 8: %s\n",
                pcm_get_error(pcm));
        return 1;
    }
    if (pcm_prepare(pcm) < 0) {
        fprintf(stderr, "cannot prepare card 0 device 8: %s\n",
                pcm_get_error(pcm));
        goto close_pcm;
    }
    if (publish_ready(ready_path, &config))
        goto close_pcm;

    printf("prepared-not-started pid=%ld card=0 device=8 rate=%u channels=%u\n",
           (long)getpid(), config.rate, config.channels);
    fflush(stdout);
    while (!stop_requested)
        pause();
    result = 0;
    unlink(ready_path);

close_pcm:
    pcm_close(pcm);
    return result;
}
