#include <errno.h>
#include <stddef.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

// Ventura's VMM imports a small libSystem surface introduced with iPadOS 16.
// Raw local VM disks do not exercise the encrypted DiskImages or *at helpers,
// but dyld must still resolve them on iPadOS 15. Return a real unsupported
// result if an unexpected configuration reaches one of these paths.
static int unsupported(void) {
    errno = ENOTSUP;
    return -1;
}

int ccctr_init(const void *mode, void *context, size_t keyLength,
               const void *key, const void *iv) {
    (void)mode; (void)context; (void)keyLength; (void)key; (void)iv;
    return unsupported();
}

int ccctr_update(void *context, size_t length,
                 const void *input, void *output) {
    (void)context; (void)length; (void)input; (void)output;
    return unsupported();
}

int ccctr_one_shot(const void *mode, size_t keyLength, const void *key,
                   const void *iv, size_t length,
                   const void *input, void *output) {
    (void)mode; (void)keyLength; (void)key; (void)iv;
    (void)length; (void)input; (void)output;
    return unsupported();
}

int ccecb_one_shot(const void *mode, size_t keyLength, const void *key,
                   size_t blockCount, const void *input, void *output) {
    (void)mode; (void)keyLength; (void)key;
    (void)blockCount; (void)input; (void)output;
    return unsupported();
}

ssize_t freadlink(int descriptor, char *buffer, size_t size) {
    (void)descriptor; (void)buffer; (void)size;
    return (ssize_t)unsupported();
}

int mkfifoat(int descriptor, const char *path, mode_t mode) {
    (void)descriptor; (void)path; (void)mode;
    return unsupported();
}

int mknodat(int descriptor, const char *path, mode_t mode, dev_t device) {
    (void)descriptor; (void)path; (void)mode; (void)device;
    return unsupported();
}
