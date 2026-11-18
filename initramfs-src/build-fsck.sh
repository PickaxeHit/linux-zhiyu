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
		"https://git.kernel.org/pub/scm/linux/kernel/git/jaegeuk/f2fs-tools.git/snapshot/f2fs-tools-$version.tar.gz" \
		"$checksum" "$src"
fi
[ -f "$src/configure.ac" ] || die "f2fs-tools source is missing: $src"
cd "$src"

if [ ! -f Makefile ]; then
	# The git snapshot ships no generated configure script.
	./autogen.sh >/dev/null 2>&1
	./configure --host="${CROSS%-}" --disable-shared --enable-static \
		--without-selinux --without-blkid >/dev/null
fi
make -j"$jobs" >/dev/null 2>&1

# libtool still links a dynamic binary even with LDFLAGS=-static, so link the
# objects that were just built against the static convenience library by hand.
"$cc" -static -o "$out.tmp" fsck/*.o lib/.libs/libf2fs.a -lpthread
file -b "$out.tmp" | grep -q "statically linked" \
	|| die "$out.tmp is not statically linked"
install -Dm0755 "$out.tmp" "$out"
rm -f "$out.tmp"
echo "fsck.f2fs: $out ($(stat -c %s "$out") bytes, f2fs-tools $version)"
