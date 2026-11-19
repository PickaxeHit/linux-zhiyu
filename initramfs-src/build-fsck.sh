#!/bin/bash
# Build a fully static aarch64 fsck.f2fs from the pinned f2fs-tools release.
#
# The initramfs runs it against the metadata-encrypted userdata dm device when
# the f2fs checkpoint still carries CP_ERROR/CP_FSCK.  Those flags survive a
# normal mount and make Android refuse the volume ("repair required"), so the
# only place where they can be cleared is here, before the rw mount.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
read -r version checksum < "$here/F2FS-TOOLS-RELEASE.txt"
src=${F2FS_SRC:-$here/.sources/f2fs-tools-$version}
out=${F2FS_OUT:-$here/blobs/fsck.f2fs}
jobs=${JOBS:-$(nproc)}
CROSS=${CROSS_COMPILE:-aarch64-linux-gnu-}
cc=${CROSS}gcc

die() { echo "build-fsck.sh: $*" >&2; exit 1; }

if [ -z "${F2FS_SRC:-}" ]; then
	bash "$here/fetch-source.sh" \
		"https://deb.debian.org/debian/pool/main/f/f2fs-tools/f2fs-tools_$version.orig.tar.xz" \
		"$checksum" "$src"
fi
[ -f "$src/configure.ac" ] || die "f2fs-tools source is missing: $src"
cd "$src"

[ -f configure ] || ./autogen.sh >/dev/null 2>&1
# Force every optional dependency off so the result does not depend on what
# the build host happens to have installed: with libuuid/libselinux/liblz4
# present, configure compiles in uuid_unparse()/LZ4_compress_fast_extState()
# calls that the static link below would then have to resolve.
# -std=gnu17: 1.16 still has "typedef u8 bool;", which GCC 15 and later
# reject because bool is a keyword in their default C23 mode.
CFLAGS="-std=gnu17 -O2" \
./configure --host="${CROSS%-}" --disable-shared --enable-static \
	--without-selinux --without-blkid --without-lz4 --without-lzo2 \
	ac_cv_lib_uuid_uuid_clear=no ac_cv_header_uuid_uuid_h=no >/dev/null
for feature in HAVE_LIBUUID HAVE_LIBSELINUX HAVE_LIBLZ4 HAVE_LIBLZO2; do
	grep -q "#define $feature" config.h \
		&& die "$feature was detected; the static link needs $feature"
done
make -j"$jobs" >/dev/null 2>&1

# libtool still links a dynamic binary even with LDFLAGS=-static, so link the
# objects that were just built against the static convenience library by hand.
"$cc" -static -o "$out.tmp" fsck/*.o lib/.libs/libf2fs.a -lpthread
file -b "$out.tmp" | grep -q "statically linked" \
	|| die "$out.tmp is not statically linked"
install -Dm0755 "$out.tmp" "$out"
rm -f "$out.tmp"
echo "fsck.f2fs: $out ($(stat -c %s "$out") bytes, f2fs-tools $version)"
