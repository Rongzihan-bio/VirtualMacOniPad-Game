#import "VZSupport.h"
#import "VZLocalization.h"

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

void VZAddFailureSupportActions(UIAlertController *alert)
{
    if (!alert)
        return;
    [alert addAction:[UIAlertAction actionWithTitle:VZL(@"Get Help")
        style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            (void)action;
            VZOpenSupportURL(VZGetHelpURLString);
        }]];
    [alert addAction:[UIAlertAction actionWithTitle:VZL(@"Report Issue")
        style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            (void)action;
            VZOpenSupportURL(VZReportIssueURLString);
        }]];
}
