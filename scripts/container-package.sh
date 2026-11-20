#!/bin/bash
set -euo pipefail
cd /work
export PACKAGE_OUT="out/build/packages/$DISTRO/result"
rm -rf "$PACKAGE_OUT"
mkdir -p "$PACKAGE_OUT"
# Record actual installed build environment (after distro package installation).
case $DISTRO in
    debian) dpkg-query -W -f='${Package}\t${Version}\n' ;;
    arch) pacman -Q ;;
    fedora) rpm -qa --qf '%{NAME}\t%{VERSION}-%{RELEASE}.%{ARCH}\n' ;;
esac | LC_ALL=C sort > "$PACKAGE_OUT/installed-packages.txt"
# Compare the actual installed environment before compilation. A lock detects
# repository drift; it is not an offline package mirror or version resolver.
python3 scripts/check-package-environment.py "$PACKAGE_OUT/installed-packages.txt"
if [[ $BUILD_KERNEL == true ]]; then
    scripts/smoke-test-headers.sh
    scripts/package-staged-kernel.sh
fi
if [[ $BUILD_USERSPACE == true ]]; then scripts/package-userspace.sh; fi
if [[ $DISTRO == fedora ]]; then
    mv "$PACKAGE_OUT"/aarch64/*.rpm "$PACKAGE_OUT/"
    rmdir "$PACKAGE_OUT/aarch64"
fi
