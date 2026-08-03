#include <stdbool.h>

/*
 * iPadOS 16 has DIInitialize and the attach APIs used by MobileDevice, but it
 * lacks macOS's DIIsInitialized query. Returning false asks MobileDevice to
 * run the native idempotent initializer before use.
 */
bool DIIsInitialized(void)
{
    return false;
}
