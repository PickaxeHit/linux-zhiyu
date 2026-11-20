#!/usr/bin/env python3
"""Hash actual image inputs, including new/untracked source files, not build output."""
import hashlib
from pathlib import Path

root = Path(__file__).resolve().parent.parent
paths = ['deps/deps.json', 'containers/build-lock.json', 'scripts/check-rust.sh', 'initramfs-src', 'keymint', 'dts/lenovo-zhiyu.dts',
         'configs/modprobe.d', 'build.sh', 'mkbootimg', 'mkvendorbootimg',
         'mkinitbootimg', 'mkvbmetaimg', 'scripts/image-tools.sh', 'scripts/deps.py',
         'scripts/kernel-env.sh', 'scripts/image-inputs.py', 'bootconfig.extra']
for name in paths:
    path = root / name
    if not path.exists():
        continue
    for f in sorted(path.rglob('*') if path.is_dir() else [path]):
        rel = f.relative_to(root)
        if f.name == "sm8750-tplg.bin" or not f.is_file() or any(p.startswith('.') or p in ('bin','__pycache__') for p in rel.parts):
            continue
        print(hashlib.sha256(f.read_bytes()).hexdigest(), rel.as_posix())
