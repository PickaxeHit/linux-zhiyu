#!/bin/bash
set -euo pipefail
cd /work
[[ $(uname -m) == aarch64 ]] || { echo 'Expected linux/arm64 image' >&2; exit 1; }
scripts/container-deps.sh
# Rootful engines install packages as root then build using the invoking UID.
# Rootless engines already map container root to the invoking host UID.
if [[ $HOST_MAPPED_ROOT == false && $HOST_UID != 0 ]]; then
    export HOME=$(mktemp -d /tmp/zhiyu-home.XXXXXX)
    chown "$HOST_UID:$HOST_GID" "$HOME"
    exec setpriv --reuid "$HOST_UID" --regid "$HOST_GID" --clear-groups bash scripts/container-package.sh
fi
exec bash scripts/container-package.sh
