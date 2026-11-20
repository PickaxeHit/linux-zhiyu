#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
[[ $(cat out/package-build.id) == "$(cat out/images-build.id) ${PKG_REVISION:-1}" ]]
(cd out && sha256sum -c image-build.SHA256SUMS)
mkdir -p out/ci-transfer
tar -czf out/LICENSES.tar.gz -C stage/linux-zhiyu-images/usr/share/licenses/linux-zhiyu-images .
# Stage and images are separate so aggregation never downloads modules/headers.
shared=(out/kernel-release out/package-build.id out/images-build.id)
tar -I 'zstd -T0 -3' -cf out/ci-transfer/stage.tar.zst "${shared[@]}" stage/linux-zhiyu-{modules,headers,firmware,images}
tar -I 'zstd -T0 -3' -cf out/ci-transfer/images.tar.zst "${shared[@]}" out/*.img out/image-build.SHA256SUMS out/sm8750-tplg.bin out/LICENSES.tar.gz
(cd out/ci-transfer && sha256sum stage.tar.zst > stage.tar.zst.sha256 && sha256sum images.tar.zst > images.tar.zst.sha256)
