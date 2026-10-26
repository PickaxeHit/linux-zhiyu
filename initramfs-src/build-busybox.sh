#!/bin/bash
# Build a static aarch64 busybox from the initramfs-src/busybox submodule.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
src=${BB_SRC:-$here/busybox}
out=${BB_OUT:-$src/busybox}
jobs=${JOBS:-$(nproc)}
CROSS=${CROSS_COMPILE:-aarch64-linux-gnu-}

die() { echo "build-busybox.sh: $*" >&2; exit 1; }

[ -d "$src" ] || die "busybox submodule is not initialized: $src"
cd "$src"

if [ ! -f .config ]; then
	echo "== busybox defconfig =="
	make ARCH=arm64 CROSS_COMPILE="$CROSS" defconfig >/dev/null
	if grep -q '^# CONFIG_STATIC is not set' .config; then
		sed -i 's/^# CONFIG_STATIC is not set/CONFIG_STATIC=y/' .config
	elif ! grep -q '^CONFIG_STATIC=y' .config; then
		echo 'CONFIG_STATIC=y' >> .config
	fi
	sed -i 's/^CONFIG_TC=y/# CONFIG_TC is not set/' .config
	sed -i 's/^CONFIG_FEATURE_TC_INGRESS=y/# CONFIG_FEATURE_TC_INGRESS is not set/' .config
	make ARCH=arm64 CROSS_COMPILE="$CROSS" oldconfig >/dev/null
fi
grep -q '^CONFIG_STATIC=y' .config || die "CONFIG_STATIC is not set in .config"

echo "== building busybox (static, aarch64) =="
make -j"$jobs" ARCH=arm64 CROSS_COMPILE="$CROSS" busybox >/dev/null
file busybox | sed 's/^/   /'
cp -f busybox "$out"
aarch64-linux-gnu-strip "$out" 2>/dev/null || true
echo "== $out: $(stat -c %s "$out") bytes, md5 $(md5sum "$out" | cut -d' ' -f1) =="
