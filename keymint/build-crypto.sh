#!/usr/bin/env bash
# Build a static aarch64 libcrypto from the pinned OpenSSL source.
#
# The initramfs binaries use only libcrypto, so this builds it from the Git
# revision in deps/deps.json instead of unpacking a distribution package.
set -euo pipefail
base=$(cd -- "$(dirname -- "$0")" && pwd)
root=$(cd "$base/.." && pwd)
deps=${KEYMINT_DEPS:-$base/.deps}
mkdir -p "$deps"
deps=$(cd "$deps" && pwd)
cc=${CC:-${CROSS_COMPILE:-}gcc}
case $("$cc" -dumpmachine) in aarch64*) ;; *) echo 'Set CC or CROSS_COMPILE for ARM64' >&2; exit 1 ;; esac
cross=${CROSS_COMPILE-aarch64-linux-gnu-}
src=$(python3 "$root/scripts/deps.py" path openssl)
rev=$(python3 "$root/scripts/deps.py" rev openssl)
build_id=$({ printf "%s\n" "$rev" "$cross" "$cc"; "$cc" --version; sha256sum "$0"; } | sha256sum | cut -d' ' -f1)

# Reuse only the same source, compiler and build recipe.
if [ "$(cat "$deps/crypto/.build-id" 2>/dev/null)" = "$build_id" ] &&
	[ -f "$deps/crypto/usr/lib/aarch64-linux-gnu/libcrypto.a" ]; then
	echo "openssl: using existing static libcrypto $rev"
	exit 0
fi

build=$deps/openssl-build
stage=$(mktemp -d "$deps/crypto.XXXXXX")
trap 'rm -rf "$stage"' EXIT
rm -rf "$build"
mkdir -p "$build"

if ! (
	cd "$build"
	env -u CC "$src/Configure" linux-aarch64 --cross-compile-prefix="$cross" \
		--prefix=/usr --libdir=lib/aarch64-linux-gnu --openssldir=/etc/ssl \
		no-shared no-tests no-zlib
) >"$build/configure.log" 2>&1; then
	cat "$build/configure.log" >&2
	exit 1
fi
if ! make -C "$build" -j"${JOBS:-4}" >"$build/make.log" 2>&1; then
	tail -n 100 "$build/make.log" >&2
	exit 1
fi
if ! make -C "$build" install_sw DESTDIR="$stage" >"$build/install.log" 2>&1; then
	tail -n 100 "$build/install.log" >&2
	exit 1
fi

lib=$stage/usr/lib/aarch64-linux-gnu/libcrypto.a
[ -f "$lib" ] || { echo "OpenSSL did not install libcrypto.a" >&2; exit 1; }
size=$(stat -c %s "$lib")
printf '%s\n' "$rev" > "$stage/.openssl-rev"
printf '%s\n' "$build_id" > "$stage/.build-id"
rm -rf "$deps/crypto"
mv "$stage" "$deps/crypto"
echo "openssl: static libcrypto $rev ($size bytes)"
