#!/bin/bash

# Validate both directions of the native virtio-sound device:
#   guest system sound -> iPad output sink
#   iPad microphone -> guest input source
# The guest microphone TCC prompt is accepted through Virtual Mac's one-shot
# input command bridge, so the test remains repeatable over USB SSH.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../lib/common.sh"

: "${VZ_GUEST_HOST:?set VZ_GUEST_HOST to the guest address}"
: "${VZ_GUEST_USER:?set VZ_GUEST_USER to the guest SSH user}"
: "${VZ_GUEST_PASSWORD:?set VZ_GUEST_PASSWORD to the guest SSH password}"
GUEST_HOST="$VZ_GUEST_HOST"
GUEST_USER="$VZ_GUEST_USER"
GUEST_PORT="${VZ_GUEST_USB_PORT:-2208}"
GUEST_PASSWORD="$VZ_GUEST_PASSWORD"
PROBE_ROOT="$(mktemp -d -t vz-audio-probe.XXXXXX)"
REMOTE_ROOT="/tmp/vz-audio-probe-$$"

need_command codesign
need_command ldid
need_command lsof
need_command ssh
need_command sshpass
need_command xcrun
ensure_ipad_usb

owned_tunnel=0
if ! lsof -nP -iTCP:"$GUEST_PORT" -sTCP:LISTEN >/dev/null 2>&1; then
    sshpass -p "$VZ_IPAD_PASSWORD" ssh "${IPAD_SSH_ARGS[@]}" \
        -o ControlMaster=no -o ControlPath=none \
        -N -L "127.0.0.1:$GUEST_PORT:$GUEST_HOST:22" "$IPAD_TARGET" &
    tunnel_pid=$!
    owned_tunnel=1
fi
cleanup() {
    if [[ "$owned_tunnel" == 1 ]]; then
        listener_pids="$(lsof -t -iTCP:"$GUEST_PORT" -sTCP:LISTEN 2>/dev/null || true)"
        if [[ -n "$listener_pids" ]]; then
            # shellcheck disable=SC2086
            kill $listener_pids 2>/dev/null || true
        fi
        kill "$tunnel_pid" 2>/dev/null || true
        wait "$tunnel_pid" 2>/dev/null || true
    fi
    rm -rf "$PROBE_ROOT"
}
trap cleanup EXIT

for _ in {1..40}; do
    lsof -nP -iTCP:"$GUEST_PORT" -sTCP:LISTEN >/dev/null 2>&1 && break
    sleep 0.25
done
lsof -nP -iTCP:"$GUEST_PORT" -sTCP:LISTEN >/dev/null 2>&1 ||
    die "iPad guest SSH tunnel did not open"

guest_ssh=(sshpass -p "$GUEST_PASSWORD" ssh -p "$GUEST_PORT"
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
    -o ConnectTimeout=10 -o PubkeyAuthentication=no
    -o PreferredAuthentications=password -o NumberOfPasswordPrompts=1
    "$GUEST_USER@127.0.0.1")
guest_scp=(sshpass -p "$GUEST_PASSWORD" scp -P "$GUEST_PORT"
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
    -o ConnectTimeout=10 -o PubkeyAuthentication=no
    -o PreferredAuthentications=password -o NumberOfPasswordPrompts=1)

APP="$PROBE_ROOT/AudioCaptureProbe.app"
mkdir -p "$APP/Contents/MacOS"
xcrun --sdk macosx clang -arch arm64 -mmacosx-version-min=13.0 -fblocks \
    "$VZ_REPO_ROOT/vz/development/probes/audio_capture_app.m" \
    -framework AppKit -framework AVFoundation \
    -o "$APP/Contents/MacOS/AudioCaptureProbe"
cp "$VZ_REPO_ROOT/vz/development/probes/AudioCaptureProbe-Info.plist" \
    "$APP/Contents/Info.plist"
codesign -s - --force --deep "$APP"
ditto -c -k --sequesterRsrc --keepParent "$APP" \
    "$PROBE_ROOT/AudioCaptureProbe.zip"

xcrun --sdk macosx clang -arch arm64 -mmacosx-version-min=13.0 -fobjc-arc \
    "$VZ_REPO_ROOT/vz/development/probes/window_list_probe.m" \
    -framework CoreGraphics -framework Foundation \
    -o "$PROBE_ROOT/window-list-probe"
codesign -s - --force "$PROBE_ROOT/window-list-probe"

SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
xcrun --sdk iphoneos clang -arch arm64 -miphoneos-version-min=16.0 \
    -isysroot "$SDK" -fobjc-arc \
    "$VZ_REPO_ROOT/vz/development/probes/audio_tone_probe.m" \
    -framework AVFAudio -framework AudioToolbox -framework Foundation \
    -o "$PROBE_ROOT/audio-tone-probe"
ldid -S"$VZ_REPO_ROOT/vz/host/VirtualMac.entitlements" \
    "$PROBE_ROOT/audio-tone-probe"
tone_hash="$(ldid -h "$PROBE_ROOT/audio-tone-probe" |
    sed -n 's/^CDHash=//p')"
[[ -n "$tone_hash" ]] || die "could not read tone probe CDHash"

"${guest_ssh[@]}" "mkdir -p '$REMOTE_ROOT'"
"${guest_scp[@]}" "$PROBE_ROOT/AudioCaptureProbe.zip" \
    "$PROBE_ROOT/window-list-probe" \
    "$GUEST_USER@127.0.0.1:$REMOTE_ROOT/"
ipad_scp "$PROBE_ROOT/audio-tone-probe" \
    "$IPAD_TARGET:/var/root/VirtualMac/audio-tone-probe"
ipad_ssh "chmod 755 /var/root/VirtualMac/audio-tone-probe; \
    jbctl trustcache add '$tone_hash'"

"${guest_ssh[@]}" "set -eu
pkill -f '/AudioCaptureProbe.*app/Contents/MacOS/AudioCaptureProbe' 2>/dev/null || true
chmod 755 '$REMOTE_ROOT/window-list-probe'
ditto -x -k '$REMOTE_ROOT/AudioCaptureProbe.zip' '$REMOTE_ROOT'
: >/tmp/vz-audio-capture-result.txt
open '$REMOTE_ROOT/AudioCaptureProbe.app'"

# A prompt is a UserNotificationCenter window on-screen. Compute the Allow
# button from its actual bounds instead of assuming a guest resolution.
for _ in {1..12}; do
    windows="$("${guest_ssh[@]}" "$REMOTE_ROOT/window-list-probe")"
    screen="$(printf '%s\n' "$windows" | sed -n 's/^screen //p')"
    alert="$(printf '%s\n' "$windows" |
        grep 'owner=UserNotificationCenter' | grep -E ' y=[0-9]' | head -1 || true)"
    if [[ -n "$alert" ]]; then
        read -r normalized_x normalized_y < <(awk -v screen="$screen" \
            -v alert="$alert" 'BEGIN {
              split(screen, s, /[ =]/); n=split(alert, a, /[ =]/);
              sw=s[2]; sh=s[4];
              for (i=1; i<=n; i++) {
                if (a[i] == "x") x=a[i+1];
                if (a[i] == "y") y=a[i+1];
                if (a[i] == "width") w=a[i+1];
                if (a[i] == "height") h=a[i+1];
              }
              printf "%.5f %.5f\n", (x + 0.75*w)/sw, (y + 0.83*h)/sh;
            }')
        ipad_ssh "printf 'click %s %s 1\n' '$normalized_x' '$normalized_y' \
            >/tmp/vz-input-command; chown mobile:mobile /tmp/vz-input-command"
    fi
    sleep 0.5
    [[ -z "$alert" ]] && break
done

# The guest beep exercises its virtual output stream. The iPad tone then gives
# the physical microphone a deterministic signal for the guest input stream.
"${guest_ssh[@]}" "osascript -e 'set volume output volume 75' -e 'beep 5'"
ipad_ssh "/var/root/VirtualMac/audio-tone-probe 3"
sleep 3

result="$("${guest_ssh[@]}" 'cat /tmp/vz-audio-capture-result.txt')"
printf '%s\n' "$result"
printf '%s\n' "$result" | grep -Fq 'permission=granted' ||
    die "guest microphone permission was not granted"
peak="$(printf '%s\n' "$result" | sed -n 's/.* peak=\([0-9.]*\).*/\1/p')"
[[ -n "$peak" ]] || die "guest microphone probe did not report a peak"
awk -v peak="$peak" 'BEGIN { exit !(peak > 0.00001) }' ||
    die "guest microphone stream contained only zeros"

"${guest_ssh[@]}" "printf '%s\n' '$GUEST_PASSWORD' | sudo -S \
    log show --last 2m --style compact 2>/dev/null | \
    grep -F 'setPlayState Started  Output {AVIODevice' | tail -1"
ipad_ssh "ps ax | grep -F \
  '/payload/VirtualMachine.xpc/Contents/MacOS/com.apple.Virtualization.VirtualMachine' | \
  grep -v grep"
echo "iPad guest audio input/output validation passed"
