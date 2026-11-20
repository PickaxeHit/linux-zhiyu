#!/bin/bash
# Never silently use a different toolchain for a strict local build.
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
    [[ ${STRICT_LOCK:-false} != true ]] || { echo 'No pinned Rust version; capture environment first' >&2; exit 1; }
    exit 0
fi
actual=$(rustc --version | awk '{print $2}')
if [[ $version != "$actual" ]]; then
    echo "Expected Rust $version; got $actual. Run scripts/setup-rust.sh" >&2
    [[ ${STRICT_LOCK:-false} != true ]] || exit 1
fi
