#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ ${1:-} == --prepared ]]; then
    # Aggregation job downloaded the verified common images/license bundle and
    # merged its manifest; never require the original Kbuild tree here.
    test -s out/manifest.json
    test -s out/LICENSES.tar.gz
    python3 - <<'CHECK'
import hashlib,json
from pathlib import Path
out=Path('out')
manifest=json.loads((out/'manifest.json').read_text())
assert manifest.get('kernel'), 'Missing kernel provenance'
for name, metadata in manifest['artifacts'].items():
    p=out/name
    with p.open('rb') as f:
        assert hashlib.file_digest(f,'sha256').hexdigest()==metadata['sha256'], name
    assert p.stat().st_size==metadata['size'], name
CHECK
else
    source scripts/kernel-env.sh
    [[ -f out/package-build.id && $(cat out/package-build.id) == "$(cat out/images-build.id) ${PKG_REVISION:-1}" && $(cat out/images-build.id) == "$(images_id)" ]] || { echo "Build matching images and stage first" >&2; exit 1; }
    python3 scripts/build-manifest.py
    tar -czf out/LICENSES.tar.gz -C stage/linux-zhiyu-images/usr/share/licenses/linux-zhiyu-images .
fi
(cd out && sha256sum --check image-build.SHA256SUMS)
cd out
images=(boot.img boot-none.img boot-selinux.img boot-apparmor.img vendor_boot.img init_boot.img vbmeta.img vbmeta-none.img vbmeta-selinux.img vbmeta-apparmor.img)
rm -f zhiyu-images.tar.xz zhiyu-images.tar.zst
sha256sum "${images[@]}" LICENSES.tar.gz manifest.json > SHA256SUMS
if [ "${IMAGE_COMPRESSION:-xz}" = xz ]; then
  tar -I 'xz -9e -T1' -cf zhiyu-images.tar.xz "${images[@]}" SHA256SUMS LICENSES.tar.gz manifest.json
elif [ "${IMAGE_COMPRESSION:-xz}" = zstd ]; then
  tar -I 'zstd -T0 -19' -cf zhiyu-images.tar.zst "${images[@]}" SHA256SUMS LICENSES.tar.gz manifest.json
else
  echo "Unsupported IMAGE_COMPRESSION: $IMAGE_COMPRESSION" >&2; exit 2
fi
