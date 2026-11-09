"""Exercise the script with real curl and a local HTTP server; no external service."""
from email.parser import BytesParser
from email.policy import default
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import threading
import unittest

ROOT = Path(__file__).resolve().parents[1]
BASH = os.environ.get('TEST_BASH', '/bin/bash')


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_HEAD(self):
        self.send_response(200)
        self.end_headers()

    def do_POST(self):
        body = self.rfile.read(int(self.headers['Content-Length']))
        message = BytesParser(policy=default).parsebytes(
            ('Content-Type: ' + self.headers['Content-Type'] + '\r\n\r\n').encode() + body)
        self.server.fields = {
            part.get_param('name', header='content-disposition'): part.get_payload(decode=True)
            for part in message.iter_parts()
        }
        self.server.posts += 1
        self.send_response(self.server.status)
        self.send_header('Content-Type', self.server.content_type)
        self.end_headers()
        self.wfile.write(self.server.response)


class HttpTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='pms-http-')
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        self.server.response = b'{"ok":true}'
        self.server.status = 200
        self.server.content_type = 'application/json'
        self.server.posts = 0
        self.server.fields = {}
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.addCleanup(self.stop_server)
        self.env = os.environ.copy()
        for key in list(self.env):
            if key.startswith(('GIT_', 'GITHUB_', 'DRONE_')):
                self.env.pop(key)
        self.env.update(ACCESS_TOKEN='synthetic-token', NO_PROXY='127.0.0.1',
                        RELEASE_URL='http://127.0.0.1:%s/release' % self.server.server_port)
        self.artifact = self.base / 'app.apk'
        self.artifact.write_bytes(b'actual artifact\x00contents')
        # Isolated tool paths allow the same cases to exercise both JSON backends.
        self.paths = {}
        required = ('curl', 'git', 'python3', 'basename', 'mktemp', 'rm', 'cat',
                    'head', 'grep', 'tail', 'tr', 'dirname')
        for backend in ('python', 'jq'):
            bindir = self.base / backend
            bindir.mkdir()
            for tool in required + (('jq',) if backend == 'jq' else ()):
                executable = shutil.which(tool)
                if executable:
                    (bindir / tool).symlink_to(executable)
            self.paths[backend] = str(bindir)

    def stop_server(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()

    def release(self, artifact=None, metadata=None, backend='jq', success=True):
        if backend == 'jq' and not shutil.which('jq'):
            self.skipTest('jq is not installed')
        env = dict(self.env, PATH=self.paths[backend])
        args = metadata or ['v1', 'project', 'package', 'artifact', 'linux', 'universal']
        result = subprocess.run([BASH, str(ROOT / 'scripts/pms-releaser.sh'),
                                 str(artifact or self.artifact), *args],
                                cwd=self.base, env=env, capture_output=True, text=True)
        if success:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn('Release upload successful', result.stdout)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertNotIn('Release upload successful', result.stdout)
        return result

    def test_single_json_value_required_for_both_backends(self):
        for backend in ('jq', 'python'):
            if backend == 'jq' and not shutil.which('jq'):
                continue
            for response in (b'', b' \n', b'{}\n{}', b'{', b'not JSON'):
                with self.subTest(backend=backend, response=response):
                    self.server.response = response
                    self.release(backend=backend, success=False)
            for response in (b'{"ok":true}', b'[]', b'null', b'false'):
                with self.subTest(backend=backend, response=response):
                    self.server.response = response
                    self.release(backend=backend)

    def test_text_fields_are_literal(self):
        private = self.base / 'synthetic-private-data'
        private.write_text('DO_NOT_UPLOAD_THIS_MARKER')
        metadata = ['@' + str(private), '<' + str(private), '@' + str(private),
                    'artifact;type=text/plain', '<linux', '@universal']
        self.env.update(GITHUB_REF='refs/tags/@release', GITHUB_SHA='', GITHUB_REF_NAME='@release')
        self.release(metadata=metadata)
        for key, value in zip(('version', 'project_name', 'package_name', 'artifact', 'os', 'arch'), metadata):
            self.assertEqual(self.server.fields[key], value.encode())
        self.assertEqual(self.server.fields['drone_tag'], b'@release')
        self.assertFalse(any(b'DO_NOT_UPLOAD_THIS_MARKER' in value for value in self.server.fields.values()))

    def test_special_file_and_temp_paths(self):
        tmpdir = self.base / 'temp;,"\\ space'
        tmpdir.mkdir()
        self.env['TMPDIR'] = str(tmpdir)
        for filename in ('app;debug.apk', 'app,debug.apk', 'app"\\ spaced.apk', '@应用.apk'):
            with self.subTest(filename=filename):
                artifact = self.base / filename
                artifact.write_bytes(self.artifact.read_bytes())
                self.release(artifact=artifact)
                self.assertEqual(self.server.fields['file'], self.artifact.read_bytes())
                self.assertIn(b'- Release v1', self.server.fields['changelog'])
                self.assertEqual(list(tmpdir.iterdir()), [])

    def test_http_failures_and_html_do_not_report_success_or_retry(self):
        for status, content_type, response in (
            (500, 'application/json', b'{"error":"failed"}'),
            (302, 'application/json', b'{}'),
            (200, 'text/html', b'<html>frontend</html>'),
        ):
            with self.subTest(status=status, content_type=content_type):
                self.server.status = status
                self.server.content_type = content_type
                self.server.response = response
                posts_before = self.server.posts
                self.release(success=False)
                self.assertEqual(self.server.posts, posts_before + 1)


if __name__ == '__main__':
    unittest.main()
