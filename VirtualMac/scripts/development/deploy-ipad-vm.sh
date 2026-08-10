#!/bin/bash

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

LOCAL="$VZ_BUILD_ROOT/ipad-vm"
PAYLOAD="$LOCAL/payload"
REMOTE="${VZ_IPAD_WORK:-/var/root/VirtualMac}"
ARCHIVE="$(mktemp -t VirtualMac-vm.XXXXXX.tar.gz)"
trap 'rm -f "$ARCHIVE"' EXIT

need_command sshpass
need_command tar
need_file "$PAYLOAD/bin/vzboot"
need_file "$PAYLOAD/trustcache.txt"

tar -C "$LOCAL" -czf "$ARCHIVE" payload
ipad_ssh "mkdir -p '$REMOTE'"
ipad_scp "$ARCHIVE" "$IPAD_TARGET:$REMOTE/deploy.tar.gz"

remote_script="$(cat <<EOF
set -eu
# Installation.xpc is a separately built DeviceSupport overlay. Replacing the
# whole payload here used to silently delete its bundled usbmuxd and made a
# later in-app IPSW restore fail before launch. Replace only VM-owned paths so
# the VM and installation deployments are order-independent.
rm -rf \
  '$REMOTE/payload/bin' \
  '$REMOTE/payload/Frameworks' \
  '$REMOTE/payload/VirtualMachine.xpc' \
  '$REMOTE/payload/trustcache.txt'
tar -xzf '$REMOTE/deploy.tar.gz' -C '$REMOTE'
rm -f '$REMOTE/deploy.tar.gz'
chmod 755 \
  '$REMOTE/payload/bin/vzboot' \
  '$REMOTE/payload/bin/VZHostCompat.dylib' \
  '$REMOTE/payload/VirtualMachine.xpc/Contents/MacOS/com.apple.Virtualization.VirtualMachine'

if command -v jbctl >/dev/null 2>&1; then
  while IFS=\$(printf '\\t') read -r hash file; do
    test -n "\$hash"
    test -f '$REMOTE/payload/'"\$file"
    jbctl trustcache add "\$hash"
  done <'$REMOTE/payload/trustcache.txt'
elif test -x /taurine/jbexec; then
  # Taurine has no jbctl. Ask jailbreakd to prepare every shipped Mach-O,
  # including dylibs selected later through an iPadOS-version symlink/copy.
  # Preparing only the VMM executable leaves its iPadOS 14 Hypervisor image
  # untrusted and dyld terminates the child before main().
  while IFS=\$(printf '\\t') read -r hash file; do
    target='$REMOTE/payload/'"\$file"
    test -f "\$target" || continue
    PREFLIGHT=1 /bin/bash -c \
      'exec -a "\$1" /taurine/jbexec' _ "\$target" >/dev/null || true
  done <'$REMOTE/payload/trustcache.txt'
else
  echo 'error: neither jbctl nor Taurine jbexec is available' >&2
  exit 1
fi

if test -d '$REMOTE/payload/Installation.xpc'; then
  test -x '$REMOTE/payload/Installation.xpc/Contents/Frameworks/MobileDevice.framework/Versions/A/Resources/usbmuxd'
  printf 'INSTALLATION_OVERLAY\\tpreserved\\n'
else
  printf 'INSTALLATION_OVERLAY\\tnot-installed\\n'
fi

printf 'VM_LIBRARY\\t%s\\n' '/var/mobile/Media/VirtualMac'
EOF
)"

ipad_ssh "$remote_script"
echo "iPad VM payload deployed without altering /var/mobile/Media/VirtualMac"
