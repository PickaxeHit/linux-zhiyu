#!/usr/bin/env python3
"""Validate and collect matrix artifacts without transferring Kbuild objects."""
import argparse
import hashlib
import json
import os
import shutil
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DISTROS = {'debian': ('pkgs', '.deb', 3), 'arch': ('pkgs', '.pkg.tar.zst', 2),
           'fedora': ('rpms/aarch64', '.rpm', 5)}


def sha(path):
    with path.open('rb') as f:
        return hashlib.file_digest(f, 'sha256').hexdigest()


def require(condition, message):
    if not condition:
        raise ValueError(message)


def collect(results, out, kernel, userspace, revision, deps_hash, stage_id):
    for distro, (folder, suffix, user_count) in DISTROS.items():
        src = results / distro
        packages = sorted((src / folder).glob('*' + suffix))
        expected = (4 if kernel else 0) + (user_count if userspace else 0)
        require(len(packages) == expected, f'{distro}: expected {expected} packages, got {len(packages)}')
        for name in ('modules', 'headers', 'firmware', 'images'):
            require(sum(p.name.startswith('linux-zhiyu-' + name) for p in packages) == int(kernel),
                    f'{distro}: unexpected kernel package {name}')
        if userspace:
            for name, count in [('libcamera-zhiyu', 1 if distro == 'arch' else 2), ('zhiyu-sensord', 1)]:
                require(sum(p.name.startswith(name) for p in packages) == count, f'{distro}: {name} count')
            if distro == 'fedora':
                for name in ('sensh-', 'hexagonrpc-'):
                    require(sum(p.name.startswith(name) for p in packages) == 1, f'{distro}: {name} count')
        envdir = src / 'package-environments' / distro
        expected_families = {family for family, enabled in [('kernel', kernel), ('userspace', userspace)] if enabled}
        require({p.stem for p in envdir.glob('*.json')} == expected_families, f'{distro}: unexpected provenance files')
        for family in expected_families:
            data = json.loads((envdir / (family + '.json')).read_text())
            require(data['package_revision'] == revision and data['deps_sha256'] == deps_hash,
                    f'{distro}: build revision or dependency lock mismatch')
            if family == 'kernel':
                require(data['stage_id'] == stage_id, f'{distro}: stage ID mismatch')
                require(data.get('header_smoke_test') == 'passed', f'{distro}: missing header smoke-test result')
        for path in packages:
            dest = out / folder / path.name
            require(not dest.exists(), f'duplicate package: {dest}')
            dest.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(path, dest)
        shutil.copytree(envdir, out / 'package-environments' / distro)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--kernel', action='store_true')
    parser.add_argument('--userspace', action='store_true')
    parser.add_argument('--results', type=Path, default=Path('out/ci-results'))
    args = parser.parse_args()
    os.chdir(ROOT)
    try:
        require(args.kernel or args.userspace, 'at least one package family required')
        stage_id = Path('out/package-build.id').read_text().strip() if args.kernel else None
        collect(args.results, Path('out'), args.kernel, args.userspace, os.environ['PKG_REVISION'],
                sha(Path('deps/deps.json')), stage_id)
    except (ValueError, KeyError, OSError) as exc:
        parser.exit(1, f'{exc}\n')


if __name__ == '__main__':
    main()
