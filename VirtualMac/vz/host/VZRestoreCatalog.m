#import "VZRestoreCatalog.h"

static NSString * const VZCatalogURL =
    @"https://api.virtualbuddy.app/v2/restore/mac?apiKey=15A25D48-4A34-4EE4-A293-C22B0DE1B54E";

static NSString *VZRestoreString(id value)
{
    return [value isKindOfClass:NSString.class] ? value : @"";
}

static NSString *VZRestoreVersionFromName(NSString *name)
{
    NSRegularExpression *expression = [NSRegularExpression
        regularExpressionWithPattern:@"[0-9]+(?:\\.[0-9]+){0,2}"
        options:0 error:nil];
    NSTextCheckingResult *match = [expression firstMatchInString:name
        options:0 range:NSMakeRange(0, name.length)];
    return match ? [name substringWithRange:match.range] : @"";
}

static NSInteger VZRestoreMajorVersion(NSString *version)
{
    NSScanner *scanner = [NSScanner scannerWithString:version];
    NSInteger major = 0;
    return [scanner scanInteger:&major] ? major : 0;
}

@implementation VZRestoreCatalog

+ (NSArray *)imagesFromData:(NSData *)data error:(NSError **)error
{
    if (!data.length) return nil;
    NSDictionary *root = [NSJSONSerialization JSONObjectWithData:data options:0 error:error];
    NSArray *images = [root isKindOfClass:NSDictionary.class]
        ? root[@"restoreImages"] : nil;
    if (![images isKindOfClass:NSArray.class])
        return nil;
    NSMutableArray *normalized = [NSMutableArray array];
    for (id candidate in images) {
        if (![candidate isKindOfClass:NSDictionary.class])
            continue;
        NSMutableDictionary *image = [NSMutableDictionary
            dictionaryWithDictionary:candidate];
        NSString *urlString = VZRestoreString(image[@"url"]);
        NSURL *url = [NSURL URLWithString:urlString];
        if (!url.host.length ||
            !([url.scheme.lowercaseString isEqualToString:@"https"] ||
              [url.scheme.lowercaseString isEqualToString:@"http"]))
            continue;
        NSString *name = VZRestoreString(image[@"name"]);
        NSString *version = VZRestoreString(image[@"version"]);
        if (!version.length)
            version = VZRestoreVersionFromName(name);
        NSString *group = VZRestoreString(image[@"group"]).lowercaseString;
        if (!group.length) {
            NSInteger major = VZRestoreMajorVersion(version);
            group = major > 0
                ? [NSString stringWithFormat:@"macos-%ld", (long)major]
                : @"unknown";
        }
        NSString *channel = VZRestoreString(image[@"channel"]).lowercaseString;
        if (![channel isEqualToString:@"regular"] &&
            ![channel isEqualToString:@"devbeta"])
            channel = [channel containsString:@"beta"] ? @"devbeta" : @"regular";
        if (!name.length)
            name = version.length ? [NSString stringWithFormat:@"macOS %@", version]
                                  : url.lastPathComponent;
        image[@"url"] = url.absoluteString;
        image[@"name"] = name ?: @"macOS";
        image[@"version"] = version ?: @"";
        image[@"group"] = group;
        image[@"channel"] = channel;
        image[@"build"] = VZRestoreString(image[@"build"]);
        image[@"downloadSize"] = @([image[@"downloadSize"] longLongValue]);
        [normalized addObject:image];
    }
    return normalized;
}

+ (void)loadWithCompletion:(void (^)(NSArray<NSDictionary *> *, NSError *))completion
{
    NSURL *url = [NSURL URLWithString:VZCatalogURL];
    [[[NSURLSession sharedSession] dataTaskWithURL:url
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSError *parseError = nil;
        NSArray *images = [self imagesFromData:data error:&parseError];
        if (!images.count) {
            NSString *fallback = [NSBundle.mainBundle pathForResource:@"ipsws_v2" ofType:@"json"];
            NSData *fallbackData = [NSData dataWithContentsOfFile:fallback];
            images = [self imagesFromData:fallbackData error:&parseError];
        }
        NSArray *result = images ?: @[];
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(result, result.count ? nil : (error ?: parseError));
        });
    }] resume];
}

+ (NSDictionary *)recommendedImageFromImages:(NSArray<NSDictionary *> *)images
{
    NSArray *matches = [images filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:
        ^BOOL(NSDictionary *image, NSDictionary *bindings) {
            (void)bindings;
            return [VZRestoreString(image[@"group"]) isEqualToString:@"sequoia"] &&
                [VZRestoreString(image[@"channel"]) isEqualToString:@"regular"];
        }]];
    if (!matches.count)
        matches = [images filteredArrayUsingPredicate:[NSPredicate
            predicateWithBlock:^BOOL(NSDictionary *image,
                                      NSDictionary *bindings) {
            (void)bindings;
            return [VZRestoreString(image[@"channel"])
                isEqualToString:@"regular"];
        }]];
    return [matches sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *left, NSDictionary *right) {
        return [VZRestoreString(right[@"version"])
            compare:VZRestoreString(left[@"version"]) options:NSNumericSearch];
    }].firstObject;
}

+ (NSArray<NSString *> *)orderedGroupsForImages:(NSArray<NSDictionary *> *)images
{
    NSArray *preferred = @[@"goldengate", @"tahoe", @"sequoia",
                           @"sonoma", @"ventura", @"monterey"];
    NSMutableArray *result = [NSMutableArray array];
    NSMutableSet *present = [NSMutableSet set];
    for (NSDictionary *image in images) {
        NSString *group = VZRestoreString(image[@"group"]);
        if (group.length)
            [present addObject:group];
    }
    for (NSString *group in preferred) if ([present containsObject:group]) [result addObject:group];
    NSArray *unknown = [[present allObjects]
        sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
    for (NSString *group in unknown)
        if (![result containsObject:group]) [result addObject:group];
    return result;
}

+ (BOOL)isExperimentalImage:(NSDictionary *)image
{
    NSString *group = VZRestoreString(image[@"group"]).lowercaseString;
    NSString *version = VZRestoreString(image[@"version"]);
    if (!version.length)
        version = VZRestoreVersionFromName(VZRestoreString(image[@"name"]));
    return [group isEqualToString:@"goldengate"] ||
        [group isEqualToString:@"golden-gate"] ||
        VZRestoreMajorVersion(version) >= 27;
}

+ (BOOL)isUnsupportedImage:(NSDictionary *)image
{
    NSString *version = VZRestoreString(image[@"version"]);
    if (!version.length)
        version = VZRestoreVersionFromName(VZRestoreString(image[@"name"]));
    return VZRestoreMajorVersion(version) >= 28;
}

+ (NSString *)macOSNameForImage:(NSDictionary *)image
{
    NSString *group = VZRestoreString(image[@"group"]).lowercaseString;
    NSString *version = VZRestoreString(image[@"version"]);
    if (!version.length)
        version = VZRestoreVersionFromName(VZRestoreString(image[@"name"]));
    NSInteger major = VZRestoreMajorVersion(version);
    NSDictionary *known = @{ @"monterey": @"Monterey",
        @"ventura": @"Ventura", @"sonoma": @"Sonoma",
        @"sequoia": @"Sequoia", @"tahoe": @"Tahoe",
        @"goldengate": @"Golden Gate", @"golden-gate": @"Golden Gate" };
    NSString *marketingName = known[group];
    if (!marketingName.length) {
        NSDictionary *byMajor = @{ @12: @"Monterey", @13: @"Ventura",
            @14: @"Sonoma", @15: @"Sequoia", @26: @"Tahoe",
            @27: @"Golden Gate" };
        marketingName = byMajor[@(major)];
    }
    if (marketingName.length)
        return [@"macOS " stringByAppendingString:marketingName];
    return major > 0 ? [NSString stringWithFormat:@"macOS %ld", (long)major]
                     : @"macOS";
}

+ (NSString *)artworkNameForImage:(NSDictionary *)image
{
    NSString *group = VZRestoreString(image[@"group"]).lowercaseString;
    NSDictionary *known = @{ @"monterey": @"monterey",
        @"ventura": @"ventura", @"sonoma": @"sonoma",
        @"sequoia": @"sequoia", @"tahoe": @"tahoe",
        @"goldengate": @"golden-gate", @"golden-gate": @"golden-gate" };
    NSString *artwork = known[group];
    if (artwork.length)
        return artwork;
    NSString *version = VZRestoreString(image[@"version"]);
    if (!version.length)
        version = VZRestoreVersionFromName(VZRestoreString(image[@"name"]));
    NSDictionary *byMajor = @{ @12: @"monterey", @13: @"ventura",
        @14: @"sonoma", @15: @"sequoia", @26: @"tahoe",
        @27: @"golden-gate" };
    return byMajor[@(VZRestoreMajorVersion(version))] ?: @"ipsw";
}

@end
