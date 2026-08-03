#import <AppKit/AppKit.h>
#import <AVFoundation/AVFoundation.h>
#include <math.h>

@interface AudioCaptureDelegate : NSObject <NSApplicationDelegate>
@property(nonatomic, retain) AVAudioEngine *engine;
@property(nonatomic, retain) NSWindow *window;
@property(nonatomic) uint64_t samples;
@property(nonatomic) double sumSquares;
@property(nonatomic) float peak;
@end

@implementation AudioCaptureDelegate

- (void)writeResult:(NSString *)result status:(int)status
{
    [result writeToFile:@"/tmp/vz-audio-capture-result.txt"
             atomically:YES encoding:NSUTF8StringEncoding error:nil];
    fputs(result.UTF8String, stdout);
    fflush(stdout);
    [NSApp terminate:@(status)];
}

- (void)beginCapture
{
    self.engine = [[[AVAudioEngine alloc] init] autorelease];
    AVAudioInputNode *input = self.engine.inputNode;
    AVAudioFormat *format = [input outputFormatForBus:0];
    if (!input || !format || format.channelCount == 0) {
        [self writeResult:@"permission=granted error=no-input\n" status:2];
        return;
    }
    [input installTapOnBus:0 bufferSize:1024 format:format
                     block:^(AVAudioPCMBuffer *buffer, AVAudioTime *when) {
        (void)when;
        float *const *channels = buffer.floatChannelData;
        for (AVAudioChannelCount channel = 0;
             channels && channel < buffer.format.channelCount; channel++) {
            for (AVAudioFrameCount frame = 0; frame < buffer.frameLength;
                 frame++) {
                float value = fabsf(channels[channel][frame]);
                self.sumSquares += (double)value * value;
                self.peak = MAX(self.peak, value);
                self.samples++;
            }
        }
    }];
    NSError *error = nil;
    if (![self.engine startAndReturnError:&error]) {
        [self writeResult:[NSString stringWithFormat:
            @"permission=granted error=%@\n", error] status:2];
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC),
                   dispatch_get_main_queue(), ^{
        [self.engine stop];
        [input removeTapOnBus:0];
        double rms = self.samples
            ? sqrt(self.sumSquares / (double)self.samples) : 0;
        NSString *result = [NSString stringWithFormat:
            @"permission=granted samples=%llu rms=%.8f peak=%.8f\n",
            (unsigned long long)self.samples, rms, self.peak];
        [self writeResult:result status:self.peak > 0.00001f ? 0 : 1];
    });
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification
{
    (void)notification;
    [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
    self.window = [[[NSWindow alloc]
        initWithContentRect:NSMakeRect(0, 0, 420, 120)
                  styleMask:NSWindowStyleMaskTitled
                    backing:NSBackingStoreBuffered defer:NO] autorelease];
    self.window.title = @"Virtual Mac Microphone Test";
    // The virtual display can report an empty/negative visibleFrame before
    // WindowServer finishes its first display transaction. An explicit point
    // keeps both this window and its TCC sheet on the 1366x1024 desktop.
    [self.window setFrameOrigin:NSMakePoint(473, 400)];
    [self.window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
    [AVCaptureDevice requestAccessForMediaType:AVMediaTypeAudio
                             completionHandler:^(BOOL granted) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!granted) {
                [self writeResult:@"permission=denied\n" status:1];
                return;
            }
            [self beginCapture];
        });
    }];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender
{
    (void)sender;
    return NO;
}

- (void)dealloc
{
    [_engine release];
    [_window release];
    [super dealloc];
}

@end

int main(int argc, const char *argv[]) {
    (void)argc;
    (void)argv;
    @autoreleasepool {
        NSApplication *application = NSApplication.sharedApplication;
        AudioCaptureDelegate *delegate = [[AudioCaptureDelegate alloc] init];
        application.delegate = delegate;
        [application run];
        [delegate release];
    }
    return 0;
}
