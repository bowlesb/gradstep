"""Local operator tests. Fake HTTP and actual 001–011 in disposable localhost SQL."""
import copy
import importlib.util
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import tempfile
import time
import unittest
from unittest.mock import patch
import uuid

SPEC = importlib.util.spec_from_file_location('pdf_probe_operator', Path(__file__).with_name('run.py'))
OP = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(OP)
RUN = '11111111-1111-4111-8111-111111111111'
USER = '22222222-2222-4222-8222-222222222222'
FUNCTION = '33333333-3333-4333-8333-333333333333'
ISOLATE = '44444444-4444-4444-8444-444444444444'
EXECUTION = '55555555-5555-4555-8555-555555555555'


def journal():
    created = int(time.time() * 1000)
    return {'format': 1, 'project': OP.PROJECT, 'organization': OP.ORGANIZATION, 'run_id': RUN, 'user_id': USER,
            'function_slug': OP.MARKER + '-' + RUN[:8], 'source_manifest_sha256': 'a' * 64,
            'created_at': created, 'expires_at': created + 1200000, 'function_identity': None,
            'auth_attempted': True, 'auth_confirmed': True, 'deploy_attempted': True, 'deploy_confirmed': True,
            'auth_absent': False, 'function_absent': False, 'cleanup_complete': False, 'phase': 'deployed'}


def remote_function(value):
    return {'id': FUNCTION, 'slug': value['function_slug'], 'name': value['function_slug'], 'version': 1,
            'status': 'ACTIVE', 'created_at': value['created_at'], 'updated_at': value['created_at'],
            'ezbr_sha256': 'b' * 64, 'verify_jwt': False}


def synthetic_user(value):
    return {'id': value['user_id'], 'email': 'pdf-probe-' + value['run_id'] + '@science-reader.invalid',
            'app_metadata': {'science_reader_check': OP.MARKER, 'check_run_id': value['run_id'],
                             'source_manifest_sha256': value['source_manifest_sha256']}}


class FakeResponse:
    def __init__(self, status=200, raw=b'{}', headers=None):
        self.status, self.raw, self.headers = status, raw, headers or {}

    def getheader(self, name):
        return self.headers.get(name)

    def read1(self, size):
        value, self.raw = self.raw[:size], self.raw[size:]
        return value

    def close(self):
        pass


class FakeConnection:
    sock = None

    def __init__(self, response):
        self.response, self.calls, self.closed = response, [], False

    def request(self, *args, **kwargs):
        self.calls.append((args, kwargs))

    def getresponse(self):
        return self.response

    def close(self):
        self.closed = True


class FakeAPI:
    management = 'synthetic-pat-not-real'
    anon = 'synthetic-anon-not-real'

    def __init__(self, value=None):
        self.user = synthetic_user(value) if value else None
        self.current_function = remote_function(value) if value else None
        self.account = value is not None
        self.calls, self.invocations = [], []
        self.transport = self
        self.fail_after_delete = False
        self.private_state = False
        self.auth_create_lost = False
        self.auth_create_status = 201
        self.fail_fixture = None
        self.diagnostic_fixture = None
        self.diagnostic = {'stage': 'initialization', 'code': 'unknown', 'error_class': 'WebAssembly.CompileError',
                           'observed_outcome': None, 'observed_pages': None}
        self.ordinal = 0
        self.fixture_map = {row['name']: row for row in json.loads(OP.package.checked(
            OP.package.ARTIFACTS / 'fixtures/manifest.json', OP.package.FIXTURE_MANIFEST_SHA256))}
        self.identity = json.loads(OP.package.checked(OP.package.reviewed_bundle() / 'identity.json', OP.package.BUILD_SHA256))

    def function(self, slug):
        self.calls.append(('function', slug))
        return copy.deepcopy(self.current_function)

    def management_request(self, suffix='', method='GET', body=None, expected=(200,), limit=65536):
        self.calls.append(('management', method, suffix, expected))
        if method == 'DELETE':
            assert expected == (200,)
            self.current_function = None
            if self.fail_after_delete:
                raise OP.ProbeError('transport_uncertain')
            return 200, None, {}
        raise AssertionError('Unexpected fake management request')

    def auth(self, path, method='GET', body=None, admin=False, token=None, expected=(200,)):
        self.calls.append(('auth', method, path, expected))
        if path == '/admin/users' and method == 'POST':
            assert admin and self.auth_create_status in expected
            self.user = {key: copy.deepcopy(body[key]) for key in ('id', 'email', 'app_metadata')}
            self.account = True
            if self.auth_create_lost:
                raise OP.ProbeError('transport_uncertain')
            return self.auth_create_status, copy.deepcopy(self.user), {}
        if path == '/token?grant_type=password':
            return 200, {'user': copy.deepcopy(self.user), 'access_token': 'synthetic.session.token.only'}, {}
        if path == '/user':
            return 200, copy.deepcopy(self.user), {}
        if path.startswith('/admin/users/'):
            if method == 'DELETE':
                assert admin and not self.account and expected == (200, 204)
                self.user = None
                return 204, None, {}
            status = 200 if self.user else 404
            if status not in expected:
                raise OP.ProbeError('http_' + str(status))
            return status, copy.deepcopy(self.user), {}
        raise AssertionError('Unexpected fake Auth request')

    def query(self, query, read_only=False):
        self.calls.append(('query', read_only))
        if read_only:
            return [{'present': self.account}]
        assert 'probe_account_not_pristine' in query
        if self.private_state:
            raise OP.ProbeError('http_400')
        self.account = False
        return []

    def deploy(self, work, slug, management):
        assert work == OP.ROOT / '.artifacts/pdf-verifier/hosted' / self.user['app_metadata']['check_run_id']
        assert management == self.management
        current = OP.read_json(work / 'cleanup-journal.json')
        assert current['deploy_attempted'] and not current['deploy_confirmed']
        self.current_function = remote_function(current)

    def request(self, host, path, method, body, headers, expected, timeout):
        assert host == OP.HOST and path == '/functions/v1/' + self.current_function['slug'] and method == 'POST'
        self.invocations.append(copy.deepcopy(body))
        if 'Authorization' not in headers:
            return 401, {'error': 'unauthorized'}, {}
        if body['run_id'] != self.user['app_metadata']['check_run_id'] or set(body) != {'run_id', 'fixture'}:
            return 400, {'error': 'invalid_request'}, {}
        if body['fixture'] == self.fail_fixture:
            raise OP.ProbeError('transport_uncertain')
        self.ordinal += 1
        fixture = self.fixture_map[body['fixture']]
        result = {'outcome': fixture['expected'], 'bytes': fixture['bytes'], 'sha256': fixture['sha256'],
                  'profileID': self.identity['profile']['id'], 'profileSHA256': self.identity['profile_sha256'],
                  'wasmSHA256': self.identity['wasm_sha256'], 'elapsedMS': 12.5}
        if fixture['expected'] == 'verified':
            result['pages'] = fixture['pages']
        value = {'run_id': body['run_id'], 'fixture': body['fixture'], 'build_sha256': OP.package.BUILD_SHA256,
                     'execution_id': EXECUTION, 'deployment_id': OP.PROJECT + '_' + FUNCTION + '_1',
                     'isolate_id': ISOLATE, 'ordinal': self.ordinal, 'cold': self.ordinal == 1,
                     'initialization_wall_ms': 18 if self.ordinal == 1 else 0,
                     'runtime': {'deno': '2.1.4', 'v8': '13.0', 'typescript': '5.6.2'},
                     'result': result, 'memory_snapshot': {'rss': 120000000, 'heapTotal': 2000000, 'heapUsed': 1000000, 'external': 68000000},
                     'hosted_admitted': False, 'cpu_ms': None, 'peak_memory_bytes': None}
        if body['fixture'] == self.diagnostic_fixture:
            value.pop('result')
            value.pop('memory_snapshot')
            value.update({'error': 'probe_failed', 'diagnostic': copy.deepcopy(self.diagnostic), 'initialization_wall_ms': None})
            return 500, value, {}
        return 200, value, {}


class OperatorTests(unittest.TestCase):
    def test_packaging_selects_reviewed_bundle_independent_of_live_runtime(self):
        run_id = str(uuid.uuid4())
        work = OP.package.ARTIFACTS / 'hosted' / run_id
        self.addCleanup(shutil.rmtree, work, True)
        bundle = OP.package.reviewed_bundle()
        with tempfile.TemporaryDirectory() as temporary:
            source = Path(temporary)
            (source / 'hosted').mkdir()
            for name in ('index.ts.in', 'handler.ts'):
                shutil.copyfile(OP.package.SOURCE / 'hosted' / name, source / 'hosted' / name)
            (source / 'runtime.ts').write_text('throw new Error("unreviewed working source");')
            (source / 'wasm.ts').write_text('throw new Error("unreviewed inspector");')
            with patch.object(OP.package, 'SOURCE', source):
                built = OP.package.build(run_id, str(uuid.uuid4()), int(time.time() * 1000))
        packaged = work / 'supabase/functions' / built['function']
        self.assertEqual((packaged / 'runtime.ts').read_bytes(), (bundle / 'runtime.ts').read_bytes())
        self.assertEqual((packaged / 'wasm.ts').read_bytes(), (bundle / 'wasm.ts').read_bytes())
        self.assertEqual(built['config']['buildSHA256'], OP.package.BUILD_SHA256)

    def test_missing_pinned_bundle_does_not_fall_back_to_current_or_dist(self):
        run_id = str(uuid.uuid4())
        work = OP.package.ARTIFACTS / 'hosted' / run_id
        with patch.object(OP.package, 'BUILD_SHA256', '0' * 64):
            with self.assertRaises(ValueError):
                OP.package.build(run_id, str(uuid.uuid4()), int(time.time() * 1000))
        self.assertFalse(work.exists())

    def test_transport_refuses_redirects_bounds_actual_bytes_and_redacts_errors(self):
        for status in (301, 302, 303, 307, 308):
            connection = FakeConnection(FakeResponse(status, b'private-token', {'Location': 'https://elsewhere.invalid'}))
            transport = OP.JSONTransport(lambda *args: connection)
            with self.subTest(status=status), self.assertRaisesRegex(OP.ProbeError, '^redirect_refused$'):
                transport.request(OP.MANAGEMENT, '/v1/projects/' + OP.PROJECT, headers={'Authorization': 'private-token'})
            self.assertEqual(len(connection.calls), 1)
            self.assertTrue(connection.closed)
        for response, message in [(FakeResponse(raw=b' ' * 65537, headers={'Content-Length': '1'}), 'response_limit'),
                                  (FakeResponse(raw=b'private-token'), 'invalid_remote_json'),
                                  (FakeResponse(500, b'{"token":"private-token"}'), 'http_500'),
                                  (FakeResponse(raw=b'{}', headers={'Content-Encoding': 'gzip'}), 'response_encoding')]:
            connection = FakeConnection(response)
            with self.subTest(message=message), self.assertRaisesRegex(OP.ProbeError, '^' + message + '$'):
                OP.JSONTransport(lambda *args: connection).request(OP.HOST, '/auth/v1/user')
            self.assertTrue(connection.closed)
        with self.assertRaisesRegex(OP.ProbeError, 'invalid_remote_path'):
            OP.JSONTransport(lambda *args: self.fail('must not connect')).request('another-project.supabase.co', '/')

    def test_expected_http_sets_include_empty_auth_delete_and_create_201(self):
        for status, expected in ((201, (200, 201)), (204, (200, 204)), (200, (200,))):
            connection = FakeConnection(FakeResponse(status, b''))
            self.assertEqual(OP.JSONTransport(lambda *args: connection).request(OP.HOST, '/auth/v1/admin/users', expected=expected)[:2], (status, None))

    def test_detached_close_delimited_socket_keeps_total_wall_deadline(self):
        now, timeouts = [0], []

        class Socket:
            def fileno(self):
                return 3

            def settimeout(self, value):
                timeouts.append(value)

        class Response(FakeResponse):
            def read1(self, size):
                now[0] += 5
                return super().read1(size)

        class Detached(FakeConnection):
            def request(self, *args, **kwargs):
                self.sock = Socket()
                super().request(*args, **kwargs)

            def getresponse(self):
                now[0] += 10
                self.sock = None
                return self.response

        connection = Detached(Response(raw=b'{}'))
        result = OP.JSONTransport(lambda *args: connection, lambda: now[0]).request(OP.HOST, '/auth/v1/user', timeout=45)
        self.assertEqual(result[:2], (200, {}))
        self.assertEqual(timeouts, [45, 35, 30, 25])
        self.assertTrue(connection.closed)

    def test_finished_close_delimited_socket_does_not_turn_eof_into_an_error(self):
        class Socket:
            closed = False

            def fileno(self):
                return -1 if self.closed else 3

            def settimeout(self, value):
                if self.closed:
                    raise OSError('closed socket')

        socket = Socket()

        class Response(FakeResponse):
            def read1(self, size):
                value = super().read1(size)
                socket.closed = True
                return value

        class Detached(FakeConnection):
            def request(self, *args, **kwargs):
                self.sock = socket

            def getresponse(self):
                self.sock = None
                return self.response

        connection = Detached(Response(raw=b'{}'))
        self.assertEqual(OP.JSONTransport(lambda *args: connection).request(OP.HOST, '/auth/v1/user')[:2], (200, {}))

    def test_rejecting_detached_real_http_response_closes_its_socket_owner(self):
        client, server = socket.socketpair()
        self.addCleanup(client.close)
        self.addCleanup(server.close)
        server.sendall(b'HTTP/1.1 200 OK\r\nConnection: close\r\nContent-Length: 65537\r\n\r\n')
        response = OP.http.client.HTTPResponse(client)
        response.begin()

        class Detached(FakeConnection):
            def request(self, *args, **kwargs):
                self.sock = client

            def getresponse(self):
                self.sock = None
                client.close()  # Response's makefile keeps the descriptor alive.
                return response

        connection = Detached(response)
        with self.assertRaisesRegex(OP.ProbeError, '^response_limit$'):
            OP.JSONTransport(lambda *args: connection).request(OP.HOST, '/auth/v1/user')
        self.assertTrue(response.isclosed())
        self.assertEqual(client.fileno(), -1)

    def test_project_guard_rejects_other_org_project_and_nonstaging_environment(self):
        manifest = {'organization': {'slug': OP.ORGANIZATION}, 'projects': {'staging': {'id': OP.PROJECT}}}
        env = {'SUPABASE_PROJECT_REF': OP.PROJECT, 'SUPABASE_URL': 'https://' + OP.HOST}
        remote = {'id': OP.PROJECT, 'organization_id': OP.ORGANIZATION, 'name': 'science-reader-staging'}
        OP.check_project(manifest, env, remote)
        for patch in ({'id': 'other'}, {'organization_id': 'other'}, {'name': 'science-reader-production'}):
            with self.assertRaises(OP.ProbeError):
                OP.check_project(manifest, env, {**remote, **patch})

    def test_cleanup_pins_identity_handles_lost_delete_and_contains_no_credentials(self):
        value = journal()
        value['function_identity'] = OP.function_identity(remote_function(value), value)
        api = FakeAPI(value)
        api.fail_after_delete = True
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'journal.json'
            self.assertEqual(OP.cleanup(api, value, path), [])
            written = OP.read_json(path)
            self.assertTrue(written['cleanup_complete'])
            self.assertEqual(written['function_identity']['id'], FUNCTION)
            encoded = path.read_text()
            for secret in (api.management, api.anon, 'synthetic.session.token.only', 'password'):
                self.assertNotIn(secret, encoded)
        self.assertFalse(api.account)
        self.assertIsNone(api.user)
        self.assertEqual(sum(call[:2] == ('management', 'DELETE') for call in api.calls), 1)

    def test_changed_function_or_unproven_deployment_never_deletes_by_slug(self):
        for changed in ('id', 'hash', 'unproven-present', 'unproven-absent'):
            value = journal()
            value['function_identity'] = OP.function_identity(remote_function(value), value)
            api = FakeAPI(value)
            if changed == 'id':
                api.current_function['id'] = str(uuid.uuid4())
            elif changed == 'hash':
                api.current_function['ezbr_sha256'] = 'c' * 64
            else:
                value['deploy_confirmed'], value['function_identity'] = False, None
                if changed == 'unproven-absent':
                    api.current_function = None
            with tempfile.TemporaryDirectory() as directory:
                path = Path(directory) / 'journal.json'
                failures = OP.cleanup(api, value, path)
                self.assertTrue(failures)
                self.assertFalse(OP.read_json(path)['cleanup_complete'])
            self.assertIsNone(api.user)  # Independent cleanup still completes.
            self.assertFalse(any(call[:2] == ('management', 'DELETE') for call in api.calls))

    def test_cleanup_cannot_adopt_an_unpinned_function_after_cli_success(self):
        value = journal()
        api = FakeAPI(value)
        with tempfile.TemporaryDirectory() as directory:
            self.assertEqual(OP.cleanup(api, value, Path(directory) / 'journal.json'), ['deployment_identity_unproven'])
        self.assertFalse(any(call[:2] == ('management', 'DELETE') for call in api.calls))
        self.assertIsNone(api.user)

    def test_auth_marker_or_private_state_guard_preserves_user_and_journal(self):
        for reason in ('marker', 'private_state', 'unknown_creation'):
            value = journal()
            api = FakeAPI(value)
            if reason == 'marker':
                api.user['app_metadata']['check_run_id'] = str(uuid.uuid4())
            elif reason == 'private_state':
                api.private_state = True
            else:
                value['auth_confirmed'] = False
                api.user = None
            with tempfile.TemporaryDirectory() as directory:
                path = Path(directory) / 'journal.json'
                self.assertTrue(OP.cleanup(api, value, path))
                self.assertFalse(OP.read_json(path)['cleanup_complete'])
            self.assertFalse(any(call[:2] == ('auth', 'DELETE') for call in api.calls))

    def local_run(self, api, deploy=None):
        run_id, user_id = str(uuid.uuid4()), str(uuid.uuid4())
        work = OP.ROOT / '.artifacts/pdf-verifier/hosted' / run_id
        self.addCleanup(shutil.rmtree, work, True)
        return run_id, user_id, work, lambda: OP.run_probe(api, run_id, user_id, deploy or api.deploy)

    def test_complete_operator_runs_exactly_15_serial_calls_and_post_oom_valid_fixture(self):
        for create_status in (200, 201):
            api = FakeAPI()
            api.auth_create_status = create_status
            _, _, work, execute = self.local_run(api)
            self.assertEqual(execute(), work)
            evidence = OP.read_json(work / 'evidence.json')
            self.assertEqual(len(api.invocations), 15)
            cases = [row['case'] for row in evidence['requests']]
            self.assertEqual(cases[:3], ['no_auth', 'bad_run', 'extra_input'])
            self.assertEqual(cases[cases.index('object-stream-oom') + 1], 'pages-1-after-oom')
            self.assertTrue(all(row['state'] == 'passed' for row in evidence['requests']))
            self.assertTrue(evidence['cleanup_verified'])
            self.assertFalse(evidence['hosted_admitted'])
            self.assertIsNone(api.current_function)
            for secret in (api.management, api.anon, 'synthetic.session.token.only'):
                self.assertNotIn(secret, (work / 'evidence.json').read_text() + (work / 'cleanup-journal.json').read_text())

    def test_ambiguous_execution_stops_without_retry_and_cleanup_still_verifies(self):
        api = FakeAPI()
        api.fail_fixture = 'pages-25'
        _, _, work, execute = self.local_run(api)
        with self.assertRaisesRegex(OP.ProbeError, '^transport_uncertain$'):
            execute()
        evidence = OP.read_json(work / 'evidence.json')
        self.assertEqual([body['fixture'] for body in api.invocations].count('pages-25'), 1)
        self.assertEqual(evidence['requests'][-1]['state'], 'failed_or_uncertain')
        self.assertTrue(evidence['cleanup_verified'])

    def test_http500_retains_only_validated_diagnostic_identity_before_stopping(self):
        api = FakeAPI()
        api.diagnostic_fixture = 'pages-1'
        _, _, work, execute = self.local_run(api)
        with self.assertRaisesRegex(OP.ProbeError, '^unexpected_probe_status$'):
            execute()
        evidence = OP.read_json(work / 'evidence.json')
        self.assertEqual(len(api.invocations), 4)
        attempt = evidence['requests'][-1]
        self.assertEqual(attempt['http_status'], 500)
        self.assertEqual(attempt['state'], 'failed_or_uncertain')
        diagnostic = attempt['diagnostic']
        self.assertEqual(diagnostic['diagnostic'], api.diagnostic)
        self.assertEqual(diagnostic['deployment_id'], OP.PROJECT + '_' + FUNCTION + '_1')
        self.assertEqual(diagnostic['execution_id'], EXECUTION)
        self.assertEqual(diagnostic['isolate_id'], ISOLATE)
        self.assertEqual(diagnostic['ordinal'], 1)
        self.assertTrue(diagnostic['cold'])
        self.assertIsNone(diagnostic['initialization_wall_ms'])
        self.assertFalse(diagnostic['hosted_admitted'])
        self.assertTrue(evidence['cleanup_verified'])

    def test_http500_unknown_or_extra_diagnostic_data_is_never_archived(self):
        patches = [{'stack': 'private token and document'}, {'code': 'invalid_profile: private token'},
                   {'stage': ['private']}, {'error_class': 'PrivateRuntimeError'},
                   {'observed_outcome': 'private paper'}, {'observed_pages': 2_147_483_648},
                   {'observed_pages': True}, {'observed_outcome': 'verified'}]
        for patch in patches:
            api = FakeAPI()
            api.diagnostic_fixture = 'pages-1'
            api.diagnostic.update(patch)
            _, _, work, execute = self.local_run(api)
            with self.subTest(patch=patch), self.assertRaisesRegex(OP.ProbeError, '^invalid_probe_diagnostic$'):
                execute()
            evidence = OP.read_json(work / 'evidence.json')
            self.assertNotIn('diagnostic', evidence['requests'][-1])
            self.assertNotIn('private', (work / 'evidence.json').read_text())
            self.assertEqual(len(api.invocations), 4)
            self.assertTrue(evidence['cleanup_verified'])

    def test_result_mismatch_diagnostics_keep_only_known_outcome_and_bounded_pages(self):
        api = FakeAPI()
        api.diagnostic_fixture = 'pages-1'
        api.diagnostic = {'stage': 'result_check', 'code': 'probe_result_mismatch', 'error_class': 'Error',
                          'observed_outcome': 'page_limit', 'observed_pages': 51}
        _, _, work, execute = self.local_run(api)
        with self.assertRaisesRegex(OP.ProbeError, '^unexpected_probe_status$'):
            execute()
        self.assertEqual(OP.read_json(work / 'evidence.json')['requests'][-1]['diagnostic']['diagnostic'], api.diagnostic)

    def test_lost_auth_creation_ack_is_reconciled_for_cleanup_without_deploy(self):
        api = FakeAPI()
        api.auth_create_lost = True
        _, _, work, execute = self.local_run(api)
        with self.assertRaisesRegex(OP.ProbeError, '^transport_uncertain$'):
            execute()
        value = OP.read_json(work / 'cleanup-journal.json')
        self.assertTrue(value['auth_confirmed'])
        self.assertTrue(value['cleanup_complete'])
        self.assertFalse(value['deploy_attempted'])
        self.assertEqual(api.invocations, [])
        self.assertEqual(OP.cleanup(api, value, work / 'cleanup-journal.json'), [])
        self.assertTrue(OP.read_json(work / 'cleanup-journal.json')['cleanup_complete'])

    def test_lost_deploy_ack_leaves_unproven_function_and_cleanup_journal(self):
        api = FakeAPI()

        def lost(*args):
            api.deploy(*args)
            raise OP.ProbeError('deployment_uncertain')

        _, _, work, execute = self.local_run(api, lost)
        with self.assertRaisesRegex(OP.ProbeError, '^cleanup_required_journal_retained$'):
            execute()
        value = OP.read_json(work / 'cleanup-journal.json')
        self.assertFalse(value['cleanup_complete'])
        self.assertTrue(value['auth_absent'])
        self.assertIsNone(value['function_identity'])
        self.assertIsNotNone(api.current_function)
        self.assertEqual(api.invocations, [])


class LocalCleanupSQLTests(unittest.TestCase):
    """Use only a uniquely named disposable database on explicit localhost."""
    @classmethod
    def setUpClass(cls):
        cls.pg = Path(os.environ.get('SCIENCE_READER_PG_BIN', '/Users/benbowlwes/textbrain/scripts/.pgtools/postgresql-18.4.0-aarch64-apple-darwin/bin'))
        cls.database = 'science_reader_probe_' + uuid.uuid4().hex[:12]
        cls.env = {key: value for key, value in os.environ.items() if not key.startswith('PG')}
        cls.env['PGCONNECT_TIMEOUT'] = '5'
        cls.command('createdb', [cls.database])
        cls.addClassCleanup(cls.command, 'dropdb', [cls.database])
        for source in [OP.ROOT / 'tests/database/bootstrap.sql', *sorted((OP.ROOT / 'supabase/migrations').glob('*.sql'))]:
            cls.command('psql', ['-X', '-qAt', '-v', 'ON_ERROR_STOP=1', '-d', cls.database, '-f', str(source)])
        cls.command('psql', ['-X', '-qAt', '-v', 'ON_ERROR_STOP=1', '-d', cls.database],
                    'alter table auth.users add column email text, add column raw_app_meta_data jsonb;')

    @classmethod
    def command(cls, name, args, source=None, expected=0):
        value = subprocess.run([str(cls.pg / name), '-h', '127.0.0.1', '-p', '55431', *args],
                               input=source, text=True, capture_output=True, env=cls.env, timeout=20)
        if value.returncode != expected:
            raise AssertionError('Disposable local SQL failed: ' + value.stderr)
        return value.stdout.strip()

    def sql(self, source, expected=0):
        return self.command('psql', ['-X', '-qAt', '-v', 'ON_ERROR_STOP=1', '-d', self.database], source, expected)

    def setUp(self):
        self.value = journal()
        self.value['user_id'] = str(uuid.uuid4())
        self.user = self.value['user_id']
        metadata = json.dumps(synthetic_user(self.value)['app_metadata'])
        # Real 001/010 triggers create account and cursor. No bootstrap RPC.
        self.sql(f"insert into auth.users values('{self.user}','pdf-probe-{RUN}@science-reader.invalid','{metadata}');")

    def test_pristine_cleanup_removes_only_account_then_allows_auth_deletion(self):
        self.sql(f"delete from auth.users where id='{self.user}';", expected=3)
        self.sql(OP.cleanup_account_sql(self.value))
        self.assertEqual(self.sql(f"select count(*) from auth.users where id='{self.user}';"), '1')
        self.assertEqual(self.sql(f"select count(*) from app_private.accounts where id='{self.user}';"), '0')
        self.assertEqual(self.sql(f"select count(*) from app_private.library_sync_state where account_id='{self.user}';"), '0')
        self.sql(f"delete from auth.users where id='{self.user}';")

    def test_private_state_marker_and_nonpristine_cursor_all_fail_closed(self):
        mutations = [lambda user: f"insert into app_private.keyrings(account_id,epoch,recovery_package,management_verifier) values('{user}',1,decode(repeat('00',28),'hex'),decode(repeat('00',32),'hex'));",
                     lambda user: f"select set_config('request.jwt.claim.sub','{user}',false); select public.v2_begin_import('{uuid.uuid4()}','2403.34567',0,null);",
                     lambda user: f"update auth.users set raw_app_meta_data='{{}}' where id='{user}';",
                     lambda user: f"update app_private.library_sync_state set last_seq=1 where account_id='{user}';"]
        for mutation in mutations:
            self.setUp()
            self.sql(mutation(self.user))
            self.sql(OP.cleanup_account_sql(self.value), expected=3)
            self.assertEqual(self.sql(f"select count(*) from app_private.accounts where id='{self.user}';"), '1')
            self.assertEqual(self.sql(f"select count(*) from auth.users where id='{self.user}';"), '1')


if __name__ == '__main__':
    unittest.main()
