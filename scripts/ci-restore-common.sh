#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
case ${1:-} in stage|images) kind=$1 ;; *) exit 2 ;; esac
(cd out/ci-transfer && sha256sum -c "$kind.tar.zst.sha256")
tar --zstd -xf "out/ci-transfer/$kind.tar.zst"
[[ $(cat out/package-build.id) == "$(cat out/images-build.id) ${PKG_REVISION:?}" ]]
if [[ $kind == stage ]]; then
    python3 scripts/verify-header-tools.py "stage/linux-zhiyu-headers/usr/src/linux-headers-$(cat out/kernel-release)"
else
    (cd out && sha256sum -c image-build.SHA256SUMS)
fi
