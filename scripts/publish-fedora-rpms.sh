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
# Generate a fresh, flat repository from exactly the RPM files to upload.
# Never inherit stale metadata from the artifact directory.
printf '%s\n' "${packages[@]##*/}" > "$work/current-rpms"
mkdir "$work/repository"
createrepo_c --error-exit-val --unique-md-filenames --pkglist "$work/current-rpms" \
    --outputdir "$work/repository" --baseurl "$baseurl$tag/" "$rpms"
notes="$work/release-notes.md"
printf 'Lenovo TB378FC package repository for Fedora. Build commit: %s.\n\nDNF baseurl: %s\n' "$sha" "$baseurl" > "$notes"
metadata=("$work/repository/repodata/"*)
index="$work/repository/repodata/repomd.xml"
test -s "$index"
# Check that the metadata files we are about to upload match repomd.xml.
python3 - "$index" "$work/current-rpms" <<'PY'
import gzip
import xml.etree.ElementTree as ET
import sys
from pathlib import Path

index = Path(sys.argv[1])
ns = {"r": "http://linux.duke.edu/metadata/repo"}
entries = ET.parse(index).getroot().findall("r:data", ns)
refs = set()
primary = None
for entry in entries:
    href = entry.find("r:location", ns).attrib["href"]
    path = Path(href)
    if path.parent != Path("repodata") or not (index.parent / path.name).is_file():
        raise SystemExit(f"Invalid metadata reference: {href}")
    refs.add(path.name)
    if entry.attrib["type"] == "primary":
        primary = index.parent / path.name
if refs != {p.name for p in index.parent.iterdir() if p.name != index.name} or primary is None:
    raise SystemExit("Incomplete generated RPM metadata")
# createrepo_c uses gzip for primary XML by default.
with gzip.open(primary, "rb") as stream:
    packages = ET.parse(stream).getroot().findall("{http://linux.duke.edu/metadata/common}package")
locations = [p.find("{http://linux.duke.edu/metadata/common}location").attrib["href"] for p in packages]
expected = Path(sys.argv[2]).read_text().splitlines()
if sorted(locations) != sorted(expected):
    raise SystemExit(f"RPM index differs from upload set: {locations!r}")
PY
printf '%s\n' "${packages[@]##*/}" "${metadata[@]##*/}" > "$work/current-assets"
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
    # Snapshot every previous asset ID (including releases with >100 assets).
    release_id=$(gh api "repos/$repository/releases/tags/$tag" --jq '.id')
    [[ "$release_id" =~ ^[0-9]+$ ]]
    previous=$(gh api --paginate "repos/$repository/releases/$release_id/assets?per_page=100" \
        --jq '.[] | [.id,.name] | @tsv')
    gh release upload "$tag" "${packages[@]}" --clobber --repo "$repository"
    for file in "${metadata[@]}"; do
        if [[ "${file##*/}" != repomd.xml ]]; then
            gh release upload "$tag" "$file" --clobber --repo "$repository"
        fi
    done
    # Publish the index only after every file it references is available.
    gh release upload "$tag" "$index" --clobber --repo "$repository"
    # The new index is live. Prune only obsolete managed assets; do not
    # touch unrelated attachments (keys, notes, etc.) or current assets.
    while IFS=$'\t' read -r asset_id asset; do
        [[ -n "$asset" ]] || continue
        if [[ "$asset" == *.rpm || "$asset" =~ ^[[:xdigit:]]{64}-(primary|filelists|filelists-ext|other)(\.xml|\.sqlite)(\.(gz|bz2|xz|zst|zck))?$ ]]; then
            if ! grep -Fxq -- "$asset" "$work/current-assets"; then
                [[ "$asset_id" =~ ^[0-9]+$ ]]
                printf 'Pruning obsolete Fedora asset: %s\n' "$asset"
                gh api --method DELETE "repos/$repository/releases/assets/$asset_id"
            fi
        fi
    done <<< "$previous"
    gh release edit "$tag" --title "Zhiyu Fedora package repository" --notes-file "$notes" --repo "$repository"
else
    gh release create "$tag" "${packages[@]}" "${metadata[@]}" --latest=false \
        --repo "$repository" --title "Zhiyu Fedora package repository" --notes-file "$notes"
fi
