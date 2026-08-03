#import <Foundation/Foundation.h>
#import <Virtualization/Virtualization.h>

@interface VZMacOSVirtualMachineStartOptions (ForceDFUPrivate)
@property(assign, setter=_setForceDFU:) BOOL _forceDFU;
@end

@interface VZVirtualMachine (USBLocationPrivate)
- (void)_getUSBControllerLocationIDWithCompletionHandler:
    (void (^)(id value))completionHandler;
@end

static VZVirtualMachine *gVirtualMachine;
static dispatch_source_t gLocationTimer;

static void Fail(NSString *stage, NSError *error)
{
    fprintf(stderr, "FORCE_DFU_FAILED\tstage=%s\terror=%s\n",
            stage.UTF8String, error.description.UTF8String);
    exit(1);
}

int main(int argc, const char *argv[])
{
    @autoreleasepool {
        setlinebuf(stdout);
        if (argc < 2) {
            fprintf(stderr, "usage: start-force-dfu VM.bundle\n");
            return 2;
        }
        NSString *bundlePath = @(argv[1]);
        NSURL *(^URL)(NSString *) = ^NSURL *(NSString *name) {
            return [NSURL fileURLWithPath:
                [bundlePath stringByAppendingPathComponent:name]];
        };

        NSData *hardwareData = [NSData dataWithContentsOfURL:URL(@"HardwareModel")];
        NSData *identifierData = [NSData dataWithContentsOfURL:URL(@"MachineIdentifier")];
        VZMacHardwareModel *hardwareModel =
            [[VZMacHardwareModel alloc] initWithDataRepresentation:hardwareData];
        VZMacMachineIdentifier *machineIdentifier =
            [[VZMacMachineIdentifier alloc]
                initWithDataRepresentation:identifierData];
        VZMacAuxiliaryStorage *auxiliaryStorage =
            [[VZMacAuxiliaryStorage alloc]
                initWithContentsOfURL:URL(@"AuxiliaryStorage")];
        if (!hardwareModel || !machineIdentifier || !auxiliaryStorage) {
            Fail(@"metadata", [NSError errorWithDomain:@"ForceDFU" code:1
                                               userInfo:nil]);
        }

        VZMacPlatformConfiguration *platform =
            [[VZMacPlatformConfiguration alloc] init];
        platform.hardwareModel = hardwareModel;
        platform.machineIdentifier = machineIdentifier;
        platform.auxiliaryStorage = auxiliaryStorage;

        NSError *error = nil;
        VZDiskImageStorageDeviceAttachment *attachment =
            [[VZDiskImageStorageDeviceAttachment alloc]
                initWithURL:URL(@"Disk.img") readOnly:NO error:&error];
        if (!attachment)
            Fail(@"disk", error);
        VZVirtioBlockDeviceConfiguration *blockDevice =
            [[VZVirtioBlockDeviceConfiguration alloc]
                initWithAttachment:attachment];

        VZVirtualMachineConfiguration *configuration =
            [VZVirtualMachineConfiguration new];
        configuration.platform = platform;
        configuration.CPUCount = 4;
        configuration.memorySize = 4ULL << 30;
        configuration.bootLoader = [[VZMacOSBootLoader alloc] init];
        configuration.storageDevices = @[ blockDevice ];
        if (![configuration validateWithError:&error])
            Fail(@"validation", error);

        gVirtualMachine = [[VZVirtualMachine alloc]
            initWithConfiguration:configuration];
        VZMacOSVirtualMachineStartOptions *options =
            [VZMacOSVirtualMachineStartOptions new];
        options._forceDFU = YES;
        printf("FORCE_DFU_START\tbundle=%s\n", bundlePath.UTF8String);
        [gVirtualMachine startWithOptions:options
                       completionHandler:^(NSError *startError) {
            if (startError)
                Fail(@"start", startError);
            printf("FORCE_DFU_STARTED\n");
            gLocationTimer = dispatch_source_create(
                DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
            dispatch_source_set_timer(gLocationTimer,
                dispatch_time(DISPATCH_TIME_NOW, 0), NSEC_PER_SEC,
                NSEC_PER_MSEC * 50);
            dispatch_source_set_event_handler(gLocationTimer, ^{
                [gVirtualMachine
                    _getUSBControllerLocationIDWithCompletionHandler:^(id value) {
                    printf("FORCE_DFU_LOCATION\t%s\n",
                           value ? [[value description] UTF8String] : "none");
                }];
            });
            dispatch_resume(gLocationTimer);
        }];
        dispatch_main();
    }
}
