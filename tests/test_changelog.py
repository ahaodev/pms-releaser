"""Git collector regressions; no PMS credentials or upload client needed.

Run: python3 -m unittest discover -s tests -v
"""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / 'scripts/collect-changelog.sh'
BASH = os.environ.get('TEST_BASH', '/bin/bash')


class ChangelogTests(unittest.TestCase):
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
        self.env.pop('ACCESS_TOKEN', None)
        self.env.pop('RELEASE_URL', None)
        self.env.update(GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_SYSTEM=os.devnull)
        self.git('init', '-b', 'main')
        self.git('config', 'user.name', 'Release Test')
        self.git('config', 'user.email', 'test@example.invalid')
        self.output = self.base / 'changelog.md'

    def git(self, *args, cwd=None):
        return subprocess.check_output(['git', *args], cwd=cwd or self.repo,
                                       env=self.env, stderr=subprocess.PIPE, text=True).strip()

    def commit(self, subject):
        self.git('commit', '--allow-empty', '-m', subject)

    def collect(self, version='v3', repo=None, success=True):
        result = subprocess.run([BASH, str(SCRIPT), version, str(self.output)],
                                cwd=repo or self.repo, env=self.env, text=True,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        if success:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual(result.stdout, '', 'file mode should keep stdout clean')
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertFalse(self.output.exists(), 'must not write partial notes on Git errors')
        return result

    def collected(self):
        return self.output.read_text()

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
        self.collect()
        self.assertIn('fix: main | keep separator', self.collected())
        self.assertNotIn('already released', self.collected())
        self.assertNotIn('chore: root', self.collected())

    def test_first_release_on_bash_32_compatible_path(self):
        self.commit('feat: first')
        self.commit('fix: next')
        self.collect()
        self.assertIn('### ✨ New Features', self.collected())
        self.assertIn('### 🐛 Bug Fixes', self.collected())

    def test_shallow_clone_fetches_full_history(self):
        self.merged_release()
        shallow = self.base / 'shallow'
        self.git('clone', '--depth=1', '--branch', 'v3', self.repo.as_uri(), str(shallow), cwd=self.base)
        result = self.collect(repo=shallow)
        self.assertIn('Shallow repository detected', result.stderr)
        self.assertEqual(self.git('rev-parse', '--is-shallow-repository', cwd=shallow), 'false')
        self.assertIn('fix: main', self.collected())
        self.assertNotIn('already released', self.collected())

    def test_shallow_clone_fetch_failure_stops_collection(self):
        self.commit('chore: root')
        self.commit('fix: change')
        shallow = self.base / 'shallow'
        self.git('clone', '--depth=1', self.repo.as_uri(), str(shallow), cwd=self.base)
        self.git('remote', 'set-url', 'origin', str(self.base / 'missing'), cwd=shallow)
        result = self.collect(repo=shallow, success=False)
        self.assertIn('Cannot complete Git history', result.stderr)

    def test_untrusted_owner_stops_collection_and_exposes_error(self):
        self.commit('fix: change')
        self.env['GIT_TEST_ASSUME_DIFFERENT_OWNER'] = '1'
        result = self.collect(success=False)
        self.assertIn('dubious ownership', result.stderr)

    def test_exact_safe_directory_allows_mounted_repository(self):
        self.commit('fix: mounted repository')
        system_config = self.base / 'system-gitconfig'
        # Apply the same exact-path trust setting installed by the Dockerfile.
        self.git('config', '--file', str(system_config), '--add', 'safe.directory', str(self.repo.resolve()))
        self.env['GIT_CONFIG_SYSTEM'] = str(system_config)
        self.env['GIT_TEST_ASSUME_DIFFERENT_OWNER'] = '1'
        self.collect()
        self.assertIn('fix: mounted repository', self.collected())
    def test_large_changelog_written(self):
        for index in range(35):
            self.commit('fix: %s %s' % (index, 'x' * 3000))
        self.collect()
        self.assertGreater(len(self.collected()), 100000)
        self.assertIn('fix: 0 ', self.collected())
        self.assertIn('fix: 34 ', self.collected())

    def test_non_repository_warns_and_collects_minimal_changelog(self):
        result = self.collect(repo=self.base)
        self.assertIn('Not in a git repository', result.stderr)
        self.assertIn('- Release v3', self.collected())

    def test_broken_git_entry_stops_collection(self):
        broken = self.base / 'broken'
        broken.mkdir()
        (broken / '.git').write_text('gitdir: missing-repository\n')
        self.collect(repo=broken, success=False)

    def test_invalid_ci_commit_stops_collection(self):
        self.commit('fix: change')
        self.env['GITHUB_SHA'] = 'nonexistent-commit'
        self.collect(success=False)

    def test_stdout_matches_file_output_without_credentials(self):
        self.commit('feat: independent collection')
        self.collect()
        result = subprocess.run([BASH, str(SCRIPT), 'v3'], cwd=self.repo,
                                env=self.env, capture_output=True, text=True, check=True)
        self.assertEqual(result.stdout, self.collected())
        self.assertIn('feat: independent collection', result.stdout)

    def test_missing_version_fails(self):
        result = subprocess.run([BASH, str(SCRIPT)], cwd=self.repo,
                                env=self.env, capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Usage:', result.stderr)


if __name__ == '__main__':
    unittest.main()
