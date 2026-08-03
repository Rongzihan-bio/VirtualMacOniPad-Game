#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>

int main(void) {
    @autoreleasepool {
        CGRect screen = CGDisplayBounds(CGMainDisplayID());
        printf("screen width=%.0f height=%.0f\n",
               screen.size.width, screen.size.height);
        NSArray *windows = CFBridgingRelease(CGWindowListCopyWindowInfo(
            kCGWindowListOptionOnScreenOnly, kCGNullWindowID));
        for (NSDictionary *window in windows) {
            NSString *owner = window[(id)kCGWindowOwnerName];
            NSString *name = window[(id)kCGWindowName];
            NSDictionary *boundsDictionary = window[(id)kCGWindowBounds];
            CGRect bounds = CGRectZero;
            CGRectMakeWithDictionaryRepresentation(
                (CFDictionaryRef)boundsDictionary, &bounds);
            NSNumber *layer = window[(id)kCGWindowLayer];
            NSNumber *windowID = window[(id)kCGWindowNumber];
            if (owner.length || name.length)
                printf("id=%s layer=%s owner=%s name=%s "
                       "x=%.0f y=%.0f width=%.0f height=%.0f\n",
                       windowID.stringValue.UTF8String,
                       layer.stringValue.UTF8String,
                       owner.UTF8String ?: "",
                       name.UTF8String ?: "",
                       bounds.origin.x, bounds.origin.y,
                       bounds.size.width, bounds.size.height);
        }
    }
    return 0;
}
