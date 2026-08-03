#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@class VZNewVMViewController;
@protocol VZNewVMViewControllerDelegate <NSObject>
- (void)newVMControllerChooseLocalRestoreImage:(VZNewVMViewController *)controller;
- (void)newVMController:(VZNewVMViewController *)controller
    downloadRestoreImage:(NSDictionary *)image;
@end

@interface VZNewVMViewController : UITableViewController
@property(nonatomic, assign) id<VZNewVMViewControllerDelegate> delegate;
@end

NS_ASSUME_NONNULL_END
