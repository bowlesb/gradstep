"""Migration transport must not leak credentials or hide an ambiguous result."""
import importlib.util
import io
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import sys
import threading
import unittest
import urllib.error
import urllib.request

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'scripts'))
spec = importlib.util.spec_from_file_location('migrate_supabase', ROOT / 'scripts/migrate-supabase.py')
migration = importlib.util.module_from_spec(spec)
spec.loader.exec_module(migration)


class FakeOpener:
    def __init__(self, raw=b'[]', error=None):
        self.raw, self.error, self.calls = raw, error, []

    def open(self, request, timeout):
        self.calls.append((request, timeout))
        if self.error:
            raise self.error
        return io.BytesIO(self.raw)


class MigrationTransportTests(unittest.TestCase):
    def test_redirects_never_forward_the_fixture_credential(self):
        paths = []

        class Redirect(BaseHTTPRequestHandler):
            def do_GET(self):
                paths.append(self.path)
                if self.path == '/target':
                    self.send_response(200)
                    self.end_headers()
                    return
                self.send_response(int(self.path[1:]))
                self.send_header('Location', '/target')
                self.end_headers()

            def log_message(self, *args):
                pass

        server = ThreadingHTTPServer(('127.0.0.1', 0), Redirect)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            opener = urllib.request.build_opener(migration.NoRedirect())
            for status in [301, 302, 303, 307, 308]:
                request = urllib.request.Request(f'http://127.0.0.1:{server.server_port}/{status}',
                                                 headers={'Authorization': 'Bearer synthetic-fixture-only'})
                with self.subTest(status=status), self.assertRaisesRegex(RuntimeError, 'refused an HTTP redirect'):
                    opener.open(request, timeout=2)
            self.assertEqual(paths, [f'/{status}' for status in [301, 302, 303, 307, 308]])
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=2)

    def test_only_recorded_management_paths_are_accepted(self):
        opener = FakeOpener()
        path = 'projects/coxhjvqpflgxkleydati/database/query'
        self.assertEqual(migration.management_request(opener, 'fixture', path, {'query': 'select 1'}), [])
        request, timeout = opener.calls[0]
        self.assertEqual(request.full_url, 'https://api.supabase.com/v1/' + path)
        self.assertEqual(json.loads(request.data), {'query': 'select 1'})
        self.assertEqual(timeout, 60)
        for bad in ['https://elsewhere.invalid', '//elsewhere.invalid', path + '?redirect=x', path + '/../users']:
            with self.subTest(path=bad), self.assertRaisesRegex(RuntimeError, 'Invalid'):
                migration.management_request(opener, 'fixture', bad)
        self.assertEqual(len(opener.calls), 1)

    def test_error_and_malformed_responses_are_bounded_and_redacted(self):
        path = 'projects/coxhjvqpflgxkleydati/database/query'
        cases = [
            FakeOpener(error=urllib.error.HTTPError('private-url', 500, 'private-server-message', {}, io.BytesIO(b'private SQL'))),
            FakeOpener(error=urllib.error.URLError('private-url-and-token')),
            FakeOpener(raw=b'private-body-not-json'),
            FakeOpener(raw=b' ' * 1048577),
        ]
        for opener in cases:
            with self.subTest(opener=opener):
                with self.assertRaises(RuntimeError) as error:
                    migration.management_request(opener, 'private-token', path, {'query': 'private SQL'})
                self.assertNotIn('private', str(error.exception))
                self.assertIn('ledger before retrying', str(error.exception))
                self.assertEqual(len(opener.calls), 1)  # no implicit mutation retry

    def test_duplicate_and_malformed_ledger_rows_cannot_be_collapsed(self):
        row = {'version': '202610030011', 'sha256': 'a' * 64}
        self.assertEqual(migration.applied_ledger([row]), {row['version']: row['sha256']})
        self.assertEqual(migration.applied_ledger([]), {})  # first deployment only
        for rows in [[row, row], None, {}, [{'version': []}], [{**row, 'unexpected': True}], [{'version': 1, 'sha256': 'a'}]]:
            with self.subTest(rows=rows), self.assertRaises(RuntimeError):
                migration.applied_ledger(rows)


if __name__ == '__main__':
    unittest.main()
