#!/bin/bash
set -euo pipefail

url=$1
checksum=$2
destination=$3
[ ! -d "$destination" ] || exit 0

mkdir -p "$(dirname "$destination")"
temporary=$(mktemp -d "${destination}.XXXXXX")
trap 'rm -rf "$temporary"' EXIT

# Happy eyeballs: git.kernel.org publishes an AAAA record, and a build host
# without an IPv6 route would otherwise sit on the connect() until the default
# timeout (135 s per attempt in CI).  Fall back to IPv4 quickly instead.
curl --fail --location --silent --show-error --retry 3 \
	--happy-eyeballs-timeout-ms 200 --connect-timeout 30 \
	--output "$temporary/archive" "$url"
if ! printf '%s  %s\n' "$checksum" "$temporary/archive" | sha256sum --check --status; then
	echo "SHA256 mismatch for $url" >&2
	exit 1
fi
mkdir "$temporary/source"
tar -xf "$temporary/archive" -C "$temporary/source" --strip-components=1
mv -T "$temporary/source" "$destination" || [ -d "$destination" ]
