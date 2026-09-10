from pathlib import Path
import os, shutil, subprocess, tempfile, unittest

# GitHub 网络操作使用本地替身，不登录或访问真实远程仓库。
SOURCE=Path(__file__).resolve().parents[2]
REAL_GIT=shutil.which('git')

class PublishScriptTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory(prefix='codex-publish-test-')
        self.base=Path(self.tmp.name)
        self.root=self.base/'codex-monitor'
        shutil.copytree(SOURCE,self.root,ignore=shutil.ignore_patterns('.build','.git','dist'))
        # Only mock the test command within this isolated publishing harness.
        # Actual 56 Swift regression tests were executed separately on the source.
        (self.root/'scripts/test.sh').write_text('#!/bin/bash\nexit 0\n')
        (self.root/'scripts/test.sh').chmod(0o755)
        self.bin=self.base/'bin';self.bin.mkdir()
        (self.bin/'swift').write_text('#!/bin/sh\nexit 0\n')
        (self.bin/'git').write_text('''#!/usr/bin/env python3
import os,sys,json
from pathlib import Path
with open(os.environ['MOCK_LOG'],'a') as f: f.write(json.dumps(['git']+sys.argv[1:])+'\\n')
if sys.argv[1:2]==['push']:
    if os.environ.get('FAIL_PUSH')=='1':
        print('Simulated transport failure',file=sys.stderr);sys.exit(1)
    Path(os.environ['PUSH_MARKER']).touch();sys.exit(0)
os.execv(os.environ['REAL_GIT'],[os.environ['REAL_GIT']]+sys.argv[1:])
''')
        (self.bin/'gh').write_text('''#!/usr/bin/env python3
import os,sys,json,subprocess
from pathlib import Path
args=sys.argv[1:]
with open(os.environ['MOCK_LOG'],'a') as f:f.write(json.dumps(['gh']+args)+'\\n')
if args[:2]==['auth','status']:sys.exit(1 if os.environ.get('NEED_LOGIN')=='1' else 0)
if args[:2]==['auth','login']:sys.exit(0)
if args and args[0]=='api' and 'user' in args:print(os.environ.get('MOCK_USER','yzin-17'));sys.exit(0)
if args[:2]==['repo','view']:
    state=os.environ.get('MOCK_REPO','missing')
    if state=='missing':sys.exit(1)
    print('yzin-17/codex-monitor\\t'+('true' if state=='empty' else 'false')+'\\t'+os.environ.get('MOCK_VISIBILITY','PUBLIC'));sys.exit(0)
if args[:2]==['repo','create']:
    Path(os.environ['CREATE_MARKER']).touch();sys.exit(0)
if args and args[0]=='api' and any('git/ref/heads/main' in a for a in args):
    if os.environ.get('BAD_VERIFY')=='1':print('0'*40);sys.exit(0)
    sys.exit(subprocess.run([os.environ['REAL_GIT'],'rev-parse','HEAD']).returncode)
print('Unhandled simulated gh command',args,file=sys.stderr);sys.exit(2)
''')
        for p in self.bin.iterdir():p.chmod(0o755)
        self.env=dict(os.environ)
        for key in ('GH_TOKEN','GITHUB_TOKEN','GH_ENTERPRISE_TOKEN','GITHUB_ENTERPRISE_TOKEN'):self.env.pop(key,None)
        (self.base/'home').mkdir()
        self.env.update(PATH=str(self.bin)+os.pathsep+os.environ['PATH'],REAL_GIT=REAL_GIT,
                        HOME=str(self.base/'home'),GIT_CONFIG_NOSYSTEM='1',GIT_CONFIG_GLOBAL='/dev/null',
                        MOCK_LOG=str(self.base/'commands.log'),PUSH_MARKER=str(self.base/'push'),CREATE_MARKER=str(self.base/'create'))
    def tearDown(self):self.tmp.cleanup()
    def run_script(self,args=('--public',),**env):
        return subprocess.run(['bash','scripts/publish-github.sh',*args],cwd=self.root,env={**self.env,**env},capture_output=True,text=True,timeout=20)
    def git(self,*args):return subprocess.check_output([REAL_GIT,*args],cwd=self.root,env=self.env,text=True)
    def test_requires_explicit_visibility(self):
        r=self.run_script(args=());self.assertNotEqual(r.returncode,0);self.assertFalse((self.root/'.git').exists())
    def test_rejects_wrong_account_without_creating_repository(self):
        r=self.run_script(MOCK_USER='another-user');self.assertNotEqual(r.returncode,0);self.assertFalse((self.base/'create').exists());self.assertFalse((self.root/'.git').exists())
    def test_refuses_existing_content(self):
        r=self.run_script(MOCK_REPO='nonempty');self.assertNotEqual(r.returncode,0);self.assertIn('已经有内容',r.stderr);self.assertFalse((self.base/'push').exists())
    def test_refuses_visibility_change(self):
        r=self.run_script(MOCK_REPO='empty',MOCK_VISIBILITY='PRIVATE');self.assertNotEqual(r.returncode,0);self.assertFalse((self.base/'create').exists())
    def test_only_manifest_files_are_committed(self):
        (self.root/'.env').write_text('FAKE_SECRET=do-not-publish\n')
        (self.root/'private-extra.txt').write_text('must not be committed\n')
        r=self.run_script();self.assertEqual(r.returncode,0,r.stdout+r.stderr)
        self.assertTrue((self.base/'create').exists());self.assertTrue((self.base/'push').exists())
        tracked=self.git('ls-files').splitlines();manifest=(self.root/'scripts/publish-files.txt').read_text().splitlines()
        self.assertEqual(sorted(tracked),sorted(manifest))
        self.assertEqual(self.git('config','--local','user.email').strip(),'30586807+yzin-17@users.noreply.github.com')
    def test_browser_login_when_needed(self):
        r=self.run_script(NEED_LOGIN='1');self.assertEqual(r.returncode,0,r.stdout+r.stderr)
        commands=(self.base/'commands.log').read_text();self.assertIn('"auth", "login"',commands);self.assertIn('"--web"',commands)
    def test_failed_push_never_reports_success(self):
        r=self.run_script(FAIL_PUSH='1');self.assertNotEqual(r.returncode,0);self.assertNotIn('源码已发布',r.stdout);self.assertIn('源码推送失败',r.stderr)
    def test_commit_mismatch_never_reports_success(self):
        r=self.run_script(BAD_VERIFY='1');self.assertNotEqual(r.returncode,0);self.assertNotIn('源码已发布',r.stdout)
    def test_repeated_publish_same_commit_does_not_push_again(self):
        r=self.run_script();self.assertEqual(r.returncode,0,r.stdout+r.stderr)
        (self.base/'push').unlink()
        r=self.run_script(MOCK_REPO='nonempty');self.assertEqual(r.returncode,0,r.stdout+r.stderr)
        self.assertIn('已经是当前提交',r.stdout);self.assertFalse((self.base/'push').exists())

unittest.main(verbosity=2)
