#!/usr/bin/env bash
# Use the Release tag as the repodata directory in DNF download URLs.
set -euo pipefail
rpms=$(realpath "${1:?RPM artifact directory required}")
sha=${2:?source commit required}
tag=repodata
repository=${PACKAGE_REPOSITORY:?Pass the package release repository}
baseurl="https://github.com/$repository/releases/download/"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

upstream_packages=(hexagonrpc)
# Manually selected build artifacts may predate the sensh package.
if compgen -G "$rpms/sensh-*.aarch64.rpm" >/dev/null; then
    upstream_packages+=(sensh)
fi
names=(linux-zhiyu-modules linux-zhiyu-headers linux-zhiyu-firmware linux-zhiyu-images
       libcamera-zhiyu zhiyu-sensord "${upstream_packages[@]}")
packages=("$rpms"/*.rpm)
# libcamera-zhiyu is published in more than one ABI version, everything else
# in exactly one.
test "${#packages[@]}" -ge "${#names[@]}"
for name in "${names[@]}"; do
    candidates=("$rpms/$name"-[0-9]*.aarch64.rpm)
    if [ "$name" = libcamera-zhiyu ]; then
        test "${#candidates[@]}" -ge 1
        for candidate in "${candidates[@]}"; do test -f "$candidate"; done
    else
        test "${#candidates[@]}" -eq 1
        test -f "${candidates[0]}"
    fi
done
createrepo_c --baseurl "$baseurl$tag/" "$rpms"
notes="$work/release-notes.md"
printf 'Lenovo TB378FC package repository for Fedora. Build commit: %s.\n\nDNF baseurl: %s\n' "$sha" "$baseurl" > "$notes"
metadata=("$rpms/repodata/"*)
printf '\n## Upstream sources · 上游源码\n\nBuild commit: %s\n\n' "$sha" >> "$notes"
# The build commit records the source revisions in deps/deps.json.
deps_json="$work/deps.json"
git cat-file -e "$sha:deps/deps.json" 2>/dev/null || {
    echo "build commit $sha has no deps/deps.json" >&2
    exit 1
}
git show "$sha:deps/deps.json" > "$deps_json"
for name in "${upstream_packages[@]}"; do
    revision=$(python3 - "$deps_json" "$name" <<'PY'
import json, sys
entry = json.load(open(sys.argv[1], encoding="utf-8"))[sys.argv[2]]
print(entry.get("rev") or entry["tag"])
PY
)
    source_url=$(python3 - "$deps_json" "$name" "$revision" <<'PY'
import json, sys
entry = json.load(open(sys.argv[1], encoding="utf-8"))[sys.argv[2]]
url = entry["url"].removesuffix(".git").rstrip("/")
separator = "/-/tree/" if "gitlab." in url else "/tree/"
print(f"{url}{separator}{sys.argv[3]}")
PY
)
    printf -- '- **%s** · [上游源码](%s) · [打包脚本](https://github.com/%s/tree/%s/scripts)\n' \
        "$name" "$source_url" "$GITHUB_REPOSITORY" "$sha" >> "$notes"
done
if gh release view "$tag" --repo "$repository" >/dev/null 2>&1; then
    gh release upload "$tag" "${packages[@]}" --clobber --repo "$repository"
    for file in "${metadata[@]}"; do
        if [[ "${file##*/}" != repomd.xml ]]; then
            gh release upload "$tag" "$file" --clobber --repo "$repository"
        fi
    done
    gh release upload "$tag" "$rpms/repodata/repomd.xml" --clobber --repo "$repository"
    gh release edit "$tag" --title "Zhiyu Fedora package repository" --notes-file "$notes" --repo "$repository"
else
    gh release create "$tag" "${packages[@]}" "${metadata[@]}" --latest=false \
        --repo "$repository" --title "Zhiyu Fedora package repository" --notes-file "$notes"
fi
