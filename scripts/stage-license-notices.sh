#!/bin/bash
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
stage=${1:?staging directory required}
name=${2:?package name required}
dest=$stage/usr/share/licenses/$name
install -Dm644 "$root/LICENSE.md" "$dest/NOTICE.md"

case "$name" in
    linux-zhiyu-modules|linux-zhiyu-headers|linux-zhiyu-images|zhiyu-sensord)
        install -m644 "${KS:-$root/kernel-source}/LICENSES/preferred/GPL-2.0" "$dest/GPL-2.0.txt"
        ;;
esac
case "$name" in
    linux-zhiyu-modules|linux-zhiyu-headers)
        install -d "$dest/kernel"
        cp -a "${KS:-$root/kernel-source}/LICENSES/." "$dest/kernel/"
        ;;
    linux-zhiyu-firmware|linux-zhiyu-images)
        firmware=$(python3 "$root/scripts/deps.py" path firmware)
        install -m644 "$firmware/LICENSE.qcom" "$firmware/LICENSE.qcom-2" \
            "$firmware/NOTICE.qcom" "$firmware/README.md" \
            "$root/licenses/AudioReach-BSD-3-Clause.txt" "$dest/"
        install -m644 "$firmware/MANIFEST.tsv" "$dest/firmware-manifest.tsv"
        ;;
    libcamera-zhiyu)
        # The caller names the libcamera submodule it built (libcamera/0.7 or
        # libcamera/0.8), because both ABIs are packaged separately.
        libcamera_source=${LIBCAMERA_SOURCE:?set LIBCAMERA_SOURCE to the libcamera submodule}
        install -m644 "$libcamera_source/COPYING.rst" "$dest/"
        install -d "$dest/libcamera"
        cp -a "$libcamera_source/LICENSES/." "$dest/libcamera/"
        ;;
esac

if [ "$name" = linux-zhiyu-images ]; then
    install -d "$dest/initramfs"
    install -m644 "$root/licenses/initramfs/"* "$dest/initramfs/"
    install -m644 "${KS:-$root/kernel-source}/LICENSES/preferred/LGPL-2.1" "$dest/initramfs/LGPL-2.1.txt"
fi
