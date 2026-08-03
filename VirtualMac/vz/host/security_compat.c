#include <stdint.h>
#include <stdlib.h>

typedef int32_t OSStatus;
enum { errSecUnimplemented = -4, errSecSuccess = 0 };

/*
 * These six APIs are the legacy macOS keychain surface imported by
 * MobileDevice 1857. iPadOS's Security framework has the underlying SecItem
 * API but omits the compatibility entry points. Keep the loader ABI complete;
 * calls are deliberately reported as unsupported until their SecItem-backed
 * translations are exercised by the restore path.
 */
OSStatus SecItemImport(const void *data, const void *name, void *format,
                       void *type, uint32_t flags, const void *parameters,
                       void *keychain, void *items)
{
    (void)data; (void)name; (void)format; (void)type; (void)flags;
    (void)parameters; (void)keychain; (void)items;
    return errSecUnimplemented;
}

OSStatus SecKeychainAddGenericPassword(void *keychain, uint32_t serviceLength,
                                       const char *service, uint32_t accountLength,
                                       const char *account, uint32_t passwordLength,
                                       const void *password, void *item)
{
    (void)keychain; (void)serviceLength; (void)service; (void)accountLength;
    (void)account; (void)passwordLength; (void)password; (void)item;
    return errSecUnimplemented;
}

OSStatus SecKeychainFindGenericPassword(void *keychain, uint32_t serviceLength,
                                        const char *service, uint32_t accountLength,
                                        const char *account, uint32_t *passwordLength,
                                        void **password, void *item)
{
    (void)keychain; (void)serviceLength; (void)service; (void)accountLength;
    (void)account; (void)passwordLength; (void)password; (void)item;
    return errSecUnimplemented;
}

OSStatus SecKeychainItemDelete(void *item)
{
    (void)item;
    return errSecUnimplemented;
}

OSStatus SecKeychainItemFreeContent(void *attributes, void *data)
{
    (void)attributes;
    free(data);
    return errSecSuccess;
}

OSStatus SecKeychainItemModifyContent(void *item, const void *attributes,
                                      uint32_t length, const void *data)
{
    (void)item; (void)attributes; (void)length; (void)data;
    return errSecUnimplemented;
}
