#!/bin/bash
# deploy-modules.sh — copy built kernel modules to the device's /lib/modules.
#
# The initramfs carries everything the machine needs to come up, so the copy on
# the rootfs is only there to re-probe a driver without rebuilding the image:
#
#   ./build.sh                                   # kernel + initramfs + images
#   ./scripts/deploy-modules.sh                  # all modules -> rootfs copy
#   ./scripts/deploy-modules.sh drivers/media/i2c # just one subtree
#   ssh root@pad 'modprobe -r ov13b10; modprobe ov13b10'
#
# usage: deploy-modules.sh [path-under-the-kernel-tree ...]
#
# env: KS    kernel tree (default: kernel-source)
#      HOST  ssh target (default: root@192.168.42.1, the USB network)
#      VER   kernel release (default: what the tree reports)
set -euo pipefail

here=$(cd "$(dirname "$0")/.." && pwd)
KS=${KS:-$here/kernel-source}
HOST=${HOST:-root@192.168.42.1}
JOBS=${JOBS:-$(nproc)}
SSH_OPTS=${SSH_OPTS:-}

[ -d "$KS" ] || { echo "no kernel tree: $KS" >&2; exit 1; }
VER=${VER:-$(make -s -C "$KS" ARCH=arm64 kernelversion)-zhiyu+}

stage=$(mktemp -d "${TMPDIR:-/tmp}/modstage.XXXXXX")
trap 'rm -rf "$stage"' EXIT

echo "kernel : $KS ($VER)"
echo "target : $HOST"

# Same layout the initramfs uses: /lib/modules/<ver>/kernel/... plus a modprobe
# index, stripped, so the two copies stay interchangeable.
make -C "$KS" -j"$JOBS" ARCH=arm64 LLVM=1 \
	INSTALL_MOD_PATH="$stage" INSTALL_MOD_STRIP=1 modules_install >/dev/null

mods=$stage/lib/modules/$VER
[ -d "$mods" ] || { echo "modules_install produced nothing" >&2; exit 1; }

# Kernel build links and the source symlink are build-host specific.
rm -f "$mods/build" "$mods/source"

# Keep only the requested subtrees (paths relative to the kernel tree, or
# module names), everything by default.
if [ "$#" -gt 0 ]; then
	keep=$stage/keep
	mkdir -p "$keep"
	kept=0
	while IFS= read -r ko; do
		rel=${ko#"$mods/"}
		# strip the modules_install "kernel/" prefix so a caller can pass the
		# same path it would use in the kernel tree
		sub=${rel#kernel/}
		name=$(basename "$rel" .ko)
		for want in "$@"; do
			want=${want%/}
			case "$sub" in
			"$want"/*|"$want".ko)
				;;
			*)
				[ "$name" = "$want" ] || continue
				;;
			esac
			mkdir -p "$keep/$(dirname "$rel")"
			cp "$ko" "$keep/$rel"
			kept=$((kept + 1))
			break
		done
	done <<-EOF
	$(find "$mods" -name '*.ko' | sort)
	EOF
	[ "$kept" -gt 0 ] || { echo "nothing matched: $*" >&2; exit 1; }
	echo "selected: $kept modules"
	rm -rf "$mods/kernel" "$mods/updates"
	mkdir -p "$mods"
	cp -a "$keep/." "$mods/"
	rm -rf "$keep"
fi

size=$(du -sh "$mods" | cut -f1)
echo "sending: $size"

# tar over ssh: the device has no rsync, and this keeps the layout intact.
tar -C "$mods" -cf - . |
	ssh -o Compression=no $SSH_OPTS "$HOST" 'rm -rf /tmp/moddeploy && mkdir -p /tmp/moddeploy && tar -C /tmp/moddeploy -xf -'

ssh $SSH_OPTS "$HOST" "set -e
	mkdir -p /lib/modules
	rm -rf /lib/modules/$VER
	mv /tmp/moddeploy /lib/modules/$VER
	depmod -a $VER
	echo \"installed: \$(find /lib/modules/$VER -name '*.ko' | wc -l) modules in /lib/modules/$VER\""

if [ "$#" -gt 0 ]; then
	echo
	echo "re-probe them, e.g.:"
	echo "  ssh $HOST 'modprobe -r <name>; modprobe <name>'"
fi
