#!/bin/bash
# Use the recorded toolchain when available. A first build can bootstrap stable.
set -euo pipefail
cd "$(dirname "$0")/.."
version=$(python3 - <<'PY'
import json
from pathlib import Path
p=Path('containers/build-lock.json')
print(json.loads(p.read_text()).get('rust','') if p.exists() else '')
PY
)
if [[ -z $version ]]; then
    [[ ${STRICT_LOCK:-false} != true ]] || { echo 'Missing Rust version in containers/build-lock.json' >&2; exit 1; }
    version=stable
fi
rustup toolchain install "$version" --profile minimal
rustup override set "$version"
rustc --version
