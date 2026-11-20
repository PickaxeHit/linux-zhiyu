#!/usr/bin/env python3
"""Offline smoke tests: isolated temp trees, no actual ARM64 build or flashing."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent

def run(*args, cwd=None, env=None, check=True):
    return subprocess.run(args, cwd=cwd, env=env, text=True, capture_output=True, check=check)

class BuildTools(unittest.TestCase):
    def test_dependency_lock_fetch_and_cache(self):
        with tempfile.TemporaryDirectory() as tmp:
            base = Path(tmp)
            upstream = base/'upstream'
            upstream.mkdir()
            run('git','init','-q',cwd=upstream)
            run('git','config','user.name','Test',cwd=upstream)
            run('git','config','user.email','test@example.invalid',cwd=upstream)
            (upstream/'source').write_text('first')
            run('git','add','source',cwd=upstream)
            run('git','commit','-qm','first',cwd=upstream)
            sha = run('git','rev-parse','HEAD',cwd=upstream).stdout.strip()
            run('git','tag','-am','release','v1',cwd=upstream)
            (base/'scripts').mkdir(); (base/'deps').mkdir()
            shutil.copy2(ROOT/'scripts/deps.py',base/'scripts/deps.py')
            manifest=base/'deps/deps.json'
            manifest.write_text(json.dumps({'demo':{'type':'git','url':str(upstream),'tag':'v1'}}))
            env = dict(os.environ, DEPS_DIR=str(base/'sources'), DEPS_CACHE=str(base/'cache'))
            def deps(*args, **kw):
                return run('python3','scripts/deps.py',*args,cwd=base,env=env,**kw)
            self.assertNotEqual(deps('check','--locked',check=False).returncode,0)
            deps('lock','--missing'); deps('check','--locked')
            self.assertEqual(json.loads(manifest.read_text())['demo']['rev'],sha)
            # Move the tag. A pinned fetch still obtains the old commit.
            (upstream/'source').write_text('second'); run('git','commit','-qam','second',cwd=upstream)
            run('git','tag','-f','v1',cwd=upstream)
            source = Path(deps('path','demo').stdout.strip())
            self.assertEqual((source/'source').read_text(),'first')
            (source/'source').write_text('dirty'); (source/'object.o').write_text('stale')
            deps('path','demo')
            self.assertEqual((source/'source').read_text(),'first'); self.assertFalse((source/'object.o').exists())
            # Explicit update changes rev to the new tag; no silent movement otherwise.
            deps('lock','demo'); deps('path','demo')
            self.assertEqual((source/'source').read_text(),'second')
            old = manifest.read_bytes()
            self.assertNotEqual(deps('lock','unknown',check=False).returncode,0)
            self.assertEqual(manifest.read_bytes(),old)

    @unittest.skipUnless(shutil.which('zstd') and shutil.which('dpkg-deb'), 'packaging tools not available')
    def test_package_formats(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp); stage=root/'stage'; out=root/'out'
            notice=stage/'usr/share/licenses/demo/NOTICE.md'; notice.parent.mkdir(parents=True); notice.write_text('test')
            env=dict(os.environ,PKG_NAME='demo',PKG_VERSION='1.0',PKG_LICENSE='MIT',PKG_REVISION='1')
            for formats in ('arch','deb','deb arch'):
                if out.exists(): shutil.rmtree(out)
                run('bash',str(ROOT/'scripts/mkpkgs.sh'),str(stage),str(out),env=dict(env,PKG_FORMATS=formats))
                if 'arch' in formats:
                    archive=next(out.glob('*.pkg.tar.zst'))
                    self.assertEqual(run('tar','--zstd','-tf',str(archive)).stdout.splitlines()[0],'.PKGINFO')
                    self.assertIn('arch = aarch64',run('tar','--zstd','-xOf',str(archive),'.PKGINFO').stdout)
                if 'deb' in formats:
                    archive=next(out.glob('*.deb'))
                    self.assertEqual(run('dpkg-deb','-f',str(archive),'Architecture').stdout.strip(),'arm64')

    def test_container_dispatch(self):
        # No engine is required: mock the OCI CLI, never claim to compile ARM64.
        with tempfile.TemporaryDirectory() as tmp:
            base=Path(tmp)
            for name in ('scripts','containers','bin','out/pkgs','deps'):
                (base/name).mkdir(parents=True)
            for name in ('scripts/run-package-container.sh','containers/images.json'):
                shutil.copy2(ROOT/name,base/name)
            (base/'deps/deps.json').write_text('{}')
            mock=base/'bin/mock-engine'
            mock.write_text(r'''#!/usr/bin/env python3
import json,os,sys
from pathlib import Path
args=sys.argv[1:]
with open('engine.log','a') as f: f.write(json.dumps(args)+'\n')
if args[0]=='info':
    print('true' if Path(sys.argv[0]).name=='podman' else '[]')
elif args[:2]==['image','inspect']:
    print(json.dumps([{'Id':'sha256:mock','Architecture':os.getenv('MOCK_ARCH','arm64'),'Os':'linux','RepoDigests':['repo@sha256:mock']}]))
elif args[0]=='pull':
    pass
elif args[0]=='run':
    assert '--platform' in args and args[args.index('--platform')+1]=='linux/arm64'
    assert '--privileged' not in args and '--rm' in args
    if os.getenv('MOCK_FAIL'): sys.exit(7)
    d=os.environ['DISTRO']; suffix={'debian':'.deb','arch':'.pkg.tar.zst','fedora':'.rpm'}[d]
    result=Path('out/build/packages')/d/'result'; result.mkdir(parents=True,exist_ok=True)
    for f in result.iterdir(): f.unlink()
    names=[]
    if os.environ['BUILD_KERNEL']=='true': names += ['linux-zhiyu-'+p+'-1' for p in ('modules','headers','firmware','images')]
    if os.environ['BUILD_USERSPACE']=='true':
        names += ['libcamera-zhiyu-0.7','zhiyu-sensord-1']
        if d!='arch': names+=['libcamera-zhiyu-0.8']
        if d=='fedora': names+=['sensh-1','hexagonrpc-1']
    for name in names: (result/(name+suffix)).write_text('mock')
    (result/'installed-packages.txt').write_text('mock\n')
else: sys.exit(99)
''')
            mock.chmod(0o755)
            for engine in ('podman','docker'): (base/'bin'/engine).symlink_to(mock.name)
            env=dict(os.environ,PATH=str(base/'bin')+':'+os.environ['PATH'],BUILD_KERNEL='false',BUILD_USERSPACE='true',CONTAINER_PULL='always',PKG_REVISION='123')
            (base/'out/pkgs/linux-zhiyu-images-older.deb').write_text('keep')
            (base/'out/pkgs/libcamera-zhiyu-stale.deb').write_text('remove')
            for distro,engine in [('debian','docker'),('arch','podman'),('fedora','docker')]:
                run('bash','scripts/run-package-container.sh',distro,cwd=base,env=dict(env,CONTAINER_ENGINE=engine))
                metadata=json.loads((base/'out/package-environments'/distro/'userspace.json').read_text())
                self.assertEqual(metadata['engine'],engine)
                self.assertEqual(metadata['image_id'],'sha256:mock')
            self.assertEqual(len(list((base/'out/pkgs').glob('libcamera-zhiyu*.deb'))),2)
            self.assertEqual(len(list((base/'out/pkgs').glob('libcamera-zhiyu*.pkg.tar.zst'))),1)
            self.assertEqual(len(list((base/'out/rpms/aarch64').glob('*.rpm'))),5)
            self.assertTrue((base/'out/pkgs/linux-zhiyu-images-older.deb').exists())
            self.assertFalse((base/'out/pkgs/libcamera-zhiyu-stale.deb').exists())
            # Failed/wrong-architecture containers must not replace prior packages.
            before=sorted((base/'out/pkgs').iterdir())
            for extra in ({'MOCK_ARCH':'amd64'}, {'MOCK_FAIL':'1'}):
                result=run('bash','scripts/run-package-container.sh','debian',cwd=base,env=dict(env,CONTAINER_ENGINE='docker',**extra),check=False)
                self.assertNotEqual(result.returncode,0)
                self.assertEqual(sorted((base/'out/pkgs').iterdir()),before)
            # Kernel-only stage and metadata: other family remains untouched.
            (base/'out/images-build.id').write_text('test-id\n')
            (base/'out/package-build.id').write_text('test-id 123\n')
            run('bash','scripts/run-package-container.sh','debian',cwd=base,env=dict(env,CONTAINER_ENGINE='docker',BUILD_KERNEL='true',BUILD_USERSPACE='false'))
            self.assertEqual(len(list((base/'out/pkgs').glob('linux-zhiyu-*.deb'))),4)
            self.assertEqual(len(list((base/'out/pkgs').glob('libcamera-zhiyu*.deb'))),2)

    def test_topology_failed_build_preserves_previous_output(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp); out=root/'out.bin'; out.write_bytes(b'CoSAold')
            m4=root/'m4'; m4.write_text('#!/bin/sh\necho "test"\n'); m4.chmod(0o755)
            alsa=root/'alsatplg'; alsa.write_text('#!/bin/sh\nexit 1\n'); alsa.chmod(0o755)
            env=dict(os.environ,OUT=str(out),M4=str(m4),ALSATPLG=str(alsa),AUDIOREACH_SRC=str(root))
            cmd=('bash',str(ROOT/'initramfs-src/tplg/build.sh'))
            self.assertNotEqual(run(*cmd,env=env,check=False).returncode,0)
            self.assertEqual(out.read_bytes(),b'CoSAold')
            alsa.write_text('#!/bin/sh\nprintf CoSAnew > "$4"\n')
            run(*cmd,env=env)
            self.assertEqual(out.read_bytes(),b'CoSAnew')

if __name__ == '__main__': unittest.main(verbosity=2)
