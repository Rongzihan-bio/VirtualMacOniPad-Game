#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface VZRestoreCatalog : NSObject
+ (void)loadWithCompletion:(void (^)(NSArray<NSDictionary *> *images,
                                     NSError *_Nullable error))completion;
+ (nullable NSDictionary *)recommendedImageFromImages:(NSArray<NSDictionary *> *)images;
+ (NSArray<NSString *> *)orderedGroupsForImages:(NSArray<NSDictionary *> *)images;
+ (BOOL)isExperimentalImage:(NSDictionary *)image;
+ (BOOL)isUnsupportedImage:(NSDictionary *)image;
+ (NSString *)macOSNameForImage:(NSDictionary *)image;
+ (NSString *)artworkNameForImage:(NSDictionary *)image;
@end

NS_ASSUME_NONNULL_END
