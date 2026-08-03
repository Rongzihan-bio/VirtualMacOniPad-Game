#!/var/jb/bin/sh

# On-device launcher shared by the UIKit app and SSH automation. It prewarms
# DeviceSupport's usbmuxd before VZMacOSInstaller reaches the RestoreOS USB
# handoff, then starts the real Apple installation stack in the background.

set -eu
# System applications do not inherit the interactive jailbreak shell PATH.
# Keep every utility used below resolvable when this script is exec'd by the
# setuid install-launcher from UIKit.
PATH=/var/jb/usr/bin:/var/jb/bin:/usr/bin:/bin:/usr/sbin:/sbin
export PATH
trap 'status=$?; if [ "$status" -ne 0 ] && { [ -z "${log:-}" ] || ! grep -q "INSTALL_FAILED" "$log" 2>/dev/null; }; then echo "INSTALL_FAILED launcher status=$status"; fi' EXIT

if [ "$#" -ne 7 ]; then
    echo "usage: start-install.sh IPSW STAGING_BUNDLE FINAL_BUNDLE LOG CPU MEMORY_BYTES DISK_BYTES" >&2
    exit 2
fi

remote=/var/root/VirtualMac
ipsw=$1
staging=$2
final=$3
log=$4
cpu=$5
memory=$6
disk=$7
usbmuxd="$remote/payload/Installation.xpc/Contents/Frameworks/MobileDevice.framework/Versions/A/Resources/usbmuxd"

test -f "$ipsw"
test ! -e "$staging"
test ! -e "$final"
echo "INSTALL_PREPARE_BEGIN ipsw=$ipsw"
case "$staging" in
    /var/mobile/Media/VirtualMac/Installations/*.bundle.installing) ;;
    *) echo "staging bundle must be in Virtual Mac installation storage" >&2; exit 2 ;;
esac
test "${final%/*}" = /var/mobile/Media/VirtualMac || {
    echo "final bundle must be directly in /var/mobile/Media/VirtualMac" >&2
    exit 2
}
case "$final" in
    *.bundle) ;;
    *) echo "final bundle must have a .bundle suffix" >&2; exit 2 ;;
esac

# Darwin truncates the process name used by killall, so the Installation.xpc
# executable's full bundle name is never matched reliably. Kill only helpers
# whose complete command path belongs to this payload; otherwise an orphaned
# listener can retain global usbmux/endpoint state across restore attempts.
ps -axo pid=,command= | while read -r stale_pid stale_command; do
    case "$stale_command" in
        "$remote/payload/Installation.xpc/Contents/MacOS/com.apple.Virtualization.Installation")
            kill "$stale_pid" 2>/dev/null || true
            ;;
    esac
done
sleep 0.1
ps -axo pid=,command= | while read -r stale_pid stale_command; do
    case "$stale_command" in
        "$remote/payload/Installation.xpc/Contents/MacOS/com.apple.Virtualization.Installation")
            kill -9 "$stale_pid" 2>/dev/null || true
            ;;
    esac
done
killall install-macos 2>/dev/null || true
killall usbmuxd 2>/dev/null || true
if test -f /tmp/vz-usbmuxd-launch.pid; then
    kill "$(cat /tmp/vz-usbmuxd-launch.pid)" 2>/dev/null || true
fi
rm -f /var/run/usbmuxd /tmp/vzusbmuxd /tmp/vz-usbmuxd-enable
rm -f /tmp/installation_ep.txt /tmp/vmm_ep.txt \
    /tmp/installation.stderr.log /tmp/installationhook.log \
    /tmp/installation-usb.log /tmp/restore-vmm.stderr.log \
    /tmp/vmm.stderr.log /tmp/vmmhook.log \
    /tmp/vzxpchook.log /tmp/vz-usbmuxd.log

DYLD_INSERT_LIBRARIES="$remote/payload/Installation.xpc/Contents/Frameworks/InstallationCompat.dylib" \
INSTALL_USB_POLL_US=250000 \
INSTALL_USB_ENABLE_FILE=/tmp/vz-usbmuxd-enable \
    "$usbmuxd" -debug 5 >/tmp/vz-usbmuxd.log 2>&1 &
echo $! >/tmp/vz-usbmuxd.pid

attempt=0
while ! test -S /tmp/vzusbmuxd; do
    attempt=$((attempt + 1))
    test "$attempt" -lt 30 || {
        echo "usbmuxd did not create /tmp/vzusbmuxd" >&2
        exit 1
    }
    sleep 0.1
done

installer_pid=$$
(
    while ! grep -q 'fake USB device descriptor: .* ac 05 ac 12' \
        /tmp/vmmhook.log 2>/dev/null; do
        kill -0 "$installer_pid" 2>/dev/null || exit 0
        sleep 0.01
    done
    while ! grep -q 'RestoreOS USBMux handshake cached generation=' \
        /tmp/vmmhook.log 2>/dev/null; do
        kill -0 "$installer_pid" 2>/dev/null || exit 0
        sleep 0.01
    done
    touch /tmp/vz-usbmuxd-enable
    ln -s /tmp/vzusbmuxd /var/run/usbmuxd
) >/tmp/vz-usbmuxd-launch.log 2>&1 &
echo $! >/tmp/vz-usbmuxd-launch.pid

# iPadOS cannot create Ventura's kernel-backed IOUSBHostControllerInterface.
# The userspace controller bridge carries the genuine virtual DFU endpoint
# traffic to MobileDevice and is required for unattended on-device restores.
export VZ_INSTALL_CPU_COUNT="$cpu"
export VZ_INSTALL_MEMORY_SIZE="$memory"
export VZ_INSTALL_STORAGE_SIZE="$disk"
export VZ_VMM_STDERR_LOG=/tmp/restore-vmm.stderr.log
# The setuid restore host must create its own rendezvous names. Inheriting the
# UIKit app's mobile-owned names lets the root VMM replace them and can prevent
# every later VM from starting. The host hook generates root-scoped paths.
unset VZ_VMM_ENDPOINT_FILE VZ_INSTALLATION_ENDPOINT_FILE
export VMMHOOK_TRACE_USB="${VMMHOOK_TRACE_USB:-0}"
export VMMHOOK_TRACE_IOKIT="${VMMHOOK_TRACE_IOKIT:-1}"
export VMMHOOK_TRACE_XPC_LIMIT="${VMMHOOK_TRACE_XPC_LIMIT:-200}"
export VMMHOOK_FAKE_USB="${VMMHOOK_FAKE_USB:-1}"
export INSTALL_USB_DEBUG_DELAY_MS="${INSTALL_USB_DEBUG_DELAY_MS:-}"
export INSTALL_USB_TRACE_TRANSFERS="${INSTALL_USB_TRACE_TRANSFERS:-0}"

# Keep install-macos as the validated setuid launcher's main process. The
# successful visible restore proved that a separate launchd coalition is not
# required; exec preserves errors and termination directly in the UI log.
echo $$ >/tmp/install-macos.pid
echo "INSTALL_LAUNCHED pid=$$ log=$log"
exec "$remote/install/install-macos" "$ipsw" "$staging" "$final" >>"$log" 2>&1
