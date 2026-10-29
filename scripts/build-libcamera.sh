#!/bin/bash
# build-libcamera.sh — build libcamera-zhiyu and install it on the device.
#
# The device runs an aarch64 Arch-style userland, so the build runs natively
# on the board over ssh: cross-compiling would mean maintaining a sysroot that
# matches the device's GLES, Qt6 and libyaml, which is far more work than the
# few minutes a native build takes on eight cores.
#
#   ./scripts/build-libcamera.sh              # build + install
#   ./scripts/build-libcamera.sh --setup      # re-run meson setup only
#   ./scripts/build-libcamera.sh --no-install # build, leave it in the build dir
#
# env: HOST (default root@192.168.42.1), SRC (device side source dir),
#      BUILD (device side build dir), PREFIX (default /usr/local)
set -euo pipefail

here=$(cd "$(dirname "$0")/.." && pwd)
src_repo=$here/libcamera
HOST=${HOST:-root@192.168.42.1}
PORT=${PORT:-22}
SSH_OPTS=${SSH_OPTS:-}
SRC=${SRC:-/root/libcamera}
BUILD=${BUILD:-/root/libcamera-build}
PREFIX=${PREFIX:-/usr/local}

# The options match what this device needs: the simple pipeline (the only one
# that works with the mainline camss driver), the GPU debayer (the CPU one
# cannot keep up with 13 MP), and qcam.  The V4L2 compatibility layer is built
# so that ordinary V4L2 applications - kamoso, cheese, browsers - can use the
# camera through the wrapper the build installs as libcamerify.
setup_args=(
	-Dpipelines=simple -Dipas=simple
	-Dsoftisp-gpu=enabled
	-Dgstreamer=disabled -Dpycamera=disabled -Dv4l2=enabled
	-Dcam=enabled -Dqcam=enabled
	-Dtest=false -Ddocumentation=disabled
	--prefix="$PREFIX"
)

do_install=1
setup_only=0
for arg in "$@"; do
	case "$arg" in
	--no-install) do_install=0 ;;
	--setup) setup_only=1 ;;
	*) echo "build-libcamera.sh: unknown argument $arg" >&2; exit 1 ;;
	esac
done

[ -f "$src_repo/meson.build" ] || {
	echo "build-libcamera.sh: $src_repo is empty, run" >&2
	echo "  git submodule update --init libcamera" >&2
	exit 1
}

ssh_run() { ssh $SSH_OPTS -p "$PORT" "$HOST" "$@"; }

echo "== copying the source to $HOST:$SRC =="
tar -C "$src_repo" --exclude=.git -cf - . |
	ssh_run "rm -rf '$SRC' && mkdir -p '$SRC' && tar -C '$SRC' -xf -"

if [ "$setup_only" = 0 ]; then
	echo "== meson setup =="
	ssh_run "cd '$BUILD' 2>/dev/null && meson setup --reconfigure '$BUILD' '$SRC' ${setup_args[*]}" ||
		ssh_run "meson setup '$BUILD' '$SRC' ${setup_args[*]}"

	echo "== compiling =="
	ssh_run "ninja -C '$BUILD'"

	if [ "$do_install" = 1 ]; then
		echo "== installing to $PREFIX =="
		ssh_run "ninja -C '$BUILD' install && ldconfig"
	fi
fi

echo "== done =="
