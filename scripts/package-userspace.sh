#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
[[ $(uname -m) == aarch64 ]] || { echo 'Userspace packages require an aarch64 build environment' >&2; exit 1; }
export BUILD_ROOT="out/build/packages/$DISTRO" STAGE_ROOT="stage/packages/$DISTRO"
mkdir -p "$BUILD_ROOT" "$STAGE_ROOT"
case $DISTRO in
    debian) libdir=lib/aarch64-linux-gnu; versions=(0.7 0.8) ;;
    arch) libdir=lib; versions=(0.7) ;;
    fedora) libdir=lib64; versions=(0.7 0.8); scripts/package-fedora-extras.sh ;;
    *) exit 2 ;;
esac
lc_options=(-Dwerror=false -Dqcam=enabled -Dpipelines=simple -Dgstreamer=disabled -Dpycamera=disabled -Ddocumentation=disabled -Dcam=enabled -Dv4l2=enabled -Dtest=false)
# Preserve the supported camera ABIs for each distribution.
for soname in "${versions[@]}"; do
  src=libcamera/$soname
  build="$BUILD_ROOT/libcamera-$soname"
  stage="$STAGE_ROOT/libcamera-$soname"
  test -f "$src/meson.build" || { echo "missing $src submodule" >&2; exit 1; }
  rm -rf "$build" "$stage"
  meson setup "$build" "$src" --buildtype=release --prefix=/usr --libdir="$libdir" "${lc_options[@]}"
  meson compile -j "${JOBS:-$(nproc)}" -C "$build"
  DESTDIR="$PWD/$stage" meson install -C "$build" --no-rebuild
  version=$(meson introspect "$build" --projectinfo |
    python3 -c 'import json,sys; print(json.load(sys.stdin)["version"])')
  LIBCAMERA_SOURCE="$src" bash scripts/stage-license-notices.sh "$stage" libcamera-zhiyu
  PKG_NAME=libcamera-zhiyu PKG_VERSION="$version" \
  PKG_LICENSE='LGPL-2.1-or-later AND GPL-2.0-or-later AND MIT' \
  PKG_DESC="Camera stack for the zhiyu port (simple pipeline, EGL debayer, CDAF)" \
  PKG_DEB_DEPENDS="libc6, libstdc++6, libudev1, libdrm2, libyaml-0-2, libevent-2.1-7t64, libjpeg62-turbo, libqt6widgets6" \
  PKG_DEB_PROVIDES="libcamera-tools, libcamera-ipa, libcamera$soname" \
  PKG_DEB_CONFLICTS="libcamera, libcamera-tools, libcamera-ipa, libcamera$soname" \
  PKG_DEB_REPLACES="libcamera, libcamera-tools, libcamera-ipa, libcamera$soname" \
  PKG_ARCH_DEPENDS="gcc-libs glibc systemd-libs libdrm libyaml libevent libjpeg-turbo qt6-base" \
  PKG_ARCH_PROVIDES="libcamera libcamera-tools libcamera-ipa" \
  PKG_ARCH_CONFLICTS="libcamera libcamera-tools libcamera-ipa" \
  PKG_ARCH_REPLACES="libcamera libcamera-tools libcamera-ipa" \
  PKG_RPM_PROVIDES="libcamera = $version" \
  PKG_RPM_CONFLICTS="libcamera < $version, libcamera > $version" \
  scripts/emit-package.sh "$stage" "$PACKAGE_OUT"
done

rm -rf "$STAGE_ROOT/zhiyu-sensord"
mkdir -p "$BUILD_ROOT"
if [[ $DISTRO == fedora ]]; then
    make -C sensors -B TARGET="$PWD/$BUILD_ROOT/sensord" CPPFLAGS='-DSENSH=\"/usr/bin/sensh\"'
else
    make -C sensors -B TARGET="$PWD/$BUILD_ROOT/sensord"
fi
# zhiyu-sensord, not sensord: lm_sensors owns /usr/bin/sensord and
# its unit, and pacman refuses to overwrite another package's files.
install -Dm755 "$BUILD_ROOT/sensord" "$STAGE_ROOT/zhiyu-sensord"/usr/bin/zhiyu-sensord
# The unit in the tree points at /usr/local/bin for hand installs;
# the package owns /usr/bin.
install -Dm644 sensors/zhiyu-sensord.service \
  "$STAGE_ROOT/zhiyu-sensord"/usr/lib/systemd/system/zhiyu-sensord.service
sed -i 's#^ExecStart=.*#ExecStart=/usr/bin/zhiyu-sensord#' \
  "$STAGE_ROOT/zhiyu-sensord"/usr/lib/systemd/system/zhiyu-sensord.service
bash scripts/stage-license-notices.sh "$STAGE_ROOT/zhiyu-sensord" zhiyu-sensord
PKG_NAME=zhiyu-sensord PKG_LICENSE=GPL-2.0-or-later \
PKG_VERSION=1.0.0 \
PKG_DESC="SensorProxy daemon backed by sensh/SNS Client" \
PKG_DEB_DEPENDS="libc6, libglib2.0-0t64" \
PKG_ARCH_DEPENDS="glibc glib2" \
PKG_RPM_REQUIRES=sensh \
scripts/emit-package.sh "$STAGE_ROOT/zhiyu-sensord" "$PACKAGE_OUT"
