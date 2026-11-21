#!/bin/bash
set -euo pipefail
if [[ ${1:-} == --bundle ]]; then
  images=${2:?Usage: verify-images.sh --bundle DIR KCONFIG}
  config=${3:?Pass the kernel Kconfig}
  : "${UNPACK:?Set UNPACK}" "${AVBTOOL:?Set AVBTOOL}" "${KEY:?Set KEY}"
  unpack_dir=$(mktemp -d)
  trap 'rm -rf "$unpack_dir"' EXIT
  grep -qx 'CONFIG_BOOT_CONFIG=y' "$config"
  declare -A sizes=(
    [boot]=100663296 [vendor_boot]=100663296 [init_boot]=8388608 [vbmeta]=65536
  )
  for partition in boot vendor_boot init_boot vbmeta; do
    image="$images/$partition.img"
    test "$(stat -Lc %s "$image")" = "${sizes[$partition]}"
    "$AVBTOOL" verify_image --image "$image" --key "$KEY"
    info="$unpack_dir/$partition.avb"
    "$AVBTOOL" info_image --image "$image" > "$info"
    grep -Eq '^Minimum libavb version: +1\.0$' "$info"
    grep -Eq '^Algorithm: +SHA256_RSA4096$' "$info"
    if [[ "$partition" == vbmeta ]]; then
      grep -Eq '^Flags: +3$' "$info"
      continue
    fi
    grep -Eq '^Flags: +0$' "$info"
    grep -Eq "^ +Partition Name: +$partition$" "$info"
    grep -qF "Prop: com.android.build.$partition.os_version -> '${AVB_BOOT_OS_VERSION:-15}'" "$info"
    grep -qF "Prop: com.android.build.$partition.security_patch -> '${AVB_BOOT_PATCH:-2025-06-05}'" "$info"
    "$UNPACK" --boot_img "$image" --out "$unpack_dir/$partition" > "$unpack_dir/$partition.header"
    grep -Eqi 'header version: *4$' "$unpack_dir/$partition.header"
  done
  descriptors=$(sed -n 's/^ *Partition Name: *//p' "$unpack_dir/vbmeta.avb" | LC_ALL=C sort)
  test "$descriptors" = $'boot\ninit_boot\nvendor_boot'
  if grep -qF 'androidboot.slot_suffix=' "$unpack_dir/boot.header"; then
    echo 'Hardcoded Android slot' >&2
    exit 1
  fi
  grep -qE 'command line args: .* bootconfig( |$)' "$unpack_dir/boot.header"
  exit
fi
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
