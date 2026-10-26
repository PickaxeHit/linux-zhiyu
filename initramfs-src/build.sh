#!/bin/bash
# build.sh — assemble the initramfs tree for Lenovo TB378FC ("zhiyu").
#
# Everything that ends up in the initramfs comes from exactly one of three
# places, and this script is the only thing that writes the tree:
#
#   fs/                  our own init script                  (source)
#   busybox/busybox      built from the busybox submodule (source -> binary)
#   blobs/firmware/      firmware blobs, see MANIFEST.tsv (blob)
#   modules.tsv + $KS    kernel modules built from source (source -> .ko)
#
# usage: ./build.sh [outdir]      (default: ../initramfs)
# env:   KS (kernel tree with built modules), VER (kernel release), OUT
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
OUT=${OUT:-${1:-$here/../initramfs}}
# Where the built .ko files come from.  Prefer an explicit KS, then the kernel
# tree archived next to us, then the live build tree.
first_src=$(awk -F'\t' '!/^#/ && NF>=2 {print $2; exit}' "$here/modules.tsv")
for cand in "${KS:-}" "$here/../kernel-source" /nosnap/gt13-port/linux/kernel-source; do
	[ -n "$cand" ] || continue
	if [ -f "$cand/$first_src" ]; then KS=$cand; break; fi
done
KS=${KS:-$here/../kernel-source}
VER=${VER:-7.2.11-zhiyu-diag-dirty}
BB=$here/busybox/busybox

die() { echo "build.sh: $*" >&2; exit 1; }

# ---- 1. busybox (built from source, statically linked) --------------------
if [ ! -x "$BB" ] || [ "${REBUILD_BB:-0}" = 1 ]; then
	echo "== building busybox =="
	"$here/build-busybox.sh"
fi
file -b "$BB" | grep -q "statically linked" || die "$BB is not statically linked"

# ---- 2. staging tree ------------------------------------------------------
stage=$(mktemp -d "$here/.stage.XXXXXX")
trap 'rm -rf "$stage"' EXIT
mkdir -p "$stage"/bin "$stage"/dev/pts "$stage"/etc/modprobe.d \
	"$stage"/lib/firmware "$stage"/lib/modules/"$VER" \
	"$stage"/proc "$stage"/root "$stage"/run "$stage"/sys "$stage"/tmp

# our init script
install -m 0755 "$here/fs/init" "$stage/init"

# busybox + its applet symlinks
install -m 0755 "$BB" "$stage/bin/busybox"
applets=0
while read -r a; do
	[ -n "$a" ] || continue
	ln -sf busybox "$stage/bin/$a"
	applets=$((applets + 1))
done < "$here/busybox-applets.txt"

# ---- 3. firmware blobs ----------------------------------------------------
cp -a "$here"/blobs/firmware/. "$stage/lib/firmware/"

# the SM8750 audio topology is *built* (m4 + alsatplg), not a blob: it is
# installed on top of the firmware tree at the path the ADSP firmware looks for
if [ ! -f "$here/tplg/sm8750-tplg.bin" ] || [ "${REBUILD_TPLG:-0}" = 1 ]; then
	"$here/tplg/build.sh" || die "topology build failed"
fi
install -m 0644 "$here/tplg/sm8750-tplg.bin" "$stage/lib/firmware/qcom/sm8750/sm8750-tplg.bin"
fw=$(find "$stage/lib/firmware" -type f | wc -l)

# ---- 4. kernel modules built from source ----------------------------------
mods=0
while IFS=$'\t' read -r rel src; do
	case "$rel" in ''|\#*) continue ;; esac
	[ -f "$KS/$src" ] || die "module missing: $KS/$src
       build them first: make -C $KS ARCH=arm64 LLVM=1 CROSS_COMPILE=aarch64-linux-gnu- modules"
	mkdir -p "$(dirname "$stage/lib/modules/$VER/$rel")"
	install -m 0644 "$KS/$src" "$stage/lib/modules/$VER/$rel"
	mods=$((mods + 1))
done < "$here/modules.tsv"

# ---- 5. modprobe index ----------------------------------------------------
depmod -b "$stage" "$VER" 2>/dev/null || echo "   depmod: warnings ignored"

# ---- 6. summary + publish -------------------------------------------------
echo "init   : $(head -1 "$stage/init")"
echo "busybox: $("$here"/../initramfs/bin/busybox 2>/dev/null | head -0; file -b "$BB" | cut -d, -f1-3)"
echo "applets: $applets   firmware: $fw files   modules: $mods"
echo "tree   : $(find "$stage" -type f | wc -l) files, $(du -sh "$stage" | cut -f1)"

mkdir -p "$(dirname "$OUT")"
stamp=$(date +%Y%m%d-%H%M%S)
if [ -e "$OUT" ] && [ "${KEEP_OLD:-1}" = 1 ]; then
	mv "$OUT" "$OUT.bak.$stamp"
	echo "old    : kept as $OUT.bak.$stamp"
fi
mv "$stage" "$OUT"
trap - EXIT
echo "wrote  : $OUT"
