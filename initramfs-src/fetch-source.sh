#!/bin/bash
set -euo pipefail

url=$1
checksum=$2
destination=$3
[ ! -d "$destination" ] || exit 0

mkdir -p "$(dirname "$destination")"
temporary=$(mktemp -d "${destination}.XXXXXX")
trap 'rm -rf "$temporary"' EXIT

curl --fail --location --silent --show-error --retry 3 \
	--output "$temporary/archive" "$url"
if ! printf '%s  %s\n' "$checksum" "$temporary/archive" | sha256sum --check --status; then
	echo "SHA256 mismatch for $url" >&2
	exit 1
fi
mkdir "$temporary/source"
tar -xf "$temporary/archive" -C "$temporary/source" --strip-components=1
mv -T "$temporary/source" "$destination" || [ -d "$destination" ]
