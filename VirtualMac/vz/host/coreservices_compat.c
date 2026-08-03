#include <math.h>

/* Legacy Carbon assertion hook; MobileDevice uses it only on failed checks. */
void DebugAssert(void *componentSignature, unsigned long options,
                 const char *assertionString, const char *exceptionLabelString,
                 const char *errorString, const char *fileName,
                 long lineNumber, void *value)
{
    (void)componentSignature;
    (void)options;
    (void)assertionString;
    (void)exceptionLabelString;
    (void)errorString;
    (void)fileName;
    (void)lineNumber;
    (void)value;
}

/* macOS CoreServices re-exports this libSystem math entry point; iPadOS does not. */
double log2(double value)
{
    return log(value) / 0.69314718055994530942;
}
