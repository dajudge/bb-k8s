#!/bin/sh
set -eu

user_ns=$(readlink /proc/self/ns/user)
mount_ns=$(readlink /proc/self/ns/mnt)
network_ns=$(readlink /proc/self/ns/net)

bwrap --unshare-user --unshare-pid --unshare-net --die-with-parent \
  --ro-bind / / --proc /proc --dev /dev --tmpfs /tmp --chdir /tmp \
  /bin/sh -ec '
    test "$(id -u)" = 10001
    test "$(readlink /proc/self/ns/user)" != "$1"
    test "$(readlink /proc/self/ns/mnt)" != "$2"
    test "$(readlink /proc/self/ns/net)" != "$3"
    touch /tmp/bubblewrap-writable
    if touch /workspace/bubblewrap-must-be-read-only 2>/dev/null; then
      echo "Sandbox workspace unexpectedly writable" >&2
      exit 1
    fi
  ' sh "${user_ns}" "${mount_ns}" "${network_ns}"

echo 'Bubblewrap sandbox test passed.'
