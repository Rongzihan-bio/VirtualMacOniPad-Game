#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <dlfcn.h>
#include <CoreFoundation/CoreFoundation.h>

typedef int32_t OSStatus;
typedef void *AuthorizationRef;
typedef uint32_t AuthorizationFlags;
typedef unsigned char Boolean;

typedef Boolean (*SMJobSetEnabledFn)(CFStringRef domain,
                                     AuthorizationRef authorization,
                                     CFStringRef jobLabel,
                                     Boolean enabled,
                                     CFErrorRef *error);

extern Boolean SMJobSetEnabled(CFStringRef domain,
                               AuthorizationRef authorization,
                               CFStringRef jobLabel,
                               Boolean enabled,
                               CFErrorRef *error);

extern int memorystatus_control(uint32_t command, int32_t pid,
                                uint32_t flags, void *buffer,
                                size_t buffer_size);

__attribute__((constructor)) static void raiseInternetSharingMemoryLimit(void) {
    // iPadOS rootless launch daemons have a 6 MiB default jetsam limit.
    // Ventura's InternetSharing loads its desktop framework graph before main
    // and cannot even allocate its first dispatch queue within that budget.
    // XNU command 5 sets both active and inactive soft limits; flags are MiB.
    const uint32_t memoryStatusSetHighWaterMark = 5;
    int result = memorystatus_control(memoryStatusSetHighWaterMark,
                                      getpid(), 128, NULL, 0);
    dprintf(STDERR_FILENO,
            "AuthorizationCompat: set 128 MiB jetsam limit result=%d\n",
            result);

    typedef CFTypeRef (*SecTaskCreateFromSelfFn)(CFAllocatorRef);
    typedef CFTypeRef (*SecTaskCopyValueForEntitlementFn)(
        CFTypeRef, CFStringRef, CFErrorRef *);
    SecTaskCreateFromSelfFn createTask =
        (SecTaskCreateFromSelfFn)dlsym(RTLD_DEFAULT,
                                      "SecTaskCreateFromSelf");
    SecTaskCopyValueForEntitlementFn copyEntitlement =
        (SecTaskCopyValueForEntitlementFn)dlsym(
            RTLD_DEFAULT, "SecTaskCopyValueForEntitlement");
    if (createTask && copyEntitlement) {
        CFTypeRef task = createTask(kCFAllocatorDefault);
        CFTypeRef value = task ? copyEntitlement(
            task, CFSTR("com.apple.networking.ethernet.user-access"),
            NULL) : NULL;
        int granted = value && CFGetTypeID(value) == CFBooleanGetTypeID() &&
                      CFBooleanGetValue((CFBooleanRef)value);
        dprintf(STDERR_FILENO,
                "AuthorizationCompat: ethernet entitlement=%d value=%p\n",
                granted, value);
        if (value)
            CFRelease(value);
        if (task)
            CFRelease(task);
    }
}

// InternetSharing runs as a root platform daemon on iPadOS. Desktop Security's
// Authorization Services entry points are absent there, while the daemon only
// uses them to establish and release its privileged launchd-operation context.
OSStatus AuthorizationCreate(const void *rights, const void *environment,
                             AuthorizationFlags flags,
                             AuthorizationRef *authorization) {
    (void)rights;
    (void)environment;
    (void)flags;
    if (authorization)
        *authorization = 0;
    return 0;
}

OSStatus AuthorizationFree(AuthorizationRef authorization,
                           AuthorizationFlags flags) {
    (void)authorization;
    (void)flags;
    return 0;
}

// iPadOS redirects rootless launch daemons without an explicit System session
// into the foreground-user domain. InternetSharing must live there to reach
// MobileInternetSharing, but Ventura hard-codes kSMDomainSystemLaunchd when it
// enables bootpd. Remap only our private matching-helper label to the user
// domain; every other ServiceManagement operation is forwarded unchanged.
static Boolean compatSMJobSetEnabled(CFStringRef domain,
                                     AuthorizationRef authorization,
                                     CFStringRef jobLabel,
                                     Boolean enabled,
                                     CFErrorRef *error) {
    static SMJobSetEnabledFn realFunction;
    static const CFStringRef *userDomain;
    if (!realFunction || !userDomain) {
        void *serviceManagement = dlopen(
            "/System/Library/PrivateFrameworks/ServiceManagement.framework/ServiceManagement",
            RTLD_LAZY | RTLD_LOCAL);
        realFunction = serviceManagement ? (SMJobSetEnabledFn)dlsym(
            serviceManagement, "SMJobSetEnabled") : NULL;
        userDomain = serviceManagement ? (const CFStringRef *)dlsym(
            serviceManagement, "kSMDomainUserLaunchd") : NULL;
        // An interposed dlsym result must never recurse back into this shim.
        if ((void *)realFunction == (void *)&compatSMJobSetEnabled)
            realFunction = (SMJobSetEnabledFn)dlsym(
                RTLD_NEXT, "SMJobSetEnabled");
        dprintf(STDERR_FILENO,
                "AuthorizationCompat: resolved ServiceManagement "
                "function=%p user-domain=%p\n",
                realFunction, userDomain);
    }
    bool isMatchingBootpd = jobLabel &&
        CFEqual(jobLabel, CFSTR("vzi.apple.bootpd"));
    if (isMatchingBootpd && userDomain && *userDomain) {
        domain = *userDomain;
        dprintf(STDERR_FILENO,
                "AuthorizationCompat: bootpd launch domain -> user (%d)\n",
                enabled);
    }
    if (!realFunction) {
        dprintf(STDERR_FILENO,
                "AuthorizationCompat: SMJobSetEnabled unavailable\n");
        return 0;
    }
    return realFunction(domain, authorization, jobLabel, enabled, error);
}

__attribute__((used)) static struct {
    const void *replacement;
    const void *replacee;
} interposeSMJobSetEnabled __attribute__((section("__DATA,__interpose"))) = {
    (const void *)&compatSMJobSetEnabled,
    (const void *)&SMJobSetEnabled,
};
