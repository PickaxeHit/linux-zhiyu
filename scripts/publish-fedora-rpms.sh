#!/usr/bin/env bash
# Publish RPM payloads in a Release and the directory-shaped DNF index in Git.
set -euo pipefail
rpms=$(realpath "${1:?RPM artifact directory required}")
sha=${2:?source commit required}
tag=repo-rpm
branch=rpm-repodata
baseurl="https://github.com/$GITHUB_REPOSITORY/releases/download/$tag/"
work=$(mktemp -d)
trap 'git worktree remove --force "$work/tree" 2>/dev/null || true; rm -rf "$work"' EXIT

packages=("$rpms"/*.rpm)
test "${#packages[@]}" -eq 7
for name in linux-zhiyu-modules linux-zhiyu-headers linux-zhiyu-firmware linux-zhiyu-images libcamera-zhiyu zhiyu-sensord hexagonrpc; do
    candidates=("$rpms/$name"-[0-9]*.aarch64.rpm)
    test "${#candidates[@]}" -eq 1
    test -f "${candidates[0]}"
done
createrepo_c --baseurl "$baseurl" "$rpms"

git worktree add --detach "$work/tree" "$GITHUB_SHA"
git -C "$work/tree" config user.name github-actions[bot]
git -C "$work/tree" config user.email '41898282+github-actions[bot]@users.noreply.github.com'
if git ls-remote --exit-code --heads origin "$branch" >/dev/null; then
    git fetch origin "refs/heads/$branch"
    git -C "$work/tree" switch --detach FETCH_HEAD
else
    git -C "$work/tree" switch --orphan "$branch"
fi
install -d "$work/tree/fedora/repodata"
# Retain metadata files from the previous snapshot for clients with a cached
# repomd.xml. Remove the older snapshot on the next publication.
if [[ -f "$work/tree/fedora/repodata/repomd.xml" ]]; then
    python3 - "$work/tree/fedora/repodata" <<'PY'
from pathlib import Path
import sys
from xml.etree import ElementTree as XML
root = Path(sys.argv[1])
keep = {Path(node.attrib["href"]).name for node in XML.parse(root / "repomd.xml").findall(".//{*}location")}
for entry in root.iterdir():
    if entry.is_file() and entry.name not in keep:
        entry.unlink()
PY
fi
cp -a "$rpms/repodata/." "$work/tree/fedora/repodata/"
git -C "$work/tree" add fedora/repodata
if ! git -C "$work/tree" diff --cached --quiet; then
    git -C "$work/tree" commit -m "Update Fedora repository for ${sha:0:12}"
fi

revision=$(git show "$sha:scripts/hexagonrpc-revision")
hexagonrpc_packages=("$rpms"/hexagonrpc-[0-9]*.aarch64.rpm)
hexagonrpc_asset=${hexagonrpc_packages[0]##*/}
notes="$work/release-notes.md"
if gh release view "$tag" --json body --jq .body > "$notes"; then
    existing=1
else
    existing=0
    printf 'DNF baseurl: https://raw.githubusercontent.com/%s/%s/fedora/\n' \
        "$GITHUB_REPOSITORY" "$branch" > "$notes"
fi
if ! grep -Fq -- "$hexagonrpc_asset" "$notes"; then
    printf '\n- `%s`: [upstream source](https://github.com/linux-msm/hexagonrpc/archive/%s.tar.gz) and [packaging scripts](https://github.com/%s/tree/%s/scripts).\n' \
        "$hexagonrpc_asset" "$revision" "$GITHUB_REPOSITORY" "$sha" >> "$notes"
fi
if [[ "$existing" == 1 ]]; then
    gh release edit "$tag" --notes-file "$notes"
    gh release upload "$tag" "${packages[@]}" --clobber
else
    gh release create "$tag" "${packages[@]}" --target "$sha" --latest=false \
        --title "Zhiyu Fedora RPM repository" --notes-file "$notes"
fi
git -C "$work/tree" push origin "HEAD:refs/heads/$branch"
