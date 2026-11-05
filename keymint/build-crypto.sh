#!/usr/bin/env bash
# Fetch official ARM64 distribution packages; never import device/host libraries.
set -euo pipefail
base=$(cd -- "$(dirname -- "$0")" && pwd)
deps=${KEYMINT_DEPS:-$base/.deps}
mkdir -p "$deps/downloads"
deps=$(cd "$deps" && pwd)
stage=$(mktemp -d "$deps/crypto.XXXXXX")
trap 'rm -rf "$stage"' EXIT
while read -r package version digest archive; do
 [[ -n $package && $package != \#* ]] || continue
 file=$deps/downloads/${archive##*/}
 if ! printf '%s  %s\n' "$digest" "$file" | sha256sum --check --status 2>/dev/null; then
  rm -f "$file"
  curl --fail --location --silent --show-error --retry 3 \
   "https://ports.ubuntu.com/ubuntu-ports/$archive" -o "$file.part"
  printf '%s  %s\n' "$digest" "$file.part" | sha256sum --check --status
  mv "$file.part" "$file"
 fi
 [ "$(dpkg-deb -f "$file" Architecture)" = arm64 ]
 [ "$(dpkg-deb -f "$file" Package)" = "$package" ]
 [ "$(dpkg-deb -f "$file" Version)" = "$version" ]
 dpkg-deb -x "$file" "$stage"
 echo "static dependency: $package $version (official Ubuntu ARM64, SHA256 verified)"
done < "$base/static-packages.tsv"
cp "$base/static-packages.tsv" "$stage/.verified"
rm -rf "$deps/crypto"
mv "$stage" "$deps/crypto"
