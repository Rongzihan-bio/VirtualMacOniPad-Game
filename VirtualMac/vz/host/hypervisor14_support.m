// libdispatch compatibility needed by macOS 11 Hypervisor on iPadOS 14.
// This follows Apple's Big Sur libdispatch _os_object_alloc implementation:
// allocate an OS_object instance of the requested total size. The reference
// count fields are initialized explicitly because this compatibility object
// is created outside libdispatch's normal constructor path.
// Original source (libdispatch-1271.120.2):
// https://github.com/apple-oss-distributions/libdispatch/blob/libdispatch-1271.120.2/src/object.m#L50-L58
// https://github.com/apple-oss-distributions/libdispatch/blob/libdispatch-1271.120.2/src/object.m#L93-L106

#import <objc/runtime.h>

#include <stddef.h>
#include <stdint.h>

struct os_object_header {
    void *isa;
    int32_t ref_count;
    int32_t xref_count;
};

void *_os_object_alloc(const void *requested_class, size_t size) {
    if (size < sizeof(struct os_object_header))
        return NULL;
    Class cls = requested_class ? (Class)requested_class
                                : objc_getClass("OS_object");
    if (!cls)
        return NULL;
    size_t base_size = class_getInstanceSize(cls);
    if (base_size > size)
        return NULL;
    id object = class_createInstance(cls, size - base_size);
    if (!object)
        return NULL;
    struct os_object_header *header = (struct os_object_header *)object;
    header->ref_count = 1;
    header->xref_count = 1;
    return object;
}
