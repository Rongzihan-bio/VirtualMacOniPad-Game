#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <errno.h>
#import <os/log.h>
#import <ptrauth.h>
#import <stdint.h>
#import <stdlib.h>
#import <string.h>
#import <sys/mman.h>
#import <unistd.h>

static dispatch_data_t gSerializedMetallib;
static os_log_t gLog;

static id NewLibraryFromPreloadedData(id device,
                                      SEL selector,
                                      NSBundle *bundle,
                                      NSError **error)
    __attribute__((ns_returns_retained));

static id NewLibraryFromPreloadedData(id device,
                                      SEL selector,
                                      NSBundle *bundle,
                                      NSError **error) {
    (void)selector;
    (void)bundle;
    if (gSerializedMetallib == nil) {
        if (error != NULL) {
            *error = [NSError errorWithDomain:@"PVGMetallibShim"
                                         code:1
                                     userInfo:@{
                                         NSLocalizedDescriptionKey:
                                             @"default.metallib was not preloaded"
                                     }];
        }
        return nil;
    }
    return [device newLibraryWithData:gSerializedMetallib error:error];
}

static BOOL PreloadMetallib(void) {
    NSURL *url = [[NSBundle mainBundle]
        URLForResource:@"default"
        withExtension:@"metallib"];
    if (url == nil) {
        Class pvgDevice = NSClassFromString(@"_PGDevice");
        url = [[NSBundle bundleForClass:pvgDevice]
            URLForResource:@"default"
            withExtension:@"metallib"];
    }

    NSData *data = [NSData dataWithContentsOfURL:url];
    if (data.length == 0) {
        os_log_error(gLog, "could not preload default.metallib");
        return NO;
    }

    void *bytes = malloc(data.length);
    if (bytes == NULL) {
        os_log_error(gLog, "could not allocate %lu metallib bytes", data.length);
        return NO;
    }
    memcpy(bytes, data.bytes, data.length);
    gSerializedMetallib =
        dispatch_data_create(bytes,
                             data.length,
                             NULL,
                             DISPATCH_DATA_DESTRUCTOR_FREE);
    os_log(gLog, "preloaded %lu default.metallib bytes", data.length);
    return gSerializedMetallib != nil;
}

static BOOL PatchCall(void *imageBase,
                      uintptr_t offset,
                      uint32_t expectedInstruction,
                      uintptr_t targetAddress) {
    uint32_t *instruction = (uint32_t *)((uintptr_t)imageBase + offset);
    if (*instruction != expectedInstruction) {
        os_log_error(gLog,
                     "PVG instruction mismatch at 0x%lx: %08x != %08x",
                     offset,
                     *instruction,
                     expectedInstruction);
        return NO;
    }

    uintptr_t callAddress = (uintptr_t)instruction;
    intptr_t delta = (intptr_t)targetAddress - (intptr_t)callAddress;
    if ((delta & 3) != 0 ||
        delta < -(1LL << 27) ||
        delta >= (1LL << 27)) {
        os_log_error(gLog,
                     "PVG shim branch is out of range: %p -> %p",
                     instruction,
                     (void *)targetAddress);
        return NO;
    }

    uintptr_t page =
        callAddress & ~((uintptr_t)getpagesize() - 1);
    if (mprotect((void *)page,
                 (size_t)getpagesize(),
                 PROT_READ | PROT_WRITE) != 0) {
        os_log_error(gLog, "PVG text write failed: errno %d", errno);
        return NO;
    }

    *instruction =
        0x94000000U | ((uint32_t)(delta >> 2) & 0x03ffffffU);
    __builtin___clear_cache(
        (char *)instruction,
        (char *)instruction + sizeof(*instruction));
    if (mprotect((void *)page,
                 (size_t)getpagesize(),
                 PROT_READ | PROT_EXEC) != 0) {
        os_log_error(gLog, "PVG text protect failed: errno %d", errno);
        return NO;
    }
    return YES;
}

__attribute__((constructor))
static void InstallPVGMetallibShim(void) {
    @autoreleasepool {
        gLog = os_log_create("com.mac.virtual", "pvg-metallib-shim");
        if (!PreloadMetallib()) {
            return;
        }

        Class cls = NSClassFromString(@"_PGDevice");
        Method setup = class_getInstanceMethod(
            cls, NSSelectorFromString(@"setupBlitPipelines"));
        Dl_info image = {0};
        if (setup == NULL ||
            dladdr((const void *)method_getImplementation(setup), &image) == 0) {
            os_log_error(gLog, "could not locate ParavirtualizedGraphics");
            return;
        }

        uintptr_t target = (uintptr_t)ptrauth_strip(
            (void *)NewLibraryFromPreloadedData,
            ptrauth_key_function_pointer);

        // macOS 13.2.1 (22D68), PVG UUID
        // 732073AB-34E5-38C9-A919-53B628977BDB.
        BOOL displayPatched =
            PatchCall(image.dli_fbase, 0xe6d8, 0x9400bffaU, target);
        BOOL blitPatched =
            PatchCall(image.dli_fbase, 0xed24, 0x9400be67U, target);
        if (displayPatched && blitPatched) {
            os_log(gLog, "installed macOS 13.2.1 PVG metallib shim");
        }
    }
}
