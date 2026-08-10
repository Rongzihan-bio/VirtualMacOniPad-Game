#include <CoreFoundation/CoreFoundation.h>

// Added to IOKit after iPadOS 15. The Ventura VMM only uses the value as the
// HID caps-lock LED property key, so preserve the desktop spelling.
const CFStringRef kIOHIDServiceCapsLockLEDOnKey =
    CFSTR("CapsLockLEDOn");
