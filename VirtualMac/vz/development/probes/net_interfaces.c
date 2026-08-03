#include <arpa/inet.h>
#include <ifaddrs.h>
#include <net/if.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/socket.h>

int main(void) {
    struct ifaddrs *interfaces = NULL;
    if (getifaddrs(&interfaces) != 0) {
        perror("getifaddrs");
        return 1;
    }
    for (const struct ifaddrs *item = interfaces; item; item = item->ifa_next) {
        if (!item->ifa_addr)
            continue;
        int family = item->ifa_addr->sa_family;
        if (family != AF_INET && family != AF_INET6)
            continue;
        char address[INET6_ADDRSTRLEN] = {0};
        const void *bytes = family == AF_INET
            ? (const void *)&((const struct sockaddr_in *)item->ifa_addr)->sin_addr
            : (const void *)&((const struct sockaddr_in6 *)item->ifa_addr)->sin6_addr;
        if (!inet_ntop(family, bytes, address, sizeof(address)))
            continue;
        printf("%s\t%s\tflags=0x%x\n", item->ifa_name, address,
               item->ifa_flags);
    }
    freeifaddrs(interfaces);
    return 0;
}
