#!/usr/bin/env bash
# All KeyMint executables are static; no runtime library/loader is bundled.
set -euo pipefail
base=$(cd -- "$(dirname -- "$0")" && pwd)
stage=${1:?usage: stage-initramfs.sh STAGE}
mkdir -p "$stage/bin"
for pair in unlock_metadata:keymint-recover time_listener:keymint-time rpmb_readonly:keymint-rpmb userdata-map:userdata-map; do
 src=$base/bin/${pair%%:*}
 readelf -h "$src" | grep -q AArch64
 if readelf -l "$src" | grep -q INTERP || readelf -d "$src" | grep -q NEEDED; then
  echo "Not fully static: $src" >&2; exit 1
 fi
 install -m755 "$src" "$stage/bin/${pair#*:}"
done
