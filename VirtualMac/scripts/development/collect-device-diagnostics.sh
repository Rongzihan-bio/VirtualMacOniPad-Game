#!/bin/bash

set -euo pipefail

usage() {
    cat <<'EOF'
Usage: collect-device-diagnostics.sh [options]

Collects complete CrashReporter archives from connected iPads without deleting
the device copies. It also captures Virtual Mac settings through AFC and, when
USB SSH is available, live /tmp traces and an on-device diagnostics ZIP.

Options:
  --udid UDID       collect one device (repeatable; default: every connected device)
  --output DIR      destination (default: ./DeviceCrashLogs/<timestamp>)
  --ssh-user USER   SSH account (default: root)
  --port-base PORT  first local iproxy port (default: 2240)
  -h, --help        show this help

Set IPAD_SSH_PASSWORD in the environment to use password authentication.
Otherwise existing SSH authentication is used. SSH failure does not prevent
CrashReporter and AFC collection.
EOF
}

udids=()
output=""
ssh_user="root"
port_base=2240
while (($#)); do
    case "$1" in
        --udid) udids+=("$2"); shift 2 ;;
        --output) output="$2"; shift 2 ;;
        --ssh-user) ssh_user="$2"; shift 2 ;;
        --port-base) port_base="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "error: unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
done

for command in idevice_id ideviceinfo idevicecrashreport afcclient iproxy ssh scp; do
    command -v "$command" >/dev/null || {
        echo "error: required command not found: $command" >&2
        exit 1
    }
done
if ((${#udids[@]} == 0)); then
    while IFS= read -r udid; do
        [[ -n "$udid" ]] && udids+=("$udid")
    done < <(idevice_id -l)
fi
((${#udids[@]})) || { echo "error: no USB iPads found" >&2; exit 1; }

timestamp="$(date +%Y%m%d-%H%M%S)"
output="${output:-$PWD/DeviceCrashLogs/$timestamp}"
mkdir -p "$output"
proxy_pids=()
cleanup() {
    for pid in "${proxy_pids[@]:-}"; do
        kill "$pid" 2>/dev/null || true
    done
}
trap cleanup EXIT

for index in "${!udids[@]}"; do
    udid="${udids[$index]}"
    product="$(ideviceinfo -u "$udid" -k ProductType 2>/dev/null || echo unknown)"
    version="$(ideviceinfo -u "$udid" -k ProductVersion 2>/dev/null || echo unknown)"
    build="$(ideviceinfo -u "$udid" -k BuildVersion 2>/dev/null || echo unknown)"
    destination="$output/${product}-${version}-${build}-${udid}"
    mkdir -p "$destination/crash-reports" "$destination/virtual-mac" \
        "$destination/runtime-logs"
    {
        printf 'UDID=%s\nProductType=%s\nProductVersion=%s\nBuildVersion=%s\n' \
            "$udid" "$product" "$version" "$build"
        ideviceinfo -u "$udid" -k DeviceName 2>/dev/null | sed 's/^/DeviceName=/'
    } >"$destination/device.txt"

    echo "[$product $version ($build)] copying complete CrashReporter tree..."
    idevicecrashreport -u "$udid" -e -k "$destination/crash-reports" \
        >"$destination/crashreport-pull.log" 2>&1
    printf 'get VirtualMac/Settings.plist %s\nls -l VirtualMac\nquit\n' \
        "$destination/virtual-mac/Settings.plist" |
        afcclient -u "$udid" >"$destination/virtual-mac/library-listing.txt" \
        2>"$destination/virtual-mac/afc-errors.txt" || true

    port=$((port_base + index))
    iproxy "$port" 22 -u "$udid" >"$destination/iproxy.log" 2>&1 &
    proxy_pids+=("$!")
    sleep 1
    ssh_options=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
        -o ConnectTimeout=4 -o BatchMode=yes -p "$port")
    scp_options=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
        -o ConnectTimeout=4 -o BatchMode=yes -P "$port")
    ssh_command=(ssh "${ssh_options[@]}")
    scp_command=(scp "${scp_options[@]}")
    if [[ -n "${IPAD_SSH_PASSWORD:-}" ]] && command -v sshpass >/dev/null; then
        ssh_options=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
            -o ConnectTimeout=4 -p "$port")
        scp_options=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
            -o ConnectTimeout=4 -P "$port")
        ssh_command=(sshpass -p "$IPAD_SSH_PASSWORD" ssh "${ssh_options[@]}")
        scp_command=(sshpass -p "$IPAD_SSH_PASSWORD" scp "${scp_options[@]}")
    fi
    target="$ssh_user@127.0.0.1"
    if "${ssh_command[@]}" "$target" true >/dev/null 2>&1; then
        echo "[$product $version ($build)] copying live Virtual Mac traces over USB SSH..."
        for remote in /tmp/VirtualMac.log /tmp/vmmhook.log \
            /tmp/vmm.stderr.log /tmp/vzxpchook.log /tmp/pvg-trace.log \
            /tmp/InternetSharing.stdout.log /tmp/InternetSharing.stderr.log \
            /tmp/bootpd.stdout.log /tmp/bootpd.stderr.log \
            /tmp/InternetSharing.out /tmp/InternetSharing.err \
            /tmp/bootpd.out /tmp/bootpd.err \
            /tmp/bootpd-controller.out /tmp/bootpd-controller.err; do
            "${scp_command[@]}" "$target:$remote" \
                "$destination/runtime-logs/" >/dev/null 2>&1 || true
        done
        archive="$("${ssh_command[@]}" "$target" \
            '/var/jb/usr/bin/virtualmac-diagnostics 2>/dev/null' || true)"
        if [[ "$archive" == /var/mobile/Media/VirtualMac/Diagnostics/*.zip ]]; then
            "${scp_command[@]}" "$target:$archive" \
                "$destination/" >/dev/null 2>&1 || true
        fi
    else
        echo "[$product $version ($build)] USB SSH unavailable; CrashReporter/AFC collection is still complete."
    fi
done

echo "diagnostics collected: $output"
