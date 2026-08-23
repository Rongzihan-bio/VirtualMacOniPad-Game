#import <Foundation/Foundation.h>

#ifndef EXPERIMENT_GDB_DEBUG
#define EXPERIMENT_GDB_DEBUG 0
#endif

#if EXPERIMENT_GDB_DEBUG
NS_ASSUME_NONNULL_BEGIN

// Virtualization's private localhost-only GDB endpoint is used once during
// early boot to apply the guest policy required by Virtual Mac Guest Tools and
// enhanced OpenGL. No vCPU or graphics hot path is hooked.
BOOL VZGuestRuntimePolicyConfigureDebugStub(id configuration, BOOL enabled);
void VZGuestRuntimePolicyConfigureStartOptions(id startOptions);
void VZGuestRuntimePolicyApplyAsync(
    void (^completion)(BOOL success, NSError *_Nullable error));

NS_ASSUME_NONNULL_END
#endif
