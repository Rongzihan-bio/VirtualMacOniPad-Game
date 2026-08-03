#import <AVFAudio/AVFAudio.h>
#import <AudioToolbox/AudioToolbox.h>
#include <math.h>
#include <stdio.h>

static double phase;
static const double frequency = 880.0;
static const double sampleRate = 48000.0;

static void renderTone(void *context, AudioQueueRef queue,
                       AudioQueueBufferRef buffer) {
    (void)context;
    float *samples = buffer->mAudioData;
    UInt32 frames = buffer->mAudioDataBytesCapacity /
                    (2 * (UInt32)sizeof(float));
    for (UInt32 frame = 0; frame < frames; frame++) {
        float sample = (float)(sin(phase) * 0.35);
        samples[frame * 2] = sample;
        samples[frame * 2 + 1] = sample;
        phase += 2.0 * M_PI * frequency / sampleRate;
        if (phase >= 2.0 * M_PI)
            phase -= 2.0 * M_PI;
    }
    buffer->mAudioDataByteSize = frames * 2 * sizeof(float);
    AudioQueueEnqueueBuffer(queue, buffer, 0, NULL);
}

static void check(OSStatus status, const char *operation) {
    if (status == noErr)
        return;
    fprintf(stderr, "%s failed: %d (0x%08x)\n", operation,
            (int)status, (unsigned int)status);
    exit(2);
}

int main(int argc, char **argv) {
    @autoreleasepool {
        double duration = argc > 1 ? strtod(argv[1], NULL) : 4.0;
        AVAudioSession *session = AVAudioSession.sharedInstance;
        NSError *error = nil;
        AVAudioSessionCategoryOptions options =
            AVAudioSessionCategoryOptionMixWithOthers |
            AVAudioSessionCategoryOptionDefaultToSpeaker;
        if (![session setCategory:AVAudioSessionCategoryPlayAndRecord
                             mode:AVAudioSessionModeDefault
                          options:options error:&error] ||
            ![session setActive:YES error:&error]) {
            fprintf(stderr, "AVAudioSession setup failed: %s\n",
                    error.localizedDescription.UTF8String);
            return 2;
        }

        AudioStreamBasicDescription format = {
            .mSampleRate = sampleRate,
            .mFormatID = kAudioFormatLinearPCM,
            .mFormatFlags = kAudioFormatFlagIsFloat |
                            kAudioFormatFlagIsPacked |
                            kAudioFormatFlagsNativeEndian,
            .mBytesPerPacket = 2 * sizeof(float),
            .mFramesPerPacket = 1,
            .mBytesPerFrame = 2 * sizeof(float),
            .mChannelsPerFrame = 2,
            .mBitsPerChannel = 8 * sizeof(float),
        };
        AudioQueueRef queue;
        check(AudioQueueNewOutput(&format, renderTone, NULL, NULL, NULL, 0,
                                  &queue),
              "AudioQueueNewOutput");
        for (unsigned int index = 0; index < 4; index++) {
            AudioQueueBufferRef buffer;
            check(AudioQueueAllocateBuffer(queue,
                                           4800 * format.mBytesPerFrame,
                                           &buffer),
                  "AudioQueueAllocateBuffer");
            renderTone(NULL, queue, buffer);
        }
        check(AudioQueueStart(queue, NULL), "AudioQueueStart");
        printf("playing %.0f Hz for %.1f seconds\n", frequency, duration);
        NSRunLoop *runLoop = NSRunLoop.currentRunLoop;
        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:duration];
        while ([deadline timeIntervalSinceNow] > 0)
            [runLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
        AudioQueueStop(queue, true);
        AudioQueueDispose(queue, true);
        [session setActive:NO error:nil];
    }
    return 0;
}
