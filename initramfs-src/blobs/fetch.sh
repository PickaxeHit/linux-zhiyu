#!/bin/bash
# fetch.sh — (re)populate blobs/ from MANIFEST.tsv.
#
# Every file under blobs/ comes from exactly one of two places, named in
# column 3 of MANIFEST.tsv:
#
#   zuxos:<image>:<path>   a file inside a ZUXOS factory image
#                          (FAT images: BTFM.bin, NON-HLOS.bin are unpacked
#                           with 7z; ext4 images: super_*.img are read with
#                           debugfs, so nothing has to be mounted)
#   online:<url>           a download; if the URL is a package the row's
#                          target path is read from usr/lib/firmware/ inside
#                          it (that is how the ath12k firmware comes in)
#
# The audio topology is deliberately not in the manifest: initramfs-src/tplg
# builds it from the .m4 sources there, and the result is only committed as a
# blob so that normal builds do not need the AudioReach tooling.
#
# Running this is only needed when blobs/ is missing or the stock images were
# updated; build.sh uses blobs/ as it is.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
WS=${WS:-/nosnap/gt13-port}
IMAGES=${ZUXOS_IMAGES:-$WS/TB378_ZUXOS_2.0.10.252_Tool/image}
CACHE=${CACHE:-${TMPDIR:-/tmp}/zhiyu-blobs-cache}
MANIFEST=$here/MANIFEST.tsv

die() { echo "fetch: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "$1 not found"; }
need debugfs
need 7z
need curl

[ -f "$MANIFEST" ] || die "no $MANIFEST"
mkdir -p "$CACHE"

is_fat() {
	case $(file -b "$IMAGES/$1" 2>/dev/null) in
	*FAT*|*MSDOS*) return 0 ;;
	*) return 1 ;;
	esac
}

# fat_dir <image> — one-time extraction of a FAT image, cached.  7z exits 2
# on these images because the file is shorter than the FAT geometry; the
# files still come out fine.
fat_dir() {
	local img=$1 dir
	dir=$CACHE/fat-$img
	[ -d "$dir" ] && { echo "$dir"; return; }
	mkdir -p "$dir"
	7z x -y -o"$dir" "$IMAGES/$img" >/dev/null 2>&1 || [ $? -eq 2 ] || \
		die "cannot unpack $IMAGES/$img"
	[ -n "$(ls -A "$dir")" ] || die "$IMAGES/$img extracted to nothing"
	echo "$dir"
}

fetch_zuxos() {
	local img=$1 inner=$2 dst=$3 dir
	if is_fat "$img"; then
		dir=$(fat_dir "$img")
		[ -f "$dir$inner" ] || die "$img:$inner not found"
		cp -f "$dir$inner" "$dst"
	else
		rm -f "$dst"
		debugfs -R "dump $inner $dst" "$IMAGES/$img" >/dev/null 2>&1 || true
		[ -s "$dst" ] || die "cannot read $inner from $img"
	fi
}

fetch_online() {
	local url=$1 dst=$2 target=$3 pkg
	pkg=$CACHE/$(basename "$url")
	if [ ! -f "$pkg" ]; then
		echo "   downloading $(basename "$url")"
		curl -fsSL "$url" -o "$pkg.part" || die "download failed: $url"
		mv -f "$pkg.part" "$pkg"
	fi
	case $pkg in
	*.pkg.tar.zst)
		tar --zstd -xO -f "$pkg" "usr/lib/firmware/$target" > "$dst" || \
			die "$target not in $(basename "$pkg")"
		;;
	*)
		cp -f "$pkg" "$dst"
		;;
	esac
}

total=0
while IFS=$'\t' read -r target bytes source note; do
	case ${target:-} in
	''|'#'*) continue ;;
	esac
	[ -n "${source:-}" ] || die "no source for $target"
	dst=$here/$target
	mkdir -p "$(dirname "$dst")"
	case $source in
	zuxos:*)
		rest=${source#zuxos:}
		img=${rest%%:*}
		inner=${rest#*:}
		case $inner in
		/*) ;;
		*) inner=/$inner ;;
		esac
		fetch_zuxos "$img" "$inner" "$dst"
		;;
	online:*)
		fetch_online "${source#online:}" "$dst" "$target"
		;;
	*)
		die "unknown source kind: $source (row: $target)"
		;;
	esac
	size=$(stat -c %s "$dst")
	if [ -n "${bytes:-}" ] && [ "$bytes" != "$size" ]; then
		echo "   WARNING: $target is $size bytes, manifest says $bytes"
	fi
	total=$((total + 1))
done < "$MANIFEST"

echo "== $total files, $(du -sh "$here/firmware" 2>/dev/null | cut -f1) firmware, $(du -sh "$here/sensors" 2>/dev/null | cut -f1) sensors =="
