#import "VZDiagnostics.h"
#import "VZAppSettings.h"
#import <errno.h>
#import <sys/stat.h>
#import <sys/sysctl.h>
#import <sys/utsname.h>
#import <pwd.h>
#import <unistd.h>

static uint32_t VZCRC32(NSData *data)
{
    uint32_t crc = UINT32_MAX;
    const uint8_t *bytes = data.bytes;
    for (NSUInteger index = 0; index < data.length; index++) {
        crc ^= bytes[index];
        for (NSUInteger bit = 0; bit < 8; bit++)
            crc = (crc >> 1) ^ (0xedb88320U & -(int32_t)(crc & 1));
    }
    return ~crc;
}

static NSString *VZDiagnosticsLibraryPath(void)
{
    return @"/var/mobile/Media/VirtualMac";
}

static NSArray *VZDiagnosticsInstallationPaths(void)
{
    NSString *directory = [VZDiagnosticsLibraryPath()
        stringByAppendingPathComponent:@"Installations"];
    NSMutableArray *paths = [NSMutableArray array];
    for (NSString *name in [NSFileManager.defaultManager
            contentsOfDirectoryAtPath:directory error:nil])
        [paths addObject:[directory stringByAppendingPathComponent:name]];
    return paths;
}

static void VZAppend16(NSMutableData *data, uint16_t value)
{
    [data appendBytes:&value length:sizeof(value)];
}

static void VZAppend32(NSMutableData *data, uint32_t value)
{
    [data appendBytes:&value length:sizeof(value)];
}

static NSData *VZBoundedFileData(NSString *path)
{
    NSFileHandle *handle = [NSFileHandle fileHandleForReadingAtPath:path];
    if (!handle)
        return nil;
    unsigned long long size = [handle seekToEndOfFile];
    const unsigned long long limit = 8ULL << 20;
    if (size > limit)
        [handle seekToFileOffset:size - limit];
    NSData *data = [handle readDataToEndOfFile];
    [handle closeFile];
    return data;
}

typedef void (^VZDiagnosticEntryHandler)(NSString *name, NSData *data);

static void VZAddEntry(VZDiagnosticEntryHandler handler,
                       NSString *name, NSData *data)
{
    if (!name.length || !data.length)
        return;
    handler(name, data);
}

static void VZEnumerateDiagnosticEntries(VZDiagnosticEntryHandler handler)
{
    struct utsname systemInfo = {0};
    uname(&systemInfo);
    size_t buildLength = 0;
    sysctlbyname("kern.osversion", NULL, &buildLength, NULL, 0);
    NSMutableData *buildData = [NSMutableData dataWithLength:buildLength ?: 1];
    if (buildLength)
        sysctlbyname("kern.osversion", buildData.mutableBytes,
                     &buildLength, NULL, 0);
    NSString *osBuild = buildLength
        ? [NSString stringWithUTF8String:buildData.bytes] : @"unknown";
    NSDictionary *fileSystem = [NSFileManager.defaultManager
        attributesOfFileSystemForPath:VZDiagnosticsLibraryPath() error:nil] ?: @{};
    NSDictionary *bundleInfo = NSBundle.mainBundle.infoDictionary ?: @{};
    NSString *manifest = [NSString stringWithFormat:
        @"Virtual Mac diagnostics\n"
         "Created: %@\nApp version: %@ (%@)\nDevice: %s\n"
         "iPadOS: %@ (%@)\nPhysical memory: %llu\nFree storage: %@\n",
        NSDate.date, bundleInfo[@"CFBundleShortVersionString"] ?: @"unknown",
        bundleInfo[@"CFBundleVersion"] ?: @"unknown", systemInfo.machine,
        NSProcessInfo.processInfo.operatingSystemVersionString, osBuild,
        (unsigned long long)NSProcessInfo.processInfo.physicalMemory,
        fileSystem[NSFileSystemFreeSize] ?: @"unknown"];
    VZAddEntry(handler, @"manifest.txt",
        [manifest dataUsingEncoding:NSUTF8StringEncoding]);

    NSData *settings = [NSPropertyListSerialization dataWithPropertyList:
        VZAppSettings.sharedSettings.dictionaryRepresentation
        format:NSPropertyListXMLFormat_v1_0 options:0 error:nil];
    VZAddEntry(handler, @"Settings.plist", settings);

    NSArray *logNames = @[@"VirtualMac.log", @"vmmhook.log",
        @"vmm.stderr.log", @"vzxpchook.log", @"pvg-trace.log",
        @"InternetSharing.stdout.log", @"InternetSharing.stderr.log",
        @"bootpd.stdout.log", @"bootpd.stderr.log"];
    for (NSString *name in logNames)
        VZAddEntry(handler, [@"logs" stringByAppendingPathComponent:name],
            VZBoundedFileData([@"/tmp" stringByAppendingPathComponent:name]));

    NSArray *temporary = [NSFileManager.defaultManager
        contentsOfDirectoryAtPath:@"/tmp" error:nil];
    for (NSString *name in temporary) {
        if (![name hasPrefix:@"VirtualMac-install"] &&
            ![name hasPrefix:@"vz-usbmuxd"] &&
            ![name hasPrefix:@"installation"])
            continue;
        VZAddEntry(handler, [@"restore" stringByAppendingPathComponent:name],
            VZBoundedFileData([@"/tmp" stringByAppendingPathComponent:name]));
    }

    NSMutableArray *inventory = [NSMutableArray array];
    NSArray *bundles = [NSFileManager.defaultManager
        contentsOfDirectoryAtPath:VZDiagnosticsLibraryPath() error:nil];
    for (NSString *name in bundles) {
        if (![name.pathExtension.lowercaseString isEqualToString:@"bundle"])
            continue;
        NSString *bundlePath = [VZDiagnosticsLibraryPath()
            stringByAppendingPathComponent:name];
        NSMutableDictionary *item = [NSMutableDictionary dictionary];
        item[@"Name"] = name;
        for (NSString *fileName in @[@"Disk.img", @"MachineIdentifier",
                                      @"AuxiliaryStorage", @"HardwareModel"]) {
            NSDictionary *attributes = [NSFileManager.defaultManager
                attributesOfItemAtPath:[bundlePath
                    stringByAppendingPathComponent:fileName] error:nil];
            if (attributes[NSFileSize])
                item[fileName] = attributes[NSFileSize];
        }
        [inventory addObject:item];
        NSString *configuration = [bundlePath
            stringByAppendingPathComponent:@"VirtualMac.plist"];
        VZAddEntry(handler,
            [NSString stringWithFormat:@"virtual-machines/%@/VirtualMac.plist",
                                       name],
            VZBoundedFileData(configuration));
    }
    NSData *inventoryData = [NSJSONSerialization dataWithJSONObject:inventory
        options:NSJSONWritingPrettyPrinted error:nil];
    VZAddEntry(handler, @"virtual-machines/inventory.json", inventoryData);

    NSString *crashRoot = @"/var/mobile/Library/Logs/CrashReporter";
    NSDirectoryEnumerator *crashEnumerator = [NSFileManager.defaultManager
        enumeratorAtPath:crashRoot];
    NSUInteger crashFileCount = 0;
    NSUInteger unreadableCrashFileCount = 0;
    for (NSString *relativePath in crashEnumerator) {
        NSString *path = [crashRoot stringByAppendingPathComponent:relativePath];
        BOOL directory = NO;
        if (![NSFileManager.defaultManager fileExistsAtPath:path
            isDirectory:&directory] || directory)
            continue;
        NSData *contents = [[NSData alloc] initWithContentsOfFile:path];
        if (!contents) {
            unreadableCrashFileCount++;
            continue;
        }
        crashFileCount++;
        VZAddEntry(handler, [@"crash-reports"
            stringByAppendingPathComponent:relativePath], contents);
        [contents release];
    }
    NSString *crashSummary = [NSString stringWithFormat:
        @"Included files: %lu\nUnreadable files: %lu\nSource: %@\n",
        (unsigned long)crashFileCount,
        (unsigned long)unreadableCrashFileCount, crashRoot];
    VZAddEntry(handler, @"crash-reports/summary.txt",
        [crashSummary dataUsingEncoding:NSUTF8StringEncoding]);

    for (NSString *artifactPath in VZDiagnosticsInstallationPaths()) {
        NSDirectoryEnumerator *enumerator = [NSFileManager.defaultManager
            enumeratorAtPath:artifactPath];
        for (NSString *relativePath in enumerator) {
            NSString *extension = relativePath.pathExtension.lowercaseString;
            if (![@[@"plist", @"log", @"txt"] containsObject:extension])
                continue;
            NSString *path = [artifactPath stringByAppendingPathComponent:
                relativePath];
            NSString *archiveName = [NSString stringWithFormat:
                @"restore/attempts/%@/%@", artifactPath.lastPathComponent,
                relativePath];
            VZAddEntry(handler, archiveName, VZBoundedFileData(path));
        }
    }
}

NSURL *VZCreateDiagnosticsArchive(NSError **error)
{
    NSString *directory = [@"/var/mobile/Media/VirtualMac"
        stringByAppendingPathComponent:@"Diagnostics"];
    if (![NSFileManager.defaultManager createDirectoryAtPath:directory
        withIntermediateDirectories:YES attributes:nil error:error])
        return nil;
    NSDateFormatter *formatter = [[[NSDateFormatter alloc] init] autorelease];
    formatter.dateFormat = @"yyyyMMdd-HHmmss";
    NSString *path = [directory stringByAppendingPathComponent:
        [NSString stringWithFormat:@"VirtualMac-Diagnostics-%@.zip",
                                   [formatter stringFromDate:NSDate.date]]];

    [NSFileManager.defaultManager createFileAtPath:path contents:nil
                                       attributes:nil];
    NSFileHandle *archive = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!archive) {
        if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain
            code:EIO userInfo:@{NSLocalizedDescriptionKey:
                @"The diagnostics archive could not be opened."}];
        return nil;
    }
    NSMutableArray *central = [NSMutableArray array];
    __block uint64_t archiveLength = 0;
    @try {
        VZEnumerateDiagnosticEntries(^(NSString *entryName, NSData *contents) {
            NSData *name = [entryName dataUsingEncoding:NSUTF8StringEncoding];
            uint64_t resultingLength = archiveLength + 30 + name.length +
                contents.length;
            if (name.length > UINT16_MAX || contents.length > UINT32_MAX ||
                resultingLength > UINT32_MAX || central.count >= UINT16_MAX)
                return;
            uint32_t offset = (uint32_t)archiveLength;
            uint32_t crc = VZCRC32(contents);
            NSMutableData *header = [NSMutableData data];
            VZAppend32(header, 0x04034b50);
            VZAppend16(header, 20); VZAppend16(header, 0);
            VZAppend16(header, 0); VZAppend16(header, 0);
            VZAppend16(header, 0); VZAppend32(header, crc);
            VZAppend32(header, (uint32_t)contents.length);
            VZAppend32(header, (uint32_t)contents.length);
            VZAppend16(header, (uint16_t)name.length); VZAppend16(header, 0);
            [archive writeData:header];
            [archive writeData:name];
            [archive writeData:contents];
            archiveLength = resultingLength;
            [central addObject:@{ @"name": name, @"size": @(contents.length),
                                  @"crc": @(crc), @"offset": @(offset) }];
        });
    } @catch (NSException *exception) {
        [archive closeFile];
        [NSFileManager.defaultManager removeItemAtPath:path error:nil];
        if (error) *error = [NSError errorWithDomain:NSCocoaErrorDomain
            code:NSFileWriteUnknownError userInfo:@{NSLocalizedDescriptionKey:
                exception.reason ?: @"The diagnostics archive could not be written."}];
        return nil;
    }
    uint32_t centralOffset = (uint32_t)archiveLength;
    NSMutableData *centralData = [NSMutableData data];
    for (NSDictionary *entry in central) {
        NSData *name = entry[@"name"];
        VZAppend32(centralData, 0x02014b50);
        VZAppend16(centralData, 20); VZAppend16(centralData, 20);
        VZAppend16(centralData, 0); VZAppend16(centralData, 0);
        VZAppend16(centralData, 0); VZAppend16(centralData, 0);
        VZAppend32(centralData, [entry[@"crc"] unsignedIntValue]);
        VZAppend32(centralData, [entry[@"size"] unsignedIntValue]);
        VZAppend32(centralData, [entry[@"size"] unsignedIntValue]);
        VZAppend16(centralData, (uint16_t)name.length);
        VZAppend16(centralData, 0); VZAppend16(centralData, 0);
        VZAppend16(centralData, 0); VZAppend16(centralData, 0);
        VZAppend32(centralData, 0);
        VZAppend32(centralData, [entry[@"offset"] unsignedIntValue]);
        [centralData appendData:name];
    }
    uint32_t centralSize = (uint32_t)centralData.length;
    VZAppend32(centralData, 0x06054b50);
    VZAppend16(centralData, 0); VZAppend16(centralData, 0);
    VZAppend16(centralData, (uint16_t)central.count);
    VZAppend16(centralData, (uint16_t)central.count);
    VZAppend32(centralData, centralSize); VZAppend32(centralData, centralOffset);
    VZAppend16(centralData, 0);
    [archive writeData:centralData];
    [archive synchronizeFile];
    [archive closeFile];
    chmod(path.fileSystemRepresentation, 0644);
    if (geteuid() == 0) {
        struct passwd *mobile = getpwnam("mobile");
        if (mobile) {
            chown(directory.fileSystemRepresentation,
                  mobile->pw_uid, mobile->pw_gid);
            chown(path.fileSystemRepresentation,
                  mobile->pw_uid, mobile->pw_gid);
        }
    }
    return [NSURL fileURLWithPath:path];
}
