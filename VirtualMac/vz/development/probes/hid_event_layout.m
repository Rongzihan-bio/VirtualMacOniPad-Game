#import <CoreFoundation/CoreFoundation.h>
#include <dlfcn.h>
#include <malloc/malloc.h>
#include <stdint.h>
#include <stdio.h>

typedef CFTypeRef (*CreateKeyboardEventFn)(
    CFAllocatorRef, uint64_t, uint32_t, uint32_t, Boolean, uint32_t);
typedef uint32_t (*GetEventTypeFn)(CFTypeRef);

static void dumpBytes(const char *label, const void *object, size_t limit) {
    size_t allocationSize = malloc_size(object);
    size_t dumpSize = allocationSize < limit ? allocationSize : limit;
    printf("%s=%p allocation=%zu dump=%zu\n",
           label, object, allocationSize, dumpSize);
    const uint8_t *bytes = (const uint8_t *)object;
    for (size_t offset = 0; offset < dumpSize; offset += 16) {
        printf("%04zx:", offset);
        size_t lineEnd = offset + 16 < dumpSize ? offset + 16 : dumpSize;
        for (size_t i = offset; i < lineEnd; i++)
            printf(" %02x", bytes[i]);
        putchar('\n');
    }
}

int main(void) {
    CreateKeyboardEventFn createKeyboardEvent =
        (CreateKeyboardEventFn)dlsym(RTLD_DEFAULT,
                                     "IOHIDEventCreateKeyboardEvent");
    GetEventTypeFn getEventType =
        (GetEventTypeFn)dlsym(RTLD_DEFAULT, "IOHIDEventGetType");
    if (!createKeyboardEvent || !getEventType) {
        fprintf(stderr, "IOHID event functions unavailable: %s\n", dlerror());
        return 1;
    }

    CFTypeRef event = createKeyboardEvent(
        kCFAllocatorDefault, 0, 0x07, 0x04, true, 0);
    if (!event) {
        fprintf(stderr, "IOHIDEventCreateKeyboardEvent returned NULL\n");
        return 1;
    }

    printf("type=%u\n", getEventType(event));
    dumpBytes("event", event, 512);
    const void *payload = *(const void *const *)((const uint8_t *)event + 0x68);
    if (payload)
        dumpBytes("payload", payload, 1024);
    CFShow(event);
    CFRelease(event);
    return 0;
}
