#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <objc/message.h>
#import <objc/runtime.h>

static BOOL has_argument(int argc, const char *argv[], const char *argument) {
    for (int index = 1; index < argc; ++index) {
        if (strcmp(argv[index], argument) == 0)
            return YES;
    }
    return NO;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        BOOL customMSAA = has_argument(argc, argv, "--custom-msaa2");
        BOOL msaa = customMSAA || has_argument(argc, argv, "--msaa2");
        id<MTLTexture> texture = [device newTextureWithDescriptor:({
            MTLTextureDescriptor *descriptor = [MTLTextureDescriptor new];
            descriptor.textureType = msaa
                ? MTLTextureType2DMultisample : MTLTextureType2D;
            descriptor.pixelFormat = MTLPixelFormatRGBA8Unorm;
            descriptor.width = 64;
            descriptor.height = 64;
            descriptor.sampleCount = msaa ? 2 : 1;
            descriptor.storageMode = msaa ? MTLStorageModePrivate :
                (has_argument(argc, argv, "--managed")
                    ? MTLStorageModeManaged : MTLStorageModeShared);
            descriptor.usage = MTLTextureUsageRenderTarget;
            if (has_argument(argc, argv, "--broad-usage")) {
                descriptor.usage |= MTLTextureUsageShaderRead |
                    MTLTextureUsageShaderWrite | MTLTextureUsagePixelFormatView;
            }
            descriptor;
        })];
        id<MTLCommandQueue> queue = [device newCommandQueue];
        id<MTLCommandBuffer> command =
            has_argument(argc, argv, "--unretained")
            ? [queue commandBufferWithUnretainedReferences]
            : [queue commandBuffer];
        MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor
                                         renderPassDescriptor];
        pass.colorAttachments[0].texture = texture;
        pass.colorAttachments[0].loadAction = MTLLoadActionClear;
        pass.colorAttachments[0].storeAction =
            has_argument(argc, argv, "--store-unknown")
            ? MTLStoreActionUnknown : MTLStoreActionStore;
        pass.colorAttachments[0].clearColor = MTLClearColorMake(
            0.25, 0.5, 0.75, 1.0);
        if (customMSAA) {
            MTLSamplePosition positions[] = {
                { .x = 0.75, .y = 0.75 },
                { .x = 0.25, .y = 0.25 },
            };
            [pass setSamplePositions:positions count:2];
            pass.renderTargetWidth = 64;
            pass.renderTargetHeight = 64;
        }
        if (has_argument(argc, argv, "--dump-ivars")) {
            for (Class cls = object_getClass(pass); cls != Nil;
                 cls = class_getSuperclass(cls)) {
                unsigned int count = 0;
                Method *methods = class_copyMethodList(cls, &count);
                for (unsigned int index = 0; index < count; ++index) {
                    const char *name = sel_getName(
                        method_getName(methods[index]));
                    if (strcasestr(name, "sample"))
                        printf("method class=%s name=%s type=%s\n",
                               class_getName(cls), name,
                               method_getTypeEncoding(methods[index]));
                }
                free(methods);
                Ivar *ivars = class_copyIvarList(cls, &count);
                for (unsigned int index = 0; index < count; ++index)
                    printf("ivar class=%s name=%s type=%s offset=%td\n",
                           class_getName(cls), ivar_getName(ivars[index]),
                           ivar_getTypeEncoding(ivars[index]),
                           ivar_getOffset(ivars[index]));
                free(ivars);
            }
        }
        if (has_argument(argc, argv, "--null-depth-clear"))
            pass.depthAttachment.loadAction = MTLLoadActionClear;
        if (has_argument(argc, argv, "--null-stencil-clear"))
            pass.stencilAttachment.loadAction = MTLLoadActionClear;
        if (has_argument(argc, argv, "--target-size")) {
            pass.renderTargetWidth = 64;
            pass.renderTargetHeight = 64;
        }
        if (has_argument(argc, argv, "--null-store-dontcare")) {
            for (NSUInteger index = 1; index < 8; ++index)
                pass.colorAttachments[index].storeAction =
                    MTLStoreActionDontCare;
        }
        if (has_argument(argc, argv, "--private-opengl"))
            ((void (*)(id, SEL, BOOL))objc_msgSend)(
                pass, NSSelectorFromString(@"setOpenGLModeEnabled:"), YES);
        if (has_argument(argc, argv, "--private-dither"))
            ((void (*)(id, SEL, BOOL))objc_msgSend)(
                pass, NSSelectorFromString(@"setDitherEnabled:"), YES);
        if (has_argument(argc, argv, "--private-point-flip"))
            ((void (*)(id, SEL, BOOL))objc_msgSend)(
                pass, NSSelectorFromString(@"setPointCoordYFlipEnabled:"),
                YES);
        if (has_argument(argc, argv, "--private-samples"))
            ((void (*)(id, SEL, NSUInteger))objc_msgSend)(
                pass,
                NSSelectorFromString(@"setDefaultRasterSampleCount:"), 1);
        id<MTLBuffer> visibility = nil;
        if (has_argument(argc, argv, "--visibility")) {
            visibility = [device newBufferWithLength:16384 options:0];
            pass.visibilityResultBuffer = visibility;
        }
        id<MTLRenderCommandEncoder> encoder =
            [command renderCommandEncoderWithDescriptor:pass];
        if (encoder == nil) {
            fprintf(stderr, "render encoder is nil\n");
            return 2;
        }
        [encoder endEncoding];
        [command commit];
        [command waitUntilCompleted];
        if (msaa) {
            printf("status=%ld error=%s\n", (long)command.status,
                   command.error ? command.error.description.UTF8String
                                 : "none");
            return command.status == MTLCommandBufferStatusCompleted ? 0 : 1;
        }
        unsigned char pixel[4] = {0};
        [texture getBytes:pixel bytesPerRow:4 fromRegion:MTLRegionMake2D(0, 0, 1, 1)
              mipmapLevel:0];
        printf("status=%ld error=%s pixel=%u,%u,%u,%u\n",
               (long)command.status,
               command.error ? command.error.description.UTF8String : "none",
               pixel[0], pixel[1], pixel[2], pixel[3]);
        return command.status == MTLCommandBufferStatusCompleted &&
               pixel[0] == 64 && pixel[1] == 128 && pixel[2] == 191 &&
               pixel[3] == 255 ? 0 : 1;
    }
}
