#!/bin/bash
# The packaging format is selected once by the container backend.
set -euo pipefail
cd "$(dirname "$0")/.."
case ${DISTRO:?DISTRO required} in
    debian) PKG_FORMATS=deb exec scripts/mkpkgs.sh "$@" ;;
    arch) PKG_FORMATS=arch exec scripts/mkpkgs.sh "$@" ;;
    fedora) exec scripts/mkrpm.sh "$@" ;;
    *) exit 2 ;;
esac
