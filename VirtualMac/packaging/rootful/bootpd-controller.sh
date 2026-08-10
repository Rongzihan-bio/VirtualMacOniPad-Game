#!/bin/sh

# iPadOS 14 InternetSharing is sandboxed and cannot call launchctl itself.
# Cross that boundary with Apple's /bin/sh under a root launchd job, and touch
# only Virtual Mac's private label and package-owned plist/program paths.
set -u

launchctl=/usr/bin/launchctl
label=system/vzi.apple.bootpd
plist=/var/root/VirtualMac/rootful/Library/LaunchDaemons/com.apple.bootpd.plist
config=/tmp/bootpd.plist

dhcp_active=0
if test -s "$config"; then
    # WatchPaths may fire while a writer is completing an atomic replacement.
    sleep 1
    test -s "$config" || exit 0
    in_dhcp_enabled=0
    while IFS= read -r line; do
        case "$line" in
            *'<key>dhcp_enabled</key>'*)
                in_dhcp_enabled=1
                ;;
            *'<string>bridge100</string>'*)
                if test "$in_dhcp_enabled" = 1; then
                    dhcp_active=1
                    break
                fi
                ;;
            *'</array>'*)
                in_dhcp_enabled=0
                ;;
        esac
    done <"$config"
fi

if test "$dhcp_active" = 1; then
    "$launchctl" enable "$label"
    if ! "$launchctl" print "$label" >/dev/null 2>&1; then
        "$launchctl" bootstrap system "$plist"
    fi
else
    "$launchctl" bootout "$label" 2>/dev/null || true
    "$launchctl" disable "$label"
fi

exit 0
