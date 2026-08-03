#include <CoreFoundation/CoreFoundation.h>

/*
 * Ventura's bootpd still links OpenDirectory for optional NetBoot and
 * directory-backed account management.  iPadOS 16 ships the framework but
 * not these desktop-only exports.  Basic DHCP never enters these routines;
 * keep the imports resolvable and report the optional service as unavailable
 * if a future configuration does request it.
 */

const void *kODAttributeTypeStandardOnly = NULL;
const void *kODRecordTypeGroups = NULL;
const void *kODSessionDefault = NULL;

static void clear_error(void **error)
{
    if (error != NULL) {
        *error = NULL;
    }
}

void *ODNodeCopyRecord(void *node, void *record_type, void *record_name,
                       void *attributes, void **error)
{
    (void)node;
    (void)record_type;
    (void)record_name;
    (void)attributes;
    clear_error(error);
    return NULL;
}

void *ODNodeCreateRecord(void *node, void *record_type, void *record_name,
                         void *attributes, void **error)
{
    (void)node;
    (void)record_type;
    (void)record_name;
    (void)attributes;
    clear_error(error);
    return NULL;
}

void *ODNodeCreateWithNodeType(void *allocator, void *session,
                               unsigned int node_type, void **error)
{
    (void)allocator;
    (void)session;
    (void)node_type;
    clear_error(error);
    return NULL;
}

void *ODQueryCreateWithNode(void *allocator, void *node, void *record_types,
                            void *attribute, unsigned int match_type,
                            void *query_values, void *return_attributes,
                            long maximum_results, void **error)
{
    (void)allocator;
    (void)node;
    (void)record_types;
    (void)attribute;
    (void)match_type;
    (void)query_values;
    (void)return_attributes;
    (void)maximum_results;
    clear_error(error);
    return NULL;
}

void *ODQueryCopyResults(void *query, Boolean allow_partial, void **error)
{
    (void)query;
    (void)allow_partial;
    clear_error(error);
    return NULL;
}

Boolean ODRecordAddMember(void *group, void *member, void **error)
{
    (void)group;
    (void)member;
    clear_error(error);
    return false;
}

Boolean ODRecordChangePassword(void *record, void *old_password,
                               void *new_password, void **error)
{
    (void)record;
    (void)old_password;
    (void)new_password;
    clear_error(error);
    return false;
}

void *ODRecordCopyValues(void *record, void *attribute, void **error)
{
    (void)record;
    (void)attribute;
    clear_error(error);
    return NULL;
}

void *ODRecordGetRecordName(void *record)
{
    (void)record;
    return NULL;
}

Boolean ODRecordSynchronize(void *record, void **error)
{
    (void)record;
    clear_error(error);
    return false;
}
