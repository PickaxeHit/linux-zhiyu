#!/bin/bash
# mkpkgs.sh — package an installed tree as both a Debian .deb and an Arch
# .pkg.tar.zst, without needing makepkg or dpkg-buildpackage.
#
#   usage: mkpkgs.sh <stagedir> <outdir>
#   env:   PKG_NAME PKG_VERSION PKG_DESC PKG_URL
#          PKG_DEB_DEPENDS   (comma separated, Debian names)
#          PKG_ARCH_DEPENDS  (space separated, Arch names)
#
# <stagedir> is a root tree (us/, etc/ below it); it is copied, never modified.
set -euo pipefail

stage=${1:?usage: mkpkgs.sh <stagedir> <outdir>}
out=${2:?usage: mkpkgs.sh <stagedir> <outdir>}
name=${PKG_NAME:?PKG_NAME}
ver=${PKG_VERSION:?PKG_VERSION}
desc=${PKG_DESC:-$name}
url=${PKG_URL:-https://github.com/PickaxeHit/linux-zhiyu}
arch=aarch64

mkdir -p "$out"

# ---- Debian -------------------------------------------------------------
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cp -a "$stage" "$work/root"
install -d "$work/root/DEBIAN"
{
	printf 'Package: %s\n' "$name"
	printf 'Version: %s\n' "$ver"
	printf 'Architecture: arm64\n'
	printf 'Maintainer: linux-zhiyu CI <ci@localhost>\n'
	if [ -n "${PKG_DEB_DEPENDS:-}" ]; then
		printf 'Depends: %s\n' "$PKG_DEB_DEPENDS"
	fi
	printf 'Description: %s\n' "$desc"
} > "$work/root/DEBIAN/control"
dpkg-deb --build --root-owner-group "$work/root" "$out/${name}_${ver}_arm64.deb" >/dev/null
echo "wrote $out/${name}_${ver}_arm64.deb"

# ---- Arch ---------------------------------------------------------------
archpkg="${name}-${ver}-1-${arch}"
install -d "$work/arch"
cp -a "$stage/." "$work/arch/"
size=$(du -sb "$stage" | cut -f1)
{
	printf 'pkgname = %s\n' "$name"
	printf 'pkgbase = %s\n' "$name"
	printf 'pkgver = %s-1\n' "$ver"
	printf 'pkgdesc = %s\n' "$desc"
	printf 'url = %s\n' "$url"
	printf 'builddate = %s\n' "$(date +%s)"
	printf 'packager = linux-zhiyu CI\n'
	printf 'size = %s\n' "$size"
	printf 'arch = aarch64\n'
	printf 'license = GPL-2.0-only\n'
	for d in ${PKG_ARCH_DEPENDS:-}; do
		printf 'depend = %s\n' "$d"
	done
} > "$work/arch/.PKGINFO"
( cd "$work/arch" && tar --zstd --numeric-owner -cf "$out/${archpkg}.pkg.tar.zst" . )
echo "wrote $out/${archpkg}.pkg.tar.zst"
