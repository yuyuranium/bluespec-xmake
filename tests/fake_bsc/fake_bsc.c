#define _POSIX_C_SOURCE 200809L

#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <time.h>
#include <unistd.h>

static int64_t now_us(void) {
    struct timespec value;
    clock_gettime(CLOCK_MONOTONIC, &value);
    return (int64_t)value.tv_sec * 1000000 + value.tv_nsec / 1000;
}

static void sleep_ms(long milliseconds) {
    struct timespec value;
    value.tv_sec = milliseconds / 1000;
    value.tv_nsec = (milliseconds % 1000) * 1000000;
    while (nanosleep(&value, &value) != 0 && errno == EINTR) {}
}

static const char *value_after(int argc, char **argv, const char *flag) {
    for (int index = 1; index + 1 < argc; ++index) {
        if (strcmp(argv[index], flag) == 0) return argv[index + 1];
    }
    return "";
}

static int has_flag(int argc, char **argv, const char *flag) {
    for (int index = 1; index < argc; ++index) {
        if (strcmp(argv[index], flag) == 0) return 1;
    }
    return 0;
}

static const char *source_arg(int argc, char **argv) {
    for (int index = argc - 1; index > 0; --index) {
        size_t length = strlen(argv[index]);
        if (length >= 4 && strcmp(argv[index] + length - 4, ".bsv") == 0) return argv[index];
    }
    return "";
}

static void package_name(const char *source, char *result, size_t size) {
    const char *base = strrchr(source, '/');
    base = base ? base + 1 : source;
    snprintf(result, size, "%s", base);
    char *extension = strrchr(result, '.');
    if (extension) *extension = '\0';
}

static int write_text(const char *pathname, const char *contents) {
    FILE *file = fopen(pathname, "w");
    if (!file) return -1;
    fputs(contents, file);
    return fclose(file);
}

static void log_event(const char *event, const char *kind, int status,
                      const char *bdir, const char *vdir, const char *source,
                      const char *top) {
    const char *log = getenv("BLUESPEC_FAKE_BSC_LOG");
    if (!log || !*log) return;
    char line[4096];
    int length = snprintf(line, sizeof(line),
        "event=%s time_us=%lld pid=%ld ppid=%ld status=%d kind=%s target=%s job=%s phase=%s "
        "bdir=%s vdir=%s source=%s top=%s\n",
        event, (long long)now_us(), (long)getpid(), (long)getppid(), status, kind,
        getenv("BLUESPEC_XMAKE_TARGET") ? getenv("BLUESPEC_XMAKE_TARGET") : "",
        getenv("BLUESPEC_XMAKE_JOB") ? getenv("BLUESPEC_XMAKE_JOB") : "",
        getenv("BLUESPEC_XMAKE_PHASE") ? getenv("BLUESPEC_XMAKE_PHASE") : "",
        bdir, vdir, source, top);
    if (length <= 0) return;
    if ((size_t)length >= sizeof(line)) length = (int)sizeof(line) - 1;
    int fd = open(log, O_WRONLY | O_CREAT | O_APPEND, 0666);
    if (fd >= 0) {
        (void)write(fd, line, (size_t)length);
        close(fd);
    }
}

int main(int argc, char **argv) {
    if (argc == 2 && strcmp(argv[1], "-v") == 0) {
        puts("Bluespec Compiler, fake concurrency regression v1");
        return 0;
    }

    const char *bdir = value_after(argc, argv, "-bdir");
    const char *vdir = value_after(argc, argv, "-vdir");
    const char *top = value_after(argc, argv, "-g");
    const char *source = source_arg(argc, argv);
    const char *kind = has_flag(argc, argv, "-verilog") && *top ? "backend" : "package";
    const char *sleep_value = getenv(strcmp(kind, "backend") == 0
        ? "BLUESPEC_FAKE_BSC_BACKEND_MS" : "BLUESPEC_FAKE_BSC_PACKAGE_MS");
    long delay = sleep_value ? strtol(sleep_value, NULL, 10) : 50;
    log_event("start", kind, 0, bdir, vdir, source, top);
    if (delay > 0) sleep_ms(delay);

    const char *fail_top = getenv("BLUESPEC_FAKE_BSC_FAIL_TOP");
    int status = fail_top && *fail_top && strcmp(fail_top, top) == 0 ? 23 : 0;
    if (status == 0 && strcmp(kind, "backend") == 0) {
        char output[4096];
        snprintf(output, sizeof(output), "%s/%s.v", vdir, top);
        status = write_text(output, "// fake Bluespec Verilog output\n") == 0 ? 0 : 24;
    } else if (status == 0) {
        char package[512];
        char output[4096];
        package_name(source, package, sizeof(package));
        snprintf(output, sizeof(output), "%s/%s.bo", bdir, package);
        status = write_text(output, "fake Bluespec package object\n") == 0 ? 0 : 25;
    }
    log_event("end", kind, status, bdir, vdir, source, top);
    if (status != 0) fprintf(stderr, "fake bsc failure status=%d top=%s\n", status, top);
    return status;
}
