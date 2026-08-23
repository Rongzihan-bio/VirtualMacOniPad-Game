#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface VZRestoreCatalog : NSObject
+ (void)loadWithCompletion:(void (^)(NSArray<NSDictionary *> *images,
                                     NSError *_Nullable error))completion;
+ (nullable NSDictionary *)recommendedImageFromImages:(NSArray<NSDictionary *> *)images;
+ (NSArray<NSString *> *)orderedGroupsForImages:(NSArray<NSDictionary *> *)images;
+ (BOOL)isExperimentalImage:(NSDictionary *)image;
+ (BOOL)isUnsupportedImage:(NSDictionary *)image;
+ (BOOL)enablesOpenGLByDefaultForImage:(NSDictionary *)image;
+ (NSInteger)majorVersionForImage:(NSDictionary *)image;
+ (NSString *)versionForImage:(NSDictionary *)image;
+ (nullable NSString *)marketingNameForImage:(NSDictionary *)image;
+ (NSString *)displayNameForImage:(NSDictionary *)image compact:(BOOL)compact;
+ (NSString *)macOSNameForImage:(NSDictionary *)image;
+ (NSString *)artworkNameForImage:(NSDictionary *)image;
+ (NSString *)artworkNameForMachineName:(NSString *)name;
+ (NSString *)defaultVirtualMachineNameForRestoreImagePath:(NSString *)path;
@end

NS_ASSUME_NONNULL_END
