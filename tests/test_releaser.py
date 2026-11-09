"""End-to-end regressions using local Git repositories and a fake upload client.

Run: python3 -m unittest discover -s tests -v
"""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / 'scripts/pms-releaser.sh'
BASH = os.environ.get('TEST_BASH', '/bin/bash')


class ReleaserTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='pms-releaser-test-')
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.repo = self.base / 'repo'
        self.repo.mkdir()
        self.env = os.environ.copy()
        for key in list(self.env):
            if key.startswith(('GIT_', 'DRONE_', 'GITHUB_')):
                self.env.pop(key)
        self.env.update(GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_SYSTEM=os.devnull,
                        ACCESS_TOKEN='test-token', RELEASE_URL='https://unused.invalid/release',
                        CAPTURE=str(self.base / 'uploaded-changelog'))
        self.git('init', '-b', 'main')
        self.git('config', 'user.name', 'Release Test')
        self.git('config', 'user.email', 'test@example.invalid')
        self.bin = self.base / 'bin'
        self.bin.mkdir()
        fake = self.bin / 'curl'
        fake.write_text('''#!/usr/bin/env python3
import os, pathlib, shlex, sys
args = sys.argv[1:]
if '-I' in args:
    sys.exit(0)
value = next(args[i+1] for i, arg in enumerate(args) if arg == '-F' and args[i+1].startswith('changelog=<'))
pathlib.Path(os.environ['CAPTURE']).write_text(pathlib.Path(shlex.split(value[len('changelog=<'):])[0]).read_text())
pathlib.Path(args[args.index('--dump-header')+1]).write_text('Content-Type: application/json\\r\\n')
pathlib.Path(args[args.index('--output')+1]).write_text('{"ok":true}')
print('200', end='')
''')
        fake.chmod(0o755)
        self.env['PATH'] = str(self.bin) + os.pathsep + self.env['PATH']
        self.artifact = self.base / 'app.apk'
        self.artifact.write_bytes(b'app')

    def git(self, *args, cwd=None):
        return subprocess.check_output(['git', *args], cwd=cwd or self.repo,
                                       env=self.env, stderr=subprocess.PIPE, text=True).strip()

    def commit(self, subject):
        self.git('commit', '--allow-empty', '-m', subject)

    def release(self, version='v3', repo=None, success=True):
        result = subprocess.run([BASH, str(SCRIPT), str(self.artifact), version, 'project', 'package'],
                                cwd=repo or self.repo, env=self.env, text=True,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        if success:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn('Release upload successful', result.stdout)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertFalse(Path(self.env['CAPTURE']).exists(), 'must not upload on Git errors')
        return result

    def uploaded(self):
        return Path(self.env['CAPTURE']).read_text()

    def merged_release(self):
        self.commit('chore: root')
        self.git('tag', 'v1')
        self.git('checkout', '-b', 'release')
        self.commit('feat: already released')
        self.git('tag', '-a', 'v2', '-m', 'second release')
        self.git('checkout', 'main')
        self.commit('fix: main | keep separator')
        self.git('merge', '--no-ff', 'release', '-m', 'chore: merge release')
        self.git('tag', '-a', 'v3', '-m', 'third release')
        self.git('tag', 'v3-alias')

    def test_merge_uses_tag_on_second_parent_and_keeps_subject(self):
        self.merged_release()
        self.release()
        self.assertIn('fix: main | keep separator', self.uploaded())
        self.assertNotIn('already released', self.uploaded())
        self.assertNotIn('chore: root', self.uploaded())

    def test_first_release_on_bash_32_compatible_path(self):
        self.commit('feat: first')
        self.commit('fix: next')
        self.release()
        self.assertIn('### ✨ New Features', self.uploaded())
        self.assertIn('### 🐛 Bug Fixes', self.uploaded())

    def test_shallow_clone_fetches_full_history(self):
        self.merged_release()
        shallow = self.base / 'shallow'
        self.git('clone', '--depth=1', '--branch', 'v3', self.repo.as_uri(), str(shallow), cwd=self.base)
        result = self.release(repo=shallow)
        self.assertIn('Shallow repository detected', result.stderr)
        self.assertEqual(self.git('rev-parse', '--is-shallow-repository', cwd=shallow), 'false')
        self.assertIn('fix: main', self.uploaded())
        self.assertNotIn('already released', self.uploaded())

    def test_shallow_clone_fetch_failure_stops_upload(self):
        self.commit('chore: root')
        self.commit('fix: change')
        shallow = self.base / 'shallow'
        self.git('clone', '--depth=1', self.repo.as_uri(), str(shallow), cwd=self.base)
        self.git('remote', 'set-url', 'origin', str(self.base / 'missing'), cwd=shallow)
        result = self.release(repo=shallow, success=False)
        self.assertIn('Cannot complete Git history', result.stderr)

    def test_untrusted_owner_stops_upload_and_exposes_error(self):
        self.commit('fix: change')
        self.env['GIT_TEST_ASSUME_DIFFERENT_OWNER'] = '1'
        result = self.release(success=False)
        self.assertIn('dubious ownership', result.stderr)

    def test_exact_safe_directory_allows_mounted_repository(self):
        self.commit('fix: mounted repository')
        system_config = self.base / 'system-gitconfig'
        # Apply the same exact-path trust setting installed by the Dockerfile.
        self.git('config', '--file', str(system_config), '--add', 'safe.directory', str(self.repo.resolve()))
        self.env['GIT_CONFIG_SYSTEM'] = str(system_config)
        self.env['GIT_TEST_ASSUME_DIFFERENT_OWNER'] = '1'
        self.release()
        self.assertIn('fix: mounted repository', self.uploaded())
        dockerfile = (ROOT / 'Dockerfile').read_text()
        for mount in ('/workspace', '/github/workspace'):
            self.assertIn('safe.directory ' + mount, dockerfile)
        self.assertNotIn('safe.directory *', dockerfile)

    def test_large_changelog_reaches_upload(self):
        for index in range(35):
            self.commit('fix: %s %s' % (index, 'x' * 3000))
        self.release()
        self.assertGreater(len(self.uploaded()), 100000)
        self.assertIn('fix: 0 ', self.uploaded())
        self.assertIn('fix: 34 ', self.uploaded())

    def test_non_repository_warns_and_uploads_minimal_changelog(self):
        result = self.release(repo=self.base)
        self.assertIn('Not in a git repository', result.stderr)
        self.assertIn('- Release v3', self.uploaded())

    def test_broken_git_entry_stops_upload(self):
        broken = self.base / 'broken'
        broken.mkdir()
        (broken / '.git').write_text('gitdir: missing-repository\n')
        self.release(repo=broken, success=False)

    def test_invalid_ci_commit_stops_upload(self):
        self.commit('fix: change')
        self.env['GITHUB_SHA'] = 'nonexistent-commit'
        self.release(success=False)


if __name__ == '__main__':
    unittest.main()
