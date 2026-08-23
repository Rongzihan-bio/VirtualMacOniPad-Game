#!/bin/bash
# Helper for the matching macOS guest VM.
# Keeps the whole ssh/scp command in one script (zsh won't word-split a $VAR of -o flags).
#   vz/development/harness/vm.sh ssh '<remote command>'
#   vz/development/harness/vm.sh scp <src> <guest-user>@<guest-address>:<dst>
: "${VZ_GUEST_HOST:?set VZ_GUEST_HOST}"
: "${VZ_GUEST_USER:?set VZ_GUEST_USER}"
HOST="$VZ_GUEST_HOST"
USER="$VZ_GUEST_USER"
PASSWORD="${VZ_GUEST_PASSWORD:?set VZ_GUEST_PASSWORD}"
OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10
      -o PubkeyAuthentication=no -o PreferredAuthentications=password -o NumberOfPasswordPrompts=1)
case "$1" in
  ssh) shift; exec sshpass -p "$PASSWORD" ssh "${OPTS[@]}" "$USER@$HOST" "$@";;
  scp) shift; exec sshpass -p "$PASSWORD" scp "${OPTS[@]}" "$@";;
  *) echo "usage: vm.sh ssh '<cmd>' | scp <src> USER@$HOST:<dst>"; exit 1;;
esac
