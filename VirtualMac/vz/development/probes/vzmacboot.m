#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>
#import <Virtualization/Virtualization.h>
#include <mach-o/dyld.h>
#include <signal.h>

static VZVirtualMachine *machine;
static NSWindow *vmWindow;
static BOOL stopping;

static void printError(NSString *label, NSError *error)
{
    for (unsigned depth = 0; error && depth < 8; depth++) {
        printf("%s_ERROR\tdepth=%u\tdomain=%s\tcode=%ld\tdescription=%s\n",
               label.UTF8String, depth, error.domain.UTF8String,
               (long)error.code, error.localizedDescription.UTF8String);
        printf("%s_USERINFO\t%s\n", label.UTF8String,
               error.userInfo.description.UTF8String);
        error = error.userInfo[NSUnderlyingErrorKey];
    }
}

static void printLoadedFrameworks(void)
{
    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; i++) {
        const char *name = _dyld_get_image_name(i);
        if (name && (strstr(name, "Hypervisor.framework") ||
                     strstr(name, "ParavirtualizedGraphics.framework") ||
                     strstr(name, "Virtualization.framework")))
            printf("LOADED_IMAGE\t%s\n", name);
    }
}

static void finishStop(void)
{
    if (stopping)
        return;
    stopping = YES;
    NSError *error = nil;
    if (machine.canRequestStop && [machine requestStopWithError:&error]) {
        printf("REQUEST_STOP\taccepted\n");
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 20 * NSEC_PER_SEC),
                       dispatch_get_main_queue(), ^{
            if (machine.canStop) {
                [machine stopWithCompletionHandler:^(NSError *stopError) {
                    printf("FORCED_STOP\t%s\n",
                           stopError ? stopError.localizedDescription.UTF8String : "ok");
                    exit(stopError ? 1 : 0);
                }];
            } else {
                exit(0);
            }
        });
    } else if (machine.canStop) {
        printf("REQUEST_STOP\tfailed\t%s\n",
               error ? error.localizedDescription.UTF8String : "unavailable");
        [machine stopWithCompletionHandler:^(NSError *stopError) {
            printf("FORCED_STOP\t%s\n",
                   stopError ? stopError.localizedDescription.UTF8String : "ok");
            exit(stopError ? 1 : 0);
        }];
    } else {
        exit(0);
    }
}

@interface VMDelegate : NSObject <VZVirtualMachineDelegate>
@end

@implementation VMDelegate
- (void)guestDidStopVirtualMachine:(VZVirtualMachine *)virtualMachine
{
    (void)virtualMachine;
    printf("GUEST_STOPPED\n");
    exit(0);
}

- (void)virtualMachine:(VZVirtualMachine *)virtualMachine
 didStopWithError:(NSError *)error
{
    (void)virtualMachine;
    printf("VM_STOP_ERROR\t%s\n", error.localizedDescription.UTF8String);
    exit(1);
}
@end

static VZVirtualMachineConfiguration *configuration(NSURL *bundleURL)
{
    NSError *error = nil;
    NSData *hardwareData = [NSData dataWithContentsOfURL:
        [bundleURL URLByAppendingPathComponent:@"HardwareModel"]];
    NSData *identifierData = [NSData dataWithContentsOfURL:
        [bundleURL URLByAppendingPathComponent:@"MachineIdentifier"]];
    if (!hardwareData || !identifierData)
        return nil;

    VZMacHardwareModel *hardwareModel =
        [[VZMacHardwareModel alloc] initWithDataRepresentation:hardwareData];
    VZMacMachineIdentifier *identifier =
        [[VZMacMachineIdentifier alloc] initWithDataRepresentation:identifierData];
    VZMacAuxiliaryStorage *auxiliaryStorage =
        [[VZMacAuxiliaryStorage alloc] initWithURL:
            [bundleURL URLByAppendingPathComponent:@"AuxiliaryStorage"]];

    VZMacPlatformConfiguration *platform =
        [[VZMacPlatformConfiguration alloc] init];
    platform.hardwareModel = hardwareModel;
    platform.machineIdentifier = identifier;
    platform.auxiliaryStorage = auxiliaryStorage;

    VZVirtualMachineConfiguration *config =
        [[VZVirtualMachineConfiguration alloc] init];
    config.platform = platform;
    config.CPUCount = 4;
    config.memorySize = 4ULL << 30;
    config.bootLoader = [[VZMacOSBootLoader alloc] init];

    VZDiskImageStorageDeviceAttachment *attachment =
        [[VZDiskImageStorageDeviceAttachment alloc]
            initWithURL:[bundleURL URLByAppendingPathComponent:@"Disk.img"]
               readOnly:NO
                  error:&error];
    if (!attachment) {
        fprintf(stderr, "disk attachment: %s\n", error.localizedDescription.UTF8String);
        return nil;
    }
    config.storageDevices = @[
        [[VZVirtioBlockDeviceConfiguration alloc] initWithAttachment:attachment]
    ];

    if (!getenv("VZ_NO_GRAPHICS")) {
        VZMacGraphicsDisplayConfiguration *display =
            [[VZMacGraphicsDisplayConfiguration alloc]
                initWithWidthInPixels:1280 heightInPixels:800 pixelsPerInch:80];
        VZMacGraphicsDeviceConfiguration *graphics =
            [[VZMacGraphicsDeviceConfiguration alloc] init];
        graphics.displays = @[display];
        config.graphicsDevices = @[graphics];
    }
    if (!getenv("VZ_NO_INPUT")) {
        config.keyboards = @[[[VZUSBKeyboardConfiguration alloc] init]];
        config.pointingDevices = @[
            [[VZUSBScreenCoordinatePointingDeviceConfiguration alloc] init]
        ];
    }
    if (!getenv("VZ_NO_NETWORK")) {
        VZVirtioNetworkDeviceConfiguration *network =
            [[VZVirtioNetworkDeviceConfiguration alloc] init];
        network.MACAddress = [[VZMACAddress alloc]
            initWithString:@"d6:a7:58:8e:78:d6"];
        network.attachment = [[VZNATNetworkDeviceAttachment alloc] init];
        config.networkDevices = @[network];
    }
    const char *sharedPath = getenv("VZ_SHARED_DIRECTORY");
    if (sharedPath && sharedPath[0]) {
        NSURL *sharedURL = [NSURL fileURLWithPath:@(sharedPath)
                                      isDirectory:YES];
        VZSharedDirectory *directory = [[VZSharedDirectory alloc]
            initWithURL:sharedURL readOnly:NO];
        VZMultipleDirectoryShare *share = [[VZMultipleDirectoryShare alloc]
            initWithDirectories:@{@"Host Share": directory}];
        VZVirtioFileSystemDeviceConfiguration *fileSystem =
            [[VZVirtioFileSystemDeviceConfiguration alloc]
                initWithTag:[VZVirtioFileSystemDeviceConfiguration
                    macOSGuestAutomountTag]];
        fileSystem.share = share;
        config.directorySharingDevices = @[fileSystem];
        printf("SHARED_DIRECTORY\t%s\ttag=%s\n", sharedPath,
               fileSystem.tag.UTF8String);
    }
    return config;
}

int main(int argc, const char *argv[])
{
    @autoreleasepool {
        const char *logPath = getenv("VZ_LOG_PATH");
        if (logPath) {
            freopen(logPath, "w", stdout);
            freopen(logPath, "a", stderr);
        }
        setvbuf(stdout, NULL, _IONBF, 0);
        if (argc != 2) {
            fprintf(stderr, "usage: vzmacboot <VM.bundle>\n");
            return 2;
        }

        NSURL *bundleURL = [NSURL fileURLWithPath:@(argv[1]) isDirectory:YES];
        VZVirtualMachineConfiguration *config = configuration(bundleURL);
        if (!config) {
            fprintf(stderr, "error: could not construct VM configuration\n");
            return 1;
        }
        NSError *error = nil;
        BOOL valid = [config validateWithError:&error];
        printf("CONFIG_VALID\t%d\t%s\n", valid,
               error ? error.localizedDescription.UTF8String : "ok");
        printLoadedFrameworks();
        if (!valid)
            return 1;

        static VMDelegate *delegate;
        delegate = [[VMDelegate alloc] init];
        machine = [[VZVirtualMachine alloc] initWithConfiguration:config];
        machine.delegate = delegate;
        printf("VM_CREATED\t%p\tcanStart=%d\n", machine, machine.canStart);

        BOOL gui = getenv("VZ_GUI") != NULL;
        if (gui) {
            [NSApplication sharedApplication];
            [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
            NSRect frame = NSMakeRect(0, 0, 1280, 800);
            vmWindow = [[NSWindow alloc]
                initWithContentRect:frame
                          styleMask:(NSWindowStyleMaskTitled |
                                     NSWindowStyleMaskClosable |
                                     NSWindowStyleMaskMiniaturizable |
                                     NSWindowStyleMaskResizable)
                            backing:NSBackingStoreBuffered
                              defer:NO];
            vmWindow.title = @"macOS 13.2.1 — Virtual Mac extraction control";
            VZVirtualMachineView *view =
                [[VZVirtualMachineView alloc] initWithFrame:frame];
            view.virtualMachine = machine;
            view.capturesSystemKeys = YES;
            vmWindow.contentView = view;
            [vmWindow center];
            [vmWindow makeKeyAndOrderFront:nil];
            [NSApp activateIgnoringOtherApps:YES];
            printf("GUI_WINDOW\tvisible=1\tframe=1280x800\n");
        }

        [machine startWithCompletionHandler:^(NSError *startError) {
            printf("START_COMPLETION\t%s\tstate=%ld\n",
                   startError ? startError.localizedDescription.UTF8String : "ok",
                   (long)machine.state);
            if (startError) {
                printError(@"START", startError);
                exit(1);
            }
        }];

        __block unsigned ticks = 0;
        dispatch_source_t timer =
            dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                   dispatch_get_main_queue());
        dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, 0),
                                  5 * NSEC_PER_SEC, NSEC_PER_SEC / 10);
        dispatch_source_set_event_handler(timer, ^{
            ticks++;
            printf("VM_STATE\tseconds=%u\tstate=%ld\n", ticks * 5,
                   (long)machine.state);
            const char *limit = getenv("VZ_RUN_SECONDS");
            unsigned seconds = limit ? (unsigned)strtoul(limit, NULL, 10) : 300;
            if (ticks * 5 >= seconds)
                finishStop();
        });
        dispatch_resume(timer);
        if (gui)
            [NSApp run];
        else
            dispatch_main();
    }
    return 0;
}
