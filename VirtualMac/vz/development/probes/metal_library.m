#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc != 2) {
            fprintf(stderr, "usage: metal-library /path/to/default.metallib\n");
            return 2;
        }

        NSString *path = [NSString stringWithUTF8String:argv[1]];
        NSURL *url = [NSURL fileURLWithPath:path];
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        if (device == nil) {
            fprintf(stderr, "METAL_DEVICE\t(null)\n");
            return 1;
        }

        NSError *error = nil;
        id<MTLLibrary> library = [device newLibraryWithURL:url error:&error];
        printf("METAL_DEVICE\t%s\n", device.name.UTF8String);
        printf("METALLIB_PATH\t%s\n", url.path.UTF8String);
        printf("METALLIB_RESULT\t%s\n", library != nil ? "loaded" : "failed");
        if (error != nil) {
            printf("METALLIB_ERROR_DOMAIN\t%s\n", error.domain.UTF8String);
            printf("METALLIB_ERROR_CODE\t%ld\n", (long)error.code);
            printf("METALLIB_ERROR\t%s\n", error.description.UTF8String);
        }
        if (library == nil) {
            return 1;
        }

        NSArray<NSString *> *names = [library.functionNames sortedArrayUsingSelector:@selector(compare:)];
        printf("METALLIB_FUNCTION_COUNT\t%lu\n", (unsigned long)names.count);
        for (NSString *name in names) {
            id<MTLFunction> function = [library newFunctionWithName:name];
            printf("METALLIB_FUNCTION\t%s\t%s\n",
                   name.UTF8String,
                   function != nil ? "loaded" : "failed");
        }
    }
    return 0;
}
