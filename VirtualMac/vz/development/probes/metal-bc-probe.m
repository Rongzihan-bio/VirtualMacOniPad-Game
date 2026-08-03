#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

int main(void)
{
    @autoreleasepool {
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        MTLTextureDescriptor *descriptor = [[MTLTextureDescriptor alloc] init];
        descriptor.textureType = MTLTextureType2D;
        descriptor.pixelFormat = (MTLPixelFormat)152; // BC7 RGBA, Mac only
        descriptor.width = 64;
        descriptor.height = 64;
        descriptor.mipmapLevelCount = 1;
        descriptor.usage = MTLTextureUsageShaderRead;
        id<MTLTexture> texture = [device newTextureWithDescriptor:descriptor];
        fprintf(stderr, "metal-bc-probe device=%s format=%lu texture=%p\n",
                device.name.UTF8String, (unsigned long)descriptor.pixelFormat,
                texture);
        return texture ? 0 : 1;
    }
}
