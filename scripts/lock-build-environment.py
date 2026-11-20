#!/usr/bin/env python3
"""Capture observed OCI digests / package inventories / Rust version from a successful build."""
import argparse
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DIGEST = re.compile(r'^.+@sha256:[0-9a-f]{64}$')
VERSION = re.compile(r'^rustc (\d+\.\d+\.\d+)\b')


def capture(manifest):
    result = {'images': {}, 'packages': {}}
    envs = manifest['package_environments']
    for distro in ('debian','arch','fedora'):
        families = [k for k in envs if k.startswith(distro + '/')]
        if not families:
            raise ValueError(f'Missing {distro} environment')
        digests = None
        for family in families:
            record = envs[family]
            repo = record['image'].split('@')[0]
            # Drop tag only from the last path component, not a registry port.
            base, sep, leaf = repo.rpartition('/')
            repo = base + sep + leaf.split(':')[0]
            candidates = {x for x in record['repo_digests'] if DIGEST.fullmatch(x) and x.split('@')[0] == repo}
            # Docker can normalize away docker.io/library or add it. Prefer a
            # uniquely reported digest if there is no exact repository match.
            if not candidates:
                candidates = {x for x in record['repo_digests'] if DIGEST.fullmatch(x)}
            digests = candidates if digests is None else digests & candidates
            profile = record.get('install_profile', 'userspace' if distro+'/userspace' in envs else 'kernel')
            key = distro+'/'+profile
            if key in result['packages'] and result['packages'][key] != record['installed_packages']:
                raise ValueError(f'{key}: conflicting package inventories')
            result['packages'][key] = record['installed_packages']
        if len(digests or ()) != 1:
            raise ValueError(f'{distro}: no unique shared registry digest; rebuild the families using the same image')
        result['images'][distro] = digests.pop()
    version = VERSION.match(manifest.get('host_toolchain', {}).get('rustc',''))
    if not version or not manifest.get('kernel'):
        raise ValueError('Use a complete build manifest with kernel and Rust provenance')
    if not {d+'/'+f for d in ('debian','arch','fedora') for f in ('kernel','userspace')}.issubset(envs):
        raise ValueError('Use a complete build manifest containing both package families')
    result['rust'] = version.group(1)
    return result


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('manifest', type=Path, nargs='?', default=ROOT/'out/manifest.json')
    parser.add_argument('--kernel-only-manifest', type=Path, help='optional separate kernel-only build inventory')
    args = parser.parse_args()
    try:
        data = capture(json.loads(args.manifest.read_text()))
        if args.kernel_only_manifest:
            extra = json.loads(args.kernel_only_manifest.read_text())['package_environments']
            for d in ('debian','arch','fedora'):
                record=extra[d+'/kernel']
                if (record.get('install_profile','kernel') != 'kernel' or d+'/userspace' in extra or
                        data['images'][d] not in record['repo_digests']):
                    raise ValueError(f'{d}: kernel-only environment must use the same image digest')
                data['packages'][d+'/kernel']=record['installed_packages']
        target = ROOT/'containers/build-lock.json'
        tmp = target.with_suffix('.json.tmp')
        tmp.write_text(json.dumps(data, indent=2, sort_keys=True)+'\n')
        tmp.replace(target)
        print(f'Wrote {target}; review and commit it. Package inventories detect drift, not repository snapshots.')
    except (ValueError, KeyError, OSError) as e:
        parser.exit(1, f'{e}\n')
