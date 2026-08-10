#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString * const VZGetHelpURLString;
FOUNDATION_EXPORT NSString * const VZReportIssueURLString;

typedef NS_OPTIONS(NSUInteger, VZFailureSupportOptions) {
    VZFailureSupportOptionNone = 0,
    VZFailureSupportOptionSuggestDebugLogging = 1 << 0,
    VZFailureSupportOptionDiagnosticsUnavailable = 1 << 1,
    VZFailureSupportOptionSuggestScreenRecording = 1 << 2,
};

FOUNDATION_EXPORT void VZOpenSupportURL(NSString *urlString);
FOUNDATION_EXPORT void VZPresentFailureReport(
    UIViewController *presenter, NSString *title,
    NSString * _Nullable message, NSString * _Nullable details,
    VZFailureSupportOptions options);

NS_ASSUME_NONNULL_END
