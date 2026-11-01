#!/bin/bash
# Build kernel Image/modules, initramfs, boot.img and vendor_boot.img.
#
#   KS    kernel tree (default: the kernel-source submodule)
#   CFG   kernel config (default: configs/linux-<major.minor>-zhiyu.config)
#   VER   `uname -r` of the result (default: <kernel version>-zhiyu+)
set -euo pipefail
root=$(cd "$(dirname "$0")" && pwd)
KS=${KS:-$root/kernel-source}
JOBS=${JOBS:-$(nproc)}

[ -d "$KS" ] || { echo "kernel-source submodule is not initialized" >&2; exit 1; }

# The board config is kept per stable series, and the branch we build (zhiyu)
# is a merge target for it, so pulling in v7.3.2 or v7.4 keeps working here
# without an edit: only a new series needs a new configs/linux-<X.Y> file.
KVER=${KVER:-$(make -s -C "$KS" ARCH=arm64 kernelversion)}
SERIES=${SERIES:-${KVER%.*}}
CFG=${CFG:-$root/configs/linux-$SERIES-zhiyu.config}
VER=${VER:-$KVER-zhiyu+}
[ -f "$CFG" ] || { echo "no kernel config for $SERIES: $CFG" >&2; exit 1; }

echo "kernel : $KS ($KVER)"
echo "config : $CFG"
echo "release: $VER"

cp "$CFG" "$KS/.config"
make -C "$KS" ARCH=arm64 LLVM=1 olddefconfig
make -C "$KS" -j"$JOBS" ARCH=arm64 LLVM=1 Image modules
( cd "$root" && KS="$KS" VER="$VER" ./initramfs-src/build.sh )
( cd "$root" && KERNEL="$KS/arch/arm64/boot/Image" ./mkbootimg )
( cd "$root" && ./mkvendorbootimg )
