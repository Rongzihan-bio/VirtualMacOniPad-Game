#import <CoreFoundation/CoreFoundation.h>
#import <Foundation/Foundation.h>
#import <IOKit/IOKitLib.h>
#import <Metal/Metal.h>
#import <malloc/malloc.h>
#import <objc/message.h>
#import <objc/runtime.h>

static IMP originalSupportsFamily;
static IMP originalNewCommandQueue;
static IMP originalNewTexture;
static IMP originalNewBuffer;
static IMP originalNewBufferNoCopy;
static IMP originalNewRenderPipeline;
static IMP originalNewRenderPipelineReflection;
static IMP originalNewLibrarySource;
static IMP originalNewLibraryData;
static IMP originalNewFunctionGLCoreIR;
static IMP originalNewFunctionGLCoreIRInputs;
static IMP originalCommandBuffer;
static IMP originalCommandBufferUnretained;
static IMP originalRenderEncoder;
static IMP originalComputeEncoder;
static IMP originalBlitEncoder;
static IMP originalCommit;
static IMP originalEndEncoding;
static IMP originalSetRenderPipelineState;
static IMP originalSetVisibilityResultMode;
static IMP originalSetVertexBuffer;
static IMP originalSetVertexBytes;
static IMP originalSetViewport;
static IMP originalSetFragmentBuffer;
static IMP originalDrawPrimitives;
static IMP originalDrawPrimitivesInstanced;
static IMP originalDrawPrimitivesInstancedBase;
static IMP originalSetColorStoreAction;

static void replace_method(Class cls, SEL selector, IMP replacement,
                           IMP *original) {
    Method method = class_getInstanceMethod(cls, selector);
    if (method == NULL || *original != NULL)
        return;
    *original = method_getImplementation(method);
    class_replaceMethod(cls, selector, replacement,
                        method_getTypeEncoding(method));
}

static void install_command_buffer_trace(id commandBuffer);

static void trace_descriptor_private_state(id descriptor) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        for (Class cls = [descriptor class]; cls != Nil;
             cls = class_getSuperclass(cls)) {
            unsigned int count = 0;
            Method *methods = class_copyMethodList(cls, &count);
            for (unsigned int index = 0; index < count; ++index) {
                const char *name = sel_getName(method_getName(methods[index]));
                if (strcasestr(name, "gl") || strcasestr(name, "flip") ||
                    strcasestr(name, "invert") ||
                    strcasestr(name, "swizzle") ||
                    strcasestr(name, "raster") ||
                    strcasestr(name, "dither") ||
                    strcasestr(name, "viewport") ||
                    strcasestr(name, "point") ||
                    strcasestr(name, "target")) {
                    fprintf(stderr,
                            "OpenGLPVGShim: render-pass method class=%s %s %s\n",
                            class_getName(cls), name,
                            method_getTypeEncoding(methods[index]));
                }
            }
            free(methods);
        }
    });
    SEL dither = [descriptor respondsToSelector:
                                  NSSelectorFromString(@"ditherEnabled")]
                      ? NSSelectorFromString(@"ditherEnabled")
                      : NSSelectorFromString(@"isDitherEnabled");
    fprintf(stderr,
            "OpenGLPVGShim: render-pass private openGL=%d dither=%d "
            "pointFlip=%d defaultSamples=%lu\n",
            ((BOOL (*)(id, SEL))objc_msgSend)(
                descriptor, NSSelectorFromString(@"openGLModeEnabled")),
            ((BOOL (*)(id, SEL))objc_msgSend)(descriptor, dither),
            ((BOOL (*)(id, SEL))objc_msgSend)(
                descriptor, NSSelectorFromString(@"pointCoordYFlipEnabled")),
            (unsigned long)((NSUInteger (*)(id, SEL))objc_msgSend)(
                descriptor,
                NSSelectorFromString(@"defaultRasterSampleCount")));
}

static void traced_end_encoding(id self, SEL selector) {
    fprintf(stderr, "OpenGLPVGShim: end render encoding\n");
    ((void (*)(id, SEL))originalEndEncoding)(self, selector);
}

static void traced_set_render_pipeline(id self, SEL selector, id state) {
    fprintf(stderr, "OpenGLPVGShim: set render pipeline=%p label=%s\n", state,
            [[[state label] description] UTF8String]);
    ((void (*)(id, SEL, id))originalSetRenderPipelineState)(self, selector,
                                                            state);
}

static void traced_set_visibility(id self, SEL selector, NSUInteger mode,
                                  NSUInteger offset) {
    fprintf(stderr,
            "OpenGLPVGShim: set visibility mode=%lu offset=%lu\n",
            (unsigned long)mode, (unsigned long)offset);
    ((void (*)(id, SEL, NSUInteger, NSUInteger))originalSetVisibilityResultMode)(
        self, selector, mode, offset);
}

static void traced_set_vertex_buffer(id self, SEL selector, id buffer,
                                     NSUInteger offset, NSUInteger index) {
    static dispatch_once_t bufferMethodsOnce;
    dispatch_once(&bufferMethodsOnce, ^{
        for (Class current = [buffer class]; current != Nil;
             current = class_getSuperclass(current)) {
            unsigned int count = 0;
            Method *methods = class_copyMethodList(current, &count);
            for (unsigned int methodIndex = 0; methodIndex < count;
                 ++methodIndex) {
                const char *name = sel_getName(
                    method_getName(methods[methodIndex]));
                if (strcasestr(name, "sync") ||
                    strcasestr(name, "flush") ||
                    strcasestr(name, "modify") ||
                    strcasestr(name, "content")) {
                    fprintf(stderr,
                            "OpenGLPVGShim: buffer method class=%s %s %s\n",
                            class_getName(current), name,
                            method_getTypeEncoding(methods[methodIndex]));
                }
            }
            free(methods);
        }
    });
    fprintf(stderr,
            "OpenGLPVGShim: set vertex buffer=%p offset=%lu index=%lu\n",
            buffer, (unsigned long)offset, (unsigned long)index);
    SEL originalObjectSelector = NSSelectorFromString(@"originalObject");
    if ([buffer respondsToSelector:originalObjectSelector]) {
        id original = ((id (*)(id, SEL))objc_msgSend)(
            buffer, originalObjectSelector);
        fprintf(stderr,
                "OpenGLPVGShim: vertex original=%p class=%s contents=%p\n",
                original, object_getClassName(original),
                [original respondsToSelector:@selector(contents)]
                    ? [original contents]
                    : NULL);
    }
    if (buffer != nil && [buffer respondsToSelector:@selector(contents)] &&
        [buffer length] >= offset + 24) {
        const float *values = (const float *)((const uint8_t *)[buffer contents] +
                                               offset);
        fprintf(stderr,
                "OpenGLPVGShim: vertex data %.3f %.3f %.3f %.3f %.3f %.3f\n",
                values[0], values[1], values[2], values[3], values[4],
                values[5]);
        const char *inlineLengthText = getenv("GL_PVG_INLINE_VERTEX_BYTES");
        if (inlineLengthText != NULL) {
            NSUInteger inlineLength = strtoul(inlineLengthText, NULL, 10);
            inlineLength = MIN(inlineLength, [buffer length] - offset);
            fprintf(stderr,
                    "OpenGLPVGShim: replacing vertex buffer with %lu inline "
                    "bytes\n",
                    (unsigned long)inlineLength);
            ((void (*)(id, SEL, const void *, NSUInteger, NSUInteger))
                 objc_msgSend)(self,
                               @selector(setVertexBytes:length:atIndex:),
                               values, inlineLength, index);
            return;
        }
    }
    ((void (*)(id, SEL, id, NSUInteger, NSUInteger))originalSetVertexBuffer)(
        self, selector, buffer, offset, index);
}

static void traced_set_viewport(id self, SEL selector, MTLViewport viewport) {
    fprintf(stderr,
            "OpenGLPVGShim: viewport %.3f %.3f %.3f %.3f %.3f %.3f\n",
            viewport.originX, viewport.originY, viewport.width,
            viewport.height, viewport.znear, viewport.zfar);
    ((void (*)(id, SEL, MTLViewport))originalSetViewport)(self, selector,
                                                          viewport);
}

static void traced_set_vertex_bytes(id self, SEL selector, const void *bytes,
                                    NSUInteger length, NSUInteger index) {
    fprintf(stderr,
            "OpenGLPVGShim: set vertex bytes=%p length=%lu index=%lu\n",
            bytes, (unsigned long)length, (unsigned long)index);
    ((void (*)(id, SEL, const void *, NSUInteger, NSUInteger))
         originalSetVertexBytes)(self, selector, bytes, length, index);
}

static void traced_set_fragment_buffer(id self, SEL selector, id buffer,
                                       NSUInteger offset, NSUInteger index) {
    fprintf(stderr,
            "OpenGLPVGShim: set fragment buffer=%p offset=%lu index=%lu\n",
            buffer, (unsigned long)offset, (unsigned long)index);
    ((void (*)(id, SEL, id, NSUInteger, NSUInteger))originalSetFragmentBuffer)(
        self, selector, buffer, offset, index);
}

static void traced_draw_primitives(id self, SEL selector, NSUInteger type,
                                   NSUInteger start, NSUInteger count) {
    fprintf(stderr,
            "OpenGLPVGShim: draw primitives type=%lu start=%lu count=%lu\n",
            (unsigned long)type, (unsigned long)start, (unsigned long)count);
    ((void (*)(id, SEL, NSUInteger, NSUInteger, NSUInteger))originalDrawPrimitives)(
        self, selector, type, start, count);
}

static void traced_draw_primitives_instanced(
    id self, SEL selector, NSUInteger type, NSUInteger start,
    NSUInteger count, NSUInteger instances) {
    fprintf(stderr,
            "OpenGLPVGShim: draw primitives type=%lu start=%lu count=%lu "
            "instances=%lu\n",
            (unsigned long)type, (unsigned long)start, (unsigned long)count,
            (unsigned long)instances);
    ((void (*)(id, SEL, NSUInteger, NSUInteger, NSUInteger, NSUInteger))
         originalDrawPrimitivesInstanced)(self, selector, type, start, count,
                                           instances);
}

static void traced_draw_primitives_instanced_base(
    id self, SEL selector, NSUInteger type, NSUInteger start,
    NSUInteger count, NSUInteger instances, NSUInteger baseInstance) {
    fprintf(stderr,
            "OpenGLPVGShim: draw primitives type=%lu start=%lu count=%lu "
            "instances=%lu base=%lu\n",
            (unsigned long)type, (unsigned long)start, (unsigned long)count,
            (unsigned long)instances, (unsigned long)baseInstance);
    ((void (*)(id, SEL, NSUInteger, NSUInteger, NSUInteger, NSUInteger,
               NSUInteger))originalDrawPrimitivesInstancedBase)(
        self, selector, type, start, count, instances, baseInstance);
}

static void traced_set_color_store_action(id self, SEL selector,
                                          NSUInteger action,
                                          NSUInteger index) {
    fprintf(stderr,
            "OpenGLPVGShim: set color store action=%lu index=%lu\n",
            (unsigned long)action, (unsigned long)index);
    ((void (*)(id, SEL, NSUInteger, NSUInteger))originalSetColorStoreAction)(
        self, selector, action, index);
}

static void install_render_encoder_trace(id encoder) {
    Class cls = [encoder class];
    static dispatch_once_t listOnce;
    dispatch_once(&listOnce, ^{
        for (Class current = cls; current != Nil;
             current = class_getSuperclass(current)) {
            unsigned int count = 0;
            Method *methods = class_copyMethodList(current, &count);
            for (unsigned int index = 0; index < count; ++index) {
                const char *name = sel_getName(method_getName(methods[index]));
                if (strcasestr(name, "draw") ||
                    strcasestr(name, "vertex")) {
                    fprintf(stderr,
                            "OpenGLPVGShim: encoder method class=%s %s %s\n",
                            class_getName(current), name,
                            method_getTypeEncoding(methods[index]));
                }
            }
            free(methods);
        }
    });
    replace_method(cls, @selector(endEncoding), (IMP)traced_end_encoding,
                   &originalEndEncoding);
    replace_method(cls, @selector(setRenderPipelineState:),
                   (IMP)traced_set_render_pipeline,
                   &originalSetRenderPipelineState);
    replace_method(cls, @selector(setVisibilityResultMode:offset:),
                   (IMP)traced_set_visibility,
                   &originalSetVisibilityResultMode);
    replace_method(cls, @selector(setVertexBuffer:offset:atIndex:),
                   (IMP)traced_set_vertex_buffer, &originalSetVertexBuffer);
    replace_method(cls, @selector(setVertexBytes:length:atIndex:),
                   (IMP)traced_set_vertex_bytes, &originalSetVertexBytes);
    replace_method(cls, @selector(setViewport:), (IMP)traced_set_viewport,
                   &originalSetViewport);
    replace_method(cls, @selector(setFragmentBuffer:offset:atIndex:),
                   (IMP)traced_set_fragment_buffer,
                   &originalSetFragmentBuffer);
    replace_method(cls, @selector(drawPrimitives:vertexStart:vertexCount:),
                   (IMP)traced_draw_primitives, &originalDrawPrimitives);
    replace_method(
        cls,
        @selector(drawPrimitives:vertexStart:vertexCount:instanceCount:),
        (IMP)traced_draw_primitives_instanced,
        &originalDrawPrimitivesInstanced);
    replace_method(
        cls,
        @selector(drawPrimitives:vertexStart:vertexCount:instanceCount:
                                                   baseInstance:),
        (IMP)traced_draw_primitives_instanced_base,
        &originalDrawPrimitivesInstancedBase);
    replace_method(cls, @selector(setColorStoreAction:atIndex:),
                   (IMP)traced_set_color_store_action,
                   &originalSetColorStoreAction);
}

static id traced_render_encoder(id self, SEL selector, id descriptor) {
    fprintf(stderr, "OpenGLPVGShim: render encoder %s\n",
            [[descriptor description] UTF8String]);
    trace_descriptor_private_state(descriptor);
    if (getenv("GL_PVG_FIX_DEFAULT_SAMPLE_COUNT") != NULL) {
        ((void (*)(id, SEL, NSUInteger))objc_msgSend)(
            descriptor,
            NSSelectorFromString(@"setDefaultRasterSampleCount:"), 0);
        fprintf(stderr,
                "OpenGLPVGShim: cleared unsupported default sample count\n");
    }
    id encoder = ((id (*)(id, SEL, id))originalRenderEncoder)(
        self, selector, descriptor);
    fprintf(stderr, "OpenGLPVGShim: render encoder object=%p class=%s\n",
            encoder, object_getClassName(encoder));
    install_render_encoder_trace(encoder);
    return encoder;
}

static id traced_compute_encoder(id self, SEL selector) {
    fprintf(stderr, "OpenGLPVGShim: compute encoder\n");
    return ((id (*)(id, SEL))originalComputeEncoder)(self, selector);
}

static id traced_blit_encoder(id self, SEL selector) {
    fprintf(stderr, "OpenGLPVGShim: blit encoder\n");
    return ((id (*)(id, SEL))originalBlitEncoder)(self, selector);
}

static void traced_commit(id self, SEL selector) {
    fprintf(stderr, "OpenGLPVGShim: commit command buffer=%p\n", self);
    ((void (*)(id, SEL))originalCommit)(self, selector);
}

static void install_command_buffer_trace(id commandBuffer) {
    Class cls = [commandBuffer class];
    replace_method(cls, @selector(renderCommandEncoderWithDescriptor:),
                   (IMP)traced_render_encoder, &originalRenderEncoder);
    replace_method(cls, @selector(computeCommandEncoder),
                   (IMP)traced_compute_encoder, &originalComputeEncoder);
    replace_method(cls, @selector(blitCommandEncoder),
                   (IMP)traced_blit_encoder, &originalBlitEncoder);
    replace_method(cls, @selector(commit),
                   (IMP)traced_commit, &originalCommit);
}

static id traced_command_buffer(id self, SEL selector) {
    id commandBuffer = ((id (*)(id, SEL))originalCommandBuffer)(
        self, selector);
    fprintf(stderr, "OpenGLPVGShim: command buffer=%p\n", commandBuffer);
    install_command_buffer_trace(commandBuffer);
    return commandBuffer;
}

static id traced_command_buffer_unretained(id self, SEL selector) {
    BOOL retainReferences = getenv("GL_PVG_RETAIN_REFERENCES") != NULL;
    id commandBuffer = retainReferences
        ? ((id (*)(id, SEL))originalCommandBuffer)(self,
                                                   @selector(commandBuffer))
        : ((id (*)(id, SEL))originalCommandBufferUnretained)(self, selector);
    fprintf(stderr,
            "OpenGLPVGShim: requested unretained command buffer=%p%s\n",
            commandBuffer,
            retainReferences ? " (using retained references)" : "");
    install_command_buffer_trace(commandBuffer);
    return commandBuffer;
}

static void install_queue_trace(id queue) {
    Class cls = [queue class];
    replace_method(cls, @selector(commandBuffer),
                   (IMP)traced_command_buffer, &originalCommandBuffer);
    replace_method(cls, NSSelectorFromString(@"commandBufferWithUnretainedReferences"),
                   (IMP)traced_command_buffer_unretained,
                   &originalCommandBufferUnretained);
}

static id traced_new_command_queue(id self, SEL selector) {
    id queue = ((id (*)(id, SEL))originalNewCommandQueue)(self, selector);
    fprintf(stderr,
            "OpenGLPVGShim: command queue=%p class=%s openGLMode=%d "
            "isOpenGLQueue=%d\n",
            queue, object_getClassName(queue),
            [queue respondsToSelector:NSSelectorFromString(
                @"setOpenGLModeEnabled:")],
            [queue respondsToSelector:NSSelectorFromString(
                @"setIsOpenGLQueue:")]);
    install_queue_trace(queue);
    return queue;
}

static id traced_new_texture(id self, SEL selector, id descriptor) {
    fprintf(stderr, "OpenGLPVGShim: new texture %s\n",
            [[descriptor description] UTF8String]);
    return ((id (*)(id, SEL, id))originalNewTexture)(
        self, selector, descriptor);
}

static id traced_new_buffer(id self, SEL selector, NSUInteger length,
                            MTLResourceOptions options) {
    fprintf(stderr, "OpenGLPVGShim: new buffer length=%lu options=0x%lx\n",
            (unsigned long)length, (unsigned long)options);
    return ((id (*)(id, SEL, NSUInteger, MTLResourceOptions))originalNewBuffer)(
        self, selector, length, options);
}

static id traced_new_buffer_no_copy(id self, SEL selector, void *bytes,
                                    NSUInteger length,
                                    MTLResourceOptions options,
                                    void (^deallocator)(void *, NSUInteger)) {
    fprintf(stderr,
            "OpenGLPVGShim: new no-copy buffer bytes=%p length=%lu "
            "options=0x%lx\n", bytes, (unsigned long)length,
            (unsigned long)options);
    return ((id (*)(id, SEL, void *, NSUInteger, MTLResourceOptions, id))
            originalNewBufferNoCopy)(self, selector, bytes, length, options,
                                     deallocator);
}

static id traced_new_render_pipeline(id self, SEL selector, id descriptor,
                                     NSError **error) {
    fprintf(stderr, "OpenGLPVGShim: new render pipeline %s\n",
            [[descriptor description] UTF8String]);
    id result = ((id (*)(id, SEL, id, NSError **))originalNewRenderPipeline)(
        self, selector, descriptor, error);
    fprintf(stderr, "OpenGLPVGShim: render pipeline result=%p error=%s\n",
            result,
            error != NULL ? [[[(*error) description] description] UTF8String]
                          : "(no error pointer)");
    return result;
}

static id traced_new_render_pipeline_reflection(
    id self, SEL selector, id descriptor, MTLPipelineOption options,
    MTLAutoreleasedRenderPipelineReflection reflection, NSError **error) {
    fprintf(stderr,
            "OpenGLPVGShim: new render pipeline options=0x%lx %s\n",
            (unsigned long)options, [[descriptor description] UTF8String]);
    id result = ((id (*)(id, SEL, id, MTLPipelineOption,
                         MTLAutoreleasedRenderPipelineReflection,
                         NSError **))originalNewRenderPipelineReflection)(
        self, selector, descriptor, options, reflection, error);
    fprintf(stderr, "OpenGLPVGShim: render pipeline result=%p error=%s\n",
            result,
            error != NULL ? [[[(*error) description] description] UTF8String]
                          : "(no error pointer)");
    return result;
}

static uint64_t trace_hash(const void *bytes, size_t length) {
    const uint8_t *cursor = bytes;
    uint64_t hash = UINT64_C(1469598103934665603);
    for (size_t index = 0; index < length; ++index) {
        hash ^= cursor[index];
        hash *= UINT64_C(1099511628211);
    }
    return hash;
}

static id traced_new_library_source(id self, SEL selector, NSString *source,
                                    id options, NSError **error) {
    NSData *data = [source dataUsingEncoding:NSUTF8StringEncoding];
    fprintf(stderr,
            "OpenGLPVGShim: new library source length=%lu hash=%016llx\n",
            (unsigned long)data.length,
            (unsigned long long)trace_hash(data.bytes, data.length));
    return ((id (*)(id, SEL, id, id, NSError **))originalNewLibrarySource)(
        self, selector, source, options, error);
}

static id traced_new_library_data(id self, SEL selector, dispatch_data_t data,
                                  NSError **error) {
    const void *bytes = NULL;
    size_t length = 0;
    dispatch_data_t mapped = dispatch_data_create_map(data, &bytes, &length);
    fprintf(stderr,
            "OpenGLPVGShim: new library data length=%lu hash=%016llx\n",
            (unsigned long)length,
            (unsigned long long)trace_hash(bytes, length));
    (void)mapped;
    return ((id (*)(id, SEL, dispatch_data_t, NSError **))
                originalNewLibraryData)(self, selector, data, error);
}

static id traced_new_function_glcore(id self, SEL selector,
                                     const void *coreIR,
                                     NSUInteger functionType) {
    size_t coreIRSize = malloc_size(coreIR);
    id result = ((id (*)(id, SEL, const void *, NSUInteger))
                     originalNewFunctionGLCoreIR)(self, selector, coreIR,
                                                   functionType);
    fprintf(stderr,
            "OpenGLPVGShim: GLCoreIR=%p size=%lu hash=%016llx type=%lu "
            "function=%s\n",
            coreIR, (unsigned long)coreIRSize,
            (unsigned long long)trace_hash(coreIR, coreIRSize),
            (unsigned long)functionType, [[result description] UTF8String]);
    return result;
}

static id traced_new_function_glcore_inputs(id self, SEL selector,
                                            const void *coreIR, id inputs,
                                            NSUInteger functionType) {
    size_t coreIRSize = malloc_size(coreIR);
    id result = ((id (*)(id, SEL, const void *, id, NSUInteger))
                     originalNewFunctionGLCoreIRInputs)(
        self, selector, coreIR, inputs, functionType);
    fprintf(stderr,
            "OpenGLPVGShim: GLCoreIR=%p size=%lu hash=%016llx inputs=%s "
            "type=%lu function=%s\n",
            coreIR, (unsigned long)coreIRSize,
            (unsigned long long)trace_hash(coreIR, coreIRSize),
            [[inputs description] UTF8String],
            (unsigned long)functionType, [[result description] UTF8String]);
    return result;
}

static id underlying_device(id device) {
    SEL selector = NSSelectorFromString(@"originalObject");
    while ([device respondsToSelector:selector]) {
        id next = ((id (*)(id, SEL))objc_msgSend)(device, selector);
        if (next == nil || next == device)
            break;
        device = next;
    }
    return device;
}

static BOOL pvg_supports_family(id self, SEL selector, NSUInteger family) {
    NSUInteger maximumFamily = 1005;
    const char *configuredFamily = getenv("GL_PVG_APPLE_FAMILY");
    if (configuredFamily != NULL) {
        NSUInteger parsed = (NSUInteger)strtoul(configuredFamily, NULL, 10);
        if (parsed >= 1 && parsed <= 9)
            maximumFamily = 1000 + parsed;
    }
    if (family >= 1001 && family <= maximumFamily)
        return YES;
    return ((BOOL (*)(id, SEL, NSUInteger))originalSupportsFamily)(
        self, selector, family);
}

static void enable_apple_gpu_families(id<MTLDevice> device) {
    device = underlying_device(device);
    BOOL isPVG = [NSStringFromClass(device.class)
        isEqualToString:@"AppleParavirtDevice"];
    if (!isPVG && getenv("GL_PVG_TRACE_ANY_DEVICE") == NULL)
        return;

    static dispatch_once_t once;
    dispatch_once(&once, ^{
        for (Class current = device.class; current != Nil;
             current = class_getSuperclass(current)) {
            unsigned int count = 0;
            Method *methods = class_copyMethodList(current, &count);
            for (unsigned int index = 0; index < count; ++index) {
                const char *name = sel_getName(method_getName(methods[index]));
                if (strcasestr(name, "library") ||
                    strcasestr(name, "function") ||
                    strcasestr(name, "pipeline")) {
                    fprintf(stderr,
                            "OpenGLPVGShim: device method class=%s %s %s\n",
                            class_getName(current), name,
                            method_getTypeEncoding(methods[index]));
                }
            }
            free(methods);
        }
        if (isPVG) {
            SEL selector = @selector(supportsFamily:);
            Method method = class_getInstanceMethod(device.class, selector);
            originalSupportsFamily = method_getImplementation(method);
            class_replaceMethod(device.class, selector,
                                (IMP)pvg_supports_family,
                                method_getTypeEncoding(method));
        }
        replace_method(device.class, @selector(newCommandQueue),
                       (IMP)traced_new_command_queue,
                       &originalNewCommandQueue);
        replace_method(device.class, @selector(newTextureWithDescriptor:),
                       (IMP)traced_new_texture, &originalNewTexture);
        replace_method(device.class, @selector(newBufferWithLength:options:),
                       (IMP)traced_new_buffer, &originalNewBuffer);
        replace_method(device.class,
                       NSSelectorFromString(
                           @"newBufferWithBytesNoCopy:length:options:deallocator:"),
                       (IMP)traced_new_buffer_no_copy,
                       &originalNewBufferNoCopy);
        replace_method(device.class,
                       @selector(newRenderPipelineStateWithDescriptor:error:),
                       (IMP)traced_new_render_pipeline,
                       &originalNewRenderPipeline);
        replace_method(
            device.class,
            @selector(newRenderPipelineStateWithDescriptor:options:reflection:
                                                              error:),
            (IMP)traced_new_render_pipeline_reflection,
            &originalNewRenderPipelineReflection);
        replace_method(device.class,
                       @selector(newLibraryWithSource:options:error:),
                       (IMP)traced_new_library_source,
                       &originalNewLibrarySource);
        replace_method(device.class, @selector(newLibraryWithData:error:),
                       (IMP)traced_new_library_data,
                       &originalNewLibraryData);
        replace_method(
            device.class,
            NSSelectorFromString(@"newFunctionWithGLCoreIR:functionType:"),
            (IMP)traced_new_function_glcore,
            &originalNewFunctionGLCoreIR);
        replace_method(
            device.class,
            NSSelectorFromString(
                @"newFunctionWithGLCoreIR:inputsDescription:functionType:"),
            (IMP)traced_new_function_glcore_inputs,
            &originalNewFunctionGLCoreIRInputs);
        fprintf(stderr,
                "OpenGLPVGShim: tracing device=%s pvg=%d "
                "openGLMode=%d isOpenGLQueue=%d\n",
                object_getClassName(device), isPVG,
                [device respondsToSelector:NSSelectorFromString(
                    @"setOpenGLModeEnabled:")],
                [device respondsToSelector:NSSelectorFromString(
                    @"setIsOpenGLQueue:")]);
    });
}

static NSArray<id<MTLDevice>> *pvg_MTLCopyAllDevices(void)
    NS_RETURNS_RETAINED {
    NSArray<id<MTLDevice>> *devices = MTLCopyAllDevices();
    for (id<MTLDevice> device in devices)
        enable_apple_gpu_families(device);
    return devices;
}

static id<MTLDevice> pvg_MTLCreateSystemDefaultDevice(void) {
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    enable_apple_gpu_families(device);
    return device;
}

static bool is_paravirtual_gpu(io_registry_entry_t entry) {
    io_name_t class_name = {0};
    return IOObjectGetClass(entry, class_name) == KERN_SUCCESS &&
           strcmp(class_name, "AppleParavirtGPU") == 0;
}

static CFTypeRef pvg_IORegistryEntryCreateCFProperty(
    io_registry_entry_t entry, CFStringRef key, CFAllocatorRef allocator,
    IOOptionBits options) {
    if (getenv("GL_PVG_TRACE_ANY_DEVICE") != NULL &&
        CFEqual(key, CFSTR("IOGLBundleName"))) {
        for (id<MTLDevice> device in MTLCopyAllDevices())
            enable_apple_gpu_families(device);
    }
    if (is_paravirtual_gpu(entry) &&
        CFEqual(key, CFSTR("IOGLBundleName"))) {
        for (id<MTLDevice> device in MTLCopyAllDevices())
            enable_apple_gpu_families(device);
        fprintf(stderr,
                "OpenGLPVGShim: supplying AppleMetalOpenGLRenderer\n");
        return CFRetain(CFSTR("AppleMetalOpenGLRenderer"));
    }
    return IORegistryEntryCreateCFProperty(entry, key, allocator, options);
}

#define INTERPOSE(name, replacement, original)                               \
    __attribute__((used)) static struct {                                    \
        const void *replacement;                                             \
        const void *original;                                                \
    } name __attribute__((section("__DATA,__interpose"))) = {                \
        (const void *)&replacement, (const void *)&original                  \
    }

INTERPOSE(pvg_ioreg_property, pvg_IORegistryEntryCreateCFProperty,
          IORegistryEntryCreateCFProperty);
INTERPOSE(pvg_metal_devices, pvg_MTLCopyAllDevices, MTLCopyAllDevices);
INTERPOSE(pvg_default_metal_device, pvg_MTLCreateSystemDefaultDevice,
          MTLCreateSystemDefaultDevice);
