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
# The Arch step cds into the package tree, so both paths have to be absolute.
stage=$(realpath "$stage")
out=$(realpath -m "$out")
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
	if [ -n "${PKG_DEB_PROVIDES:-}" ]; then
		printf 'Provides: %s\n' "$PKG_DEB_PROVIDES"
	fi
	if [ -n "${PKG_DEB_CONFLICTS:-}" ]; then
		printf 'Conflicts: %s\n' "$PKG_DEB_CONFLICTS"
	fi
	if [ -n "${PKG_DEB_REPLACES:-}" ]; then
		printf 'Replaces: %s\n' "$PKG_DEB_REPLACES"
		printf 'Breaks: %s\n' "$PKG_DEB_REPLACES"
	fi
	printf 'Description: %s\n' "$desc"
} > "$work/root/DEBIAN/control"
dpkg-deb --build --root-owner-group "$work/root" "$out/${name}_${ver}_arm64.deb" >/dev/null
echo "wrote $out/${name}_${ver}_arm64.deb"

# ---- Arch ---------------------------------------------------------------
# pacman's pkgver may not contain "-" (it separates the pkgrel), and our
# kernel version is 7.3.1-zhiyu+: Arch gets 7.3.1_zhiyu+ while the Debian
# package keeps the original string.
archver=$(printf '%s' "$ver" | tr '-' '_')
archpkg="${name}-${archver}-1-${arch}"
install -d "$work/arch"
cp -a "$stage/." "$work/arch/"
size=$(du -sb "$stage" | cut -f1)
{
	printf 'pkgname = %s\n' "$name"
	printf 'pkgbase = %s\n' "$name"
	printf 'pkgver = %s-1\n' "$archver"
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
	for p in ${PKG_ARCH_PROVIDES:-}; do
		printf 'provides = %s\n' "$p"
	done
	# Versioned shared libraries: makepkg records a "provides" entry for every
	# SONAME (libfoo.so.1.2.3 -> libfoo.so=1.2.3-64), which is what dependents
	# such as gst-plugin-libcamera actually require (libcamera.so=0.7-64).
	# mkpkgs writes .PKGINFO by hand, so derive the same entries here.
	find "$work/arch" -type f \( -name '*.so' -o -name '*.so.*' \) -print0 |
	while IFS= read -r -d '' sofile; do
		soname=$(readelf -d "$sofile" 2>/dev/null |
			sed -n 's/.*(SONAME).*\[\(.*\)\]/\1/p')
		case $soname in
		*.so.*) ;;
		*) continue ;;	# unversioned or no SONAME: nothing to provide
		esac
		printf 'provides = %s=%s-64\n' "${soname%%.so.*}.so" "${soname#*.so.}"
	done | sort -u
	for p in ${PKG_ARCH_CONFLICTS:-}; do
		printf 'conflict = %s\n' "$p"
	done
	for p in ${PKG_ARCH_REPLACES:-}; do
		printf 'replaces = %s\n' "$p"
	done
} > "$work/arch/.PKGINFO"
# .PKGINFO must be the first entry and must not be prefixed with "./":
# libalpm looks for that exact name and otherwise reports "missing package
# metadata" and refuses to install the package.
( cd "$work/arch" &&
  tar --zstd --numeric-owner -cf "$out/${archpkg}.pkg.tar.zst" .PKGINFO \
      $(find . -mindepth 1 -maxdepth 1 ! -name .PKGINFO -printf '%f\n') )
echo "wrote $out/${archpkg}.pkg.tar.zst"
