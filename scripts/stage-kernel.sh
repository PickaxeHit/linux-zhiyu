#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/kernel-env.sh
rm -f out/package-build.id out/manifest.json
[[ -f out/kernel-build.id && "$(cat out/kernel-build.id)" == "$(kernel_id)" ]] || { echo 'Run ./build.sh images first (kernel inputs changed)' >&2; exit 1; }
[[ -f out/images-build.id && "$(cat out/images-build.id)" == "$(images_id)" ]] || { echo 'Run ./build.sh images first (image inputs changed)' >&2; exit 1; }
(cd out && sha256sum --check image-build.SHA256SUMS)
VER=$(kmake -s kernelrelease)
for part in modules headers firmware images; do rm -rf "stage/linux-zhiyu-$part"; done
# ---- modules ----
kmake \
  INSTALL_MOD_PATH="$PWD/stage/linux-zhiyu-modules" modules_install
# modules_install writes lib/modules; on Arch /lib is a symlink to
# usr/lib owned by the filesystem package, so packaging lib/... both
# conflicts with it and would claim the symlink itself.
mkdir -p "stage/linux-zhiyu-modules/usr"
if [ -d "stage/linux-zhiyu-modules/lib" ]; then
  mv "stage/linux-zhiyu-modules/lib" "stage/linux-zhiyu-modules/usr/lib"
fi
# build/source point into the CI tree; useless (and dangling) in a
# package.
rm -f "stage/linux-zhiyu-modules/usr/lib/modules/$VER/build" \
      "stage/linux-zhiyu-modules/usr/lib/modules/$VER/source"
depmod -b "stage/linux-zhiyu-modules/usr" "$VER"
bash scripts/stage-license-notices.sh stage/linux-zhiyu-modules linux-zhiyu-modules

# ---- headers ----
# A prepared build tree, which is what out-of-tree module builds
# need (UAPI only would be useless for that).
# The upstream install-extmod-build helper supports cross-compiling Kbuild
# programs (CC != HOSTCC). It does not cover objtool/resolve_btfids/plugins.
# Refuse unsupported configurations rather than deliver native x86 tools.
if [[ $(uname -m) != aarch64 ]]; then
    [[ $("${CROSS_COMPILE}gcc" -dumpmachine) == aarch64* ]] || { echo "ARM64 cross compiler required" >&2; exit 1; }
    if grep -Eq '^CONFIG_(OBJTOOL|DEBUG_INFO_BTF_MODULES|GCC_PLUGINS|RUST)=y$' "$KBUILD_DIR/.config"; then
        echo 'This config needs extra target-native header tools; stage on ARM64' >&2; exit 1
    fi
fi
kmake prepare modules_prepare
# Use Kbuild's own external-module header installation logic, including
# generated headers and build tools from the object tree.
H="$PWD/stage/linux-zhiyu-headers/usr/src/linux-headers-$VER"
install -d "$H"
( cd "$KBUILD_DIR" && srctree="$KS" SRCARCH=arm64 ARCH=arm64 \
    CC="${CROSS_COMPILE}gcc" HOSTCC=gcc MAKE=make \
    "$KS/scripts/package/install-extmod-build" "$H" )
install -m644 "$KBUILD_DIR/.config" "$H/.config"
python3 scripts/verify-header-tools.py "$H"
install -d "stage/linux-zhiyu-headers/usr/lib/modules/$VER"
ln -sfn "../../../src/linux-headers-$VER" \
  "stage/linux-zhiyu-headers/usr/lib/modules/$VER/build"
du -sh "$H"
# provides linux-headers: AUR/out-of-tree module builds depend on
# that name, and without it pacman would pull Arch's official
# linux-headers (for the wrong kernel) instead of this tree.
bash scripts/stage-license-notices.sh stage/linux-zhiyu-headers linux-zhiyu-headers

# ---- firmware ----
FW=$(python3 scripts/deps.py path firmware)
F=stage/linux-zhiyu-firmware/usr/lib/firmware
install -d "$F"
cp -a "$FW/firmware/." "$F"/
install -Dm644 out/sm8750-tplg.bin \
  "$F/qcom/sm8750/sm8750-tplg.bin"
# The SNS config/registry hexagonrpcd serves to the ADSP belongs with
# the firmware: the rootfs then gets it from this package instead of
# copying the firmware repository's sensors tree itself.
Q=stage/linux-zhiyu-firmware/usr/share/qcom
install -d "$Q"
cp -a "$FW/sensors" "$Q"/
U=stage/linux-zhiyu-firmware/usr/share/alsa/ucm2
install -d "$U"
cp -a scripts/alsa-ucm2/. "$U"/
R=stage/linux-zhiyu-firmware/usr/lib/udev/rules.d
V=stage/linux-zhiyu-firmware/etc/udev/rules.d
install -d "$R"
install -m644 scripts/90-dma-heap.rules scripts/91-flash-led.rules \
  scripts/90-fastrpc.rules "$R"/
install -Dm644 scripts/60-persistent-v4l.rules "$V/60-persistent-v4l.rules"
find "$F" -type f | wc -l
find "$Q" -type f | wc -l
find "$U" "$R" -type f | sort
bash scripts/stage-license-notices.sh stage/linux-zhiyu-firmware linux-zhiyu-firmware

# The package maintainer hook selects the LSM-matched AVB chain and
# updates only the slot that actually booted. CONFIG_BOOT_CONFIG plus
# the kernel's bootconfig command-line switch are required so ABL's
# androidboot.slot_suffix is available without guessing.
I=stage/linux-zhiyu-images/usr/lib/linux-zhiyu/images
install -d "$I"
install -m644 out/boot-none.img out/boot-selinux.img \
  out/boot-apparmor.img out/vendor_boot.img out/init_boot.img \
  out/vbmeta-none.img out/vbmeta-selinux.img out/vbmeta-apparmor.img "$I"/
(
  cd "$I"
  sha256sum -- *.img > SHA256SUMS
  stat -c "%s %n" -- *.img > SIZES
  xz -9e -T1 -- *.img
)
install -Dm755 scripts/update-boot-images.sh \
  stage/linux-zhiyu-images/usr/libexec/zhiyu/update-boot-images.sh
bash scripts/stage-license-notices.sh stage/linux-zhiyu-images linux-zhiyu-images

printf "%s %s\n" "$(cat out/images-build.id)" "${PKG_REVISION:-1}" > out/package-build.id
