#import "VZSupport.h"
#import "VZFailureDetailsViewController.h"

NSString * const VZGetHelpURLString =
    @"https://github.com/nfzerox/VirtualMacOniPad#what-if-i-encounter-crashes-bugs-or-other-issues";
NSString * const VZReportIssueURLString =
    @"https://github.com/nfzerox/VirtualMacOniPad/issues?q=is%3Aissue";

void VZOpenSupportURL(NSString *urlString)
{
    NSURL *url = [NSURL URLWithString:urlString];
    if (url)
        [UIApplication.sharedApplication openURL:url options:@{}
            completionHandler:nil];
}

static UIViewController *VZTopViewController(void)
{
    UIWindow *window = nil;
    for (UIWindow *candidate in UIApplication.sharedApplication.windows) {
        if (candidate.isKeyWindow) { window = candidate; break; }
    }
    window = window ?: UIApplication.sharedApplication.windows.firstObject;
    UIViewController *controller = window.rootViewController;
    while (controller.presentedViewController)
        controller = controller.presentedViewController;
    if ([controller isKindOfClass:UINavigationController.class])
        controller = ((UINavigationController *)controller).topViewController;
    return controller;
}

void VZPresentFailureReport(UIViewController *presenter, NSString *title,
                            NSString *message, NSString *details,
                            VZFailureSupportOptions options)
{
    presenter = presenter ?: VZTopViewController();
    if (!presenter)
        return;
    VZFailureDetailsViewController *controller =
        [[[VZFailureDetailsViewController alloc]
            initWithTitle:title message:message details:details
            options:options] autorelease];
    UINavigationController *navigation = [[[UINavigationController alloc]
        initWithRootViewController:controller] autorelease];
    navigation.modalPresentationStyle = UIModalPresentationPageSheet;
    navigation.preferredContentSize = CGSizeMake(640, 720);
    [presenter presentViewController:navigation animated:YES completion:nil];
}
