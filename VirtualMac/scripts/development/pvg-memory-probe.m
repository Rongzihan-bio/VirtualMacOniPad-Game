#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

// Allocate and touch ordinary private Metal buffers one chunk at a time. This
// deliberately avoids complex shaders so a guest GPU-command compatibility
// failure cannot be mistaken for the host's memory-capacity boundary.
int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSUInteger chunkMiB = argc > 1 ? strtoull(argv[1], NULL, 10) : 64;
        NSUInteger maximumMiB = argc > 2 ? strtoull(argv[2], NULL, 10) : 12288;
        useconds_t delayUsec = argc > 3 ? strtoul(argv[3], NULL, 10) : 100000;
        if (chunkMiB == 0 || maximumMiB < chunkMiB) {
            fprintf(stderr, "usage: pvg-memory-probe [chunk-MiB] [maximum-MiB] [delay-usec]\n");
            return 64;
        }

        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        id<MTLCommandQueue> queue = [device newCommandQueue];
        if (device == nil || queue == nil) {
            fprintf(stderr, "Metal device or command queue unavailable\n");
            return 69;
        }

        NSMutableArray<id<MTLBuffer>> *buffers = [NSMutableArray array];
        id<MTLBuffer> readback = [device newBufferWithLength:4096
            options:MTLResourceStorageModeShared];
        if (readback == nil) {
            fprintf(stderr, "readback buffer unavailable\n");
            return 69;
        }
        NSUInteger chunkBytes = chunkMiB << 20;
        NSUInteger allocatedMiB = 0;
        printf("device=%s chunk=%lu MiB maximum=%lu MiB\n",
               device.name.UTF8String,
               (unsigned long)chunkMiB, (unsigned long)maximumMiB);
        fflush(stdout);

        while (allocatedMiB + chunkMiB <= maximumMiB) {
            @autoreleasepool {
                id<MTLBuffer> buffer = [device
                    newBufferWithLength:chunkBytes
                    options:MTLResourceStorageModePrivate];
                if (buffer == nil) {
                    printf("allocation-refused after=%lu MiB\n",
                           (unsigned long)allocatedMiB);
                    fflush(stdout);
                    return 0;
                }

                id<MTLCommandBuffer> command = [queue commandBuffer];
                id<MTLBlitCommandEncoder> blit =
                    [command blitCommandEncoder];
                [blit fillBuffer:buffer
                           range:NSMakeRange(0, chunkBytes)
                           value:(uint8_t)(buffers.count + 1)];
                [blit copyFromBuffer:buffer sourceOffset:0
                            toBuffer:readback destinationOffset:0
                                size:readback.length];
                [blit endEncoding];
                [command commit];
                [command waitUntilCompleted];
                if (command.status == MTLCommandBufferStatusError) {
                    printf("command-failed after=%lu MiB error=%s\n",
                           (unsigned long)allocatedMiB,
                           command.error.description.UTF8String ?: "unknown");
                    fflush(stdout);
                    return 1;
                }
                uint8_t expected = (uint8_t)(buffers.count + 1);
                const uint8_t *bytes = readback.contents;
                for (NSUInteger index = 0; index < readback.length; index++) {
                    if (bytes[index] != expected) {
                        printf("verification-failed after=%lu MiB "
                               "offset=%lu expected=%u actual=%u\n",
                               (unsigned long)allocatedMiB,
                               (unsigned long)index, expected, bytes[index]);
                        fflush(stdout);
                        return 1;
                    }
                }

                [buffers addObject:buffer];
                [buffer release];
                allocatedMiB += chunkMiB;
                printf("allocated=%lu MiB guest-current=%llu MiB\n",
                       (unsigned long)allocatedMiB,
                       (unsigned long long)(device.currentAllocatedSize >> 20));
                fflush(stdout);
            }
            if (delayUsec != 0)
                usleep(delayUsec);
        }

        printf("maximum-reached allocated=%lu MiB\n",
               (unsigned long)allocatedMiB);
        fflush(stdout);
        sleep(5);
        [readback release];
        [queue release];
    }
    return 0;
}
