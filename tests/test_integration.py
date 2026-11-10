"""Small compatibility checks for the combined entrypoint and action wiring."""
import os
from pathlib import Path
import subprocess
import tempfile
import textwrap
import unittest

ROOT = Path(__file__).resolve().parents[1]
BASH = os.environ.get('TEST_BASH', '/bin/bash')


class IntegrationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='pms-integration-')
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.scripts = self.base / 'scripts'
        self.scripts.mkdir()
        (self.scripts / 'pms-releaser.sh').write_bytes((ROOT / 'scripts/pms-releaser.sh').read_bytes())
        (self.scripts / 'resolve-changelog.sh').write_bytes((ROOT / 'scripts/resolve-changelog.sh').read_bytes())
        self.env = dict(os.environ, CAPTURE=str(self.base / 'captured'),
                        COLLECTED=str(self.base / 'collected'))
        for key in list(self.env):
            if key.startswith(('GIT_', 'GITHUB_')):
                self.env.pop(key)
        (self.scripts / 'collect-changelog.sh').write_text('''#!/bin/bash
printf '%s' "$1" > "$COLLECTED"
printf '## %s\\n' "$1" > "$2"
''')
        (self.scripts / 'pms-publish.sh').write_text('''#!/bin/bash
printf '%s\\n' "$@" > "$CAPTURE"
cat "$5" > "$CAPTURE.notes"
exit "${PUBLISH_EXIT:-0}"
''')

    def run_wrapper(self, *extra):
        return subprocess.run([BASH, str(self.scripts / 'pms-releaser.sh'),
                               'app.apk', 'v1', 'project', 'package', *extra],
                              cwd=self.base, env=self.env, capture_output=True, text=True)

    def test_old_arguments_collect_then_publish_and_cleanup(self):
        result = self.run_wrapper('MyApp', 'linux', 'arm64')
        self.assertEqual(result.returncode, 0, result.stderr)
        args = Path(self.env['CAPTURE']).read_text().splitlines()
        self.assertEqual(args[:4], ['app.apk', 'v1', 'project', 'package'])
        self.assertEqual(args[5:], ['MyApp', 'linux', 'arm64'])
        self.assertEqual(Path(self.env['CAPTURE'] + '.notes').read_text(), '## v1\n')
        self.assertFalse(Path(args[4]).exists(), 'temporary notes must be cleaned up')

    def test_supplied_notes_skip_collection_and_preserve_file(self):
        notes = self.base / 'existing.md'
        notes.write_text('Provided notes')
        result = self.run_wrapper('', '', '', str(notes))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(Path(self.env['COLLECTED']).exists())
        self.assertEqual(notes.read_text(), 'Provided notes')
        self.assertEqual(Path(self.env['CAPTURE'] + '.notes').read_text(), 'Provided notes')

    def test_default_changelog_extracts_version(self):
        (self.base / 'CHANGELOG.md').write_text('# History\n\n## [1] - 2026-11-10\n\n- Fixed\n\n## 0\n- Old\n')
        result = self.run_wrapper()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(Path(self.env['COLLECTED']).exists())
        notes = Path(self.env['CAPTURE'] + '.notes').read_text()
        self.assertIn('- Fixed', notes)
        self.assertNotIn('- Old', notes)

    def test_missing_version_falls_back(self):
        (self.base / 'CHANGELOG.md').write_text('## v0\n- Old\n')
        result = self.run_wrapper()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(Path(self.env['COLLECTED']).exists())

    def test_invalid_sections_prevent_publish(self):
        for content in ('## v1\n\n', '## v1\n- A\n## [1]\n- B\n'):
            with self.subTest(content=content):
                (self.base / 'CHANGELOG.md').write_text(content)
                result = self.run_wrapper()
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(Path(self.env['CAPTURE']).exists())

    def test_publisher_failure_propagates_and_cleans_up(self):
        self.env['PUBLISH_EXIT'] = '9'
        result = self.run_wrapper()
        self.assertEqual(result.returncode, 9)
        args = Path(self.env['CAPTURE']).read_text().splitlines()
        self.assertFalse(Path(args[4]).exists())

    def test_collector_failure_prevents_upload(self):
        (self.scripts / 'collect-changelog.sh').write_text('exit 4\n')
        result = self.run_wrapper()
        self.assertEqual(result.returncode, 4)
        self.assertFalse(Path(self.env['CAPTURE']).exists())

    def test_composite_action_exposes_reusable_workspace_file(self):
        action = (ROOT / 'actions/changelog/action.yml').read_text()
        command = textwrap.dedent(action.split('      run: |\n', 1)[1])
        output = self.base / 'action-output'
        env = dict(self.env, GITHUB_WORKSPACE=str(self.base), GITHUB_OUTPUT=str(output),
                   RELEASE_VERSION='v1', COLLECTOR=str(ROOT / 'scripts/resolve-changelog.sh'))
        result = subprocess.run([BASH, '-c', command], cwd=self.base, env=env,
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        key, path = output.read_text().strip().split('=', 1)
        self.assertEqual(key, 'changelog_file')
        self.assertFalse(Path(path).is_absolute(), 'Docker Actions must reuse a workspace-relative path')
        self.assertIn('- Release v1', (self.base / path).read_text())

    def test_installed_command_alias_finds_sibling_scripts(self):
        alias = self.scripts / 'pms-releaser'
        alias.symlink_to(self.scripts / 'pms-releaser.sh')
        result = subprocess.run([BASH, str(alias), 'app.apk', 'v1', 'project', 'package'],
                                cwd=self.base, env=self.env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(Path(self.env['CAPTURE'] + '.notes').read_text(), '## v1\n')


if __name__ == '__main__':
    unittest.main()
