#import <Foundation/Foundation.h>

// Keep the on-device LocalPolicy implementation and this development probe in
// one translation unit so the test exercises the exact private DER helpers.
#import "../../host/VZLocalPolicy.m"

int main(int argc, const char *argv[])
{
    @autoreleasepool {
        if (argc != 4) {
            fprintf(stderr, "usage: %s input.bin enabled|disabled output.bin\n",
                    argv[0]);
            return 2;
        }
        NSMutableData *data = [NSMutableData dataWithContentsOfFile:
            [NSString stringWithUTF8String:argv[1]]];
        if (data.length != kBlockSize) {
            fprintf(stderr, "input must be one 4096-byte LocalPolicy slot\n");
            return 2;
        }
        BOOL enabled = !strcmp(argv[2], "enabled");
        if (!enabled && strcmp(argv[2], "disabled")) return 2;
        LocalPolicyLayout layout;
        LocalPolicyProperties properties;
        BOOL parsed = ParseLocalPolicy(data.bytes, data.length, &layout);
        BOOL propertiesParsed = parsed &&
            ParsePolicyProperties(layout, &properties);
        fprintf(stderr, "policy=%d properties=%d sip=%lu insert=%td\n",
                parsed, propertiesParsed,
                propertiesParsed ? (unsigned long)properties.sipCount : 0,
                propertiesParsed && properties.insertionPoint
                    ? properties.insertionPoint - (const uint8_t *)data.bytes
                    : -1);
        NSError *error = nil;
        if (!UpdatePolicyInBlock(data.mutableBytes, enabled, &error)) {
            fprintf(stderr, "%s\n", error.localizedDescription.UTF8String);
            return 1;
        }
        if (![data writeToFile:[NSString stringWithUTF8String:argv[3]]
                       options:NSDataWritingAtomic error:&error]) {
            fprintf(stderr, "%s\n", error.localizedDescription.UTF8String);
            return 1;
        }
    }
    return 0;
}
