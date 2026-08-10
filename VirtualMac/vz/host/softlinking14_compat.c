#include <dlfcn.h>
#include <ptrauth.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// Introduced in iPadOS 15. The first argument is a null-terminated list of
// candidate images; the optional second argument receives an allocated error
// string. Installation.xpc only needs the successful DeviceSupport path.
// SoftLinking exports the Mach-O symbol `__sl_dlopen`. A C identifier gains
// the platform's leading underscore, so the source-level name must contain
// exactly one underscore here.
void *_sl_dlopen(const char *const paths[], char **errorString) {
    if (errorString != NULL)
        *errorString = NULL;
    if (paths == NULL)
        return NULL;

    const char *lastError = NULL;
    for (const char *const *path = paths; *path != NULL; path++) {
        void *handle = dlopen(*path, RTLD_LAZY);
        if (handle != NULL)
            return handle;
        lastError = dlerror();
    }
    if (errorString != NULL && lastError != NULL)
        *errorString = strdup(lastError);
    return NULL;
}

// Ventura's Installation service places several shared_ptr control-block
// vtables in its own __DATA_CONST. iPadOS 14 uses an older arm64e vtable
// authentication scheme and traps when libc++ invokes the final weak-owner
// destructor through one of those slots. The service is short-lived, so keep
// only those incompatible control blocks alive until process exit. Objects
// backed by an iPadOS image continue through the native libc++ implementation.
extern void _ZNSt3__119__shared_weak_count14__release_weakEv(void *object);

typedef void (*ReleaseWeakFn)(void *object);

static void release_weak_ipados14(void *object) {
    if (object) {
        uintptr_t signedVtable = *(const uintptr_t *)object;
        const void *vtable = ptrauth_strip((const void *)signedVtable,
            ptrauth_key_process_independent_data);
        Dl_info image = {0};
        if (dladdr(vtable, &image) && image.dli_fname &&
            strstr(image.dli_fname,
                "/com.apple.Virtualization.Installation")) {
            __atomic_fetch_sub((long *)((uint8_t *)object + 16), 1,
                __ATOMIC_RELAXED);
            static int logged;
            if (!logged) {
                logged = 1;
                dprintf(2, "SoftLinking14Compat: retained incompatible "
                    "Installation weak control blocks\n");
            }
            return;
        }
    }

    static ReleaseWeakFn nativeRelease;
    if (!nativeRelease)
        nativeRelease = (ReleaseWeakFn)dlsym(RTLD_NEXT,
            "_ZNSt3__119__shared_weak_count14__release_weakEv");
    if (nativeRelease)
        nativeRelease(object);
}

__attribute__((used)) static struct {
    const void *replacement;
    const void *replacee;
} release_weak_interpose __attribute__((section("__DATA,__interpose"))) = {
    (const void *)&release_weak_ipados14,
    (const void *)&_ZNSt3__119__shared_weak_count14__release_weakEv,
};
