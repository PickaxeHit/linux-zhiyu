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

upstream_packages=(hexagonrpc)
# Manually selected build artifacts may predate the sensh package.
if git cat-file -e "$sha:scripts/sensh-revision" 2>/dev/null; then
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
createrepo_c --baseurl "$baseurl" "$rpms"

git worktree add --detach "$work/tree" "$GITHUB_SHA"
git -C "$work/tree" config user.name github-actions[bot]
git -C "$work/tree" config user.email '41898282+github-actions[bot]@users.noreply.github.com'
if git ls-remote --exit-code --heads origin "$branch" >/dev/null; then
    git fetch origin "+refs/heads/$branch:refs/remotes/origin/$branch"
    git -C "$work/tree" switch --detach "refs/remotes/origin/$branch"
else
    git -C "$work/tree" switch --orphan "$branch"
fi
git -C "$work/tree" rm -r --ignore-unmatch fedora/repodata
install -d "$work/tree/fedora/repodata"
cp -a "$rpms/repodata/." "$work/tree/fedora/repodata/"
git -C "$work/tree" add fedora/repodata
if ! git -C "$work/tree" diff --cached --quiet; then
    git -C "$work/tree" commit -m "Update Fedora repository for ${sha:0:12}"
fi

notes="$work/release-notes.md"
if gh release view "$tag" --json body,assets > "$work/release.json"; then
    existing=1
    jq -r '.assets[].name' "$work/release.json" > "$work/previous-assets"
    jq -r '.body
        | split("\n")
        | map(select(. != "## Upstream sources · 上游源码"
            and (test("^- `(hexagonrpc|sensh)-[^`]+\\.rpm`: \\[upstream source\\]") | not)
            and (test("^- \\*\\*(hexagonrpc|sensh)\\*\\* · \\[上游源码\\]") | not)))
        | join("\n")
        | sub("\\n+$"; "")' "$work/release.json" > "$notes"
else
    existing=0
    printf 'DNF baseurl: https://raw.githubusercontent.com/%s/%s/fedora/\n' \
        "$GITHUB_REPOSITORY" "$branch" > "$notes"
fi
printf '\n## Upstream sources · 上游源码\n\n' >> "$notes"
for name in "${upstream_packages[@]}"; do
    revision=$(git show "$sha:scripts/$name-revision")
    case "$name" in
        hexagonrpc) source_url="https://github.com/linux-msm/hexagonrpc/archive/$revision.tar.gz" ;;
        sensh) source_url="https://gitlab.com/flamingradian/sensh/-/archive/$revision/sensh-$revision.tar.gz" ;;
    esac
    printf -- '- **%s** · [上游源码](%s) · [打包脚本](https://github.com/%s/tree/%s/scripts)\n' \
        "$name" "$source_url" "$GITHUB_REPOSITORY" "$sha" >> "$notes"
done
if [[ "$existing" == 1 ]]; then
    gh release upload "$tag" "${packages[@]}" --clobber
else
    gh release create "$tag" "${packages[@]}" --target "$sha" --latest=false \
        --title "Zhiyu Fedora RPM repository" --notes-file "$notes"
fi
git -C "$work/tree" push origin "HEAD:refs/heads/$branch"
if [[ "$existing" == 1 ]]; then
    printf '%s\n' "${packages[@]##*/}" > "$work/current-assets"
    while IFS= read -r asset; do
        if [[ "$asset" == *.rpm ]] && ! grep -Fxq -- "$asset" "$work/current-assets"; then
            gh release delete-asset "$tag" "$asset" --yes
        fi
    done < "$work/previous-assets"
    gh release edit "$tag" --notes-file "$notes"
fi
