#!/bin/bash
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
stage=${1:?staging directory required}
name=${2:?package name required}
dest=$stage/usr/share/licenses/$name
install -Dm644 "$root/LICENSE.md" "$dest/NOTICE.md"

case "$name" in
    linux-zhiyu-modules|linux-zhiyu-headers|linux-zhiyu-images|zhiyu-sensord)
        install -m644 "$root/kernel-source/LICENSES/preferred/GPL-2.0" "$dest/GPL-2.0.txt"
        ;;
esac
case "$name" in
    linux-zhiyu-modules|linux-zhiyu-headers)
        install -d "$dest/kernel"
        cp -a "$root/kernel-source/LICENSES/." "$dest/kernel/"
        ;;
    linux-zhiyu-firmware|linux-zhiyu-images)
        install -m644 "$root/licenses/firmware/"* "$root/licenses/AudioReach-BSD-3-Clause.txt" "$dest/"
        install -m644 "$root/initramfs-src/blobs/MANIFEST.tsv" "$dest/firmware-manifest.tsv"
        ;;
    libcamera-zhiyu)
        install -m644 "$root/libcamera/COPYING.rst" "$dest/"
        install -d "$dest/libcamera"
        cp -a "$root/libcamera/LICENSES/." "$dest/libcamera/"
        ;;
esac

if [ "$name" = linux-zhiyu-images ]; then
    install -d "$dest/initramfs"
    install -m644 "$root/licenses/initramfs/"* "$dest/initramfs/"
    install -m644 "$root/kernel-source/LICENSES/preferred/LGPL-2.1" "$dest/initramfs/LGPL-2.1.txt"
fi
