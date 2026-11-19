#!/bin/bash
# Clone the libcamera fork at one release branch into a build directory.
#
#   usage: fetch-libcamera.sh <branch> <directory>
#
# The fork keeps one branch per upstream release (zhiyu-0.7.2, zhiyu-0.8.0,
# ...), so which libcamera a package build uses is just the branch name.
# Nothing is vendored in the superproject any more: the clone is shallow and
# only needs the tree, since meson takes the version from meson.build.
set -euo pipefail
branch=${1:?usage: fetch-libcamera.sh <branch> <dir>}
dir=${2:?usage: fetch-libcamera.sh <branch> <dir>}
url=${LIBCAMERA_URL:-https://github.com/PickaxeHit/libcamera-zhiyu.git}

if [ -d "$dir/.git" ]; then
	exit 0
fi

rm -rf "$dir"
mkdir -p "$(dirname "$dir")"
for attempt in 1 2 3; do
	if git clone --quiet --depth 1 --branch "$branch" "$url" "$dir"; then
		exit 0
	fi
	echo "fetch-libcamera.sh: clone of $branch failed (attempt $attempt)" >&2
	rm -rf "$dir"
	sleep 5
done
echo "fetch-libcamera.sh: cannot clone $url $branch" >&2
exit 1
