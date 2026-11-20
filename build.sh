#!/bin/bash
# Local and CI build entry point. No arguments retains the historical image build.
set -euo pipefail
cd "$(dirname "$0")"
root=$PWD
export JOBS=${JOBS:-$(nproc)}
export PKG_REVISION=${PKG_REVISION:-1}
export IMAGE_COMPRESSION=${IMAGE_COMPRESSION:-xz}

kernel() {
    source scripts/kernel-env.sh
    mkdir -p out "$KBUILD_DIR"
    local input_id
    input_id=$(kernel_id)
    # Discard only this Kbuild object tree when switching input/toolchain.
    if [[ -f "$KBUILD_DIR/.zhiyu-input" && $(cat "$KBUILD_DIR/.zhiyu-input") != "$input_id" ]]; then
        kmake clean
    fi
    printf "%s\n" "$input_id" > "$KBUILD_DIR/.zhiyu-input"
    rm -f out/kernel-build.id out/images-build.id out/package-build.id out/manifest.json
    cp "$CFG" "$KBUILD_DIR/.config"
    kmake olddefconfig
    kmake -j"$JOBS" Image modules
    kmake -s kernelrelease > out/kernel-release
    kernel_id > out/kernel-build.id
}
initramfs() {
    source scripts/kernel-env.sh
    rm -f out/images-build.id out/package-build.id out/manifest.json
    [[ -f out/kernel-build.id && $(cat out/kernel-build.id) == "$(kernel_id)" ]] || { echo 'Build the matching kernel first' >&2; return 1; }
    export VER=$(cat out/kernel-release)
    export MODULES_DIR="$KBUILD_DIR"
    # Rebuild small userspace from clean build trees; never reuse unkeyed binaries.
    export KEYMINT_DEPS="$root/out/build/keymint" KEYMINT_BIN="$root/out/build/keymint/bin"
    scripts/check-rust.sh
    keymint/build-deps.sh
    KEEP_OLD=0 TPLG_OUT="$root/out/sm8750-tplg.bin" OUT="$root/initramfs" initramfs-src/build.sh
}
images() {
    rm -f out/images-build.id
    kernel
    initramfs
    source scripts/image-tools.sh
    for variant in none selinux apparmor; do
        KERNEL="$KBUILD_DIR/arch/arm64/boot/Image" LSM_VARIANT="$variant" OUT="$root/out" ./mkbootimg
    done
    OUT="$root/out" DTB="$root/out/lenovo-zhiyu.dtb" ./mkvendorbootimg
    OUT="$root/out" ./mkinitbootimg
    for variant in none selinux apparmor; do OUT="$root/out" LSM_VARIANT="$variant" ./mkvbmetaimg; done
    scripts/verify-images.sh
    (cd out && sha256sum boot.img boot-none.img boot-selinux.img boot-apparmor.img vendor_boot.img init_boot.img vbmeta.img vbmeta-none.img vbmeta-selinux.img vbmeta-apparmor.img sm8750-tplg.bin > image-build.SHA256SUMS)
    images_id > out/images-build.id
}
usage() {
    cat <<'HELP'
Usage: ./build.sh [target] [--distro debian|arch|fedora|all]
  kernel           Build kernel and modules into out/kernel
  initramfs        Assemble ramdisk from the matching built kernel
  images (default) Build and verify the complete image set
  stage-kernel     Prepare shared kernel packages (after images)
  kernel-packages  Package kernel stage inside selected distro containers
  userspace        Compile and package userspace inside selected containers
  packages         Both kernel and userspace packages in selected containers
  archive          Archive the previously staged kernel packages/images
  manifest         Record source and output checksums
  all              Build images, all distro packages and archive
  check            Validate dependency manifest
CONTAINER_ENGINE=auto|podman|docker; CONTAINER_PULL=missing|always|never
STRICT_LOCK=true requires committed dependency pins and recorded environment
HELP
}
target=${1:-images}
if [[ $# -gt 0 ]]; then shift; fi
distro=all
while [[ $# -gt 0 ]]; do
    case $1 in
        --distro) distro=${2:?missing distro}; shift 2 ;;
        *) usage >&2; exit 2 ;;
    esac
done
case $distro in debian|arch|fedora|all) ;; *) usage >&2; exit 2 ;; esac
case $target in
    -h|--help|help) usage; exit 0 ;;
    check) python3 scripts/deps.py check; exit 0 ;;
    kernel|initramfs|images|stage-kernel|kernel-packages|userspace|packages|archive|manifest|all) ;;
    *) usage >&2; exit 2 ;;
esac
if [[ $distro != all ]]; then
    case $target in kernel-packages|userspace|packages|all) ;; *) echo '--distro only applies to package build targets' >&2; exit 2 ;; esac
fi
packages() {
    export BUILD_KERNEL=$1 BUILD_USERSPACE=$2
    for flag in "$BUILD_KERNEL" "$BUILD_USERSPACE"; do [[ $flag == true || $flag == false ]] || { echo "Build flags must be true or false" >&2; return 2; }; done
    [[ $BUILD_KERNEL == true || $BUILD_USERSPACE == true ]] || { echo "Select at least one package family" >&2; return 2; }
    if [[ $BUILD_KERNEL == true ]]; then
        scripts/stage-kernel.sh
    fi
    local selection=() d
    if [[ $distro == all ]]; then selection=(debian arch fedora); else selection=("$distro"); fi
    for d in "${selection[@]}"; do scripts/run-package-container.sh "$d"; done
}
if [[ ${STRICT_LOCK:-false} == true ]]; then
    python3 scripts/deps.py check --locked
else
    python3 scripts/deps.py check
fi
case $target in
    kernel) kernel ;;
    initramfs) initramfs ;;
    images) images ;;
    stage-kernel) scripts/stage-kernel.sh ;;
    kernel-packages) packages true false ;;
    userspace) packages false true ;;
    packages) packages "${BUILD_KERNEL:-true}" "${BUILD_USERSPACE:-true}" ;;
    archive) scripts/archive-images.sh ;;
    manifest) python3 scripts/build-manifest.py ;;
    all) images; packages true true; scripts/archive-images.sh ;;
esac
