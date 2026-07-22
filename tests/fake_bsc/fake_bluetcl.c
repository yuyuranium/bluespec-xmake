#define _POSIX_C_SOURCE 200809L

#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
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

static char *read_stdin(void) {
    size_t capacity = 4096;
    size_t length = 0;
    char *text = malloc(capacity);
    if (!text) return NULL;
    while (!feof(stdin)) {
        if (length + 2048 + 1 > capacity) {
            capacity *= 2;
            char *grown = realloc(text, capacity);
            if (!grown) {
                free(text);
                return NULL;
            }
            text = grown;
        }
        length += fread(text + length, 1, capacity - length - 1, stdin);
        if (ferror(stdin)) {
            free(text);
            return NULL;
        }
    }
    text[length] = '\0';
    return text;
}

static void command_argument(const char *script, const char *command,
                             char *result, size_t size) {
    result[0] = '\0';
    const char *cursor = strstr(script, command);
    if (!cursor) return;
    cursor += strlen(command);
    while (*cursor == ' ' || *cursor == '\t') ++cursor;
    char quote = 0;
    if (*cursor == '"') {
        quote = '"';
        ++cursor;
    } else if (*cursor == '{') {
        quote = '}';
        ++cursor;
    }
    size_t length = 0;
    while (*cursor && length + 1 < size) {
        if (quote ? *cursor == quote :
            (*cursor == ' ' || *cursor == '\t' || *cursor == '\r' ||
             *cursor == '\n' || *cursor == ']')) break;
        if (*cursor == '\\' && cursor[1]) ++cursor;
        result[length++] = *cursor++;
    }
    result[length] = '\0';
}

static void package_name(const char *source, char *result, size_t size) {
    const char *base = strrchr(source, '/');
    base = base ? base + 1 : source;
    snprintf(result, size, "%s", base);
    char *extension = strrchr(result, '.');
    if (extension) *extension = '\0';
}

static void log_event(const char *event, int status, const char *root,
                      const char *search) {
    const char *log = getenv("BLUESPEC_FAKE_BLUETCL_LOG");
    if (!log || !*log) return;
    char line[8192];
    int length = snprintf(line, sizeof(line),
        "event=%s time_us=%lld pid=%ld ppid=%ld status=%d target=%s root=%s search=%s\n",
        event, (long long)now_us(), (long)getpid(), (long)getppid(), status,
        getenv("BLUESPEC_XMAKE_TARGET") ? getenv("BLUESPEC_XMAKE_TARGET") : "",
        root, search);
    if (length <= 0) return;
    if ((size_t)length >= sizeof(line)) length = (int)sizeof(line) - 1;
    int fd = open(log, O_WRONLY | O_CREAT | O_APPEND, 0666);
    if (fd >= 0) {
        (void)write(fd, line, (size_t)length);
        close(fd);
    }
}

int main(void) {
    char *script = read_stdin();
    if (!script) return 20;
    char root[4096];
    char search[4096];
    command_argument(script, "Bluetcl::depend make", root, sizeof(root));
    command_argument(script, "Bluetcl::flags set -p", search, sizeof(search));
    free(script);
    if (!*root) return 21;

    log_event("start", 0, root, search);
    const char *delay_value = getenv("BLUESPEC_FAKE_BLUETCL_MS");
    long delay = delay_value ? strtol(delay_value, NULL, 10) : 50;
    if (delay > 0) sleep_ms(delay);

    const char *fail_root = getenv("BLUESPEC_FAKE_BLUETCL_FAIL_ROOT");
    int status = fail_root && *fail_root && strstr(root, fail_root) ? 22 : 0;
    if (status == 0) {
        char package[512];
        package_name(root, package, sizeof(package));
        printf("%s.bo: %s\n", package, root);
    } else {
        fprintf(stderr, "fake bluetcl failure status=%d root=%s\n", status, root);
    }
    log_event("end", status, root, search);
    return status;
}
