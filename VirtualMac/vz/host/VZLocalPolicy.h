#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Disables guest SIP by updating the signed LocalPolicy stored in the VM's
// iBoot System Container. The disk remains a sparse regular file: at most one
// already-allocated 4 KiB filesystem block is replaced.
BOOL VZEnsureGuestSIPDisabled(NSString *bundlePath, NSError **error);
BOOL VZSetGuestSIPEnabled(NSString *bundlePath, BOOL enabled,
                          NSError **error);

// Restores the exact signed policy saved before Virtual Mac's first change.
// If no policy was changed, this is a no-op.
BOOL VZRestoreGuestLocalPolicy(NSString *bundlePath, NSError **error);

NS_ASSUME_NONNULL_END
