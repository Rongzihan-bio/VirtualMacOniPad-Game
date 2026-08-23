#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <objc/message.h>
#import <objc/runtime.h>

#import "../../host/native_bc_texture_support.h"

static UITextView *gLogView;
static BOOL gDumpedTextureClasses;

static void ProbeLog(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
static void ProbeLog(NSString *format, ...) {
    va_list arguments;
    va_start(arguments, format);
    NSString *line = [[NSString alloc] initWithFormat:format arguments:arguments];
    va_end(arguments);
    fprintf(stderr, "[NativeBCProbe] %s\n", line.UTF8String);
    NSString *path = @"/tmp/NativeBCProbe.log";
    NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!handle) {
        [@"" writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
        handle = [NSFileHandle fileHandleForWritingAtPath:path];
    }
    [handle seekToEndOfFile];
    [handle writeData:[[line stringByAppendingString:@"\n"]
                       dataUsingEncoding:NSUTF8StringEncoding]];
    [handle closeFile];
    dispatch_async(dispatch_get_main_queue(), ^{
        gLogView.text = [(gLogView.text ?: @"") stringByAppendingFormat:@"%@\n", line];
    });
}

static void DumpTextureClassLayout(id texture) {
    if (gDumpedTextureClasses) return;
    gDumpedTextureClasses = YES;
    for (Class cls = object_getClass(texture); cls; cls = class_getSuperclass(cls)) {
        unsigned int count = 0;
        Ivar *ivars = class_copyIvarList(cls, &count);
        ProbeLog(@"CLASS %@ size=%lu ivars=%u", NSStringFromClass(cls),
                 (unsigned long)class_getInstanceSize(cls), count);
        for (unsigned int index = 0; index < count; ++index) {
            ProbeLog(@"  IVAR %s offset=%td type=%s", ivar_getName(ivars[index]),
                     ivar_getOffset(ivars[index]),
                     ivar_getTypeEncoding(ivars[index]));
        }
        free(ivars);
    }
}

static NSData *RepeatedBlock(const uint8_t block[16], NSUInteger width,
                             NSUInteger height) {
    NSUInteger count = ((width + 3) / 4) * ((height + 3) / 4);
    NSMutableData *data = [NSMutableData dataWithLength:count * 16];
    uint8_t *destination = data.mutableBytes;
    for (NSUInteger index = 0; index < count; ++index)
        memcpy(destination + index * 16, block, 16);
    return data;
}

static NSData *SolidMagentaBC3(NSUInteger width, NSUInteger height) {
    const uint8_t block[16] = {
        0xff, 0xff, 0, 0, 0, 0, 0, 0,
        0x1f, 0xf8, 0x1f, 0xf8, 0, 0, 0, 0,
    };
    return RepeatedBlock(block, width, height);
}

static NSData *SolidMagentaBC7(NSUInteger width, NSUInteger height) {
    // Generated from opaque magenta with Intel's ISPC Texture Compressor,
    // using GetProfile_alpha_slow().
    const uint8_t block[16] = {
        0x04, 0xfe, 0xff, 0xff, 0x7f, 0x00, 0x00, 0x00,
        0xe0, 0xff, 0xff, 0xff, 0x5f, 0xab, 0xaa, 0xaa,
    };
    return RepeatedBlock(block, width, height);
}

static BOOL SampleTexture(id<MTLDevice> device, id<MTLCommandQueue> queue,
                          id<MTLTexture> texture, NSString *label) {
    NSError *error = nil;
    id<MTLLibrary> library = [device newDefaultLibrary];
    id<MTLFunction> vertex = [library newFunctionWithName:@"native_bc_probe_vertex"];
    id<MTLFunction> fragment = [library newFunctionWithName:@"native_bc_probe_fragment"];
    MTLRenderPipelineDescriptor *pipelineDescriptor =
        [[MTLRenderPipelineDescriptor alloc] init];
    pipelineDescriptor.vertexFunction = vertex;
    pipelineDescriptor.fragmentFunction = fragment;
    pipelineDescriptor.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
    id<MTLRenderPipelineState> pipeline = [device
        newRenderPipelineStateWithDescriptor:pipelineDescriptor error:&error];
    if (!pipeline) {
        ProbeLog(@"%@ pipeline FAILED: %@", label, error);
        return NO;
    }

    MTLTextureDescriptor *targetDescriptor = [MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                     width:64 height:64 mipmapped:NO];
    targetDescriptor.storageMode = MTLStorageModeShared;
    targetDescriptor.usage = MTLTextureUsageRenderTarget;
    id<MTLTexture> target = [device newTextureWithDescriptor:targetDescriptor];
    id<MTLCommandBuffer> command = [queue commandBuffer];
    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = target;
    pass.colorAttachments[0].loadAction = MTLLoadActionClear;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
    id<MTLRenderCommandEncoder> encoder =
        [command renderCommandEncoderWithDescriptor:pass];
    [encoder setRenderPipelineState:pipeline];
    [encoder setFragmentTexture:texture atIndex:0];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [encoder endEncoding];
    [command commit];
    [command waitUntilCompleted];
    uint8_t pixel[4] = {};
    [target getBytes:pixel bytesPerRow:4
          fromRegion:MTLRegionMake2D(32, 32, 1, 1) mipmapLevel:0];
    BOOL passed = command.status == MTLCommandBufferStatusCompleted &&
        pixel[0] > 240 && pixel[1] < 15 && pixel[2] > 240 && pixel[3] > 240;
    ProbeLog(@"%@ sample status=%ld error=%@ pixel=%u,%u,%u,%u %@", label,
             (long)command.status, command.error, pixel[0], pixel[1], pixel[2],
             pixel[3], passed ? @"PASS" : @"FAIL");
    return passed;
}

static BOOL RunFormatProbe(id<MTLDevice> device, id<MTLCommandQueue> queue,
                           MTLPixelFormat format, NSUInteger width,
                           NSUInteger height, NSData *blocks,
                           BOOL useReplaceRegion) {
    NSString *label = [NSString stringWithFormat:@"format=%lu %lux%lu %@",
        (unsigned long)format, (unsigned long)width, (unsigned long)height,
        useReplaceRegion ? @"replaceRegion" : @"GPU-blit"];
    MTLTextureDescriptor *descriptor = [MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:format width:width height:height
        mipmapped:NO];
    descriptor.usage = MTLTextureUsageShaderRead;
    descriptor.storageMode = MTLStorageModePrivate;
    id<MTLTexture> texture = nil;
    @try {
        texture = [device newTextureWithDescriptor:descriptor];
    } @catch (NSException *exception) {
        ProbeLog(@"%@ create EXCEPTION %@: %@", label, exception.name,
                 exception.reason);
        return NO;
    }
    ProbeLog(@"%@ create texture=%@ class=%@", label, texture,
             NSStringFromClass([(id)texture class]));
    if (!texture) return NO;
    DumpTextureClassLayout(texture);

    NSUInteger rowBytes = ((width + 3) / 4) * 16;
    if (useReplaceRegion) {
        [texture replaceRegion:MTLRegionMake2D(0, 0, width, height)
                   mipmapLevel:0 withBytes:blocks.bytes bytesPerRow:rowBytes];
    } else {
        id<MTLBuffer> upload = [device newBufferWithBytes:blocks.bytes
                                                   length:blocks.length options:0];
        id<MTLCommandBuffer> command = [queue commandBuffer];
        id<MTLBlitCommandEncoder> blit = [command blitCommandEncoder];
        [blit copyFromBuffer:upload sourceOffset:0 sourceBytesPerRow:rowBytes
         sourceBytesPerImage:blocks.length sourceSize:MTLSizeMake(width, height, 1)
                   toTexture:texture destinationSlice:0 destinationLevel:0
          destinationOrigin:MTLOriginMake(0, 0, 0)];
        [blit endEncoding];
        [command commit];
        [command waitUntilCompleted];
        ProbeLog(@"%@ upload status=%ld error=%@", label,
                 (long)command.status, command.error);
        if (command.status != MTLCommandBufferStatusCompleted) return NO;
    }
    return SampleTexture(device, queue, texture, label);
}

static BOOL RunHeapProbe(id<MTLDevice> device, id<MTLCommandQueue> queue,
                         MTLPixelFormat format, NSData *blocks) {
    const NSUInteger width = 1024;
    const NSUInteger height = 512;
    NSString *label = [NSString stringWithFormat:@"format=%lu heap",
        (unsigned long)format];
    MTLTextureDescriptor *descriptor = [MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:format width:width height:height
        mipmapped:NO];
    descriptor.storageMode = MTLStorageModePrivate;
    descriptor.usage = MTLTextureUsageShaderRead;
    MTLSizeAndAlign sizeAndAlign = [device
        heapTextureSizeAndAlignWithDescriptor:descriptor];
    ProbeLog(@"%@ size=%llu align=%llu", label,
             (unsigned long long)sizeAndAlign.size,
             (unsigned long long)sizeAndAlign.align);
    if (!sizeAndAlign.size || !sizeAndAlign.align) return NO;
    MTLHeapDescriptor *heapDescriptor = [[MTLHeapDescriptor alloc] init];
    heapDescriptor.storageMode = MTLStorageModePrivate;
    heapDescriptor.size = sizeAndAlign.size;
    id<MTLHeap> heap = [device newHeapWithDescriptor:heapDescriptor];
    id<MTLTexture> texture = [heap newTextureWithDescriptor:descriptor];
    ProbeLog(@"%@ heap=%@ texture=%@", label, heap, texture);
    if (!texture) return NO;
    NSUInteger rowBytes = ((width + 3) / 4) * 16;
    id<MTLBuffer> upload = [device newBufferWithBytes:blocks.bytes
                                               length:blocks.length options:0];
    id<MTLCommandBuffer> command = [queue commandBuffer];
    id<MTLBlitCommandEncoder> blit = [command blitCommandEncoder];
    [blit copyFromBuffer:upload sourceOffset:0 sourceBytesPerRow:rowBytes
     sourceBytesPerImage:blocks.length sourceSize:MTLSizeMake(width, height, 1)
               toTexture:texture destinationSlice:0 destinationLevel:0
      destinationOrigin:MTLOriginMake(0, 0, 0)];
    [blit endEncoding];
    [command commit];
    [command waitUntilCompleted];
    if (command.status != MTLCommandBufferStatusCompleted) {
        ProbeLog(@"%@ upload FAIL status=%ld error=%@", label,
                 (long)command.status, command.error);
        return NO;
    }
    return SampleTexture(device, queue, texture, label);
}

static BOOL RunViewProbe(id<MTLDevice> device, id<MTLCommandQueue> queue,
                         MTLPixelFormat baseFormat, MTLPixelFormat viewFormat,
                         NSData *blocks) {
    const NSUInteger width = 64;
    const NSUInteger height = 64;
    NSString *label = [NSString stringWithFormat:@"format=%lu view=%lu",
        (unsigned long)baseFormat, (unsigned long)viewFormat];
    MTLTextureDescriptor *descriptor = [MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:baseFormat width:width height:height
        mipmapped:NO];
    descriptor.storageMode = MTLStorageModePrivate;
    descriptor.usage = MTLTextureUsageShaderRead | MTLTextureUsagePixelFormatView;
    id<MTLTexture> texture = [device newTextureWithDescriptor:descriptor];
    if (!texture) {
        ProbeLog(@"%@ base texture FAIL", label);
        return NO;
    }
    NSUInteger rowBytes = ((width + 3) / 4) * 16;
    [texture replaceRegion:MTLRegionMake2D(0, 0, width, height)
               mipmapLevel:0 withBytes:blocks.bytes bytesPerRow:rowBytes];
    id<MTLTexture> view = nil;
    @try {
        view = [texture newTextureViewWithPixelFormat:viewFormat];
    } @catch (NSException *exception) {
        ProbeLog(@"%@ EXCEPTION %@: %@", label, exception.name,
                 exception.reason);
        return NO;
    }
    ProbeLog(@"%@ base=%@ view=%@", label, texture, view);
    BOOL metadataPassed = view && view.pixelFormat == viewFormat;
    ProbeLog(@"%@ view metadata pixelFormat=%lu %@", label,
             (unsigned long)view.pixelFormat,
             metadataPassed ? @"PASS" : @"FAIL");
    return metadataPassed && SampleTexture(device, queue, view, label);
}

typedef struct {
    uint64_t words[7];
} ProbePixelFormatInfo;
typedef ProbePixelFormatInfo (*ProbePixelFormatInfoFn)(
    id<MTLDevice>, MTLPixelFormat);

static BOOL RunPixelFormatInfoProbe(id<MTLDevice> device,
                                    MTLPixelFormat format) {
    ProbePixelFormatInfoFn getInfo = (ProbePixelFormatInfoFn)dlsym(
        RTLD_DEFAULT, "MTLPixelFormatGetInfoForDevice");
    if (!getInfo) {
        ProbeLog(@"format=%lu frontend metadata symbol missing FAIL",
                 (unsigned long)format);
        return NO;
    }
    ProbePixelFormatInfo actual = getInfo(device, format);
    ProbePixelFormatInfo surrogate = getInfo(
        device, VZBCValidationSurrogate(format));
    BOOL passed = memcmp(&actual, &surrogate, sizeof(actual)) == 0;
    ProbeLog(@"format=%lu frontend metadata=%016llx,%016llx,%016llx,"
             "%016llx,%016llx,%016llx,%016llx %@",
             (unsigned long)format,
             actual.words[0], actual.words[1], actual.words[2],
             actual.words[3], actual.words[4], actual.words[5],
             actual.words[6], passed ? @"PASS" : @"FAIL");
    return passed;
}

static void RunNativeBCProbe(void) {
    [[NSFileManager defaultManager] removeItemAtPath:@"/tmp/NativeBCProbe.log"
                                               error:nil];
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    SEL selector = NSSelectorFromString(@"supportsBCTextureCompression");
    int supportsBC = [(id)device respondsToSelector:selector]
        ? ((BOOL (*)(id, SEL))objc_msgSend)(device, selector) : -1;
    ProbeLog(@"device=%@ class=%@ supportsBC=%d nativePatch=%d", device.name,
             NSStringFromClass([(id)device class]), supportsBC,
             VZNativeBCTextureSupportInstalled());
    id<MTLCommandQueue> queue = [device newCommandQueue];
    BOOL results[] = {
        RunPixelFormatInfoProbe(device, (MTLPixelFormat)135),
        RunPixelFormatInfoProbe(device, (MTLPixelFormat)153),
        RunFormatProbe(device, queue, (MTLPixelFormat)135, 2048, 2048,
                       SolidMagentaBC3(2048, 2048), NO),
        RunFormatProbe(device, queue, (MTLPixelFormat)153, 1024, 512,
                       SolidMagentaBC7(1024, 512), NO),
        RunFormatProbe(device, queue, (MTLPixelFormat)135, 64, 64,
                       SolidMagentaBC3(64, 64), YES),
        RunFormatProbe(device, queue, (MTLPixelFormat)153, 64, 64,
                       SolidMagentaBC7(64, 64), YES),
        RunHeapProbe(device, queue, (MTLPixelFormat)135,
                     SolidMagentaBC3(1024, 512)),
        RunHeapProbe(device, queue, (MTLPixelFormat)153,
                     SolidMagentaBC7(1024, 512)),
        RunViewProbe(device, queue, (MTLPixelFormat)153,
                     (MTLPixelFormat)152, SolidMagentaBC7(64, 64)),
        RunViewProbe(device, queue, (MTLPixelFormat)152,
                     (MTLPixelFormat)153, SolidMagentaBC7(64, 64)),
    };
    BOOL passed = YES;
    for (NSUInteger index = 0; index < sizeof(results) / sizeof(results[0]); ++index)
        passed &= results[index];
    ProbeLog(@"OVERALL %@", passed ? @"PASS" : @"FAIL");
}

@interface NativeBCProbeViewController : UIViewController @end
@implementation NativeBCProbeViewController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    UILabel *title = [[UILabel alloc] init];
    title.translatesAutoresizingMaskIntoConstraints = NO;
    title.text = @"Native BC Texture Probe";
    title.font = [UIFont preferredFontForTextStyle:UIFontTextStyleTitle2];
    gLogView = [[UITextView alloc] init];
    gLogView.translatesAutoresizingMaskIntoConstraints = NO;
    gLogView.editable = NO;
    gLogView.font = [UIFont monospacedSystemFontOfSize:13 weight:UIFontWeightRegular];
    [self.view addSubview:title];
    [self.view addSubview:gLogView];
    [NSLayoutConstraint activateConstraints:@[
        [title.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:20],
        [title.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor constant:20],
        [gLogView.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:12],
        [gLogView.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor constant:12],
        [gLogView.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor constant:-12],
        [gLogView.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-12],
    ]];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        RunNativeBCProbe();
    });
}
@end

@interface NativeBCProbeAppDelegate : UIResponder <UIApplicationDelegate>
@property(nonatomic, strong) UIWindow *window;
@end
@implementation NativeBCProbeAppDelegate
- (BOOL)application:(UIApplication *)application
    didFinishLaunchingWithOptions:(NSDictionary *)options {
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window.rootViewController = [[NativeBCProbeViewController alloc] init];
    [self.window makeKeyAndVisible];
    return YES;
}
@end

int main(int argc, char **argv) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil,
            NSStringFromClass(NativeBCProbeAppDelegate.class));
    }
}
