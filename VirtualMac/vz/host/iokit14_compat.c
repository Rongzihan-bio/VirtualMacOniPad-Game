#include <CoreFoundation/CoreFoundation.h>
#include <mach/mach.h>

// Renamed from kIOMasterPortDefault after iPadOS 14. Both constants represent
// the default IOKit main port and are MACH_PORT_NULL by contract.
const mach_port_t kIOMainPortDefault = MACH_PORT_NULL;

// IOMainPort replaced IOMasterPort after iPadOS 14. Forward the Ventura
// spelling to the identical legacy operation on the oldest supported host.
extern kern_return_t IOMasterPort(mach_port_t bootstrapPort,
                                  mach_port_t *masterPort);

kern_return_t IOMainPort(mach_port_t bootstrapPort, mach_port_t *mainPort)
{
    return IOMasterPort(bootstrapPort, mainPort);
}

const CFStringRef kIOHIDServiceCapsLockLEDOnKey =
    CFSTR("CapsLockLEDOn");
