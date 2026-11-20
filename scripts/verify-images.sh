#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/kernel-env.sh
source scripts/image-tools.sh
# All LSM variants must be usable from either slot.
unpack_dir=$(mktemp -d)
trap 'rm -rf "$unpack_dir"' EXIT
for image in out/boot.img out/boot-{none,selinux,apparmor}.img; do
  "$UNPACK" \
    --boot_img "$image" --out "$unpack_dir" > "$unpack_dir/header"
  if grep -qF 'androidboot.slot_suffix=' "$unpack_dir/header"; then
    echo "Hardcoded slot in $image" >&2
    exit 1
  fi
done
grep -qx 'CONFIG_BOOT_CONFIG=y' "$KBUILD_DIR/.config"
mkdir -p "$unpack_dir/bootconfig"
"$UNPACK" \
  --boot_img out/boot-apparmor.img --out "$unpack_dir/bootconfig" \
  > "$unpack_dir/bootconfig-header"
grep -q '^command line args: .* bootconfig ' "$unpack_dir/bootconfig-header" || {
  echo "boot image does not ask ABL to load the bootconfig" >&2
  exit 1
}
cmp out/boot.img out/boot-none.img
cmp out/vbmeta.img out/vbmeta-none.img
ls -l out/boot*.img out/vendor_boot.img out/init_boot.img out/vbmeta*.img
sha256sum out/boot*.img out/vendor_boot.img out/init_boot.img out/vbmeta*.img
