#!/usr/bin/env bash
# Build flat APT and Pacman repository snapshots from versioned CI packages.
set -euo pipefail
format=${1:?repository format required}
packages=$(realpath "${2:?package directory required}")
out=$(realpath -m "${3:?output directory required}")
shopt -s nullglob
case "$format" in
    debian) files=("$packages"/*.deb) ;;
    archlinuxarm) files=("$packages"/*.pkg.tar.zst) ;;
    *) echo "Unknown format: $format" >&2; exit 2 ;;
esac
(( ${#files[@]} )) || { echo "No $format packages found" >&2; exit 1; }
mkdir -p "$out"
mkdir "$out/$format"
cd "$out/$format"
cp -- "${files[@]}" .
if [[ $format == debian ]]; then
    dpkg-scanpackages --arch arm64 . > Packages
    gzip -n -c Packages > Packages.gz
    {
        cat <<'EOF'
Origin: linux-zhiyu
Label: linux-zhiyu packages
Suite: stable
Codename: zhiyu
Architectures: arm64
Components: main
Description: Lenovo TB378FC mainline Linux packages
SHA256:
EOF
        for file in Packages Packages.gz; do
            printf ' %s %8s %s\n' \
                "$(sha256sum "$file" | cut -d' ' -f1)" \
                "$(stat -c %s "$file")" "$file"
        done
    } > Release
else
    repo-add zhiyu.db.tar.gz ./*.pkg.tar.zst
    for name in zhiyu.db zhiyu.files; do
        rm -- "$name"
        cp -- "$name.tar.gz" "$name"
    done
fi
