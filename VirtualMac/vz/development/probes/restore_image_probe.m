#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include <dlfcn.h>
#import "../../host/NSViewShim.h"

static BOOL loadImage(NSString *path)
{
    void *image = dlopen(path.fileSystemRepresentation, RTLD_NOW | RTLD_GLOBAL);
    if (!image) {
        fprintf(stderr, "DLOPEN_FAILED\t%s\t%s\n",
                path.fileSystemRepresentation, dlerror());
        return NO;
    }
    printf("DLOPEN_OK\t%s\n", path.fileSystemRepresentation);
    return YES;
}

int main(int argc, const char *argv[])
{
    @autoreleasepool {
        setlinebuf(stdout);
        setlinebuf(stderr);
        if (argc != 2) {
            fprintf(stderr, "usage: restore-image-probe <restore.ipsw>\n");
            return 2;
        }

        // Realize the AppKit ABI shim before dyld registers Virtualization's
        // Objective-C classes. Several display classes inherit from NSView;
        // leaving this lazy makes objc reject the image's complete class set,
        // including unrelated restore-image classes.
        printf("FAKE_CLASS\tNSView\tsuperclass=%s\tinstance-size=%zu\n",
               class_getName(class_getSuperclass([NSView class])),
               class_getInstanceSize([NSView class]));

        NSString *root = @"/var/root/VirtualMac";
        NSString *installer = [root stringByAppendingPathComponent:
            @"payload/Installation.xpc/Contents/MacOS/"
             "com.apple.Virtualization.Installation"];
        setenv("VZ_INSTALLATION_BIN", installer.fileSystemRepresentation, 1);

        NSArray<NSString *> *images = @[
            [root stringByAppendingPathComponent:
                @"install/VZHostCompat.dylib"],
            [root stringByAppendingPathComponent:
                @"payload/Frameworks/Hypervisor.framework/Hypervisor"],
            [root stringByAppendingPathComponent:
                @"payload/Frameworks/ParavirtualizedGraphics.framework/"
                 "ParavirtualizedGraphics"],
            [root stringByAppendingPathComponent:
                @"payload/Frameworks/Virtualization.framework/Virtualization"],
        ];
        for (NSString *image in images)
            if (!loadImage(image))
                return 1;

        Class virtualMachineClass = objc_getClass("VZVirtualMachine");
        Method startMethod = class_getInstanceMethod(
            virtualMachineClass,
            sel_registerName("startWithCompletionHandler:"));
        Dl_info virtualizationInfo = {0};
        if (!startMethod ||
            !dladdr((const void *)method_getImplementation(startMethod),
                    &virtualizationInfo) ||
            !virtualizationInfo.dli_fbase) {
            fprintf(stderr, "VZ_IMAGE_BASE_UNAVAILABLE\n");
            return 1;
        }
        int (*rebindVirtualization)(void *) =
            (int (*)(void *))dlsym(RTLD_DEFAULT, "vz_rebind_virtualization");
        int rebindResult = rebindVirtualization
            ? rebindVirtualization(virtualizationInfo.dli_fbase) : -1;
        printf("VZ_REBIND\tbase=%p\tresult=%d\n",
               virtualizationInfo.dli_fbase, rebindResult);
        if (rebindResult != 0)
            return 1;

        Class restoreImageClass = objc_getClass("VZMacOSRestoreImage");
        SEL loadSelector = sel_registerName("loadFileURL:completionHandler:");
        if (!restoreImageClass ||
            !class_getClassMethod(restoreImageClass, loadSelector)) {
            fprintf(stderr, "RESTORE_CLASS_UNAVAILABLE\n");
            return 1;
        }

        NSURL *url = [NSURL fileURLWithPath:@(argv[1])];
        printf("RESTORE_LOAD_BEGIN\t%s\n", url.path.UTF8String);
        void (^completion)(id, NSError *) = ^(id image, NSError *error) {
            if (!image) {
                fprintf(stderr, "RESTORE_LOAD_FAILED\t%s\n",
                        error.description.UTF8String ?: "(unknown)");
                fflush(NULL);
                exit(1);
            }
            NSString *build = [image valueForKey:@"buildVersion"];
            NSNumber *supported = [image valueForKey:@"supported"];
            id requirements =
                [image valueForKey:@"mostFeaturefulSupportedConfiguration"];
            id model = [requirements valueForKey:@"hardwareModel"];
            NSData *modelData = [model valueForKey:@"dataRepresentation"];
            NSNumber *minimumCPU =
                [requirements valueForKey:@"minimumSupportedCPUCount"];
            NSNumber *minimumMemory =
                [requirements valueForKey:@"minimumSupportedMemorySize"];
            printf("RESTORE_LOAD_OK\tbuild=%s\tsupported=%d\n",
                   build.UTF8String ?: "(unknown)", supported.boolValue);
            printf("RESTORE_REQUIREMENTS\tcpu=%llu\tmemory=%llu\t"
                   "hardware-model-bytes=%llu\n",
                   minimumCPU.unsignedLongLongValue,
                   minimumMemory.unsignedLongLongValue,
                   (unsigned long long)modelData.length);
            fflush(NULL);
            exit(requirements && modelData.length ? 0 : 1);
        };
        ((void (*)(id, SEL, NSURL *, id))objc_msgSend)(
            restoreImageClass, loadSelector, url, completion);
        dispatch_main();
    }
}
