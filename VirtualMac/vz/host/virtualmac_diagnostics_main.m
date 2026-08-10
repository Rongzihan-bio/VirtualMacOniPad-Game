#import <Foundation/Foundation.h>
#import "VZDiagnostics.h"

int main(int argc, char **argv)
{
    (void)argc;
    (void)argv;
    @autoreleasepool {
        NSError *error = nil;
        NSURL *archive = VZCreateDiagnosticsArchive(&error);
        if (!archive) {
            fprintf(stderr, "virtualmac-diagnostics: %s\n",
                    error.localizedDescription.UTF8String ?: "unknown error");
            return 1;
        }
        printf("%s\n", archive.path.fileSystemRepresentation);
    }
    return 0;
}
