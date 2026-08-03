#include <AudioToolbox/AudioToolbox.h>
#include <CoreFoundation/CoreFoundation.h>
#include <math.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

static AudioQueueRef queue;
static volatile sig_atomic_t finished;
static uint64_t frames;
static double sum_squares;
static float peak;

static void capture(void *context, AudioQueueRef audio_queue,
                    AudioQueueBufferRef buffer,
                    const AudioTimeStamp *start_time,
                    UInt32 packet_count,
                    const AudioStreamPacketDescription *descriptions) {
    (void)context;
    (void)start_time;
    (void)packet_count;
    (void)descriptions;
    const float *samples = buffer->mAudioData;
    size_t count = buffer->mAudioDataByteSize / sizeof(*samples);
    for (size_t index = 0; index < count; index++) {
        float value = fabsf(samples[index]);
        sum_squares += (double)value * value;
        if (value > peak)
            peak = value;
    }
    frames += count / 2;
    if (!finished)
        AudioQueueEnqueueBuffer(audio_queue, buffer, 0, NULL);
}

static void stop_capture(int signal_number) {
    (void)signal_number;
    finished = 1;
}

static void check(OSStatus status, const char *operation) {
    if (status == noErr)
        return;
    fprintf(stderr, "%s failed: %d (0x%08x)\n", operation,
            (int)status, (unsigned int)status);
    exit(2);
}

int main(int argc, char **argv) {
    double duration = argc > 1 ? strtod(argv[1], NULL) : 5.0;
    AudioStreamBasicDescription format = {
        .mSampleRate = 48000,
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

    signal(SIGINT, stop_capture);
    signal(SIGTERM, stop_capture);
    check(AudioQueueNewInput(&format, capture, NULL, NULL,
                             kCFRunLoopCommonModes, 0, &queue),
          "AudioQueueNewInput");
    for (unsigned int index = 0; index < 4; index++) {
        AudioQueueBufferRef buffer;
        check(AudioQueueAllocateBuffer(queue, 48000 * format.mBytesPerFrame / 10,
                                       &buffer),
              "AudioQueueAllocateBuffer");
        check(AudioQueueEnqueueBuffer(queue, buffer, 0, NULL),
              "AudioQueueEnqueueBuffer");
    }
    check(AudioQueueStart(queue, NULL), "AudioQueueStart");

    CFAbsoluteTime deadline = CFAbsoluteTimeGetCurrent() + duration;
    while (!finished && CFAbsoluteTimeGetCurrent() < deadline)
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.05, false);
    finished = 1;
    AudioQueueStop(queue, true);
    AudioQueueDispose(queue, true);

    double rms = frames ? sqrt(sum_squares / (double)(frames * 2)) : 0;
    char result[160];
    snprintf(result, sizeof(result), "frames=%llu rms=%.8f peak=%.8f\n",
             (unsigned long long)frames, rms, peak);
    fputs(result, stdout);
    FILE *result_file = fopen("/tmp/vz-audio-capture-result.txt", "w");
    if (result_file) {
        fputs(result, result_file);
        fclose(result_file);
    }
    return frames && peak > 0.00001f ? 0 : 1;
}
