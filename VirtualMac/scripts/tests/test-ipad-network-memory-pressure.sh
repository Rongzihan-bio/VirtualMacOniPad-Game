#!/bin/bash

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

DURATION="${VZ_NETWORK_PRESSURE_TEST_SECONDS:-60}"
INTERVAL="${VZ_NETWORK_PRESSURE_TEST_INTERVAL:-1}"

case "$DURATION" in
    ''|*[!0-9]*) die "VZ_NETWORK_PRESSURE_TEST_SECONDS must be an integer" ;;
esac
case "$INTERVAL" in
    ''|*[!0-9]*) die "VZ_NETWORK_PRESSURE_TEST_INTERVAL must be an integer" ;;
esac
[[ "$INTERVAL" -gt 0 ]] || die "VZ_NETWORK_PRESSURE_TEST_INTERVAL must be positive"

echo "Monitoring an already-running, high-memory VM for $DURATION seconds."
echo "This test does not change VM configuration or create memory pressure."

ipad_ssh "
if test -x /bin/sh; then
    exec /bin/sh -s -- '$DURATION' '$INTERVAL'
else
    exec /var/jb/usr/bin/sh -s -- '$DURATION' '$INTERVAL'
fi
" <<'DEVICE_SCRIPT'
set -eu
PATH=/var/jb/usr/bin:/usr/bin:/bin:/usr/sbin:/sbin
export PATH
DURATION="$1"
INTERVAL="$2"

pid_for_name()
{
    ps ax -o pid= -o comm= | while read -r pid command; do
        case "$command" in
            "$1"|*/"$1") echo "$pid"; break ;;
        esac
    done
}

internet_sharing_pid="$(pid_for_name InternetSharing)"
bootpd_pid="$(pid_for_name bootpd)"
if test -z "$internet_sharing_pid" || test -z "$bootpd_pid"; then
    echo "error: start a NAT-connected Virtual Mac before running this test" >&2
    exit 1
fi

case "$(sw_vers -productVersion)" in
    14.*|15.*) expected_priority=14 ;;
    16.*) expected_priority=140 ;;
    *)
        echo "error: unsupported host version: $(sw_vers -productVersion)" >&2
        exit 1
        ;;
esac

policy_log="$(cat /tmp/InternetSharing.err /tmp/bootpd.err 2>/dev/null || true)"
printf '%s\n' "$policy_log" | grep -q \
    "NetworkMemoryPolicy:.*actual-priority=$expected_priority limit=128 MiB" || {
    echo "error: network memory policy did not report the expected live state" >&2
    printf '%s\n' "$policy_log" | grep NetworkMemoryPolicy >&2 || true
    exit 1
}

minimum_free_pages=2147483647
elapsed=0
while test "$elapsed" -lt "$DURATION"; do
    current_internet_sharing_pid="$(pid_for_name InternetSharing)"
    current_bootpd_pid="$(pid_for_name bootpd)"
    if test "$current_internet_sharing_pid" != "$internet_sharing_pid"; then
        echo "error: InternetSharing exited or restarted under pressure" >&2
        exit 1
    fi
    if test "$current_bootpd_pid" != "$bootpd_pid"; then
        echo "error: bootpd exited or restarted under pressure" >&2
        exit 1
    fi

    free_line="$(vm_stat | grep '^Pages free:' || true)"
    set -- $free_line
    free_pages="${3%.}"
    if test -n "$free_pages" && test "$free_pages" -lt "$minimum_free_pages"; then
        minimum_free_pages="$free_pages"
    fi
    sleep "$INTERVAL"
    elapsed=$((elapsed + INTERVAL))
done

echo "PASS: networking daemons retained their original PIDs for $DURATION seconds"
echo "InternetSharing PID: $internet_sharing_pid"
echo "bootpd PID: $bootpd_pid"
echo "Minimum free pages observed: $minimum_free_pages"
DEVICE_SCRIPT
