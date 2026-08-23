#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

extern int memorystatus_control(uint32_t command, int32_t pid,
                                uint32_t flags, void *buffer,
                                size_t buffer_size);

// https://github.com/apple-oss-distributions/xnu/blob/xnu-8792.81.2/bsd/sys/kern_memorystatus.h
typedef struct {
    int32_t memlimit_active;
    uint32_t memlimit_active_attr;
    int32_t memlimit_inactive;
    uint32_t memlimit_inactive_attr;
} memorystatus_memlimit_properties_t;

typedef struct {
    int32_t pid;
    int32_t priority;
    uint64_t user_data;
    int32_t limit;
    uint32_t state;
} memorystatus_priority_entry_t;

static int parseInt(const char *text, int32_t *value) {
    char *end = NULL;
    errno = 0;
    long parsed = strtol(text, &end, 10);
    if (errno != 0 || end == text || *end != '\0' ||
        parsed < INT32_MIN || parsed > INT32_MAX)
        return -1;
    *value = (int32_t)parsed;
    return 0;
}

static int printStatus(pid_t pid) {
    memorystatus_memlimit_properties_t limits = {0};
    errno = 0;
    int limitsResult = memorystatus_control(
        8, pid, 0, &limits, sizeof(limits));
    int limitsError = errno;
    printf("pid=%d limits-result=%d errno=%d active=%d/0x%x "
           "inactive=%d/0x%x\n", pid, limitsResult, limitsError,
           limits.memlimit_active, limits.memlimit_active_attr,
           limits.memlimit_inactive, limits.memlimit_inactive_attr);

    memorystatus_priority_entry_t priority = {0};
    errno = 0;
    int priorityResult = memorystatus_control(
        1, pid, 0, &priority, sizeof(priority));
    int priorityError = errno;
    printf("pid=%d priority-result=%d errno=%d priority=%d "
           "cached-limit=%d state=0x%x\n", pid, priorityResult,
           priorityError, priority.priority, priority.limit, priority.state);
    return limitsResult == 0 && priorityResult >= 0 ? 0 : 1;
}

int main(int argc, char **argv) {
    if (argc != 2 && argc != 4) {
        fprintf(stderr, "usage: %s PID [ACTIVE_MIB INACTIVE_MIB]\n",
                argv[0]);
        return 64;
    }
    int32_t pidValue = 0;
    if (parseInt(argv[1], &pidValue) != 0 || pidValue <= 0) {
        fprintf(stderr, "invalid pid: %s\n", argv[1]);
        return 64;
    }
    if (argc == 2)
        return printStatus((pid_t)pidValue);

    memorystatus_memlimit_properties_t limits = {0};
    if (parseInt(argv[2], &limits.memlimit_active) != 0 ||
        parseInt(argv[3], &limits.memlimit_inactive) != 0) {
        fprintf(stderr, "memory limits must be signed MiB integers\n");
        return 64;
    }
    errno = 0;
    int result = memorystatus_control(7, (pid_t)pidValue, 0,
                                      &limits, sizeof(limits));
    int error = errno;
    printf("set pid=%d result=%d errno=%d\n", pidValue, result, error);
    return result == 0 ? printStatus((pid_t)pidValue) : 1;
}
