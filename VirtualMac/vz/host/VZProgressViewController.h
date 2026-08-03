#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface VZProgressViewController : UIViewController
@property(nonatomic, copy) NSString *statusText;
@property(nonatomic, copy, nullable) NSString *detailText;
@property(nonatomic, copy, nullable) NSString *consoleText;
@property(nonatomic, copy, nullable) dispatch_block_t cancellationHandler;
@property(nonatomic, assign) float progress;
@property(nonatomic, assign, getter=isIndeterminate) BOOL indeterminate;
@property(nonatomic, assign) BOOL consoleHidden;
- (instancetype)initWithTitle:(NSString *)title;
@end

NS_ASSUME_NONNULL_END
