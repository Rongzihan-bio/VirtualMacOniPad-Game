#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <objc/message.h>

static id send_object(id object, const char *selector_name) {
    SEL selector = sel_registerName(selector_name);
    return [object respondsToSelector:selector]
        ? ((id (*)(id, SEL))objc_msgSend)(object, selector)
        : nil;
}

int main(void) {
    @autoreleasepool {
        for (id<MTLDevice> device in MTLCopyAllDevices()) {
            printf("device=%p class=%s name=%s registryID=0x%llx\n",
                   device, object_getClassName(device),
                   device.name.UTF8String, device.registryID);
            const char *selector_names[] = {"vendorName", "className"};
            for (NSUInteger index = 0; index < 2; index++) {
                const char *selector_name = selector_names[index];
                id value = send_object(device, selector_name);
                printf("  %s=%s\n", selector_name,
                       value ? [[value description] UTF8String] : "(missing)");
            }
            for (NSUInteger family = 1000; family <= 1012; family++)
                printf("  supportsFamily:%lu=%d\n", (unsigned long)family,
                       [device supportsFamily:(MTLGPUFamily)family]);
            for (NSUInteger family = 2000; family <= 2004; family++)
                printf("  supportsFamily:%lu=%d\n", (unsigned long)family,
                       [device supportsFamily:(MTLGPUFamily)family]);
            for (NSUInteger family = 3000; family <= 3004; family++)
                printf("  supportsFamily:%lu=%d\n", (unsigned long)family,
                       [device supportsFamily:(MTLGPUFamily)family]);
        }
    }
    return 0;
}
