#!/usr/bin/env python3
"""Record exact source IDs (including tag resolutions) and output hashes."""
import argparse
import hashlib
import json
import os
import subprocess
import shutil
from pathlib import Path

root = Path(__file__).resolve().parent.parent
os.chdir(root)

def git(path, *args):
    return subprocess.run(['git','-C',str(path),*args], text=True, stdout=subprocess.PIPE,
                          stderr=subprocess.DEVNULL, check=True).stdout.strip()

def sha(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--base', type=Path, help='common job manifest for CI aggregation')
args = parser.parse_args()
manifest = json.loads(Path('deps/deps.json').read_text())
source = {'main': git('.', 'rev-parse', 'HEAD'), 'main_dirty': bool(git('.', 'status', '--porcelain'))}
for path in ('kernel-source','libcamera/0.7','libcamera/0.8'):
    if (Path(path)/'.git').exists():
        source[path] = {'commit': git(path,'rev-parse','HEAD'), 'dirty': bool(git(path,'status','--porcelain'))}
source_cache = Path(os.environ.get('DEPS_DIR', root/'.sources'))
for name, dep in manifest.items():
    if dep['type'] == 'git' and (source_cache/name/'.git').exists():
        dep['checkout'] = git(source_cache/name,'rev-parse','HEAD')
        if dep.get('rev') and dep['rev'] != dep['checkout']:
            # A previous local run may have fetched an unused dependency; do not claim it was used.
            dep['cached_checkout_mismatch'] = True

out = Path('out')
files = sorted(set(out.glob('*.img')) | set(out.glob('pkgs/*')) | set(out.glob('rpms/aarch64/*.rpm')))
toolchain = {}
for tool in ('gcc', 'ld', 'aarch64-linux-gnu-gcc', 'aarch64-linux-gnu-ld', 'rustc', 'cargo', 'cmake', 'meson', 'python3', 'dtc', 'alsatplg'):
    if shutil.which(tool):
        r = subprocess.run([tool, '--version'], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        if r.returncode == 0 and r.stdout.strip():
            toolchain[tool] = r.stdout.splitlines()[0]
result = {'schema': 1, 'host_toolchain': toolchain, 'device': 'TB378FC', 'android_base': 'ZUXOS 2.0.10.252',
          'package_revision': os.environ.get('PKG_REVISION','1'), 'source': source,
          'dependencies': manifest, 'artifacts': {str(f.relative_to(out)): {'sha256':sha(f),'size':f.stat().st_size}
          for f in files if f.is_file()}}
result['package_environments'] = {
    str(f.relative_to(out/'package-environments').with_suffix('')): json.loads(f.read_text())
    for f in sorted((out/'package-environments').glob('*/*.json'))
}
if args.base:
    base = json.loads(args.base.read_text())
    if base['source']['main'] != source['main'] or base['package_revision'] != result['package_revision']:
        raise SystemExit('Common manifest source/revision mismatch')
    if base.get('deps_sha256') != sha(Path('deps/deps.json')):
        raise SystemExit('Common manifest dependency lock mismatch')
    for name, metadata in base['artifacts'].items():
        if result['artifacts'].get(name) != metadata:
            raise SystemExit(f'Common artifact mismatch: {name}')
    for key in ('source','dependencies','host_toolchain','kernel'):
        if key in base: result[key] = base[key]
    if 'kernel' in base and (out/'kernel-release').read_text().strip() != base['kernel']['release']:
        raise SystemExit('Kernel release mismatch')
elif (out/'images-build.id').exists():
    cfg = Path(os.environ.get('KBUILD_DIR',out/'kernel'))/'.config'
    result['kernel'] = {'release': (out/'kernel-release').read_text().strip(), 'config_sha256':sha(cfg)}
result['deps_sha256'] = sha(Path('deps/deps.json'))
out.mkdir(exist_ok=True)
(out/'manifest.json').write_text(json.dumps(result,indent=2)+'\n')
