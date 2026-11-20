#!/bin/bash
# Package the common, already-verified stage inside the target distribution.
set -euo pipefail
cd "$(dirname "$0")/.."
VER=$(cat out/kernel-release)
for part in modules headers firmware images; do
    test -d "stage/linux-zhiyu-$part"
done
PKG_NAME=linux-zhiyu-modules PKG_LICENSE=GPL-2.0-only \
PKG_VERSION="$VER" \
PKG_DESC="Linux $VER modules for the zhiyu port" \
PKG_DEB_DEPENDS="kmod" \
PKG_ARCH_DEPENDS="kmod" \
PKG_RPM_REQUIRES=kmod \
scripts/emit-package.sh stage/linux-zhiyu-modules "$PACKAGE_OUT"

PKG_NAME=linux-zhiyu-headers PKG_LICENSE='GPL-2.0-only AND (GPL-2.0-only WITH Linux-syscall-note)' \
PKG_VERSION="$VER" \
PKG_DESC="Linux $VER headers for the zhiyu port" \
PKG_DEB_DEPENDS="gcc-14" \
PKG_DEB_PROVIDES="linux-headers" \
PKG_ARCH_DEPENDS="gcc" \
PKG_ARCH_PROVIDES="linux-headers" \
PKG_RPM_REQUIRES='gcc, make' \
scripts/emit-package.sh stage/linux-zhiyu-headers "$PACKAGE_OUT"

PKG_NAME=linux-zhiyu-firmware PKG_LICENSE='BSD-3-Clause AND LicenseRef-LICENSE.qcom AND LicenseRef-LICENSE.qcom-2 AND LicenseRef-Zhiyu-Firmware AND LicenseRef-Zhiyu-Unspecified' \
PKG_VERSION="$VER" \
PKG_DESC="Firmware blobs, AudioReach topology and SNS registry for the zhiyu port" \
PKG_DEB_DEPENDS="" \
PKG_ARCH_DEPENDS="" \
scripts/emit-package.sh stage/linux-zhiyu-firmware "$PACKAGE_OUT"

PKG_NAME=linux-zhiyu-images PKG_LICENSE='GPL-2.0-only AND LGPL-2.1-or-later AND Apache-2.0 AND BSD-3-Clause AND LicenseRef-LICENSE.qcom AND LicenseRef-LICENSE.qcom-2 AND LicenseRef-Zhiyu-Firmware AND LicenseRef-Zhiyu-Unspecified' \
PKG_VERSION="$VER" \
PKG_DESC="AVB-signed boot image set and active-slot updater for zhiyu" \
PKG_DEB_DEPENDS="coreutils, util-linux, grep, sed, mawk | gawk, diffutils, xz-utils, linux-zhiyu-modules (= ${VER}-${PKG_REVISION:-1})" \
PKG_ARCH_DEPENDS="coreutils util-linux grep sed gawk diffutils xz linux-zhiyu-modules=${VER//-/_}-${PKG_REVISION:-1}" \
PKG_DEB_POSTINST=scripts/linux-zhiyu-images.postinst \
PKG_ARCH_INSTALL=scripts/linux-zhiyu-images.install \
PKG_RPM_REQUIRES="coreutils, util-linux, grep, sed, gawk, diffutils, xz, linux-zhiyu-modules = ${VER//-/_}-${PKG_REVISION:-1}" \
PKG_RPM_POST=/usr/libexec/zhiyu/update-boot-images.sh \
scripts/emit-package.sh stage/linux-zhiyu-images "$PACKAGE_OUT"

