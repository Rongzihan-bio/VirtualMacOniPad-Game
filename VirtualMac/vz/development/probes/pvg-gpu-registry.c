#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <stdio.h>

int main(void) {
    io_iterator_t iterator = IO_OBJECT_NULL;
    kern_return_t result = IOServiceGetMatchingServices(
        kIOMainPortDefault, IOServiceMatching("AppleARMIODevice"),
        &iterator);
    if (result != KERN_SUCCESS)
        return 1;

    io_registry_entry_t entry;
    while ((entry = IOIteratorNext(iterator)) != IO_OBJECT_NULL) {
        io_name_t name = {0};
        IORegistryEntryGetName(entry, name);
        CFMutableDictionaryRef properties = NULL;
        result = IORegistryEntryCreateCFProperties(
            entry, &properties, kCFAllocatorDefault, 0);
        if (result == KERN_SUCCESS && properties != NULL) {
            CFTypeRef compatible = CFDictionaryGetValue(
                properties, CFSTR("compatible"));
            CFTypeRef deviceType = CFDictionaryGetValue(
                properties, CFSTR("device_type"));
            if (compatible != NULL || deviceType != NULL) {
                fprintf(stderr, "%s compatible=", name);
                CFShow(compatible);
                fprintf(stderr, "%s device_type=", name);
                CFShow(deviceType);
            }
            CFRelease(properties);
        }
        IOObjectRelease(entry);
    }
    IOObjectRelease(iterator);
    return 0;
}
