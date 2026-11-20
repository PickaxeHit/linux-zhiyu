#!/bin/bash
# Pull a public OCI image and build only one distro's packages. No Dockerfile,
# Distrobox integration, privileged mode, daemon socket or host HOME mount.
set -euo pipefail
cd "$(dirname "$0")/.."
root=$PWD
DISTRO=${1:?usage: run-package-container.sh DISTRO}
export DISTRO
export BUILD_KERNEL=${BUILD_KERNEL:-true} BUILD_USERSPACE=${BUILD_USERSPACE:-true}
export PKG_REVISION=${PKG_REVISION:-1} JOBS=${JOBS:-$(nproc)}
case $DISTRO in
    debian) override=${DEBIAN_IMAGE:-}; pattern='*.deb'; dest=out/pkgs ;;
    arch) override=${ARCH_IMAGE:-}; pattern='*.pkg.tar.zst'; dest=out/pkgs ;;
    fedora) override=${FEDORA_IMAGE:-}; pattern='*.rpm'; dest=out/rpms/aarch64 ;;
    *) echo "Unknown distro: $DISTRO" >&2; exit 2 ;;
esac
for flag in "$BUILD_KERNEL" "$BUILD_USERSPACE"; do [[ $flag == true || $flag == false ]] || exit 2; done
[[ $BUILD_KERNEL == true || $BUILD_USERSPACE == true ]] || exit 2
if [[ $BUILD_KERNEL == true ]]; then
    [[ -f out/package-build.id && -f out/images-build.id && $(cat out/package-build.id) == "$(cat out/images-build.id) $PKG_REVISION" ]] || { echo 'Prepare matching kernel stage first' >&2; exit 1; }
fi
image=$(python3 - "$DISTRO" "$override" <<'PYIMAGE'
import json,os,re,sys
from pathlib import Path
distro,override=sys.argv[1:]
p=Path('containers/build-lock.json')
locked=json.loads(p.read_text()).get('images',{}).get(distro) if p.exists() else None
if os.environ.get('STRICT_LOCK')=='true' and (override or not locked or not re.fullmatch(r'.+@sha256:[0-9a-f]{64}',locked)):
    sys.exit('STRICT_LOCK requires a recorded image digest and no image override')
print(override or locked or json.loads(Path('containers/images.json').read_text())[distro])
PYIMAGE
)
engine=${CONTAINER_ENGINE:-auto}
if [[ $engine == auto ]]; then
    if command -v podman >/dev/null && podman info >/dev/null 2>&1; then engine=podman
    elif command -v docker >/dev/null && docker info >/dev/null 2>&1; then engine=docker
    else echo 'Install/configure Podman or Docker first' >&2; exit 1; fi
fi
case $engine in
    podman) mapped=$($engine info --format '{{.Host.Security.Rootless}}') ;;
    docker) mapped=false; if $engine info --format '{{json .SecurityOptions}}' | grep -q rootless; then mapped=true; fi ;;
    *) echo 'CONTAINER_ENGINE must be auto, podman or docker' >&2; exit 2 ;;
esac
[[ $mapped == true || $mapped == false ]] || { echo 'Cannot determine container user mapping' >&2; exit 1; }
# Use the locally cached ARM64 image by default; CI starts with an empty cache.
case ${CONTAINER_PULL:-missing} in
    always) "$engine" pull --platform linux/arm64 "$image" ;;
    missing) if ! "$engine" image inspect "$image" >/dev/null 2>&1; then "$engine" pull --platform linux/arm64 "$image"; fi ;;
    never) ;;
    *) echo 'CONTAINER_PULL must be missing, always or never' >&2; exit 2 ;;
esac
metadata="out/build/packages/$DISTRO/image.json"
mkdir -p "$(dirname "$metadata")" "$dest"
"$engine" image inspect "$image" > "$metadata"
# Refuse a cached image for the wrong platform rather than silently build x86.
id=$(python3 - "$metadata" <<'PY'
import json,sys
x=json.load(open(sys.argv[1]))[0]
if x.get('Architecture') != 'arm64' or x.get('Os', x.get('OS')) != 'linux':
    sys.exit('Image must be linux/arm64; use CONTAINER_PULL=always to refresh')
print(x['Id'])
PY
)
# Fedora hosts may need CONTAINER_VOLUME_SUFFIX=z to label the checkout for SELinux.
volume="$root:/work${CONTAINER_VOLUME_SUFFIX:+:$CONTAINER_VOLUME_SUFFIX}"
rm -f out/manifest.json
"$engine" run --rm --pull=never --platform linux/arm64 --user 0:0 \
    -e DISTRO -e BUILD_KERNEL -e BUILD_USERSPACE -e PKG_REVISION -e JOBS -e STRICT_LOCK \
    -e HOST_UID="$(id -u)" -e HOST_GID="$(id -g)" -e HOST_MAPPED_ROOT="$mapped" \
    -e GIT_CONFIG_COUNT=1 -e GIT_CONFIG_KEY_0=safe.directory -e 'GIT_CONFIG_VALUE_0=*' \
    --volume "$volume" --workdir /work --entrypoint /bin/bash "$id" scripts/container-entry.sh
result="out/build/packages/$DISTRO/result"
# Publish just the selected package families on success. Preserve other formats
# and the unselected family for local incremental builds.
shopt -s nullglob
packages=("$result"/$pattern)
[[ ${#packages[@]} -gt 0 && -f "$result/installed-packages.txt" ]] || { echo 'No packages or provenance emitted' >&2; exit 1; }
for part in modules headers firmware images; do
    if [[ $BUILD_KERNEL == true ]]; then
        files=("$result"/linux-zhiyu-"$part"*$pattern)
        [[ ${#files[@]} -eq 1 ]] || { echo "Missing or duplicate $part" >&2; exit 1; }
    fi
done
if [[ $BUILD_USERSPACE == true ]]; then
    cam=("$result"/libcamera-zhiyu*$pattern); sensor=("$result"/zhiyu-sensord*$pattern)
    expected=2; [[ $DISTRO != arch ]] || expected=1
    [[ ${#cam[@]} -eq $expected && ${#sensor[@]} -eq 1 ]] || { echo 'Missing camera or sensor package' >&2; exit 1; }
    if [[ $DISTRO == fedora ]]; then
        for name in sensh hexagonrpc; do files=("$result"/"$name"-*$pattern); [[ ${#files[@]} -eq 1 ]] || exit 1; done
    fi
fi
if [[ $BUILD_KERNEL == true ]]; then
    rm -f "$dest"/linux-zhiyu-{modules,headers,firmware,images}*$pattern
fi
if [[ $BUILD_USERSPACE == true ]]; then
    rm -f "$dest"/libcamera-zhiyu*$pattern "$dest"/zhiyu-sensord*$pattern
    if [[ $DISTRO == fedora ]]; then rm -f "$dest"/sensh-*$pattern "$dest"/hexagonrpc-*$pattern; fi
fi
mv "${packages[@]}" "$dest/"
# Each family gets independent provenance, even when rebuilt separately.
python3 - "$metadata" "$result/installed-packages.txt" "$image" "$engine" <<'PY'
import hashlib,json,os,sys
from pathlib import Path
x=json.load(open(sys.argv[1]))[0]
p=Path('out/package-environments')/os.environ['DISTRO']; p.mkdir(parents=True,exist_ok=True)
value={'image':sys.argv[3], 'image_id':x['Id'], 'repo_digests':x.get('RepoDigests') or [],
       'engine':sys.argv[4], 'package_revision':os.environ['PKG_REVISION'],
       'deps_sha256':hashlib.sha256(Path('deps/deps.json').read_bytes()).hexdigest(),
       'install_profile':'userspace' if os.environ['BUILD_USERSPACE']=='true' else 'kernel',
       'installed_packages':Path(sys.argv[2]).read_text().splitlines()}
for family, flag in [('kernel','BUILD_KERNEL'),('userspace','BUILD_USERSPACE')]:
    if os.environ[flag]=='true':
        record=dict(value)
        if family=='kernel':
            record['stage_id']=Path('out/package-build.id').read_text().strip()
            record['header_smoke_test']='passed' # container exits on smoke-test failure
        (p/(family+'.json')).write_text(json.dumps(record,indent=2)+'\n')
PY
