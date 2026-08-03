#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include <stdarg.h>
#include <stdio.h>
#include <unistd.h>

typedef struct __attribute__((packed)) {
    uint32_t control;
    uint32_t data0;
    uint64_t data1;
} VZUSBHCIMessage;

typedef id (*InitIMP)(id, SEL, id, id, NSUInteger, id *, id, id, void *);
typedef BOOL (*EnqueueOneIMP)(id, SEL, const VZUSBHCIMessage *, id *);
typedef BOOL (*EnqueueOneExpediteIMP)(id, SEL, const VZUSBHCIMessage *, BOOL,
                                      id *);
typedef BOOL (*EnqueueManyIMP)(id, SEL, const VZUSBHCIMessage *, NSUInteger,
                               id *);
typedef BOOL (*EnqueueManyExpediteIMP)(id, SEL, const VZUSBHCIMessage *,
                                       NSUInteger, BOOL, id *);
typedef BOOL (*CommandCallbackIMP)(id, SEL, int, id *);
typedef BOOL (*DoorbellCallbackIMP)(id, SEL, int, uint64_t, id *);

static InitIMP gInit;
static EnqueueOneIMP gEnqueueOne;
static EnqueueOneExpediteIMP gEnqueueOneExpedite;
static EnqueueManyIMP gEnqueueMany;
static EnqueueManyExpediteIMP gEnqueueManyExpedite;
static CommandCallbackIMP gCommandCallback;
static DoorbellCallbackIMP gDoorbellCallback;
static uint64_t gSequence;

static void Log(const char *format, ...)
{
    FILE *file = fopen("/tmp/usb-hci-oracle.log", "a");
    if (!file)
        return;
    va_list arguments;
    va_start(arguments, format);
    fprintf(file, "pid=%d ", getpid());
    vfprintf(file, format, arguments);
    va_end(arguments);
    fputc('\n', file);
    fclose(file);
}

static void LogMessages(const char *direction, const VZUSBHCIMessage *messages,
                        NSUInteger count, BOOL expedite)
{
    if (!messages)
        return;
    for (NSUInteger index = 0; index < count; index++) {
        const VZUSBHCIMessage *message = &messages[index];
        uint64_t sequence = __atomic_add_fetch(&gSequence, 1, __ATOMIC_RELAXED);
        Log("%s sequence=%llu index=%llu/%llu expedite=%d control=0x%08x "
            "type=0x%02x status=0x%x data0=0x%08x data1=0x%016llx",
            direction, sequence, (uint64_t)index + 1, (uint64_t)count,
            expedite, message->control, message->control & 0x3f,
            (message->control >> 8) & 0xf, message->data0, message->data1);
    }
}

static id TraceInit(id self, SEL selector, NSData *capabilities, id queue,
                    NSUInteger rate, id *error,
                    void (^commandHandler)(id, VZUSBHCIMessage),
                    void (^doorbellHandler)(id, uint32_t *, uint32_t),
                    void *interestHandler)
{
    Log("init self=%p capability-bytes=%llu rate=%llu command=%p "
        "doorbell=%p interest=%p", self, capabilities.length, rate,
        commandHandler, doorbellHandler, interestHandler);
    void (^wrappedCommand)(id, VZUSBHCIMessage) =
        ^(id controller, VZUSBHCIMessage command) {
        LogMessages("kernel-command", &command, 1, NO);
        commandHandler(controller, command);
    };
    void (^wrappedDoorbell)(id, uint32_t *, uint32_t) =
        ^(id controller, uint32_t *doorbells, uint32_t count) {
        for (uint32_t index = 0; index < count; index++)
            Log("kernel-doorbell index=%u/%u value=0x%08x", index + 1,
                count, doorbells[index]);
        doorbellHandler(controller, doorbells, count);
    };
    return gInit(self, selector, capabilities, queue, rate, error,
                 wrappedCommand, wrappedDoorbell, interestHandler);
}

static BOOL TraceEnqueueOne(id self, SEL selector,
                            const VZUSBHCIMessage *message, id *error)
{
    LogMessages("controller-interrupt", message, 1, NO);
    return gEnqueueOne(self, selector, message, error);
}

static BOOL TraceEnqueueOneExpedite(id self, SEL selector,
                                    const VZUSBHCIMessage *message,
                                    BOOL expedite, id *error)
{
    LogMessages("controller-interrupt", message, 1, expedite);
    return gEnqueueOneExpedite(self, selector, message, expedite, error);
}

static BOOL TraceEnqueueMany(id self, SEL selector,
                             const VZUSBHCIMessage *messages,
                             NSUInteger count, id *error)
{
    LogMessages("controller-interrupt", messages, count, NO);
    return gEnqueueMany(self, selector, messages, count, error);
}

static BOOL TraceEnqueueManyExpedite(id self, SEL selector,
                                     const VZUSBHCIMessage *messages,
                                     NSUInteger count, BOOL expedite,
                                     id *error)
{
    LogMessages("controller-interrupt", messages, count, expedite);
    return gEnqueueManyExpedite(self, selector, messages, count, expedite,
                                error);
}

static BOOL TraceCommandCallback(id self, SEL selector, int result, id *error)
{
    Ivar commandIvar = class_getInstanceVariable(object_getClass(self),
                                                  "_command");
    if (!commandIvar)
        commandIvar = class_getInstanceVariable([self class], "_command");
    if (commandIvar) {
        const VZUSBHCIMessage *message =
            (const void *)((const uint8_t *)(__bridge const void *)self +
                           ivar_getOffset(commandIvar));
        Log("command-callback result=0x%x error=%p self=%p", result,
            error ? *error : nil, self);
        LogMessages("kernel-command", message, 1, NO);
    } else {
        Log("command-callback result=0x%x missing-command-ivar self=%p",
            result, self);
    }
    return gCommandCallback(self, selector, result, error);
}

static BOOL TraceDoorbellCallback(id self, SEL selector, int result,
                                  uint64_t length, id *error)
{
    Ivar doorbellsIvar = class_getInstanceVariable([self class], "_doorbells");
    id doorbells = doorbellsIvar ? object_getIvar(self, doorbellsIvar) : nil;
    const uint32_t *bytes = [doorbells respondsToSelector:@selector(bytes)]
        ? [doorbells bytes] : NULL;
    NSUInteger byteLength =
        [doorbells respondsToSelector:@selector(length)] ? [doorbells length] : 0;
    NSUInteger count = MIN((NSUInteger)length, byteLength) / sizeof(uint32_t);
    Log("doorbell-callback result=0x%x length=%llu bytes=%llu error=%p self=%p",
        result, length, (uint64_t)byteLength, error ? *error : nil, self);
    for (NSUInteger index = 0; index < count; index++)
        Log("kernel-doorbell index=%llu/%llu value=0x%08x",
            (uint64_t)index + 1, (uint64_t)count, bytes[index]);
    return gDoorbellCallback(self, selector, result, length, error);
}

static IMP Replace(Class controller, const char *name, IMP replacement)
{
    Method method = class_getInstanceMethod(controller, sel_registerName(name));
    return method ? method_setImplementation(method, replacement) : NULL;
}

__attribute__((constructor)) static void InstallTrace(void)
{
    @autoreleasepool {
        Class controller = objc_getClass("IOUSBHostControllerInterface");
        if (!controller) {
            Log("IOUSBHostControllerInterface unavailable process=%s",
                NSProcessInfo.processInfo.processName.UTF8String);
            return;
        }
        Method commandCallback = class_getInstanceMethod(
            controller,
            sel_registerName("commandAsyncCallbackWithResult:error:"));
        Method doorbellCallback = class_getInstanceMethod(
            controller,
            sel_registerName("doorbellAsyncCallbacKWithResult:length:error:"));
        Ivar commandIvar = class_getInstanceVariable(controller, "_command");
        Ivar doorbellsIvar = class_getInstanceVariable(controller,
                                                        "_doorbells");
        Log("callback-types command=%s doorbell=%s command-ivar=%s@%llu "
            "doorbells-ivar=%s@%llu",
            commandCallback ? method_getTypeEncoding(commandCallback) : "?",
            doorbellCallback ? method_getTypeEncoding(doorbellCallback) : "?",
            commandIvar ? ivar_getTypeEncoding(commandIvar) : "?",
            commandIvar ? (uint64_t)ivar_getOffset(commandIvar) : 0,
            doorbellsIvar ? ivar_getTypeEncoding(doorbellsIvar) : "?",
            doorbellsIvar ? (uint64_t)ivar_getOffset(doorbellsIvar) : 0);
        gInit = (InitIMP)Replace(
            controller,
            "initWithCapabilities:queue:interruptRateHz:error:commandHandler:"
            "doorbellHandler:interestHandler:", (IMP)TraceInit);
        gEnqueueOne = (EnqueueOneIMP)Replace(
            controller, "enqueueInterrupt:error:", (IMP)TraceEnqueueOne);
        gEnqueueOneExpedite = (EnqueueOneExpediteIMP)Replace(
            controller, "enqueueInterrupt:expedite:error:",
            (IMP)TraceEnqueueOneExpedite);
        gEnqueueMany = (EnqueueManyIMP)Replace(
            controller, "enqueueInterrupts:count:error:",
            (IMP)TraceEnqueueMany);
        gEnqueueManyExpedite = (EnqueueManyExpediteIMP)Replace(
            controller, "enqueueInterrupts:count:expedite:error:",
            (IMP)TraceEnqueueManyExpedite);
        gCommandCallback = (CommandCallbackIMP)Replace(
            controller, "commandAsyncCallbackWithResult:error:",
            (IMP)TraceCommandCallback);
        gDoorbellCallback = (DoorbellCallbackIMP)Replace(
            controller, "doorbellAsyncCallbacKWithResult:length:error:",
            (IMP)TraceDoorbellCallback);
        Log("trace installed process=%s init=%p",
            NSProcessInfo.processInfo.processName.UTF8String, gInit);
    }
}
