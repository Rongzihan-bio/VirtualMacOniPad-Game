#include <stdbool.h>

/* MobileDevice only consults this policy bit while preparing diagnostics. */
bool CRIsAutoSubmitEnabled(void)
{
    return false;
}
