#import <UIKit/UIKit.h>
#import "VZSupport.h"

NS_ASSUME_NONNULL_BEGIN

@interface VZFailureDetailsViewController : UITableViewController
    <UIDocumentPickerDelegate>
- (instancetype)initWithTitle:(NSString *)title
                       message:(nullable NSString *)message
                       details:(nullable NSString *)details
                       options:(VZFailureSupportOptions)options;
- (void)setDestructiveActionTitle:(NSString *)title
                          handler:(void (^)(void))handler;
@end

NS_ASSUME_NONNULL_END
