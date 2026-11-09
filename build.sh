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
# Default to the upstream-aligned config (Arch's feature set + the board
# support); the older slim board config stays as a fallback for series that
# do not have an aligned one yet.
CFG=${CFG:-$root/configs/linux-$SERIES-upstream.config}
[ -f "$CFG" ] || CFG=$root/configs/linux-$SERIES-zhiyu.config
[ -f "$CFG" ] || { echo "no kernel config for $SERIES: $CFG" >&2; exit 1; }

echo "kernel : $KS ($KVER)"
echo "config : $CFG"

cp "$CFG" "$KS/.config"
# gcc, not LLVM=1: LTO is disabled in the config, and a clang-built kernel
# makes dkms append LLVM=1 to every out-of-tree module build (it reads
# CONFIG_CC_IS_CLANG from the kernel config), which drags the whole LLVM
# toolchain onto the device.  Set CROSS_COMPILE when building on a host of a
# different architecture.
MAKE_ARGS="ARCH=arm64"
[ -n "${CROSS_COMPILE:-}" ] && MAKE_ARGS="$MAKE_ARGS CROSS_COMPILE=$CROSS_COMPILE"
# Kconfig probes the *target* compiler for CPU/assembler features (LSE, MTE,
# SME, LSUI, the errata list) and drops the corresponding symbols when the
# probe fails.  Probing with a non-arm64 host gcc therefore rewrites half of
# the config, and the later `make` stops to ask questions on stdin.  Cross
# builds have to name the cross toolchain up front.
if [ "$(uname -m)" != aarch64 ] && [ -z "${CROSS_COMPILE:-}" ]; then
	echo "build.sh: on $(uname -m) set CROSS_COMPILE=aarch64-linux-gnu- (config probes run against it)" >&2
	exit 1
fi
make -C "$KS" $MAKE_ARGS olddefconfig
VER=${VER:-$(make -s -C "$KS" $MAKE_ARGS kernelrelease)}
echo "release: $VER"
make -C "$KS" -j"$JOBS" $MAKE_ARGS Image modules
"$root/keymint/build-deps.sh"
( cd "$root" && KS="$KS" VER="$VER" ./initramfs-src/build.sh )
( cd "$root" && KERNEL="$KS/arch/arm64/boot/Image" ./mkbootimg )
( cd "$root" && ./mkvendorbootimg )
