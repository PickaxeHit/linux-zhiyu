#!/usr/bin/env python3
"""Offline tests of CI fan-in, transfers, ELF checks and package-lock policy."""
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent

def load(name):
    spec = importlib.util.spec_from_file_location(name, ROOT/'scripts'/f'{name}.py')
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod

ci = load('ci-artifacts')
headers = load('verify-header-tools')
lock = load('lock-build-environment')

def elf(path, machine=183):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(b'\x7fELF\x02\x01'+b'\0'*12+machine.to_bytes(2,'little'))
    path.chmod(0o755)

class Tests(unittest.TestCase):
    def test_header_arch(self):
        with tempfile.TemporaryDirectory() as t:
            p = Path(t)
            elf(p/'scripts/basic/fixdep'); elf(p/'scripts/mod/modpost')
            headers.verify(p)
            elf(p/'scripts/other',62)
            with self.assertRaises(ValueError): headers.verify(p)
            (p/'scripts/other').unlink()
            (p/'scripts/basic/fixdep').chmod(0o644)
            with self.assertRaises(ValueError): headers.verify(p)

    def test_matrix_aggregation(self):
        for k,u in [(True,True),(True,False),(False,True)]:
            with self.subTest(kernel=k,userspace=u), tempfile.TemporaryDirectory() as t:
                p=Path(t); results=p/'results'; out=p/'out'
                for d,(folder,suffix,count) in ci.DISTROS.items():
                    dst=results/d/folder; dst.mkdir(parents=True)
                    names=['linux-zhiyu-'+n for n in ('modules','headers','firmware','images')] if k else []
                    if u:
                        names+=['libcamera-zhiyu-0.7','zhiyu-sensord']
                        if d!='arch': names+=['libcamera-zhiyu-0.8']
                        if d=='fedora': names+=['sensh-1','hexagonrpc-1']
                    for n in names: (dst/(n+suffix)).write_text('test')
                    env=results/d/'package-environments'/d; env.mkdir(parents=True)
                    for family,enabled in [('kernel',k),('userspace',u)]:
                        if enabled:
                            (env/(family+'.json')).write_text(json.dumps({'package_revision':'1','deps_sha256':'abc', 'stage_id':'stage 1','header_smoke_test':'passed'}))
                ci.collect(results,out,k,u,'1','abc','stage 1')
                self.assertEqual(len(list((out/'pkgs').iterdir()))+len(list((out/'rpms/aarch64').iterdir())),12*int(k)+10*int(u))
                with self.assertRaises(ValueError): ci.collect(results,p/'wrong',k,u,'2','abc','stage 1')

    @unittest.skipUnless(shutil.which('zstd'), 'zstd unavailable')
    def test_transfer_permissions(self):
        with tempfile.TemporaryDirectory() as t:
            root=Path(t); (root/'scripts').mkdir()
            for n in ('ci-bundle-common.sh','ci-restore-common.sh','verify-header-tools.py'):
                shutil.copy2(ROOT/'scripts'/n, root/'scripts'/n)
            out=root/'out'; out.mkdir(); (out/'kernel-release').write_text('test\n')
            (out/'package-build.id').write_text('stage 1\n');(out/'images-build.id').write_text('stage\n')
            for n in ('boot.img','sm8750-tplg.bin'): (out/n).write_text('test')
            (out/'image-build.SHA256SUMS').write_text(''.join(ci.sha(out/n)+'  '+n+'\n' for n in ('boot.img','sm8750-tplg.bin')))
            stage=root/'stage';
            for n in ('modules','headers','firmware','images'): (stage/('linux-zhiyu-'+n)).mkdir(parents=True)
            h=stage/'linux-zhiyu-headers/usr/src/linux-headers-test'
            elf(h/'scripts/basic/fixdep'); elf(h/'scripts/mod/modpost'); (h/'link').symlink_to('scripts/mod/modpost')
            lic=stage/'linux-zhiyu-images/usr/share/licenses/linux-zhiyu-images';lic.mkdir(parents=True);(lic/'NOTICE').write_text('notice')
            env=dict(os.environ,PKG_REVISION='1')
            subprocess.run(['bash','scripts/ci-bundle-common.sh'],cwd=root,env=env,check=True,capture_output=True)
            shutil.rmtree(stage)
            subprocess.run(['bash','scripts/ci-restore-common.sh','stage'],cwd=root,env=env,check=True,capture_output=True)
            self.assertTrue((h/'link').is_symlink()); self.assertTrue((h/'scripts/mod/modpost').stat().st_mode & 0o111)
            (out/'boot.img').unlink()
            subprocess.run(['bash','scripts/ci-restore-common.sh','images'],cwd=root,env=env,check=True,capture_output=True)
            self.assertEqual((out/'boot.img').read_text(),'test')

    def test_lock_profiles(self):
        data={'kernel':{'release':'test'},'host_toolchain':{'rustc':'rustc 1.99.1 (test)'},'package_environments':{}}
        for d in ci.DISTROS:
            record={'image':'repo/'+d+':base','repo_digests':['repo/'+d+'@sha256:'+'a'*64],'installed_packages':['foo 1'],'install_profile':'userspace'}
            for f in ['kernel','userspace']: data['package_environments'][d+'/'+f]=record.copy()
        captured=lock.capture(data)
        self.assertEqual(captured['rust'],'1.99.1'); self.assertEqual(len(captured['packages']),3)
        with tempfile.TemporaryDirectory() as t:
            p=Path(t); (p/'containers').mkdir(); (p/'containers/build-lock.json').write_text(json.dumps(captured));(p/'actual').write_text('foo 1\n')
            env=dict(os.environ,DISTRO='arch',BUILD_USERSPACE='true',STRICT_LOCK='true')
            cmd=['python3',str(ROOT/'scripts/check-package-environment.py'),'actual']
            subprocess.run(cmd,cwd=p,env=env,check=True,capture_output=True)
            (p/'actual').write_text('foo 2\n')
            self.assertNotEqual(subprocess.run(cmd,cwd=p,env=env,capture_output=True).returncode,0)
            self.assertEqual(subprocess.run(cmd,cwd=p,env=dict(env,STRICT_LOCK='false'),capture_output=True).returncode,0)

    def test_fedora_rolling_publication(self):
        publisher = ROOT/'scripts/publish-fedora-rpms.sh'
        for fail_index in (False, True):
            with self.subTest(fail_index=fail_index), tempfile.TemporaryDirectory() as t:
                p = Path(t)
                bin_dir = p/'bin'; bin_dir.mkdir()
                rpms = p/'rpms'; rpms.mkdir()
                names = ['linux-zhiyu-'+n for n in ('modules','headers','firmware','images')]
                names += ['libcamera-zhiyu','zhiyu-sensord','hexagonrpc','sensh']
                packages = [n+'-1-2.aarch64.rpm' for n in names]
                packages.append('libcamera-zhiyu-2-2.aarch64.rpm')
                for name in packages: (rpms/name).touch()
                (rpms/'repodata').mkdir()
                (rpms/'repodata'/'stale.xml.gz').touch()
                primary = 'a'*64+'-primary.xml.gz'
                old_primary = 'b'*64+'-primary.xml.gz'
                old_rpm = 'hexagonrpc-1-1.aarch64.rpm'
                old = [(1, old_rpm), (2, old_primary), (3, packages[0]),
                       (4, primary), (5, 'repomd.xml'), (6, 'README.txt')]
                (p/'previous').write_text(''.join(f'{i}\t{n}\n' for i,n in old))
                mocks = {
                    'git': '''#!/bin/sh
if [ "$1" = show ]; then
  printf '%s\n' '{"hexagonrpc":{"rev":"abc","url":"https://github.com/test/hexagonrpc"},"sensh":{"rev":"abc","url":"https://gitlab.com/test/sensh"}}'
fi
''',
                    'createrepo_c': '''#!/usr/bin/env python3
import sys,gzip
from pathlib import Path
from xml.sax.saxutils import quoteattr
a=sys.argv
d=Path(a[a.index("--outputdir")+1])/"repodata"
d.mkdir()
packages=Path(a[a.index("--pkglist")+1]).read_text().splitlines()
name="a"*64+"-primary.xml.gz"
with gzip.open(d/name,"wt") as f:
    f.write('<metadata xmlns="http://linux.duke.edu/metadata/common">'+''.join('<package><location href='+quoteattr(p)+'/></package>' for p in packages)+'</metadata>')
(d/"repomd.xml").write_text('<repomd xmlns="http://linux.duke.edu/metadata/repo"><data type="primary"><location href="repodata/'+name+'"/></data></repomd>')
''',
                    'gh': '''#!/usr/bin/env python3
import os,sys
from pathlib import Path
a=sys.argv[1:]
with open(os.environ["MOCK_LOG"],"a") as f: f.write(" ".join(a)+"\\n")
if a[0]=="api" and "--paginate" in a:
    print(Path(os.environ["MOCK_PREVIOUS"]).read_text(),end="")
elif a[0]=="api" and "--jq" in a:
    print(42)
elif a[:2]==["release","upload"] and any(x.endswith("/repomd.xml") for x in a) and os.environ["FAIL_INDEX"]=="1":
    sys.exit(1)
'''}
                for name, body in mocks.items():
                    tool = bin_dir/name; tool.write_text(body); tool.chmod(0o755)
                env = dict(os.environ, PATH=str(bin_dir)+os.pathsep+os.environ['PATH'],
                           PACKAGE_REPOSITORY='test/repo', GITHUB_REPOSITORY='test/source',
                           MOCK_LOG=str(p/'log'), MOCK_PREVIOUS=str(p/'previous'),
                           FAIL_INDEX=str(int(fail_index)))
                result = subprocess.run(['bash',str(publisher),str(rpms),'abc'],cwd=p,env=env,capture_output=True,text=True)
                log = (p/'log').read_text().splitlines()
                deletes = [line for line in log if line.startswith('api --method DELETE')]
                if fail_index:
                    self.assertNotEqual(result.returncode,0)
                    self.assertFalse(deletes)
                else:
                    self.assertEqual(result.returncode,0,result.stderr)
                    self.assertEqual(deletes,['api --method DELETE repos/test/repo/releases/assets/1',
                                              'api --method DELETE repos/test/repo/releases/assets/2'])
                    index_upload = next(i for i,line in enumerate(log) if line.startswith('release upload') and '/repomd.xml' in line)
                    self.assertTrue(all(log.index(line)>index_upload for line in deletes))

if __name__=='__main__': unittest.main(verbosity=2)
