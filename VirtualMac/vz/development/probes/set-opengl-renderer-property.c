#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <stdio.h>

int main(void) {
    io_service_t service = IOServiceGetMatchingService(
        kIOMainPortDefault, IOServiceMatching("AppleParavirtGPU"));
    if (service == IO_OBJECT_NULL) {
        fprintf(stderr, "AppleParavirtGPU not found\n");
        return 1;
    }

    const void *keys[] = {
        CFSTR("IOGLBundleName"),
        CFSTR("IOGLESBundleName"),
    };
    const void *values[] = {
        CFSTR("AppleMetalOpenGLRenderer"),
        CFSTR("AppleMetalGLRenderer"),
    };
    CFDictionaryRef properties = CFDictionaryCreate(
        kCFAllocatorDefault, keys, values, 2,
        &kCFTypeDictionaryKeyCallBacks,
        &kCFTypeDictionaryValueCallBacks);
    kern_return_t result = IORegistryEntrySetCFProperties(service, properties);
    printf("IORegistryEntrySetCFProperties: 0x%x\n", result);
    CFRelease(properties);
    IOObjectRelease(service);
    return result == KERN_SUCCESS ? 0 : 2;
}
