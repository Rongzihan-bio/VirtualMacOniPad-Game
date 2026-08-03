#include <stddef.h>
#include <stdlib.h>
#include <string.h>

/*
 * Ventura's MobileDevice binds strndup to CoreUtils rather than libSystem.
 * iPadOS provides strndup in libSystem but does not re-export it from its
 * CoreUtils image.  This compatibility image occupies MobileDevice's
 * CoreUtils dependency ordinal, re-exports native CoreUtils, and supplies the
 * one missing entry point.
 */
char *strndup(const char *source, size_t maximumLength)
{
    const char *end = memchr(source, '\0', maximumLength);
    size_t length = end ? (size_t)(end - source) : maximumLength;
    char *copy = malloc(length + 1);
    if (copy == NULL) {
        return NULL;
    }
    memcpy(copy, source, length);
    copy[length] = '\0';
    return copy;
}
