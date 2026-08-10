#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Creates a self-contained ZIP containing bounded Virtual Mac logs,
// configuration, and device metadata. Guest disks and shared files are never
// included. The caller may present the returned URL with a share sheet.
FOUNDATION_EXPORT NSURL * _Nullable VZCreateDiagnosticsArchive(
    NSError **error);

NS_ASSUME_NONNULL_END
