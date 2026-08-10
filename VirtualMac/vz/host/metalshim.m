// Metal shim for the iOS-ported VZ VMM service. macOS Metal exports MTLCopyAllDevices
// (multi-GPU enumeration); iOS Metal does not (single GPU). The extracted VMM binds it,
// so dyld fails the load. We build a tiny arm64e dylib that re-exports the device's real
// Metal (so every other Metal symbol the VMM needs resolves through us) and defines the
// few macOS-only entry points the VMM imports, backed by the iOS single-device API.
// Wire-up: change the VMM binary's Metal LC_LOAD_DYLIB to /var/root/metalshim.ios.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include <stdlib.h>
#include <string.h>

static id (*gNewBufferWithLength)(id, SEL, NSUInteger, MTLResourceOptions);
static id (*gNewBufferWithBytes)(
    id, SEL, const void *, NSUInteger, MTLResourceOptions);
static id (*gNewBufferWithBytesNoCopy)(
    id, SEL, void *, NSUInteger, MTLResourceOptions,
    void (^)(void *, NSUInteger));
static id (*gNewTextureWithDescriptor)(
    id, SEL, MTLTextureDescriptor *);
static id (*gNewTextureWithDescriptorIOSurface)(
    id, SEL, MTLTextureDescriptor *, void *, NSUInteger);
static void (*gSetTextureStorageMode)(id, SEL, MTLStorageMode);
static void (*gSetTexturePixelFormat)(id, SEL, MTLPixelFormat);
static void (*gSetHeapStorageMode)(id, SEL, MTLStorageMode);
static BOOL gInstalledSharedBufferCompatibility;
static unsigned long gMacCompressedTextureCount;

static BOOL DebugLoggingEnabled(void) {
    static BOOL enabled;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        const char *value = getenv("VZ_DEBUG_LOGGING");
        enabled = value && value[0] && strcmp(value, "0") != 0;
    });
    return enabled;
}

// macOS: NSArray<id<MTLDevice>> *MTLCopyAllDevices(void)  — +1 (the "Copy" rule).
// iOS has exactly one GPU, so return the system default in a one-element array.
NSArray *MTLCopyAllDevices(void) {
    id dev = MTLCreateSystemDefaultDevice();
    NSArray *a = dev ? @[dev] : @[];
    return [a retain];  // built without ARC; "Copy" rule => return +1
}

// macOS-only; iOS logs "Ignoring call MTLSetShaderCachePath(...)" — so a no-op matches iOS behavior.
void MTLSetShaderCachePath(const char *path) { (void)path; }

// The macOS 13 VMM selects a Metal device by querying this macOS MTLDevice
// property. iOS has one integrated GPU and its concrete AGX device class does
// not implement the selector. Report the iPad GPU as integrated/non-low-power
// so the unmodified VMM can complete device selection.
static BOOL iPadMetalDeviceIsLowPower(id self, SEL selector) {
    (void)self;
    (void)selector;
    return NO;
}

static BOOL iPadMetalDeviceIsRemovable(id self, SEL selector) {
    (void)self;
    (void)selector;
    return NO;
}

static BOOL iPadMetalDeviceIsHeadless(id self, SEL selector) {
    (void)self;
    (void)selector;
    return NO;
}

static BOOL iPadMetalDeviceIsDepth24Stencil8PixelFormatSupported(
    id self, SEL selector) {
    (void)self;
    (void)selector;
    // Apple-family GPUs use 32-bit depth formats. This macOS compatibility
    // query is absent from iOS's MTLDevice surface, and reporting NO makes
    // PVG advertise the formats the iPad GPU actually supports.
    return NO;
}

static BOOL iPadMetalDeviceIsFramebufferReadSupported(id self, SEL selector) {
    (void)self;
    (void)selector;
    // Apple GPUs support framebuffer fetch. macOS exposes this private
    // capability query, while the iOS MTLDevice protocol omits the selector.
    return YES;
}

static BOOL iPadMetalDeviceReturnsYes(id self, SEL selector) {
    (void)self;
    (void)selector;
    return YES;
}

static NSUInteger iPadMetalDeviceMaxTextureDimension(id self, SEL selector) {
    (void)self;
    (void)selector;
    return 16384;
}

static NSUInteger iPadMetalDeviceMaxTotalThreads(id self, SEL selector) {
    (void)self;
    (void)selector;
    return 1024;
}

static void iPadSamplerSetReductionMode(id self, SEL selector,
                                        NSUInteger reductionMode) {
    (void)self;
    (void)selector;
    (void)reductionMode;
    // Sampler reduction mode is a macOS-only descriptor property.
    // The default weighted-average mode is value zero.
}

static NSUInteger iPadSamplerReductionMode(id self, SEL selector) {
    (void)self;
    (void)selector;
    return 0;
}

static void AddMetalMethodIfMissing(id device, NSString *name,
                                    IMP implementation,
                                    const char *types) {
    SEL selector = NSSelectorFromString(name);
    if (![device respondsToSelector:selector]) {
        class_addMethod([device class], selector, implementation, types);
    }
}

static MTLResourceOptions iPadMetalResourceOptions(
    MTLResourceOptions options) {
    // MTLStorageModeManaged is macOS-only. Apple Silicon has unified memory,
    // and current Metal headers explicitly direct Apple Silicon clients to
    // Shared instead.
    const MTLResourceOptions managed = 1UL << MTLResourceStorageModeShift;
    if ((options & MTLResourceStorageModeMask) == managed) {
        options &= ~MTLResourceStorageModeMask;
        options |= MTLResourceStorageModeShared;
    }
    return options;
}

static MTLStorageMode iPadMetalStorageMode(MTLStorageMode storageMode) {
    // Raw value 1 is MTLStorageModeManaged on macOS.
    return storageMode == (MTLStorageMode)1
        ? MTLStorageModeShared
        : storageMode;
}

static void iPadSetTextureStorageMode(id self, SEL selector,
                                     MTLStorageMode storageMode) {
    gSetTextureStorageMode(
        self, selector, iPadMetalStorageMode(storageMode));
}

static BOOL IsMacBCPixelFormat(MTLPixelFormat pixelFormat) {
    // BC1 through BC7 occupy the Mac-only Metal values 130...153.
    // iPadOS's descriptor validator rejects the enum.
    return (NSUInteger)pixelFormat >= 130 && (NSUInteger)pixelFormat <= 153;
}

static MTLPixelFormat iPadCompressedFallback(MTLPixelFormat pixelFormat) {
    // Keep each format's 4x4 block dimensions and byte count so guest upload
    // pitches, mip offsets, and buffer sizes remain valid. iPadOS 16.3 rejects
    // BC formats before the GPU driver; its native ETC/EAC/ASTC formats are a
    // safe crash-prevention fallback for effects and transient image textures.
    switch ((NSUInteger)pixelFormat) {
        case 130: return (MTLPixelFormat)180; // BC1 -> ETC2 RGB8
        case 131: return (MTLPixelFormat)181; // BC1 sRGB -> ETC2 RGB8 sRGB
        case 140: return (MTLPixelFormat)170; // BC4 unorm -> EAC R11 unorm
        case 141: return (MTLPixelFormat)172; // BC4 snorm -> EAC R11 snorm
        case 142: return (MTLPixelFormat)174; // BC5 unorm -> EAC RG11 unorm
        case 143: return (MTLPixelFormat)176; // BC5 snorm -> EAC RG11 snorm
        case 133: case 135: case 153:
            return (MTLPixelFormat)186;       // 16-byte sRGB -> ASTC 4x4 sRGB
        case 150: case 151:
            return (MTLPixelFormat)222;       // BC6H -> ASTC 4x4 HDR
        default:
            return (MTLPixelFormat)204;       // 16-byte linear -> ASTC 4x4 LDR
    }
}

static void iPadSetTexturePixelFormat(id self, SEL selector,
                                     MTLPixelFormat pixelFormat) {
    if (!IsMacBCPixelFormat(pixelFormat)) {
        gSetTexturePixelFormat(self, selector, pixelFormat);
        return;
    }
    MTLPixelFormat fallback = iPadCompressedFallback(pixelFormat);
    if (DebugLoggingEnabled()) {
        unsigned long count = __sync_add_and_fetch(
            &gMacCompressedTextureCount, 1);
        if (count <= 20 || count % 100 == 0)
            fprintf(stderr, "[metalshim] mapped Mac BC format=%lu to iPad format=%lu count=%lu\n",
                    (unsigned long)pixelFormat, (unsigned long)fallback, count);
    }
    gSetTexturePixelFormat(self, selector, fallback);
}

static void iPadSetHeapStorageMode(id self, SEL selector,
                                  MTLStorageMode storageMode) {
    gSetHeapStorageMode(
        self, selector, iPadMetalStorageMode(storageMode));
}

static void NormalizeTextureDescriptor(MTLTextureDescriptor *descriptor) {
    if ((NSUInteger)descriptor.storageMode == 1) {
        descriptor.storageMode = MTLStorageModeShared;
    }
}

static id iPadNewTextureWithDescriptor(
    id self, SEL selector, MTLTextureDescriptor *descriptor) {
    NormalizeTextureDescriptor(descriptor);
    id texture = gNewTextureWithDescriptor(self, selector, descriptor);
    if (DebugLoggingEnabled() && IsMacBCPixelFormat(descriptor.pixelFormat))
        fprintf(stderr, "[metalshim] BC texture format=%lu %lux%lu -> %p\n",
                (unsigned long)descriptor.pixelFormat,
                (unsigned long)descriptor.width,
                (unsigned long)descriptor.height, texture);
    return texture;
}

static id iPadNewTextureWithDescriptorIOSurface(
    id self, SEL selector, MTLTextureDescriptor *descriptor,
    void *surface, NSUInteger plane) {
    NormalizeTextureDescriptor(descriptor);
    return gNewTextureWithDescriptorIOSurface(
        self, selector, descriptor, surface, plane);
}

static void iPadSharedBufferDidModifyRange(id self, SEL selector,
                                           NSRange range) {
    (void)self;
    (void)selector;
    (void)range;
    // Shared memory is coherent on Apple Silicon; this macOS managed-memory
    // flush has no work to perform on iOS.
}

static id InstallSharedBufferCompatibility(id buffer) {
    if (buffer != nil &&
        __sync_bool_compare_and_swap(
            &gInstalledSharedBufferCompatibility, NO, YES)) {
        Method method = class_getInstanceMethod(
            [buffer class], NSSelectorFromString(@"didModifyRange:"));
        if (method != NULL) {
            method_setImplementation(
                method, (IMP)iPadSharedBufferDidModifyRange);
        }
    }
    return buffer;
}

static id iPadNewBufferWithLength(id self, SEL selector, NSUInteger length,
                                  MTLResourceOptions options) {
    return InstallSharedBufferCompatibility(gNewBufferWithLength(
        self, selector, length, iPadMetalResourceOptions(options)));
}

static id iPadNewBufferWithBytes(id self, SEL selector, const void *bytes,
                                 NSUInteger length,
                                 MTLResourceOptions options) {
    return InstallSharedBufferCompatibility(gNewBufferWithBytes(
        self, selector, bytes, length, iPadMetalResourceOptions(options)));
}

static id iPadNewBufferWithBytesNoCopy(
    id self, SEL selector, void *bytes, NSUInteger length,
    MTLResourceOptions options, void (^deallocator)(void *, NSUInteger)) {
    return InstallSharedBufferCompatibility(gNewBufferWithBytesNoCopy(
        self, selector, bytes, length, iPadMetalResourceOptions(options),
        deallocator));
}

static IMP ReplaceMetalMethod(Class cls, NSString *name, IMP replacement) {
    SEL selector = NSSelectorFromString(name);
    Method method = class_getInstanceMethod(cls, selector);
    if (method == NULL) {
        return NULL;
    }
    return method_setImplementation(method, replacement);
}

__attribute__((constructor))
static void InstallMacMetalDeviceCompatibility(void) {
    @autoreleasepool {
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        if (device == nil) {
            return;
        }
        class_addMethod([device class],
                        NSSelectorFromString(@"isLowPower"),
                        (IMP)iPadMetalDeviceIsLowPower,
                        "B@:");
        class_addMethod([device class],
                        NSSelectorFromString(@"isRemovable"),
                        (IMP)iPadMetalDeviceIsRemovable,
                        "B@:");
        class_addMethod([device class],
                        NSSelectorFromString(@"isHeadless"),
                        (IMP)iPadMetalDeviceIsHeadless,
                        "B@:");
        class_addMethod(
            [device class],
            NSSelectorFromString(
                @"isDepth24Stencil8PixelFormatSupported"),
            (IMP)iPadMetalDeviceIsDepth24Stencil8PixelFormatSupported,
            "B@:");
        class_addMethod(
            [device class],
            NSSelectorFromString(@"isFramebufferReadSupported"),
            (IMP)iPadMetalDeviceIsFramebufferReadSupported,
            "B@:");
        AddMetalMethodIfMissing(
            device, @"isRGB10A2GammaSupported",
            (IMP)iPadMetalDeviceReturnsYes, "B@:");
        AddMetalMethodIfMissing(
            device, @"supportsExtendedXR10Formats",
            (IMP)iPadMetalDeviceReturnsYes, "B@:");
        AddMetalMethodIfMissing(
            device, @"supportsNativeHardwareFP16",
            (IMP)iPadMetalDeviceReturnsYes, "B@:");
        AddMetalMethodIfMissing(
            device, @"maxTextureWidth2D",
            (IMP)iPadMetalDeviceMaxTextureDimension, "Q@:");
        AddMetalMethodIfMissing(
            device, @"maxTextureHeight2D",
            (IMP)iPadMetalDeviceMaxTextureDimension, "Q@:");
        AddMetalMethodIfMissing(
            device, @"maxTotalThreadsPerThreadgroup",
            (IMP)iPadMetalDeviceMaxTotalThreads, "Q@:");
        gNewBufferWithLength =
            (id (*)(id, SEL, NSUInteger, MTLResourceOptions))
                ReplaceMetalMethod(
                    [device class],
                    @"newBufferWithLength:options:",
                    (IMP)iPadNewBufferWithLength);
        gNewBufferWithBytes =
            (id (*)(id, SEL, const void *, NSUInteger, MTLResourceOptions))
                ReplaceMetalMethod(
                    [device class],
                    @"newBufferWithBytes:length:options:",
                    (IMP)iPadNewBufferWithBytes);
        gNewBufferWithBytesNoCopy =
            (id (*)(id, SEL, void *, NSUInteger, MTLResourceOptions,
                    void (^)(void *, NSUInteger)))
                ReplaceMetalMethod(
                    [device class],
                    @"newBufferWithBytesNoCopy:length:options:deallocator:",
                    (IMP)iPadNewBufferWithBytesNoCopy);
        gNewTextureWithDescriptor =
            (id (*)(id, SEL, MTLTextureDescriptor *))ReplaceMetalMethod(
                [device class],
                @"newTextureWithDescriptor:",
                (IMP)iPadNewTextureWithDescriptor);
        gNewTextureWithDescriptorIOSurface =
            (id (*)(id, SEL, MTLTextureDescriptor *, void *, NSUInteger))
                ReplaceMetalMethod(
                    [device class],
                    @"newTextureWithDescriptor:iosurface:plane:",
                    (IMP)iPadNewTextureWithDescriptorIOSurface);

        MTLTextureDescriptor *textureDescriptor =
            [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:
                                      MTLPixelFormatBGRA8Unorm
                                                             width:1
                                                            height:1
                                                         mipmapped:NO];
        gSetTextureStorageMode =
            (void (*)(id, SEL, MTLStorageMode))ReplaceMetalMethod(
                [textureDescriptor class],
                @"setStorageMode:",
                (IMP)iPadSetTextureStorageMode);
        gSetTexturePixelFormat =
            (void (*)(id, SEL, MTLPixelFormat))ReplaceMetalMethod(
                [textureDescriptor class], @"setPixelFormat:",
                (IMP)iPadSetTexturePixelFormat);

        MTLHeapDescriptor *heapDescriptor = [[MTLHeapDescriptor alloc] init];
        gSetHeapStorageMode =
            (void (*)(id, SEL, MTLStorageMode))ReplaceMetalMethod(
                [heapDescriptor class],
                @"setStorageMode:",
                (IMP)iPadSetHeapStorageMode);

        MTLSamplerDescriptor *samplerDescriptor =
            [[MTLSamplerDescriptor alloc] init];
        AddMetalMethodIfMissing(
            samplerDescriptor, @"setReductionMode:",
            (IMP)iPadSamplerSetReductionMode, "v@:Q");
        AddMetalMethodIfMissing(
            samplerDescriptor, @"reductionMode",
            (IMP)iPadSamplerReductionMode, "Q@:");
    }
}
