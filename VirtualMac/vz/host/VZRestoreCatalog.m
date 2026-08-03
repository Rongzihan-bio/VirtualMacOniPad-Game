#import "VZRestoreCatalog.h"

static NSString * const VZCatalogURL =
    @"https://api.virtualbuddy.app/v2/restore/mac?apiKey=15A25D48-4A34-4EE4-A293-C22B0DE1B54E";

@implementation VZRestoreCatalog

+ (NSArray *)imagesFromData:(NSData *)data error:(NSError **)error
{
    if (!data.length) return nil;
    NSDictionary *root = [NSJSONSerialization JSONObjectWithData:data options:0 error:error];
    NSArray *images = [root isKindOfClass:NSDictionary.class] ? root[@"restoreImages"] : nil;
    return [images isKindOfClass:NSArray.class] ? images : nil;
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
            return [image[@"group"] isEqualToString:@"sequoia"] &&
                [image[@"channel"] isEqualToString:@"regular"];
        }]];
    return [matches sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *left, NSDictionary *right) {
        return [right[@"version"] compare:left[@"version"] options:NSNumericSearch];
    }].firstObject;
}

+ (NSArray<NSString *> *)orderedGroupsForImages:(NSArray<NSDictionary *> *)images
{
    NSArray *preferred = @[@"goldengate", @"tahoe", @"sequoia",
                           @"sonoma", @"ventura", @"monterey"];
    NSMutableArray *result = [NSMutableArray array];
    NSSet *present = [NSSet setWithArray:[images valueForKey:@"group"]];
    for (NSString *group in preferred) if ([present containsObject:group]) [result addObject:group];
    for (NSString *group in present) if (![result containsObject:group]) [result addObject:group];
    return result;
}

@end
