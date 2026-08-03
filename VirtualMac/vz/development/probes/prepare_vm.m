#import <Foundation/Foundation.h>
#import <Virtualization/Virtualization.h>

static void fail(NSString *message)
{
    fprintf(stderr, "error: %s\n", message.UTF8String);
    exit(1);
}

int main(int argc, const char *argv[])
{
    @autoreleasepool {
        if (argc != 3) {
            fprintf(stderr, "usage: prepare-vm <restore.ipsw> <VM.bundle>\n");
            return 2;
        }

        NSURL *restoreURL = [NSURL fileURLWithPath:@(argv[1])];
        NSURL *bundleURL = [NSURL fileURLWithPath:@(argv[2]) isDirectory:YES];
        NSFileManager *fm = NSFileManager.defaultManager;
        NSError *error = nil;
        if (![fm createDirectoryAtURL:bundleURL
          withIntermediateDirectories:YES attributes:nil error:&error])
            fail(error.localizedDescription);

        dispatch_semaphore_t loaded = dispatch_semaphore_create(0);
        __block VZMacOSRestoreImage *image = nil;
        __block NSError *loadError = nil;
        [VZMacOSRestoreImage loadFileURL:restoreURL
                       completionHandler:^(VZMacOSRestoreImage *value, NSError *valueError) {
            image = value;
            loadError = valueError;
            dispatch_semaphore_signal(loaded);
        }];
        dispatch_semaphore_wait(loaded, DISPATCH_TIME_FOREVER);
        if (!image)
            fail([NSString stringWithFormat:@"restore image load failed: %@", loadError]);

        VZMacOSConfigurationRequirements *requirements =
            image.mostFeaturefulSupportedConfiguration;
        if (!requirements)
            fail(@"restore image has no configuration supported by this Mac");

        VZMacHardwareModel *hardwareModel = requirements.hardwareModel;
        VZMacMachineIdentifier *machineIdentifier =
            [[VZMacMachineIdentifier alloc] init];
        NSURL *hardwareURL =
            [bundleURL URLByAppendingPathComponent:@"HardwareModel"];
        NSURL *identifierURL =
            [bundleURL URLByAppendingPathComponent:@"MachineIdentifier"];
        NSURL *auxiliaryURL =
            [bundleURL URLByAppendingPathComponent:@"AuxiliaryStorage"];

        if (![hardwareModel.dataRepresentation writeToURL:hardwareURL
                                                  options:NSDataWritingAtomic
                                                    error:&error])
            fail(error.localizedDescription);
        if (![machineIdentifier.dataRepresentation writeToURL:identifierURL
                                                       options:NSDataWritingAtomic
                                                         error:&error])
            fail(error.localizedDescription);

        if (![fm fileExistsAtPath:auxiliaryURL.path]) {
            VZMacAuxiliaryStorage *auxiliaryStorage =
                [[VZMacAuxiliaryStorage alloc]
                    initCreatingStorageAtURL:auxiliaryURL
                              hardwareModel:hardwareModel
                                     options:0
                                       error:&error];
            if (!auxiliaryStorage)
                fail([NSString stringWithFormat:
                    @"auxiliary storage creation failed: %@", error]);
            printf("AUXILIARY_STORAGE\tcreated\t%s\n",
                   auxiliaryURL.path.UTF8String);
        } else {
            printf("AUXILIARY_STORAGE\texisting\t%s\n",
                   auxiliaryURL.path.UTF8String);
        }

        printf("RESTORE\t%s\t%s\n",
               image.buildVersion.UTF8String,
               image.isSupported ? "supported" : "unsupported");
        printf("REQUIREMENTS\tcpu=%lu\tmemory=%llu\n",
               (unsigned long)requirements.minimumSupportedCPUCount,
               requirements.minimumSupportedMemorySize);
        printf("HARDWARE_MODEL\tbytes=%lu\tsupported=%d\n",
               (unsigned long)hardwareModel.dataRepresentation.length,
               hardwareModel.isSupported);
        printf("VM_METADATA_READY\t%s\n", bundleURL.path.UTF8String);
    }
    return 0;
}
