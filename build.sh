#!/bin/bash
# Build kernel Image/modules, initramfs, boot.img and vendor_boot.img.
set -euo pipefail
root=$(cd "$(dirname "$0")" && pwd)
KS=${KS:-$root/kernel-source}
VER=${VER:-7.2.13-zhiyu+}
JOBS=${JOBS:-$(nproc)}

[ -d "$KS" ] || { echo "kernel-source submodule is not initialized" >&2; exit 1; }
cp "$root/configs/linux-7.2.13-zhiyu.config" "$KS/.config"
make -C "$KS" ARCH=arm64 LLVM=1 olddefconfig
make -C "$KS" -j"$JOBS" ARCH=arm64 LLVM=1 Image modules
( cd "$root" && VER="$VER" ./initramfs-src/build.sh )
( cd "$root" && ./mkbootimg )
( cd "$root" && ./mkvendorbootimg )
