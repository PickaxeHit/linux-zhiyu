#!/bin/bash
# build-qcom-va-driver.sh — build the VA-API backend for the Iris video codec
# and install it on the device.
#
# qcom-va-driver (formerly libva-v4l2) is an experimental libva driver that
# drives the stateful V4L2 encoder and decoder of the Qualcomm Iris driver.
# It is not packaged for Arch, and the kernel side it talks to is still
# moving, so the snapshot is pinned to a commit that is known to work with
# the Iris changes in kernel-source instead of following master.
#
#   ./scripts/build-qcom-va-driver.sh                 # fetch, build, install, test
#   ./scripts/build-qcom-va-driver.sh --no-install    # build only
#   TARBALL=/path/to/tar.gz ./scripts/build-qcom-va-driver.sh
#
# The driver installs as qcom_drv_video.so with the msm_drv_video.so and
# v4l2_drv_video.so aliases, which is what libva probes on a Qualcomm DRM
# device (LIBVA_DRIVER_NAME=v4l2 forces it).
#
# Meson's default CDSP VPP backend needs GHC and the Hexagon SDK; neither is
# useful here, so both optional backends are disabled.  That leaves the
# decode, encode and GPU-copy paths, which is all the device needs.
#
# env: HOST (default root@192.168.42.1), PORT (22), SSH_OPTS, SRC
#      (device side source dir), BUILD (device side build dir),
#      PREFIX (default /usr), PROXY (http proxy for the download)
set -euo pipefail

here=$(cd "$(dirname "$0")/.." && pwd)
HOST=${HOST:-root@192.168.42.1}
PORT=${PORT:-22}
SSH_OPTS=${SSH_OPTS:-}
SRC=${SRC:-/root/va-src}
BUILD=${BUILD:-$SRC/build}
PREFIX=${PREFIX:-/usr}
PROXY=${PROXY:-http://127.0.0.1:20122}

commit=0980a1decf26d34c9aa71cd0a4a0d25703a7a17f
sha256=ad1123de8e5af73e5534a5275ded6281fab485768fdd83c10c69eba6ef1c344d
TARBALL=${TARBALL:-${TMPDIR:-/tmp}/qcom-va-driver-$commit.tar.gz}

do_install=1
for arg in "$@"; do
	case "$arg" in
	--no-install) do_install=0 ;;
	*) echo "build-qcom-va-driver.sh: unknown argument $arg" >&2; exit 1 ;;
	esac
done

if [ ! -f "$TARBALL" ]; then
	echo "== downloading $commit =="
	curl -fsSL ${PROXY:+-x "$PROXY"} -o "$TARBALL" \
		"https://codeload.github.com/radxa-pkg/qcom-va-driver/tar.gz/$commit"
fi

echo "$sha256  $TARBALL" | sha256sum -c --quiet - || {
	echo "build-qcom-va-driver.sh: $TARBALL is not the pinned snapshot" >&2
	exit 1
}

ssh_run() { ssh $SSH_OPTS -p "$PORT" "$HOST" "$@"; }

echo "== copying the source to $HOST:$SRC =="
ssh_run "rm -rf '$SRC' && mkdir -p '$SRC'"
cat "$TARBALL" | ssh_run "tar -C '$SRC' --strip-components=1 -xzf -"

echo "== meson setup =="
ssh_run "meson setup --reconfigure '$BUILD' '$SRC' --buildtype=release \
	--prefix='$PREFIX' -Dlibdir=lib -Dcdsp_vpp=disabled -Dvulkan_vpp=disabled" ||
	ssh_run "meson setup '$BUILD' '$SRC' --buildtype=release \
	--prefix='$PREFIX' -Dlibdir=lib -Dcdsp_vpp=disabled -Dvulkan_vpp=disabled"

echo "== compiling =="
ssh_run "ninja -C '$BUILD'"

if [ "$do_install" = 1 ]; then
	echo "== installing to $PREFIX =="
	ssh_run "ninja -C '$BUILD' install && ldconfig"

	echo "== checking the driver =="
	ssh_run "vainfo --display drm --device /dev/dri/renderD128 >/dev/null" &&
		echo "vainfo initialised ($(ssh_run "vainfo --display drm \
			--device /dev/dri/renderD128 2>/dev/null | grep -c VAProfile") profiles)"
fi

echo "== done =="
