#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Never use --remote: the parent tree's gitlinks are the version authority.
if ! git submodule update --init --recursive --depth 1; then
    git submodule foreach --recursive 'if [ "$(git rev-parse --is-shallow-repository)" = true ]; then git fetch --unshallow origin; fi'
    git submodule update --init --recursive
fi
