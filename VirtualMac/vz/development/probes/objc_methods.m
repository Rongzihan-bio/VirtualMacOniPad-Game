#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <UIKit/UIKit.h>
#import "../../host/NSViewShim.h"
#import <dlfcn.h>
#import <objc/runtime.h>
#import <objc/message.h>

int main(int argc, const char *argv[])
{
    @autoreleasepool {
        if (argc < 3) {
            fprintf(stderr, "usage: %s /path/to/image [...] ClassName\n", argv[0]);
            return 2;
        }

        printf("FAKE_CLASS\tNSView\tsuperclass=%s\tinstance-size=%zu\n",
               class_getName(class_getSuperclass([NSView class])),
               class_getInstanceSize([NSView class]));
        for (int i = 1; i < argc - 1; i++) {
            void *image = dlopen(argv[i], RTLD_NOW | RTLD_GLOBAL);
            if (!image) {
                fprintf(stderr, "dlopen %s failed: %s\n", argv[i], dlerror());
                return 1;
            }
        }

        const char *className = argv[argc - 1];
        Class cls = objc_getClass(className);
        const char *metalDevice = getenv("VZ_METAL_DEVICE");
        if (metalDevice && metalDevice[0] && metalDevice[0] != '0') {
            id device = MTLCreateSystemDefaultDevice();
            printf("METAL_DEVICE\t%s\t%p\n",
                   device ? class_getName(object_getClass(device)) : "-",
                   device);
            if (device) {
                cls = object_getClass(device);
            }
        }
        if (!cls) {
            fprintf(stderr, "class not found: %s\n", className);
            return 1;
        }

        printf("CLASS\t%s\tinstance-size=%zu\tsuperclass=%s\n",
               class_getName(cls),
               class_getInstanceSize(cls),
               class_getSuperclass(cls) ? class_getName(class_getSuperclass(cls)) : "-");

        unsigned int count = 0;
        Method *methods = class_copyMethodList(cls, &count);
        for (unsigned int i = 0; i < count; i++) {
            SEL selector = method_getName(methods[i]);
            IMP implementation = method_getImplementation(methods[i]);
            Dl_info info = {0};
            dladdr((const void *)implementation, &info);
            uintptr_t offset = (uintptr_t)implementation - (uintptr_t)info.dli_fbase;
            printf("METHOD\t%s\t0x%llx\t%s\n",
                   sel_getName(selector),
                   (unsigned long long)offset,
                   info.dli_fname ?: "?");
        }
        free(methods);

        Ivar *ivars = class_copyIvarList(cls, &count);
        for (unsigned int i = 0; i < count; i++) {
            printf("IVAR\t%s\t%s\t%td\n",
                   ivar_getName(ivars[i]),
                   ivar_getTypeEncoding(ivars[i]),
                   ivar_getOffset(ivars[i]));
        }
        free(ivars);

        objc_property_t *properties = class_copyPropertyList(cls, &count);
        for (unsigned int i = 0; i < count; i++) {
            printf("PROPERTY\t%s\t%s\n",
                   property_getName(properties[i]),
                   property_getAttributes(properties[i]));
        }
        free(properties);

        const char *instantiate = getenv("VZ_INSTANTIATE");
        if (instantiate && instantiate[0] && instantiate[0] != '0') {
            @try {
                id object = ((id(*)(id, SEL, CGRect))objc_msgSend)(
                    [cls alloc], sel_registerName("initWithFrame:"),
                    CGRectMake(0, 0, 1024, 768));
                printf("INSTANCE\t%s\t%p\t%s\n",
                       className, object, [[object description] UTF8String]);
            } @catch (NSException *exception) {
                printf("INSTANCE_EXCEPTION\t%s\t%s\n",
                       [[exception name] UTF8String],
                       [[exception reason] UTF8String]);
                return 1;
            }
        }
    }
    return 0;
}
