#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>

#import "../vz/host/VZTrackpadScrollBridge.h"

typedef struct {
    CGVector raw;
    NSUInteger phase;
    NSUInteger momentumPhase;
} TestEvent;

static TestEvent events[256];
static NSUInteger eventCount;

static void capture(CGVector raw, CGVector accelerated, NSUInteger phase,
                    NSUInteger momentumPhase, void *context)
{
    (void)accelerated;
    (void)context;
    NSCAssert(eventCount < 256, @"event overflow");
    events[eventCount++] = (TestEvent){raw, phase, momentumPhase};
}

static void resetCapture(void)
{
    eventCount = 0;
    memset(events, 0, sizeof(events));
    VZTrackpadScrollBridgeReset();
}

static void testFlickStartsMomentum(void);

static void testSurfaceMouseFlickStartsMomentum(void)
{
    resetCapture();
    double t = CACurrentMediaTime();
    VZSurfaceMouseScrollBridgeHandle(CGVectorMake(20, 0), 1, t);
    VZSurfaceMouseScrollBridgeHandle(CGVectorMake(60, 0), 4, t + 0.008);
    VZSurfaceMouseScrollBridgeHandle(CGVectorMake(80, 0), 4, t + 0.016);
    VZSurfaceMouseScrollBridgeHandle(CGVectorMake(0, 0), 8, t + 0.024);
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:0.1];
    while ([deadline timeIntervalSinceNow] > 0)
        [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode
                               beforeDate:deadline];
    BOOL sawMomentum = NO;
    for (NSUInteger index = 0; index < eventCount; index++)
        sawMomentum |= events[index].momentumPhase != 0;
    NSCAssert(sawMomentum, @"Magic Mouse flick did not start momentum");
}

static void testFractionalPauseAndReverse(void)
{
    resetCapture();
    double t = CACurrentMediaTime();
    VZTrackpadScrollBridgeHandle(CGVectorMake(1.6, 0), 1, t);
    VZTrackpadScrollBridgeHandle(CGVectorMake(0.3, 0), 4, t + 0.01);
    NSUInteger beforeReverse = eventCount;
    VZTrackpadScrollBridgeHandle(CGVectorMake(-0.6, 0), 4, t + 0.25);
    VZTrackpadScrollBridgeHandle(CGVectorMake(-0.6, 0), 4, t + 0.26);
    BOOL sawReverse = NO;
    for (NSUInteger index = beforeReverse; index < eventCount; index++) {
        NSCAssert(events[index].raw.dx <= 0,
                  @"old fractional remainder leaked across reversal");
        sawReverse |= events[index].raw.dx < 0;
    }
    NSCAssert(sawReverse, @"fractional reversal was lost");
}

static void testPauseAndReverse(void)
{
    resetCapture();
    double t = CACurrentMediaTime();
    VZTrackpadScrollBridgeHandle(CGVectorMake(45, 0), 1, t);
    VZTrackpadScrollBridgeHandle(CGVectorMake(0, 0), 4, t + 0.02);
    NSUInteger beforePause = eventCount;
    const double samples[] = {-1, -2, -3, -6, -9, -13};
    for (NSUInteger index = 0; index < sizeof(samples) / sizeof(samples[0]);
         index++) {
        VZTrackpadScrollBridgeHandle(CGVectorMake(samples[index], 0), 4,
                                     t + 0.45 + index / 120.0);
    }
    BOOL emittedReversal = NO;
    for (NSUInteger index = beforePause; index < eventCount; index++) {
        if (events[index].raw.dx > 0.0)
            [NSException raise:@"PauseReverseFailure"
                        format:@"post-pause positive delta at %lu",
                               (unsigned long)index];
        if (events[index].raw.dx < 0.0)
            emittedReversal = YES;
    }
    NSCAssert(emittedReversal, @"reversal was never emitted");
}

static void testContactStopsMomentum(void)
{
    testFlickStartsMomentum();
    double t = CACurrentMediaTime();
    VZTrackpadScrollBridgeHandle(CGVectorMake(0, 0), 32, t);
    NSUInteger afterContact = eventCount;
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:0.05];
    while ([deadline timeIntervalSinceNow] > 0)
        [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode
                               beforeDate:deadline];
    NSCAssert(eventCount == afterContact,
              @"momentum continued after two-finger contact");
}

static void testDuplicateContactIsSuppressed(void)
{
    resetCapture();
    double t = CACurrentMediaTime();
    VZTrackpadScrollBridgeHandle(CGVectorMake(0, 0), 32, t);
    VZTrackpadScrollBridgeHandle(CGVectorMake(0, 0), 32, t + 0.002);
    NSCAssert(eventCount == 1, @"duplicate may-begin reached the guest");
}

static void testSlowReleaseHasNoMomentum(void)
{
    resetCapture();
    double t = CACurrentMediaTime();
    VZTrackpadScrollBridgeHandle(CGVectorMake(8, 0), 1, t);
    VZTrackpadScrollBridgeHandle(CGVectorMake(3, 0), 4, t + 0.02);
    VZTrackpadScrollBridgeHandle(CGVectorMake(0, 0), 4, t + 0.04);
    VZTrackpadScrollBridgeHandle(CGVectorMake(0, 0), 8, t + 0.30);
    for (NSUInteger index = 0; index < eventCount; index++)
        NSCAssert(events[index].momentumPhase == 0,
                  @"slow release started momentum");
}

static void testFlickStartsMomentum(void)
{
    resetCapture();
    double t = CACurrentMediaTime();
    VZTrackpadScrollBridgeHandle(CGVectorMake(20, 0), 1, t);
    VZTrackpadScrollBridgeHandle(CGVectorMake(60, 0), 4, t + 0.008);
    VZTrackpadScrollBridgeHandle(CGVectorMake(80, 0), 4, t + 0.016);
    VZTrackpadScrollBridgeHandle(CGVectorMake(0, 0), 8, t + 0.024);
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:0.1];
    while ([deadline timeIntervalSinceNow] > 0)
        [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode
                               beforeDate:deadline];
    BOOL sawMomentum = NO;
    for (NSUInteger index = 0; index < eventCount; index++)
        sawMomentum |= events[index].momentumPhase != 0;
    NSCAssert(sawMomentum, @"flick did not start momentum");
}

int main(void)
{
    @autoreleasepool {
        VZTrackpadScrollBridgeConfigure(capture, NULL);
        VZSurfaceMouseScrollBridgeConfigure(capture, NULL);
        testPauseAndReverse();
        testFractionalPauseAndReverse();
        testSlowReleaseHasNoMomentum();
        testFlickStartsMomentum();
        testContactStopsMomentum();
        testDuplicateContactIsSuppressed();
        testSurfaceMouseFlickStartsMomentum();
        VZTrackpadScrollBridgeReset();
        puts("scroll bridge tests passed");
    }
    return 0;
}
