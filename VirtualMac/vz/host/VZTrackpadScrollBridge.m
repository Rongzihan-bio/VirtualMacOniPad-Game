#import "VZTrackpadScrollBridge.h"

#import <QuartzCore/QuartzCore.h>
#import <math.h>

// These values come from the macOS 13.2.1 MultitouchHID and IOHIDFamily
// implementations. The original IOHID acceleration source is available at:
// https://github.com/apple-oss-distributions/IOHIDFamily/blob/IOHIDFamily-2238.100.59/IOHIDEventSystemPlugIns/IOHIDAcceleration.cpp
//
// MultitouchHID is not open source. The constants and state transitions below
// were reconstructed from Ghidra decompilation of build 22D68's
// MTChordIntegrating momentum-history/timer functions,
// MTTrackpadEventDispatcher scroll functions, and MTMouseEventDispatcher
// surface-mouse functions. The reproducible Ghidra exporters live under
// scripts/research/ExportMomentumDecomp.java and ExportScrollingPipeline.java.
// The caller supplies the root IOHID scroll delta and phase, before UIKit's
// gesture-recognizer state machine or iPad-tuned accelerated child is used.

enum {
    VZScrollPhaseBegan = 1,
    VZScrollPhaseChanged = 4,
    VZScrollPhaseEnded = 8,
    VZScrollPhaseCancelled = 16,
    VZScrollPhaseMayBegin = 32,
};

typedef struct {
    double deltaTimeMS;
    double magnitude;
} VZScrollHistoryEntry;

typedef struct {
    VZScrollHistoryEntry entries[9];
    NSUInteger count;
    double lastTimestamp;
    NSInteger direction;
} VZScrollAcceleratorAxis;

typedef struct {
    VZTrackpadScrollEmitter emitter;
    void *emitterContext;
    dispatch_source_t momentumTimer;
    VZScrollAcceleratorAxis acceleratorX;
    VZScrollAcceleratorAxis acceleratorY;
    CGVector filteredVelocity;
    double gestureStartTime;
    double lastInputTime;
    double lastMotionTime;
    double sampleInterval;
    CGVector lastMovingRaw;
    CGVector momentumVelocity;
    CGVector momentumRemainder;
    double momentumStartTime;
    BOOL momentumDidBegin;
    uint64_t momentumGeneration;
    BOOL activeGesture;
    BOOL activeDidBegin;
    BOOL contactMayBegin;
    double lastSourceTimestamp;
    CGVector lastSourceRaw;
    NSUInteger lastSourcePhase;
    CGVector sourceRemainder;
} VZMacScrollPipeline;

static VZMacScrollPipeline gTrackpadPipeline;
static VZMacScrollPipeline gSurfaceMousePipeline;
static VZMacScrollPipeline gTouchPipeline;

static void resetAxis(VZScrollAcceleratorAxis *axis)
{
    memset(axis, 0, sizeof(*axis));
}

static double trackpadCurve(double velocity)
{
    // HIDTrackpadScrollAcceleration=0.3125 interpolates equally between the
    // 0.125 and 0.5 curves published by the Ventura trackpad service.
    const double gainLinear = 0.925;
    const double gainParabolic = 0.75;
    const double tangentLinear = 6.3;
    const double tangentRoot = 12.0;
    const double deviceScale = 400.0 / 67.0;
    const double cursorScale = 96.0 / 67.0;
    double x = velocity / deviceScale;
    double y0 = gainLinear * tangentLinear +
        pow(gainParabolic * tangentLinear, 2.0);
    double slope = gainLinear +
        2.0 * tangentLinear * gainParabolic * gainParabolic;
    double intercept = y0 - slope * tangentLinear;
    double y;
    if (x <= tangentLinear) {
        y = gainLinear * x + pow(gainParabolic * x, 2.0);
    } else if (x <= tangentRoot) {
        y = slope * x + intercept;
    } else {
        double rootY = slope * tangentRoot + intercept;
        double rootSlope = 2.0 * rootY * slope;
        double rootIntercept = rootY * rootY - rootSlope * tangentRoot;
        y = sqrt(MAX(0.0, rootSlope * x + rootIntercept));
    }
    return y * cursorScale;
}

static double accelerateAxis(VZScrollAcceleratorAxis *axis,
                             double value,
                             double timestamp,
                             BOOL momentum)
{
    // IOHIDPointerScrollFilter feeds momentum at its 60 Hz dispatch rate but
    // normalizes the result back to the device's default 67 Hz rate.
    const double momentumMultiplier = 60.0 / 67.0;
    double input = value * (momentum ? momentumMultiplier : 1.0);
    double deltaTimeMS = axis->lastTimestamp > 0
        ? (timestamp - axis->lastTimestamp) * 1000.0 : 500.0;
    axis->lastTimestamp = timestamp;
    NSInteger direction = input > 0 ? 1 : (input < 0 ? -1 : axis->direction);
    if (axis->direction != direction || deltaTimeMS > 500.0) {
        axis->count = 0;
        axis->direction = direction;
    }
    if (axis->count == 9) {
        memmove(axis->entries, axis->entries + 1,
                sizeof(axis->entries[0]) * 8);
        axis->count--;
    }
    axis->entries[axis->count++] = (VZScrollHistoryEntry){
        deltaTimeMS, fabs(input)
    };

    double sumTime = 0;
    double sumMagnitude = 0;
    NSUInteger eventCount = 0;
    for (NSInteger i = (NSInteger)axis->count - 1; i >= 0; i--) {
        VZScrollHistoryEntry entry = axis->entries[i];
        sumMagnitude += entry.magnitude;
        eventCount++;
        sumTime += MIN(entry.deltaTimeMS, 150.0);
        if (entry.deltaTimeMS > 150.0 || sumTime >= 500.0)
            break;
    }
    double averageTime = MIN(150.0, MAX(1.0, sumTime / eventCount));
    double averageMagnitude = sumMagnitude / eventCount;
    double velocity = ((2.0 / 65536.0) * averageTime * averageTime -
                       (955.0 / 65536.0) * averageTime +
                       (98369.0 / 65536.0)) * averageMagnitude;
    velocity = MAX(1.0 / 65536.0, velocity);
    double multiplier = trackpadCurve(velocity) / velocity;
    double result = input * multiplier * (6554.0 / 65536.0);
    return result / (momentum ? momentumMultiplier : 1.0);
}

static CGVector acceleratedDelta(VZMacScrollPipeline *pipeline,
                                 CGVector raw, double timestamp, BOOL momentum)
{
    return CGVectorMake(
        accelerateAxis(&pipeline->acceleratorX, raw.dx, timestamp, momentum),
        accelerateAxis(&pipeline->acceleratorY, raw.dy, timestamp, momentum));
}

static double integralMickeys(double value, double *remainder)
{
    // Ventura's VMM input payload contains integral raw trackpad mickeys.
    // UIKit exposes the same physical stream as fractional points, but VMM
    // truncates each raw value independently when serializing it. Preserve
    // the fractions here so slow motion is not lost. Drop an opposite-signed
    // remainder at a real reversal; otherwise the previous direction delays
    // the first reversed mickey and produces a visible pause-then-jump.
    if (value != 0 && *remainder * value < 0)
        *remainder = 0;
    double accumulated = value + *remainder;
    double integral = trunc(accumulated);
    *remainder = accumulated - integral;
    return integral;
}

static CGVector integralRawDelta(VZMacScrollPipeline *pipeline, CGVector raw)
{
    return CGVectorMake(
        integralMickeys(raw.dx, &pipeline->sourceRemainder.dx),
        integralMickeys(raw.dy, &pipeline->sourceRemainder.dy));
}

static void emit(VZMacScrollPipeline *pipeline, CGVector raw,
                 NSUInteger phase, NSUInteger momentumPhase, double timestamp)
{
    if (!pipeline->emitter)
        return;
    CGVector accelerated = acceleratedDelta(pipeline, raw, timestamp,
                                            momentumPhase != 0);
    pipeline->emitter(raw, accelerated, phase, momentumPhase,
                      pipeline->emitterContext);
}

static void stopMomentum(VZMacScrollPipeline *pipeline, BOOL emitEnd)
{
    // A dispatch-source handler may already be queued when cancellation
    // occurs. Invalidate it before touching shared state so a stale momentum
    // frame cannot leak into the next (possibly reversed) finger gesture.
    pipeline->momentumGeneration++;
    if (pipeline->momentumTimer) {
        dispatch_source_cancel(pipeline->momentumTimer);
        dispatch_release(pipeline->momentumTimer);
        pipeline->momentumTimer = NULL;
    }
    if (emitEnd && pipeline->momentumDidBegin && pipeline->emitter) {
        pipeline->emitter(CGVectorMake(0, 0), CGVectorMake(0, 0), 0,
                          VZScrollPhaseEnded, pipeline->emitterContext);
    }
    pipeline->momentumDidBegin = NO;
    pipeline->momentumVelocity = CGVectorMake(0, 0);
    pipeline->momentumRemainder = CGVectorMake(0, 0);
}

static double momentumAlpha(CGVector velocity)
{
    const double interval = 1.0 / 60.0;
    double speed = hypot(velocity.dx, velocity.dy) / interval;
    double base = 0.975;
    if (speed < 250.0)
        base -= ((250.0 - MAX(0.0, speed)) / 250.0) * 0.065;
    return pow(base, interval / 0.008);
}

static double roundedDelta(double value, double *remainder)
{
    double accumulated = value + *remainder;
    double rounded = nearbyint(accumulated);
    *remainder = accumulated - rounded;
    return rounded;
}

static void momentumTick(VZMacScrollPipeline *pipeline)
{
    double now = CACurrentMediaTime();
    double alpha = momentumAlpha(pipeline->momentumVelocity);
    pipeline->momentumVelocity.dx *= alpha;
    pipeline->momentumVelocity.dy *= alpha;
    CGVector raw = CGVectorMake(
        roundedDelta(pipeline->momentumVelocity.dx,
                     &pipeline->momentumRemainder.dx),
        roundedDelta(pipeline->momentumVelocity.dy,
                     &pipeline->momentumRemainder.dy));
    BOOL expired = now - pipeline->momentumStartTime >= 2.2;
    BOOL stopped = fabs(pipeline->momentumVelocity.dx) < 0.5 &&
        fabs(pipeline->momentumVelocity.dy) < 0.5;
    if ((raw.dx != 0 || raw.dy != 0) && !expired) {
        emit(pipeline, raw, 0,
             pipeline->momentumDidBegin ? VZScrollPhaseChanged
                                        : VZScrollPhaseBegan, now);
        pipeline->momentumDidBegin = YES;
    }
    if (expired || stopped)
        stopMomentum(pipeline, YES);
}

static void beginMomentum(VZMacScrollPipeline *pipeline, double timestamp)
{
    // MultitouchHID expires its momentum history after 100 ms and only starts
    // momentum when fingers lift while the latest sample is still moving.
    // Checking filtered velocity alone incorrectly launches momentum after a
    // slow scroll has already settled under stationary fingers.
    if (pipeline->lastMotionTime <= 0 ||
        timestamp - pipeline->lastMotionTime > 0.1 ||
        hypot(pipeline->lastMovingRaw.dx, pipeline->lastMovingRaw.dy) < 5.0)
        return;
    double magnitude = hypot(pipeline->filteredVelocity.dx,
                             pipeline->filteredVelocity.dy);
    if (magnitude < 5.0)
        return;
    CGVector velocity = pipeline->filteredVelocity;
    if (fabs(velocity.dx) > 3.0 * fabs(velocity.dy))
        velocity.dy = 0;
    else if (fabs(velocity.dy) > 3.0 * fabs(velocity.dx))
        velocity.dx = 0;

    // Convert the filtered per-report delta into the 60 Hz frame interval
    // used by MultitouchHID's momentum timer.
    double sourceInterval = MIN(0.025, MAX(0.004,
                                          pipeline->sampleInterval));
    // Ventura applies the standard-scroll 0.5 momentum scale before its
    // 60 Hz timer. Without it, a modest release is amplified into a flick.
    double scale = 0.5 * (1.0 / 60.0) / sourceInterval;
    pipeline->momentumVelocity = CGVectorMake(velocity.dx * scale,
                                             velocity.dy * scale);
    pipeline->momentumRemainder = CGVectorMake(0, 0);
    pipeline->momentumStartTime = timestamp;
    pipeline->momentumDidBegin = NO;
    uint64_t generation = ++pipeline->momentumGeneration;

    pipeline->momentumTimer = dispatch_source_create(
        DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(pipeline->momentumTimer,
                              dispatch_time(DISPATCH_TIME_NOW, 0),
                              NSEC_PER_SEC / 60, NSEC_PER_MSEC);
    dispatch_source_set_event_handler(pipeline->momentumTimer, ^{
        if (generation == pipeline->momentumGeneration)
            momentumTick(pipeline);
    });
    dispatch_resume(pipeline->momentumTimer);
}

static void updateVelocity(VZMacScrollPipeline *pipeline,
                           CGVector raw, double timestamp)
{
    double deltaTime = pipeline->lastInputTime > 0
        ? timestamp - pipeline->lastInputTime : 1.0 / 120.0;
    if (deltaTime > 0.1 || deltaTime <= 0) {
        pipeline->filteredVelocity = CGVectorMake(0, 0);
        pipeline->gestureStartTime = timestamp;
        deltaTime = 1.0 / 120.0;
    }
    pipeline->sampleInterval = pipeline->sampleInterval > 0
        ? pipeline->sampleInterval * 0.75 + deltaTime * 0.25 : deltaTime;
    pipeline->lastInputTime = timestamp;
    double oldMagnitude = hypot(pipeline->filteredVelocity.dx,
                                pipeline->filteredVelocity.dy);
    double newMagnitude = hypot(raw.dx, raw.dy);
    double normalizedTime = deltaTime / 0.008;
    double alpha;
    if (oldMagnitude < newMagnitude) {
        double age = MIN(1.0, MAX(0.0,
            (timestamp - pipeline->gestureStartTime) / 0.4));
        double fast = exp2(-2.0 * normalizedTime);
        double slow = pow(0.8, normalizedTime);
        alpha = fast + age * (slow - fast);
    } else {
        alpha = pow(0.85, normalizedTime);
    }
    CGVector filtered = CGVectorMake(
        (1.0 - alpha) * raw.dx + alpha * pipeline->filteredVelocity.dx,
        (1.0 - alpha) * raw.dy + alpha * pipeline->filteredVelocity.dy);
    if (filtered.dx * raw.dx < 0)
        filtered.dx = 0;
    if (filtered.dy * raw.dy < 0)
        filtered.dy = 0;
    pipeline->filteredVelocity = filtered;
    if (hypot(raw.dx, raw.dy) >= 1.0) {
        pipeline->lastMovingRaw = raw;
        pipeline->lastMotionTime = timestamp;
    }
}

static void resetPipeline(VZMacScrollPipeline *pipeline)
{
    stopMomentum(pipeline, NO);
    resetAxis(&pipeline->acceleratorX);
    resetAxis(&pipeline->acceleratorY);
    pipeline->activeGesture = NO;
    pipeline->activeDidBegin = NO;
    pipeline->contactMayBegin = NO;
    pipeline->lastSourceTimestamp = -1;
    pipeline->lastSourceRaw = CGVectorMake(0, 0);
    pipeline->lastSourcePhase = 0;
    pipeline->sourceRemainder = CGVectorMake(0, 0);
    pipeline->filteredVelocity = CGVectorMake(0, 0);
    pipeline->gestureStartTime = 0;
    pipeline->lastInputTime = 0;
    pipeline->lastMotionTime = 0;
    pipeline->sampleInterval = 0;
    pipeline->lastMovingRaw = CGVectorMake(0, 0);
}

static void handlePipeline(VZMacScrollPipeline *pipeline, CGVector rawDelta,
                           NSUInteger phase, CFTimeInterval timestamp)
{
    if (timestamp <= 0)
        timestamp = CACurrentMediaTime();
    BOOL duplicate = timestamp == pipeline->lastSourceTimestamp &&
        phase == pipeline->lastSourcePhase &&
        rawDelta.dx == pipeline->lastSourceRaw.dx &&
        rawDelta.dy == pipeline->lastSourceRaw.dy;
    pipeline->lastSourceTimestamp = timestamp;
    pipeline->lastSourcePhase = phase;
    pipeline->lastSourceRaw = rawDelta;
    if (duplicate)
        return;
    if (phase == VZScrollPhaseMayBegin) {
        // This is the physical two-finger contact packet. macOS cancels an
        // in-flight momentum sequence immediately, before the fingers move.
        if (pipeline->contactMayBegin)
            return;
        pipeline->contactMayBegin = YES;
        stopMomentum(pipeline, YES);
        if (pipeline->emitter)
            pipeline->emitter(CGVectorMake(0, 0), CGVectorMake(0, 0),
                              VZScrollPhaseMayBegin, 0,
                              pipeline->emitterContext);
        return;
    }
    if (phase == VZScrollPhaseBegan) {
        pipeline->contactMayBegin = NO;
        stopMomentum(pipeline, YES);
        pipeline->activeGesture = YES;
        pipeline->activeDidBegin = NO;
        pipeline->filteredVelocity = CGVectorMake(0, 0);
        pipeline->gestureStartTime = timestamp;
        pipeline->lastInputTime = 0;
        pipeline->lastMotionTime = 0;
        pipeline->sampleInterval = 0;
        pipeline->lastMovingRaw = CGVectorMake(0, 0);
        pipeline->sourceRemainder = CGVectorMake(0, 0);
    }
    if (phase == VZScrollPhaseBegan || phase == VZScrollPhaseChanged) {
        if (phase == VZScrollPhaseChanged && pipeline->momentumTimer) {
            stopMomentum(pipeline, YES);
            pipeline->activeGesture = YES;
            pipeline->activeDidBegin = NO;
            pipeline->filteredVelocity = CGVectorMake(0, 0);
            pipeline->gestureStartTime = timestamp;
            pipeline->lastInputTime = 0;
            pipeline->lastMotionTime = 0;
            pipeline->sampleInterval = 0;
        }
        if (!pipeline->activeGesture) {
            pipeline->activeGesture = YES;
            pipeline->activeDidBegin = NO;
            pipeline->filteredVelocity = CGVectorMake(0, 0);
            pipeline->gestureStartTime = timestamp;
            pipeline->lastInputTime = 0;
            pipeline->lastMotionTime = 0;
            pipeline->sampleInterval = 0;
        }
        // Keep the contact lifecycle at the HID seam, while converting
        // UIKit's fractional displacement into the integral raw mickeys that
        // the real Mac VMM receives.
        CGVector integralRaw = integralRawDelta(pipeline, rawDelta);
        updateVelocity(pipeline, integralRaw, timestamp);
        NSUInteger emittedPhase = pipeline->activeDidBegin
            ? VZScrollPhaseChanged : VZScrollPhaseBegan;
        emit(pipeline, integralRaw, emittedPhase, 0, timestamp);
        pipeline->activeDidBegin = YES;
    } else if (phase == VZScrollPhaseEnded ||
               phase == VZScrollPhaseCancelled) {
        if (pipeline->activeDidBegin && pipeline->emitter)
            pipeline->emitter(CGVectorMake(0, 0), CGVectorMake(0, 0),
                              phase, 0, pipeline->emitterContext);
        pipeline->activeGesture = NO;
        pipeline->activeDidBegin = NO;
        pipeline->contactMayBegin = NO;
        if (phase == VZScrollPhaseEnded)
            beginMomentum(pipeline, timestamp);
        else
            stopMomentum(pipeline, NO);
    }
}

void VZTrackpadScrollBridgeConfigure(VZTrackpadScrollEmitter emitter,
                                     void * _Nullable context)
{
    NSCAssert(NSThread.isMainThread, @"trackpad bridge must use main thread");
    stopMomentum(&gTrackpadPipeline, NO);
    gTrackpadPipeline.emitter = emitter;
    gTrackpadPipeline.emitterContext = context;
    resetPipeline(&gTrackpadPipeline);
}

void VZTrackpadScrollBridgeHandle(CGVector rawDelta,
                                  NSUInteger phase,
                                  CFTimeInterval timestamp)
{
    // Called only by a main-thread gesture recognizer. Avoid an Objective-C
    // thread query in this 120 Hz path.
    handlePipeline(&gTrackpadPipeline, rawDelta, phase, timestamp);
}

void VZSurfaceMouseScrollBridgeConfigure(VZTrackpadScrollEmitter emitter,
                                         void * _Nullable context)
{
    stopMomentum(&gSurfaceMousePipeline, NO);
    gSurfaceMousePipeline.emitter = emitter;
    gSurfaceMousePipeline.emitterContext = context;
    resetPipeline(&gSurfaceMousePipeline);
}

void VZSurfaceMouseScrollBridgeHandle(CGVector rawDelta,
                                      NSUInteger phase,
                                      CFTimeInterval timestamp)
{
    handlePipeline(&gSurfaceMousePipeline, rawDelta, phase, timestamp);
}

void VZTouchScrollBridgeConfigure(VZTrackpadScrollEmitter emitter,
                                  void * _Nullable context)
{
    // Called only by a main-thread gesture recognizer.
    stopMomentum(&gTouchPipeline, NO);
    gTouchPipeline.emitter = emitter;
    gTouchPipeline.emitterContext = context;
    resetPipeline(&gTouchPipeline);
}

void VZTouchScrollBridgeHandle(CGVector translationDelta,
                               NSUInteger phase,
                               CFTimeInterval timestamp,
                               CGFloat speed)
{
    NSCAssert(NSThread.isMainThread, @"touch bridge must use main thread");
    // UIKit translations are display points, while MultitouchHID supplies
    // trackpad mickeys. This calibrated conversion places one point near the
    // middle of Ventura's native trackpad curve. The existing speed control
    // remains a touch-only multiplier; 0.25 is the established default.
    // A touchscreen point spans much more physical travel than one trackpad
    // mickey. Keep touch on its independent control, but enter the native
    // acceleration curve at one quarter of the previous scale. At the 0.25
    // default this is 1.25 mickeys per point instead of 5.
    CGFloat scale = 5.0 * MAX(0.1, MIN(1.0, speed));
    CGVector raw = CGVectorMake(translationDelta.dx * scale,
                               translationDelta.dy * scale);
    handlePipeline(&gTouchPipeline, raw, phase, timestamp);
}

void VZTrackpadScrollBridgeReset(void)
{
    NSCAssert(NSThread.isMainThread, @"trackpad bridge must use main thread");
    resetPipeline(&gTrackpadPipeline);
    resetPipeline(&gSurfaceMousePipeline);
    resetPipeline(&gTouchPipeline);
}
