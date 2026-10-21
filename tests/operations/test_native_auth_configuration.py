"""Operator contracts with fake HTTP only; never load credentials or go online."""
import copy
import importlib.util
import io
import json
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest import mock
from contextlib import redirect_stdout

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location('native_auth_configuration', ROOT / 'scripts/configure-native-auth.py')
AUTH = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(AUTH)


class FakeTransport:
    def __init__(self):
        self.project = {'id': AUTH.PROJECT, 'name': 'science-reader-staging', 'organization_id': AUTH.ORGANIZATION}
        self.reference = self.bundle_row(AUTH.REFERENCE_BUNDLE, 'REFERENCE')
        self.bundle = None
        self.prefix_rows = {}
        self.capability = None
        self.other_capabilities = []
        self.config = dict(AUTH.DESIRED_AUTH, external_apple_enabled=False, external_apple_client_id='',
            uri_allow_list='', mailer_otp_length=8, mailer_otp_exp=3600,
            mailer_templates_confirmation_content='<a>old confirmation</a>',
            mailer_templates_magic_link_content='<a>old magic link</a>',
            external_apple_additional_client_ids='', external_apple_secret='',
            external_google_enabled=False, external_google_secret='secret-google-marker',
            smtp_pass='secret-smtp-marker', external_email_enabled=True)
        self.calls = []
        self.lose_ack = None
        self.fail_without_commit = None
        self.after_capability = None

    @staticmethod
    def bundle_row(identifier, row_id='DEDICATED'):
        return {'type': 'bundleIds', 'id': row_id,
                'attributes': {'identifier': identifier, 'name': 'Science Reader', 'platform': 'IOS', 'seedId': AUTH.TEAM}}

    def request(self, host, path, token, method='GET', body=None, expected=200):
        self.calls.append((host, path, method, copy.deepcopy(body), expected))
        if self.fail_without_commit == path and method != 'GET':
            raise AUTH.ConfigurationError('transport_uncertain')
        if host == AUTH.MANAGEMENT and path == '/v1/projects/' + AUTH.PROJECT and method == 'GET':
            return copy.deepcopy(self.project)
        if host == AUTH.APPLE and path in (AUTH.bundle_query(AUTH.BUNDLE), AUTH.bundle_query(AUTH.REFERENCE_BUNDLE)):
            assert method == 'GET'
            identifier = AUTH.REFERENCE_BUNDLE if path == AUTH.bundle_query(AUTH.REFERENCE_BUNDLE) else AUTH.BUNDLE
            row = self.reference if identifier == AUTH.REFERENCE_BUNDLE else self.bundle
            rows = ([row] if row else []) + self.prefix_rows.get(identifier, [])
            return {'data': copy.deepcopy(rows), 'links': {}}
        if host == AUTH.APPLE and path == '/v1/bundleIds' and method == 'POST':
            assert expected == 201
            self.bundle = self.bundle_row(body['data']['attributes']['identifier'])
            result = {'data': copy.deepcopy(self.bundle)}
        elif (host == AUTH.APPLE and self.bundle is not None
                and path == '/v1/bundleIds/' + self.bundle['id'] + '/bundleIdCapabilities' and method == 'GET'):
            rows = ([self.capability] if self.capability else []) + self.other_capabilities
            return {'data': copy.deepcopy(rows), 'links': {}}
        elif host == AUTH.APPLE and path == '/v1/bundleIdCapabilities' and method == 'POST':
            assert expected == 201
            assert body['data']['relationships']['bundleId']['data']['id'] == self.bundle['id']
            self.capability = {'id': self.bundle['id'] + '_APPLE_ID_AUTH', 'type': 'bundleIdCapabilities',
                               'attributes': copy.deepcopy(body['data']['attributes'])}
            # Apple's read representation selects the primary option by key;
            # it does not echo the enabled flag from the POST body.
            for setting in self.capability['attributes']['settings']:
                for option in setting['options']:
                    option.pop('enabled', None)
            if self.after_capability:
                self.after_capability()
            result = {'data': copy.deepcopy(self.capability)}
        elif host == AUTH.MANAGEMENT and path == AUTH.AUTH_PATH:
            if method == 'GET':
                return copy.deepcopy(self.config)
            assert method == 'PATCH' and expected == 200
            self.config.update(copy.deepcopy(body))
            result = copy.deepcopy(self.config)
        else:
            raise AssertionError('Unexpected fake request')
        if self.lose_ack == path:
            raise AUTH.ConfigurationError('transport_uncertain')
        return result

    def mutations(self):
        return [row for row in self.calls if row[2] != 'GET']


class FakeSocket:
    def __init__(self):
        self.timeouts = []
    def fileno(self):
        return 7
    def settimeout(self, value):
        self.timeouts.append(value)


class FakeResponse:
    def __init__(self, data=b'{}', status=200, headers=None):
        self.data, self.status, self.headers = data, status, headers or {}
        self.closed = False
    def getheader(self, key):
        return self.headers.get(key)
    def read1(self, maximum):
        part, self.data = self.data[:maximum], self.data[maximum:]
        return part
    def close(self):
        self.closed = True


class FakeConnection:
    def __init__(self, response):
        self.response, self.sock, self.closed = response, FakeSocket(), False
        self.owner = self.sock
    def request(self, *args, **kwargs):
        pass
    def getresponse(self):
        self.sock = None  # Connection: close detaches the HTTPResponse socket.
        return self.response
    def close(self):
        self.closed = True


class NativeAuthConfigurationTests(unittest.TestCase):
    def remote(self, transport):
        return AUTH.Remote('management-fixture', 'apple-fixture', transport)

    def test_default_dry_run_reports_only_public_desired_fields_and_never_mutates(self):
        t = FakeTransport()
        report = AUTH.configure(self.remote(t))
        self.assertEqual(report['mode'], 'dry-run')
        self.assertTrue(report['bundle_registration_needed'])
        self.assertEqual(report['desired_public_auth_fields']['mailer_otp_length'], 6)
        self.assertEqual(report['desired_public_auth_fields']['mailer_otp_exp'], 600)
        self.assertEqual(t.mutations(), [])
        self.assertNotIn('secret-google-marker', json.dumps(report))
        self.assertNotIn('secret-smtp-marker', json.dumps(report))

    def test_apply_is_idempotent_preserves_unowned_fields_and_keeps_signup_disabled(self):
        t = FakeTransport()
        original = copy.deepcopy(t.config)
        report = AUTH.configure(self.remote(t), apply=True)
        self.assertTrue(report['configuration_verified'])
        self.assertFalse(report['live_sign_in_verified'])
        mutations = t.mutations()
        self.assertEqual([(r[1], r[2], r[4]) for r in mutations], [
            ('/v1/bundleIds', 'POST', 201), ('/v1/bundleIdCapabilities', 'POST', 201), (AUTH.AUTH_PATH, 'PATCH', 200)])
        self.assertEqual(mutations[0][3]['data']['attributes'], {
            'identifier': AUTH.BUNDLE, 'name': 'Science Reader', 'platform': 'IOS', 'seedId': AUTH.TEAM})
        self.assertEqual(mutations[1][3]['data']['attributes'], {'capabilityType': 'APPLE_ID_AUTH', 'settings': AUTH.CONSENT})
        self.assertTrue(set(mutations[2][3]).issubset(AUTH.DESIRED_AUTH))
        self.assertTrue(t.config['disable_signup'])
        for key in set(original) - set(AUTH.DESIRED_AUTH):
            self.assertEqual(t.config[key], original[key])
        AUTH.configure(self.remote(t), apply=True)
        self.assertEqual(t.mutations(), mutations)

    def test_lost_ack_for_each_mutation_uses_readback_without_replaying(self):
        for path in ('/v1/bundleIds', '/v1/bundleIdCapabilities', AUTH.AUTH_PATH):
            with self.subTest(path=path):
                t = FakeTransport(); t.lose_ack = path
                self.assertTrue(AUTH.configure(self.remote(t), apply=True)['configuration_verified'])
                self.assertEqual(sum(row[1] == path for row in t.mutations()), 1)

    def test_resume_after_registration_keeps_exact_existing_bundle_and_uses_queryless_capabilities(self):
        t = FakeTransport()
        t.bundle = t.bundle_row(AUTH.BUNDLE, '33Q7BMJ45Z')
        t.bundle['attributes']['name'] = 'Existing dedicated name'
        t.prefix_rows[AUTH.BUNDLE] = [t.bundle_row(AUTH.BUNDLE + '.watchkitapp', 'WATCHONLY')]
        t.other_capabilities = [{'id': 'OTHER', 'type': 'bundleIdCapabilities',
                                 'attributes': {'capabilityType': 'PUSH_NOTIFICATIONS'}}]
        before = copy.deepcopy(t.bundle)
        self.assertTrue(AUTH.configure(self.remote(t), apply=True)['configuration_verified'])
        self.assertEqual(t.bundle, before, 'An existing exact bundle must not be recreated or renamed')
        mutations = t.mutations()
        self.assertEqual([(r[1], r[2]) for r in mutations], [
            ('/v1/bundleIdCapabilities', 'POST'), (AUTH.AUTH_PATH, 'PATCH')])
        self.assertEqual(mutations[0][3]['data']['relationships']['bundleId']['data']['id'], '33Q7BMJ45Z')
        reads = [r[1] for r in t.calls if r[0] == AUTH.APPLE and r[2] == 'GET' and '/bundleIdCapabilities' in r[1]]
        self.assertTrue(reads)
        self.assertEqual(set(reads), {'/v1/bundleIds/33Q7BMJ45Z/bundleIdCapabilities'})
        AUTH.configure(self.remote(t), apply=True)
        self.assertEqual(t.mutations(), mutations, 'Resuming again remains idempotent')

    def test_unconfirmed_create_stops_without_retry_or_auth_mutation(self):
        t = FakeTransport(); t.fail_without_commit = '/v1/bundleIds'
        with self.assertRaisesRegex(AUTH.ConfigurationError, 'mutation_not_confirmed'):
            AUTH.configure(self.remote(t), apply=True)
        self.assertEqual(len(t.mutations()), 1)
        self.assertFalse(t.config['external_apple_enabled'])
        # A later invocation starts with GETs, not a replay hidden in the call.
        t.fail_without_commit = None
        self.assertTrue(AUTH.configure(self.remote(t), apply=True)['configuration_verified'])

    def test_actual_capability_read_shape_resumes_with_auth_patch_only(self):
        t = FakeTransport(); t.bundle = t.bundle_row(AUTH.BUNDLE, '33Q7BMJ45Z')
        t.capability = {'id': '33Q7BMJ45Z_APPLE_ID_AUTH', 'type': 'bundleIdCapabilities',
            'attributes': {'capabilityType': 'APPLE_ID_AUTH', 'settings': [
                {'key': 'APPLE_ID_AUTH_APP_CONSENT', 'options': [{'key': 'PRIMARY_APP_CONSENT'}]}]}}
        t.other_capabilities = [{'id': '33Q7BMJ45Z_IN_APP_PURCHASE', 'type': 'bundleIdCapabilities',
                                 'attributes': {'capabilityType': 'IN_APP_PURCHASE', 'settings': None}}]
        before = copy.deepcopy((t.bundle, t.capability, t.other_capabilities))
        dry = AUTH.configure(self.remote(t))
        self.assertFalse(dry['bundle_registration_needed'])
        self.assertFalse(dry['apple_capability_needed'])
        self.assertEqual(t.mutations(), [])
        self.assertTrue(AUTH.configure(self.remote(t), apply=True)['configuration_verified'])
        mutations = t.mutations()
        self.assertEqual([(r[0], r[1], r[2]) for r in mutations], [(AUTH.MANAGEMENT, AUTH.AUTH_PATH, 'PATCH')])
        self.assertEqual((t.bundle, t.capability, t.other_capabilities), before)
        AUTH.configure(self.remote(t), apply=True)
        self.assertEqual(t.mutations(), mutations)

    def test_project_team_audience_redirect_and_signup_guards_precede_writes(self):
        def foreign_exact_bundle(t):
            t.bundle = t.bundle_row(AUTH.BUNDLE)
            t.bundle['attributes']['seedId'] = 'OTHERTEAM'
        cases = [
            lambda t: t.project.update(organization_id='other-org'),
            lambda t: t.reference['attributes'].update(seedId='OTHERTEAM'),
            foreign_exact_bundle,
            lambda t: t.config.update(external_apple_client_id='com.textbrain.ios'),
            lambda t: t.config.update(external_apple_additional_client_ids='com.other.app'),
            lambda t: t.config.update(external_apple_secret='existing-web-secret'),
            lambda t: t.config.update(uri_allow_list='https://existing.example/callback'),
            lambda t: t.config.update(disable_signup=False),
        ]
        for modify in cases:
            t = FakeTransport(); modify(t)
            with self.assertRaises(AUTH.ConfigurationError):
                AUTH.configure(self.remote(t), apply=True)
            self.assertEqual(t.mutations(), [])

    def test_real_shaped_exact_and_watch_results_select_only_the_exact_reference(self):
        t = FakeTransport()
        t.reference = t.bundle_row(AUTH.REFERENCE_BUNDLE, '743HXTRX7A')
        t.reference['attributes']['platform'] = 'UNIVERSAL'
        watch = t.bundle_row(AUTH.REFERENCE_BUNDLE + '.watchkitapp', 'AR5UA8C2SU')
        watch['attributes']['platform'] = 'UNIVERSAL'
        t.prefix_rows[AUTH.REFERENCE_BUNDLE] = [watch]
        remote = self.remote(t)
        self.assertEqual(remote.bundle(AUTH.REFERENCE_BUNDLE), '743HXTRX7A')
        self.assertIsNone(remote.target_bundle_id, 'A reference lookup cannot own a capability target')
        self.assertTrue(AUTH.configure(remote)['bundle_registration_needed'])
        self.assertEqual(t.mutations(), [])

    def test_prefix_neighbour_alone_does_not_establish_or_retain_dedicated_ownership(self):
        t = FakeTransport(); t.bundle = t.bundle_row(AUTH.BUNDLE)
        remote = self.remote(t)
        self.assertEqual(remote.bundle(), 'DEDICATED')
        t.bundle = t.bundle_row(AUTH.BUNDLE + '.watchkitapp', 'WATCHONLY')
        self.assertIsNone(remote.bundle())
        self.assertIsNone(remote.target_bundle_id)
        with self.assertRaisesRegex(AUTH.ConfigurationError, 'capability_create_refused'):
            remote.apple('/v1/bundleIdCapabilities', 'POST', AUTH.capability_payload('WATCHONLY'))
        self.assertEqual(t.mutations(), [])

    def test_duplicate_exact_identifiers_refuse_even_among_prefix_neighbours(self):
        t = FakeTransport(); t.bundle = t.bundle_row(AUTH.BUNDLE)
        t.prefix_rows[AUTH.BUNDLE] = [t.bundle_row(AUTH.BUNDLE + '.watchkitapp', 'WATCH'),
                                      t.bundle_row(AUTH.BUNDLE, 'DUPLICATE')]
        with self.assertRaisesRegex(AUTH.ConfigurationError, 'ambiguous_bundle'):
            AUTH.configure(self.remote(t), apply=True)
        self.assertEqual(t.mutations(), [])

    def test_existing_grouped_or_unverified_apple_capability_is_not_overwritten(self):
        t = FakeTransport(); t.bundle = t.bundle_row(AUTH.BUNDLE)
        t.capability = {'id': 'CAPABILITY', 'type': 'bundleIdCapabilities',
                        'attributes': {'capabilityType': 'APPLE_ID_AUTH', 'settings': []}}
        with self.assertRaisesRegex(AUTH.ConfigurationError, 'primary_consent_unverified'):
            AUTH.configure(self.remote(t), apply=True)
        self.assertEqual(t.mutations(), [])

    def test_primary_selection_refuses_disabled_grouped_and_ambiguous_read_options(self):
        primary = {'key': 'PRIMARY_APP_CONSENT'}
        consent = {'key': 'APPLE_ID_AUTH_APP_CONSENT', 'options': [primary]}
        invalid = [None, [], [None], [dict(consent, options=[])],
            [dict(consent, options=[None])], [dict(consent, options=[{}])],
            [dict(consent, options=[{'key': 'GROUPED_APP_CONSENT'}])],
            [dict(consent, options=[primary, primary])],
            [dict(consent, options=[primary, {'key': 'GROUPED_APP_CONSENT', 'enabled': False}])],
            [consent, consent], [consent, {'key': 'OTHER_SETTING', 'options': []}]]
        invalid.extend([dict(consent, options=[dict(primary, enabled=value)])]
                       for value in (False, None, 0, 1, 'true'))
        for settings in invalid:
            with self.subTest(settings=settings):
                t = FakeTransport(); t.bundle = t.bundle_row(AUTH.BUNDLE)
                t.capability = {'id': 'DEDICATED_APPLE_ID_AUTH', 'type': 'bundleIdCapabilities',
                    'attributes': {'capabilityType': 'APPLE_ID_AUTH', 'settings': settings}}
                with self.assertRaisesRegex(AUTH.ConfigurationError, 'primary_consent_unverified'):
                    AUTH.configure(self.remote(t), apply=True)
                self.assertEqual(t.mutations(), [])

    def test_explicit_primary_true_remains_accepted_but_capability_id_does_not_widen_bundle_paths(self):
        t = FakeTransport(); t.bundle = t.bundle_row(AUTH.BUNDLE)
        t.capability = {'id': 'DEDICATED_APPLE_ID_AUTH', 'type': 'bundleIdCapabilities',
                       'attributes': {'capabilityType': 'APPLE_ID_AUTH', 'settings': copy.deepcopy(AUTH.CONSENT)}}
        self.assertFalse(AUTH.configure(self.remote(t))['apple_capability_needed'])
        self.assertTrue(AUTH.safe_capability_id('33Q7BMJ45Z_APPLE_ID_AUTH'))
        self.assertFalse(AUTH.safe_id('33Q7BMJ45Z_APPLE_ID_AUTH'))
        for invalid in ('', 'x' * 81, 'foreign/path', 'x?query', None):
            t.capability['id'] = invalid
            with self.assertRaisesRegex(AUTH.ConfigurationError, 'capability_identity_mismatch'):
                AUTH.configure(self.remote(t), apply=True)
        self.assertEqual(t.mutations(), [])

    def test_missing_and_ill_shaped_guard_fields_refuse_before_mutations(self):
        for key in set(AUTH.DESIRED_AUTH) | {'external_apple_additional_client_ids', 'external_apple_secret'}:
            t = FakeTransport(); del t.config[key]
            with self.assertRaisesRegex(AUTH.ConfigurationError, 'auth_config_incomplete'):
                AUTH.configure(self.remote(t), apply=True)
            self.assertEqual(t.mutations(), [])
        for key, value in [('external_apple_enabled', 'true'), ('mailer_otp_exp', True),
                           ('mailer_otp_length', '6'), ('mailer_templates_magic_link_content', None)]:
            t = FakeTransport(); t.config[key] = value
            with self.assertRaisesRegex(AUTH.ConfigurationError, 'auth_config_shape'):
                AUTH.configure(self.remote(t), apply=True)
            self.assertEqual(t.mutations(), [])

    def test_no_apple_write_can_target_the_reference_app(self):
        t = FakeTransport(); remote = self.remote(t)
        remote.bundle(AUTH.REFERENCE_BUNDLE)
        with self.assertRaisesRegex(AUTH.ConfigurationError, 'capability_create_refused'):
            remote.apple('/v1/bundleIdCapabilities', 'POST', AUTH.capability_payload('REFERENCE'))
        foreign = AUTH.bundle_payload(); foreign['data']['attributes']['identifier'] = AUTH.REFERENCE_BUNDLE
        with self.assertRaisesRegex(AUTH.ConfigurationError, 'bundle_create_refused'):
            remote.apple('/v1/bundleIds', 'POST', foreign)
        self.assertEqual(t.mutations(), [])

    def test_missing_duplicate_and_foreign_credential_locators_refuse_without_node_or_network(self):
        with tempfile.TemporaryDirectory() as directory:
            # Science Reader's own .env.appstore and secrets/ only (AGENTS.md: dedicated credentials), never another project's.
            root = Path(directory) / 'project'; keys = root / 'secrets'
            (root / 'infra').mkdir(parents=True); keys.mkdir()
            (root / 'infra/account.json').write_text(json.dumps({
                'organization': {'slug': AUTH.ORGANIZATION}, 'projects': {'staging': {'id': AUTH.PROJECT}}}))
            (keys / 'fixture.p8').write_text('fake fixture only')
            (root / 'outside.p8').write_text('fake key outside secrets/')
            (Path(directory) / 'foreign.p8').write_text('fake foreign fixture only')
            base = 'ASC_KEY_ID=ABCDEFGHIJ\nASC_ISSUER_ID=00000000-0000-4000-8000-000000000000\n'
            cases = [base, base + 'ASC_KEY_PATH=secrets/fixture.p8\nASC_KEY_ID=KLMNOPQRST\n',
                     base + 'ASC_KEY_PATH=../foreign.p8\n', base + 'ASC_KEY_PATH=outside.p8\n']
            for text in cases:
                (root / '.env.appstore').write_text(text)
                with mock.patch.object(AUTH, 'ROOT', root), mock.patch.object(AUTH, 'APPSTORE_ENV', root / '.env.appstore'), \
                     mock.patch.object(AUTH, 'APPSTORE_KEYS', keys), \
                     mock.patch.object(AUTH.subprocess, 'run', return_value=SimpleNamespace(returncode=0, stdout='fake-management')) as run:
                    with self.assertRaises(AUTH.ConfigurationError):
                        AUTH.credentials()
                    self.assertEqual(run.call_count, 1)
                    self.assertEqual(run.call_args.args[0][0], 'security', 'No real Keychain or Node process runs in this test')

    def test_main_unknown_failure_never_prints_raw_credential_or_provider_text(self):
        out = io.StringIO()
        with mock.patch('sys.argv', ['configure-native-auth.py', '--project-ref', AUTH.PROJECT]), \
             mock.patch.object(AUTH, 'credentials', side_effect=ValueError('secret-provider-fixture')), redirect_stdout(out):
            self.assertEqual(AUTH.main(), 1)
        self.assertEqual(json.loads(out.getvalue()), {'error': 'configuration_check_failed', 'configuration_verified': False})

    def test_changed_auth_preflight_is_not_overwritten_after_apple_registration(self):
        t = FakeTransport()
        t.after_capability = lambda: t.config.update(mailer_otp_exp=1200)
        with self.assertRaisesRegex(AUTH.ConfigurationError, 'auth_fields_changed'):
            AUTH.configure(self.remote(t), apply=True)
        self.assertEqual([row[2] for row in t.mutations()], ['POST', 'POST'])
        self.assertEqual(t.config['mailer_otp_exp'], 1200)

    def test_collection_requires_complete_unique_exact_binding(self):
        for value in ({'data': [], 'links': {'next': 'https://next.invalid'}}, {'data': {}}, {'data': [1]}):
            with self.assertRaises(AUTH.ConfigurationError):
                AUTH.collection(value)

    def test_transport_refuses_redirect_size_truncation_encoding_and_wrong_status_and_closes(self):
        cases = [
            (FakeResponse(status=302), 'redirect_refused'),
            (FakeResponse(headers={'Content-Length': '262145'}), 'response_limit'),
            (FakeResponse(data=b'x' * 262145), 'response_limit'),
            (FakeResponse(headers={'Content-Length': '3'}), 'response_truncated'),
            (FakeResponse(headers={'Content-Encoding': 'gzip'}), 'response_encoding'),
            (FakeResponse(data=b'{"secret":"must-not-escape"}', status=403), 'http_403'),
        ]
        for response, code in cases:
            connection = FakeConnection(response)
            transport = AUTH.JSONTransport(connect=lambda host: connection)
            with self.assertRaisesRegex(AUTH.ConfigurationError, code):
                transport.request(AUTH.MANAGEMENT, AUTH.AUTH_PATH, 'fixture')
            self.assertTrue(response.closed); self.assertTrue(connection.closed)

    def test_detached_response_keeps_tightening_its_original_socket_timeout(self):
        c = FakeConnection(FakeResponse(headers={'Content-Length': '2'}))
        clock = iter([0, 1, 2, 3, 4])
        transport = AUTH.JSONTransport(connect=lambda host: c, clock=lambda: next(clock))
        self.assertEqual(transport.request(AUTH.MANAGEMENT, AUTH.AUTH_PATH, 'fixture'), {})
        self.assertEqual(c.owner.timeouts, [29, 28, 27, 26])
        self.assertTrue(c.closed); self.assertTrue(c.response.closed)

    def test_capability_transport_allows_only_queryless_relationship_route(self):
        path = '/v1/bundleIds/33Q7BMJ45Z/bundleIdCapabilities'
        response = FakeResponse(data=b'{"data":[],"links":{}}')
        connection = FakeConnection(response)
        connect = mock.Mock(return_value=connection)
        transport = AUTH.JSONTransport(connect=connect)
        self.assertEqual(transport.request(AUTH.APPLE, path, 'fixture'), {'data': [], 'links': {}})
        connect.assert_called_once_with(AUTH.APPLE)
        self.assertTrue(response.closed); self.assertTrue(connection.closed)
        for suffix in ('?limit=200', '?limit=50', '?fields[bundleIdCapabilities]=capabilityType', '/foreign'):
            with self.assertRaisesRegex(AUTH.ConfigurationError, 'remote_scope_refused'):
                transport.request(AUTH.APPLE, path + suffix, 'fixture')
        connect.assert_called_once()

    def test_outside_project_host_or_auth_patch_is_rejected_before_connect(self):
        def no_connect(host):
            self.fail('An out-of-scope operation tried to connect')
        transport = AUTH.JSONTransport(connect=no_connect)
        for host, path, method, body in [
            (AUTH.MANAGEMENT, '/v1/projects/uskwoaldovvpuyqeymqy/config/auth', 'GET', None),
            ('other.invalid', AUTH.AUTH_PATH, 'GET', None),
            (AUTH.APPLE, '/v1/apps', 'POST', {}),
            (AUTH.MANAGEMENT, AUTH.AUTH_PATH, 'PATCH', {'disable_signup': False}),
            (AUTH.MANAGEMENT, AUTH.AUTH_PATH, 'PATCH', {'external_google_secret': 'not-allowed'}),
        ]:
            with self.assertRaises(AUTH.ConfigurationError):
                transport.request(host, path, 'fixture', method, body)


if __name__ == '__main__':
    unittest.main()
