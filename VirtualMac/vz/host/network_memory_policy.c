#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/sysctl.h>
#include <unistd.h>

extern int memorystatus_control(uint32_t command, int32_t pid,
                                uint32_t flags, void *buffer,
                                size_t buffer_size);

typedef struct {
    int32_t priority;
    uint64_t user_data;
} memorystatus_priority_properties_t;

typedef struct {
    int32_t pid;
    int32_t priority;
    uint64_t user_data;
    int32_t limit;
    uint32_t state;
} memorystatus_priority_entry_t;

static int hostMajorVersion(void)
{
    char version[32] = {0};
    size_t size = sizeof(version);
    if (sysctlbyname("kern.osproductversion", version, &size, NULL, 0) == 0)
        return (int)strtol(version, NULL, 10);
    return 0;
}

__attribute__((constructor))
static void protectVirtualMacNetworkService(void)
{
    /*
     * Unknown third-party daemons inherit the lowest daemon jetsam profile.
     * That is band 3/4 on iPadOS 14/15 and 30/40 on iPadOS 16, so a large
     * guest makes iOS kill DHCP/DNS/NAT while leaving the VM running.
     *
     * Protect these package-owned network helpers like Apple's wifid: band 14
     * on XNU 20/21 and the renumbered band 140 on XNU 22. The memorystatus ABI
     * and structures are identical across all three supported kernels:
     * https://github.com/apple-oss-distributions/xnu/blob/xnu-7195.141.2/bsd/sys/kern_memorystatus.h
     * https://github.com/apple-oss-distributions/xnu/blob/xnu-8019.41.5/bsd/sys/kern_memorystatus.h
     * https://github.com/apple-oss-distributions/xnu/blob/xnu-8792.81.2/bsd/sys/kern_memorystatus.h
     */
    const uint32_t getPriorityList = 1;
    const uint32_t setPriorityProperties = 2;
    const uint32_t setHighWaterMark = 5;
    const uint32_t priorityIsAssertion = 1;
    const int majorVersion = hostMajorVersion();
    const int32_t priority = majorVersion >= 16 ? 140 : 14;
    const pid_t pid = getpid();
    memorystatus_priority_properties_t properties = {
        .priority = priority,
        .user_data = 0,
    };
    errno = 0;
    // Use the assertion-owned priority. A requested priority alone is demoted
    // when launchd marks an idle Mach service clean, reproducing the original
    // MEMORY_IDLE_EXIT even though the constructor initially reached band 140.
    int priorityResult = memorystatus_control(setPriorityProperties, pid,
                                              priorityIsAssertion,
                                              &properties,
                                              sizeof(properties));
    int priorityError = errno;
    errno = 0;
    int memoryResult = memorystatus_control(setHighWaterMark, pid, 128,
                                            NULL, 0);
    int memoryError = errno;

    memorystatus_priority_entry_t actual = {0};
    errno = 0;
    int queryResult = memorystatus_control(getPriorityList, pid, 0,
                                           &actual, sizeof(actual));
    int queryError = errno;
    dprintf(STDERR_FILENO,
            "NetworkMemoryPolicy: host=%d requested-priority=%d "
            "priority-result=%d errno=%d memory-result=%d errno=%d "
            "query-result=%d errno=%d actual-priority=%d limit=%d MiB\n",
            majorVersion, priority, priorityResult, priorityError,
            memoryResult, memoryError, queryResult, queryError,
            actual.priority, actual.limit);
}
