#!/bin/bash
# build.sh — assemble the initramfs tree for Lenovo TB378FC ("zhiyu").
#
# Everything that ends up in the initramfs comes from one of the locations
# below, and this script is the only thing that writes the tree:
#
#   fs/                  our own init script                  (source)
#   $root/.sources/      fetched BusyBox and f2fs-tools       (see deps/)
#   firmware repo        firmware blobs and SNS registry      (see deps/)
#   modules.tsv + $KS    kernel modules built from source (source -> .ko)
#
# usage: ./build.sh [outdir]      (default: ../initramfs)
# env:   KS (kernel tree with built modules), VER (kernel release), OUT
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/.." && pwd)
OUT=${OUT:-${1:-$here/../initramfs}}
# Where the built .ko files come from.  Prefer an explicit KS, then the kernel
# tree archived next to us.
KS=${KS:-$root/kernel-source}
MODULES_DIR=${MODULES_DIR:-$KS}
VER=${VER:-$(make -s -C "$KS" ARCH=arm64 kernelrelease)}
BB=${BB_OUT:-$root/out/build/busybox/bin/busybox}
firmware=${FW_SRC:-$(python3 "$root/scripts/deps.py" path firmware)}
fsck=${FSCK_OUT:-$root/out/build/f2fs/bin/fsck.f2fs}
TPLG_OUT=${TPLG_OUT:-$root/out/sm8750-tplg.bin}

die() { echo "build.sh: $*" >&2; exit 1; }

# ---- 1. busybox (built from source, statically linked) --------------------
BB_OUT="$BB" "$here/build-busybox.sh"
file -b "$BB" | grep -q "statically linked" || die "$BB is not statically linked"


# ---- 2. staging tree ------------------------------------------------------
stage=$(mktemp -d "$here/.stage.XXXXXX")
trap 'rm -rf "$stage"' EXIT
mkdir -p "$stage"/bin "$stage"/dev/pts "$stage"/etc/modprobe.d \
	"$stage"/lib/firmware "$stage"/lib/modules/"$VER" \
	"$stage"/proc "$stage"/root "$stage"/run "$stage"/sys "$stage"/tmp

# our init script
install -m 0755 "$here/fs/init" "$stage/init"
mkdir -p "$stage/libexec"
install -m 0755 "$here/fs/libexec/metadata-root" "$stage/libexec/metadata-root"

# busybox + its applet symlinks
install -m 0755 "$BB" "$stage/bin/busybox"
applets=0
while read -r a; do
	[ -n "$a" ] || continue
	ln -sf busybox "$stage/bin/$a"
	applets=$((applets + 1))
done < "$here/busybox-applets.txt"

# ---- 2b. small static helpers --------------------------------------------
# busybox has no bluetooth code at all, but the board's factory BD address
# lives in the persist partition exactly like the WLAN address does.  btaddr
# sends the single management command that hands the address to the kernel, so
# the value never has to be written into the device tree.
CC_AARCH64=${CC_AARCH64:-${CROSS_COMPILE-aarch64-linux-gnu-}gcc}
for src in "$here"/src/*.c; do
	[ "$(basename "$src")" != userdata-map.c ] || continue
	[ -f "$src" ] || continue
	tool=$stage/bin/$(basename "$src" .c)
	"$CC_AARCH64" -static -Os -Wall -Wextra -o "$tool" "$src" \
		|| die "cannot build $src (need ${CC_AARCH64})"
	file -b "$tool" | grep -q "statically linked" \
		|| die "$tool is not statically linked"
	echo "helper : $(basename "$tool") ($(stat -c %s "$tool") bytes)"
done

# A fully static fsck.f2fs lets the initramfs repair a dirty f2fs checkpoint
# before it mounts the shared userdata volume.  Built from the pinned
# f2fs-tools release with --without-selinux/--without-libuuid, so it has no
# runtime dependencies.
F2FS_OUT="$fsck" bash "$here/build-fsck.sh"
[ -x "$fsck" ] || die "missing $fsck"
if [ -x "$fsck" ]; then
	install -m 0755 "$fsck" "$stage/bin/fsck.f2fs"
	echo "helper : fsck.f2fs ($(stat -c %s "$stage/bin/fsck.f2fs") bytes)"
fi

# Stage fully static clients built from source and verified static libraries.
"$here/../keymint/stage-initramfs.sh" "$stage"

# ---- 3. firmware blobs ----------------------------------------------------
# The firmware repository is pinned by deps/deps.json and fetched into
# .sources/firmware; it carries the firmware tree, the SNS registry and its
# own license notices.
cp -a "$firmware/firmware/." "$stage/lib/firmware/"

# the SM8750 audio topology is *built* (m4 + alsatplg), not a blob: it is
# installed on top of the firmware tree at the path the ADSP firmware looks for
OUT="$TPLG_OUT" "$here/tplg/build.sh" || die "topology build failed"
install -Dm644 "$TPLG_OUT" "$stage/lib/firmware/qcom/sm8750/sm8750-tplg.bin"
fw=$(find "$stage/lib/firmware" -type f | wc -l)

# ---- 4. kernel modules built from source ----------------------------------
mods=0
while IFS=$'\t' read -r rel src; do
	case "$rel" in ''|\#*) continue ;; esac
	[ -f "$MODULES_DIR/$src" ] || die "module missing: $MODULES_DIR/$src
       build them first: ./build.sh kernel"
	mkdir -p "$(dirname "$stage/lib/modules/$VER/$rel")"
	install -m 0644 "$MODULES_DIR/$src" "$stage/lib/modules/$VER/$rel"
	mods=$((mods + 1))
done < "$here/modules.tsv"

# ---- 5. modprobe index and load order -------------------------------------
depmod -b "$stage" "$VER" 2>/dev/null || echo "   depmod: warnings ignored"

# depmod knows the dependency graph; hand it to init so the modules can be
# insmod'ed in an order that never hits "Unknown symbol" (see order-modules.py
# for what the phases mean).
[ -x "$(command -v python3)" ] || die "python3 is needed to order the modules"
python3 "$here/order-modules.py" "$stage/lib/modules/$VER" \
	> "$stage/lib/modules/$VER/load-order" \
	|| die "module ordering failed"
ordered=$(wc -l < "$stage/lib/modules/$VER/load-order")

# ---- 6. summary + publish -------------------------------------------------
echo "init   : $(head -1 "$stage/init")"
echo "busybox: $(file -b "$BB" | cut -d, -f1-3)"
echo "applets: $applets   firmware: $fw files   modules: $mods ($ordered ordered)"
echo "tree   : $(find "$stage" -type f | wc -l) files, $(du -sh "$stage" | cut -f1)"

mkdir -p "$(dirname "$OUT")"
stamp=$(date +%Y%m%d-%H%M%S-%N)
if [ -e "$OUT" ] && [ "${KEEP_OLD:-1}" = 1 ]; then
	mv "$OUT" "$OUT.bak.$stamp"
	echo "old    : kept as $OUT.bak.$stamp"
	# Keep the last KEEP_BACKUPS snapshots (default 3) and drop the rest: one is
	# ~94 MB and a bring-up session runs this script dozens of times.
	keep=${KEEP_BACKUPS:-3}
	( cd "$(dirname "$OUT")" && ls -1d "$(basename "$OUT")".bak.* 2>/dev/null | \
		sort | head -n -"$keep" | while read -r old_bak; do
			rm -rf "$old_bak"
			echo "pruned : $old_bak"
		done )
elif [ -e "$OUT" ]; then
	rm -rf -- "$OUT"
fi
mv -T "$stage" "$OUT"
trap - EXIT
echo "wrote  : $OUT"
