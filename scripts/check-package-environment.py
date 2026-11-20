#!/usr/bin/env python3
"""Check actual package inventory; strict mode rejects drift before build."""
import json
import os
import sys
from pathlib import Path

lock = Path('containers/build-lock.json')
strict = os.environ.get('STRICT_LOCK') == 'true'
if lock.exists():
    data = json.loads(lock.read_text()).get('packages', {})
else:
    data = {}
    if not strict: sys.exit(0)
actual = set(Path(sys.argv[1]).read_text().splitlines())
# Combined builds install userspace dependencies; use the userspace inventory
# for both families. Kernel-only installation is a different profile.
profile = 'userspace' if os.environ['BUILD_USERSPACE'] == 'true' else 'kernel'
key = os.environ['DISTRO'] + '/' + profile
expected = data.get(key)
if expected is None:
    message = f'No captured package inventory for {key}'
    if strict:
        sys.exit(message)
    print('Warning: '+message, file=sys.stderr)
elif set(expected) != actual:
    print(f'{key}: package inventory changed', file=sys.stderr)
    for p in sorted(set(expected)-actual): print('- '+p, file=sys.stderr)
    for p in sorted(actual-set(expected)): print('+ '+p, file=sys.stderr)
    if strict:
        sys.exit(1)
