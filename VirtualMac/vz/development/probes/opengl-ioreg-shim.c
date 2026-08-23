#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <stdio.h>
#include <string.h>

static bool is_paravirtual_gpu(io_registry_entry_t entry) {
    io_name_t class_name = {0};
    return IOObjectGetClass(entry, class_name) == KERN_SUCCESS &&
           strcmp(class_name, "AppleParavirtGPU") == 0;
}

static CFTypeRef shim_IORegistryEntryCreateCFProperty(
    io_registry_entry_t entry, CFStringRef key, CFAllocatorRef allocator,
    IOOptionBits options) {
    if (is_paravirtual_gpu(entry) &&
        CFEqual(key, CFSTR("IOGLBundleName"))) {
        fprintf(stderr,
                "OpenGLIORegistryShim: supplying AppleMetalOpenGLRenderer\n");
        return CFRetain(CFSTR("AppleMetalOpenGLRenderer"));
    }
    if (is_paravirtual_gpu(entry) &&
        CFEqual(key, CFSTR("IOGLESBundleName"))) {
        fprintf(stderr,
                "OpenGLIORegistryShim: supplying AppleMetalGLRenderer\n");
        return CFRetain(CFSTR("AppleMetalGLRenderer"));
    }
    return IORegistryEntryCreateCFProperty(entry, key, allocator, options);
}

#define INTERPOSE(replacement, replacee)                                      \
    __attribute__((used)) static struct {                                    \
        const void *replacement;                                             \
        const void *replacee;                                                \
    } _interpose_##replacee __attribute__((section("__DATA,__interpose"))) = { \
        (const void *)(uintptr_t)&replacement,                               \
        (const void *)(uintptr_t)&replacee                                   \
    }

INTERPOSE(shim_IORegistryEntryCreateCFProperty,
          IORegistryEntryCreateCFProperty);
