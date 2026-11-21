#!/bin/bash
# Build a static aarch64 BusyBox from the pinned upstream release.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/.." && pwd)
if [ -n "${BB_SRC:-}" ]; then
	src=$BB_SRC
else
	src=$(python3 "$root/scripts/deps.py" path busybox)
fi
out=$(realpath -m "${BB_OUT:-$root/out/build/busybox/bin/busybox}")
build=$root/out/build/busybox/src
mkdir -p "$(dirname "$out")"
rm -rf "$build"
mkdir -p "$build"
cp -a "$src/." "$build/"
chmod -R u+w "$build"
src=$build
jobs=${JOBS:-$(nproc)}
CROSS=${CROSS_COMPILE-aarch64-linux-gnu-}

die() { echo "build-busybox.sh: $*" >&2; exit 1; }

[ -f "$src/Makefile" ] || die "BusyBox source is missing: $src"
cd "$src"

# Backport the split-include buffer bound used by newer BusyBox releases.
sed -i 's/fgets(line+1, buffer_size, fp_find)/fgets(line+1, buffer_size-1, fp_find)/' scripts/basic/split-include.c

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
# out defaults to the build output itself, so only copy when they differ.
[ "$out" -ef busybox ] || cp -f busybox "$out"
"${CROSS}strip" "$out" 2>/dev/null || true
echo "== $out: $(stat -c %s "$out") bytes, md5 $(md5sum "$out" | cut -d' ' -f1) =="
