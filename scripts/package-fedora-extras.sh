#!/bin/bash
# Fedora-only dependencies that other distro repositories provide separately.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p "$BUILD_ROOT" "$STAGE_ROOT"
rm -rf "$BUILD_ROOT/sensh" "$BUILD_ROOT/hexagonrpc" "$STAGE_ROOT/sensh" "$STAGE_ROOT/hexagonrpc"
sensh_source=$(python3 scripts/deps.py path sensh)
meson setup "$BUILD_ROOT/sensh" "$sensh_source" --buildtype=release --prefix=/usr
meson compile -j "${JOBS:-$(nproc)}" -C "$BUILD_ROOT/sensh"
sensh_stage="$PWD/$STAGE_ROOT/sensh"
DESTDIR="$sensh_stage" meson install -C "$BUILD_ROOT/sensh" --no-rebuild
install -Dm644 "$sensh_source/COPYING" "$sensh_stage/usr/share/licenses/sensh/COPYING"
sensh_version=$(meson introspect "$BUILD_ROOT/sensh" --projectinfo |
    python3 -c 'import json,sys; print(json.load(sys.stdin)["version"])')
PKG_NAME=sensh PKG_VERSION="$sensh_version" PKG_LICENSE=GPL-3.0-or-later \
    PKG_DESC="Qualcomm Sensor Core diagnostic shell" \
    scripts/emit-package.sh "$sensh_stage" "$PACKAGE_OUT"

hexagonrpc_source=$(python3 scripts/deps.py path hexagonrpc)
meson setup "$BUILD_ROOT/hexagonrpc" "$hexagonrpc_source" \
    --buildtype=release --prefix=/usr --libdir=lib64
meson compile -j "${JOBS:-$(nproc)}" -C "$BUILD_ROOT/hexagonrpc"
hexagonrpc_stage="$PWD/$STAGE_ROOT/hexagonrpc"
DESTDIR="$hexagonrpc_stage" meson install -C "$BUILD_ROOT/hexagonrpc" --no-rebuild
install -d "$hexagonrpc_stage/usr/lib/systemd/system" \
    "$hexagonrpc_stage/usr/lib/sysusers.d" "$hexagonrpc_stage/usr/lib/tmpfiles.d"
mv "$hexagonrpc_stage"/usr/lib64/systemd/system/hexagonrpcd-*.service \
    "$hexagonrpc_stage/usr/lib/systemd/system/"
printf '%s\n' 'u fastrpc - "FastRPC" /var/lib/fastrpc' \
    > "$hexagonrpc_stage/usr/lib/sysusers.d/fastrpc.conf"
printf '%s\n' 'd /usr/share/qcom/sensors/registry 0755 fastrpc fastrpc -' \
    > "$hexagonrpc_stage/usr/lib/tmpfiles.d/hexagonrpc.conf"
license_dir="$hexagonrpc_stage/usr/share/licenses/hexagonrpc"
install -Dm644 "$hexagonrpc_source/COPYING" "$license_dir/COPYING"
install -m644 licenses/LGPL-3.0.txt "$license_dir/LGPL-3.0.txt"
hexagonrpc_version=$(meson introspect "$BUILD_ROOT/hexagonrpc" --projectinfo |
    python3 -c 'import json,sys; print(json.load(sys.stdin)["version"])')
PKG_NAME=hexagonrpc PKG_VERSION="$hexagonrpc_version" \
    PKG_DESC="Qualcomm Hexagon FastRPC daemon and libraries" \
    PKG_LICENSE='GPL-3.0-or-later AND LGPL-3.0-or-later' \
    scripts/emit-package.sh "$hexagonrpc_stage" "$PACKAGE_OUT"

