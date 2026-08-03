#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString * const VZVMConfigurationFileName;

NSDictionary *VZVMDefaultOptions(void);
NSDictionary *VZVMOptionsForBundle(NSString *bundlePath);
BOOL VZRestoreImageUsesMontereyProfile(NSString *path);
BOOL VZWriteVMOptions(NSDictionary *options, NSString *bundlePath,
                      NSError **error);
BOOL VZIsValidVMBundle(NSString *path);
NSString *_Nullable VZVMStableIdentifier(NSString *path);
NSArray<NSDictionary *> *VZDiscoverVirtualMachines(void);
NSArray<NSString *> *VZInstallationArtifactPaths(void);
NSArray<NSString *> *VZCachedRestoreImagePaths(void);
void VZRemovePaths(NSArray<NSString *> *paths);
NSString *VZVMLibraryPath(void);
NSString *VZVMSupportPath(void);
NSString *VZRestoreImagesPath(void);
NSString *VZInstallationsPath(void);

@class VZVMLibraryViewController;

@protocol VZVMLibraryViewControllerDelegate <NSObject>
- (void)vmLibrary:(VZVMLibraryViewController *)library
    bootBundleAtPath:(NSString *)path
             options:(NSDictionary *)options;
- (void)vmLibrary:(VZVMLibraryViewController *)library
    installRestoreImageAtURL:(NSURL *)url
                        name:(NSString *)name
                     options:(NSDictionary *)options;
@optional
- (nullable NSString *)activeVMBundlePathForLibrary:
    (VZVMLibraryViewController *)library;
- (void)vmLibraryResumeActiveVM:(VZVMLibraryViewController *)library;
- (void)vmLibraryForceShutdownActiveVM:
    (VZVMLibraryViewController *)library;
@end

@interface VZVMLibraryViewController : UIViewController
    <UIDocumentPickerDelegate>
@property(nonatomic, assign) id<VZVMLibraryViewControllerDelegate> delegate;
- (void)reloadLibrary;
- (void)presentNewVMFlow;
- (void)presentSettings;
@end

NS_ASSUME_NONNULL_END
