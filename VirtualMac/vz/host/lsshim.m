// CoreServices/LaunchServices shim for the iOS-ported VZ VMM service.
// macOS CoreServices re-exports LaunchServices, which exports _LSApplicationCheckIn
// (the app's check-in with the LS database during launch). iOS CoreServices has no
// such export. The extracted VMM binds it (it's an Application-type XPCService), so
// dyld fails the load. We re-export the device's real CoreServices (so every other
// symbol resolves) and define _LSApplicationCheckIn as a benign success stub — on the
// headless direct-spawn path there is no LS launch context to check into.
// Wire-up: change the VMM binary's CoreServices LC_LOAD_DYLIB to /var/root/lsshim.ios.
#import <CoreFoundation/CoreFoundation.h>

// Real macOS signature is private/variadic; as a noErr stub the args are irrelevant
// (callee ignores them; returns 0 in x0). Four pointer params cover the common ABI.
int _LSApplicationCheckIn(void *a, void *b, void *c, void *d) {
    (void)a; (void)b; (void)c; (void)d;
    return 0; // noErr
}
