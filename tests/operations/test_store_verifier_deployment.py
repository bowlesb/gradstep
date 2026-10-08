"""Local fake-provider tests: no cloud mutations, credentials, or Apple calls."""
import copy
import importlib.util
import io
import json
import os
from pathlib import Path
import stat
import struct
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location('store_deploy', ROOT / 'scripts/deploy-store-verifier.py')
D = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(D)
IMAGE = D.IMAGE_PREFIX + '@sha256:' + 'a' * 64
REVISION = D.SERVICE + '-00001-one'
KEY_ID = '1' * 40


def service(*, maintenance=True, revision=REVISION):
    return {'name': D.SERVICE_NAME, 'uri': D.SERVICE_URL, 'uid': 'fixture-uid', 'etag': 'fixture-etag',
        'generation': 1, 'observedGeneration': 1, 'reconciling': False,
        'terminalCondition': {'state': 'CONDITION_SUCCEEDED'},
        'latestReadyRevision': D.SERVICE_NAME + '/revisions/' + revision,
        'latestCreatedRevision': D.SERVICE_NAME + '/revisions/' + revision,
        'invokerIamDisabled': False, 'ingress': 'INGRESS_TRAFFIC_ALL',
        'scaling': {'minInstanceCount': 0, 'maxInstanceCount': 1},
        'template': {'serviceAccount': D.RUNTIME, 'maxInstanceRequestConcurrency': 2, 'timeout': '80s',
            'scaling': {'minInstanceCount': 0, 'maxInstanceCount': 1},
            'containers': [{'image': IMAGE, 'resources': {'cpuIdle': True, 'startupCpuBoost': False,
                'limits': {'cpu': '1', 'memory': '512Mi'}}, 'env': [
                {'name': 'STORE_VERIFIER_POLICY_ID', 'value': D.POLICY},
                {'name': 'STORE_VERIFIER_MAINTENANCE', 'value': str(maintenance).lower()}]}]},
        'traffic': [{'type': 'TRAFFIC_TARGET_ALLOCATION_TYPE_LATEST', 'percent': 100}],
        'trafficStatuses': [{'revision': D.SERVICE_NAME + '/revisions/' + revision, 'percent': 100}]}


def health(*, maintenance=True, revision=REVISION):
    return {'version': 1, 'ok': True, 'policy_id': D.POLICY, 'policy_valid': True, 'maintenance': maintenance,
            'ready': not maintenance, 'revision': revision,
            'runtime': {'node': '24.18.0', 'apple_library': '3.1.0', 'capabilities': dict.fromkeys(D.CAPABILITIES, True),
                        'ocsp_freshness': {'policy': 'strict-utc-v1', 'applied': True,
                            'source_sha256': D.SDK_SOURCE_SHA256, 'patched_sha256': D.SDK_PATCHED_SHA256}}}


def db():
    channels = []
    for channel, limits in [('app', {'account_hour': 50, 'hour': 500, 'day': 300, 'month': 3000}),
                            ('notification', {'account_hour': None, 'hour': 60, 'day': 200, 'month': 1000})]:
        channels.append({'channel': channel, 'enabled': False, 'revision': 1, 'limits': limits,
                         'usage': {period: {'period': '2026-10-08T00:00:00Z', 'starts': 0, 'denied': 0} for period in ('hour', 'day', 'month')}})
    return {'version': 1, 'migration': '202610070033_purchase_verification_transport', 'policy_id': D.POLICY, 'channels': channels}


def key():
    return {'type': 'service_account', 'project_id': D.PROJECT, 'client_email': D.CALLER,
            'token_uri': 'https://oauth2.googleapis.com/token', 'private_key_id': KEY_ID,
            'private_key': '-----BEGIN PRIVATE KEY-----\nsynthetic-fixture-no-secret\n-----END PRIVATE KEY-----\n'}


def iam():
    return {'bindings': [{'role': 'roles/run.invoker', 'members': ['serviceAccount:' + D.CALLER]}], 'etag': 'fixture-iam-etag'}


def fixture_sources(root):
    for path in D.source_files(root):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text('synthetic source ' + path.name)


def eszip(modules):
    header, sources, maps = b'', b'', b''
    for name, original in modules.items():
        compiled = b'generated-js'
        source_map = json.dumps({'sources': [name], 'sourcesContent': [original]}).encode()
        encoded_name = name.encode()
        header += struct.pack('>I', len(encoded_name)) + encoded_name + b'\x00'
        header += struct.pack('>IIII', len(sources), len(compiled), len(maps), len(source_map)) + b'\x00'
        sources += compiled
        maps += source_map
    section = lambda b: struct.pack('>I', len(b)) + b
    return b'ESZIP2.3' + section(b'\x00\x00\x01\x00') + section(header) + section(b'') + section(sources) + section(maps)


class ScopeAndConfigurationTests(unittest.TestCase):
    def test_plan_has_no_effect_and_explicit_private_bounds(self):
        with mock.patch.object(D, 'gcloud') as cloud, mock.patch.object(D, 'json_request') as network, \
             mock.patch('sys.stdout', new_callable=io.StringIO) as output:
            D.main(['plan'])
        cloud.assert_not_called(); network.assert_not_called()
        plan = json.loads(output.getvalue())
        self.assertFalse(plan['mutations'])
        args = plan['deployment']
        for flag in ('--invoker-iam-check', '--no-allow-unauthenticated', '--cpu-throttling', '--no-cpu-boost', '--clear-secrets'):
            self.assertIn(flag, args)
        for flag, value in {'--max': '1', '--max-instances': '1', '--min': '0', '--min-instances': '0', '--concurrency': '2',
                            '--timeout': '80', '--cpu': '1', '--memory': '512Mi', '--service-account': D.RUNTIME}.items():
            self.assertEqual(args[args.index(flag) + 1], value)
        self.assertNotIn('--allow-unauthenticated', args)
        self.assertNotIn('PIPELINE_SECRET', output.getvalue())

    def test_exact_configuration_rejects_public_gateway_extra_secrets_tags_and_drift(self):
        D.verified_service(service(), REVISION, IMAGE, maintenance=True)
        edits = [lambda s: s.update(invokerIamDisabled=True),
            lambda s: s['scaling'].update(maxInstanceCount=20),
            lambda s: s['template'].update(serviceAccount='pipeline@gradstep.iam.gserviceaccount.com'),
            lambda s: s['template'].update(maxInstanceRequestConcurrency=80),
            lambda s: s['template']['containers'][0]['resources'].update(cpuIdle=False),
            lambda s: s['template']['containers'][0]['resources'].update(startupCpuBoost=True),
            lambda s: s['template']['containers'][0]['env'].append({'name': 'SECRET', 'value': 'private-fixture'}),
            lambda s: s['template']['containers'][0].update(image=IMAGE.replace('a' * 64, 'b' * 64)),
            lambda s: s['template'].update(volumes=[{'secret': {'secret': 'legacy-secret'}}]),
            lambda s: s['trafficStatuses'][0].update(tag='old'),
            lambda s: s.update(reconciling=True), lambda s: s.update(etag='')]
        for edit in edits:
            value = service(); edit(value)
            with self.subTest(value=value), self.assertRaises(D.OpsError):
                D.verified_service(value, REVISION, IMAGE, maintenance=True)
        with self.assertRaises(D.OpsError):
            D.verified_service(service(maintenance=False), REVISION, IMAGE, maintenance=True)

    def test_project_or_service_broad_iam_is_refused(self):
        for member in ('allUsers', 'allAuthenticatedUsers', 'serviceAccount:' + D.CALLER, 'serviceAccount:' + D.RUNTIME,
                       'principalSet://cloudresourcemanager.googleapis.com/projects/885355087025/type/ServiceAccount'):
            with mock.patch.object(D, 'project_identity'), mock.patch.object(D, 'gcloud', return_value=json.dumps({'bindings': [{'role': 'roles/editor', 'members': [member]}]})):
                with self.assertRaisesRegex(D.OpsError, 'broad_identity_permissions'):
                    D.project_policy()
        for bad in [dict(iam(), bindings=[]), dict(iam(), etag=''),
                    {'bindings': [{'role': 'roles/run.invoker', 'members': ['allUsers']}], 'etag': 'x'}]:
            with mock.patch.object(D, 'gcloud', return_value=json.dumps(bad)):
                with self.assertRaises(D.OpsError): D.service_iam()
        with mock.patch.object(D, 'gcloud', return_value=json.dumps(iam())):
            self.assertEqual(D.service_iam(), iam())

    def test_no_api_redirect_or_scope_escape(self):
        for url in ['https://api.supabase.com/v1/projects/other/secrets', 'https://attacker.invalid/',
                    'https://run.googleapis.com/v2/projects/gradstep/locations/us-west1/services/gradstep-pipeline',
                    'https://api.supabase.com/v1/projects/' + D.SUPABASE + '?token=x']:
            with mock.patch.object(D.urllib.request, 'build_opener') as opener:
                with self.assertRaises(D.OpsError): D.json_request(url, token='private-fixture')
                opener.assert_not_called()
        with self.assertRaisesRegex(D.OpsError, 'redirect_refused'):
            D.NoRedirect().redirect_request(None, None, None, None, None, None)

    def test_build_context_is_exact_allowlist_and_hash_changes_with_source(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary); fixture_sources(root)
            (root / '.env.staging').write_text('PRIVATE FIXTURE')
            (root / 'supabase/functions/_shared/backend.ts').write_text('DO NOT SHIP DATABASE CLIENT')
            context, manifest = D.build_context(root)
            try:
                paths = sorted(str(p.relative_to(context)) for p in context.rglob('*') if p.is_file())
                self.assertEqual(paths, sorted(str(p.relative_to(root)) for p in D.source_files(root)))
                self.assertNotIn('.env.staging', paths)
                first = D.sha(D.canonical(manifest))
                D.source_files(root)[0].write_text('changed source')
                self.assertNotEqual(first, D.sha(D.canonical(D.source_manifest(root))))
            finally:
                D.shutil.rmtree(context)

    def test_deploy_always_checks_maintenance_before_granting_invoker_and_never_activates(self):
        events = []
        with mock.patch.object(D, 'project_policy', side_effect=lambda: events.append('project-policy')), \
             mock.patch.object(D, 'verify_identities'), \
             mock.patch.object(D, 'database_readiness', side_effect=lambda t: events.append('paused') or db()), \
             mock.patch.object(D, 'management_token', return_value='fixture'), \
             mock.patch.object(D, 'verify_image_proof', side_effect=lambda p: events.append('image') or IMAGE), \
             mock.patch.object(D, 'gcloud', side_effect=lambda *a: events.append(a[:3]) or ''), \
             mock.patch.object(D, 'cloud_token', return_value='private-fixture'), \
             mock.patch.object(D, 'cloud_service', return_value=service()), \
             mock.patch.object(D, 'service_iam', side_effect=lambda **kw: events.append(('iam', kw)) or iam()):
            result = D.deploy_service({'image': IMAGE})
        self.assertEqual(events, ['project-policy', 'paused', 'image', ('run', 'deploy', D.SERVICE), ('iam', {'caller_required': False}),
            ('run', 'services', 'add-iam-policy-binding'), ('iam', {}), 'project-policy'])
        self.assertFalse(result['admission_enabled'])
        self.assertTrue(result['service']['maintenance'])


class CallerKeyTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.directory = self.root / '.artifacts/store-verifier/caller'
        self.stack = []
        for patch in (mock.patch.object(D, 'ROOT', self.root), mock.patch.object(D, 'project_policy'), mock.patch.object(D, 'service_iam'),
                      mock.patch.object(D, 'verify_identities')):
            patch.start(); self.stack.append(patch)

    def tearDown(self):
        for patch in reversed(self.stack): patch.stop()
        self.temporary.cleanup()

    def test_one_create_and_resumable_private_material(self):
        inventory = []
        calls = []
        def create(*args):
            checkpoint = D.private_read(self.directory / 'checkpoint.json')
            self.assertEqual(checkpoint['phase'], 'creating', 'intent persisted before provider operation')
            inventory.append(KEY_ID); calls.append(args)
            return key()
        with mock.patch.object(D, 'key_ids', side_effect=lambda: list(inventory)), mock.patch.object(D, 'create_key_material', side_effect=create):
            self.assertEqual(D.create_caller_key(self.directory)['phase'], 'material_ready')
            self.assertEqual(D.create_caller_key(self.directory)['phase'], 'material_ready')
        self.assertEqual(len(calls), 1)
        self.assertEqual(stat.S_IMODE(self.directory.stat().st_mode), 0o700)
        for name in ('caller.json', 'checkpoint.json'):
            self.assertEqual(stat.S_IMODE((self.directory / name).stat().st_mode), 0o600)
        self.assertNotIn('synthetic-fixture', (self.directory / 'checkpoint.json').read_text())

    def test_lost_create_response_never_recreates_even_when_listing_is_empty(self):
        with mock.patch.object(D, 'key_ids', return_value=[]), mock.patch.object(D, 'create_key_material', side_effect=D.OpsError('private-vendor-error')) as create:
            for _ in range(3):
                with self.assertRaisesRegex(D.OpsError, 'creation_ambiguous') as error:
                    D.create_caller_key(self.directory)
                self.assertNotIn('private-vendor-error', str(error.exception))
            self.assertEqual(create.call_count, 1)

    def test_lost_ack_with_material_recovers_without_new_key(self):
        inventory = []
        def create(*args):
            D.private_write(self.directory / 'caller.json', key()); inventory.append(KEY_ID)
            raise D.OpsError('transport-lost')
        with mock.patch.object(D, 'key_ids', side_effect=lambda: list(inventory)), mock.patch.object(D, 'create_key_material', side_effect=create) as send:
            with self.assertRaisesRegex(D.OpsError, 'creation_ambiguous'): D.create_caller_key(self.directory)
            self.assertEqual(D.create_caller_key(self.directory)['key_id'], KEY_ID)
            self.assertEqual(send.call_count, 1)

    def test_unknown_existing_key_and_symlinks_do_not_trigger_create(self):
        with mock.patch.object(D, 'key_ids', return_value=['2' * 40]), mock.patch.object(D, 'create_key_material') as create:
            with self.assertRaisesRegex(D.OpsError, 'existing_keys'): D.create_caller_key(self.directory)
            create.assert_not_called()
        outside = self.root / 'outside'; outside.mkdir()
        link = self.root / '.artifacts/store-verifier/link'; link.symlink_to(outside)
        with self.assertRaisesRegex(D.OpsError, 'symlink'):
            D.protected_directory(link / 'child')
        self.assertFalse((outside / 'child').exists())

    def test_secret_install_reuses_same_key_and_only_writes_two_secrets(self):
        directory = D.protected_directory(self.directory)
        D.private_write(directory / 'checkpoint.json', {'scope': D.SCOPE, 'phase': 'material_ready', 'key_id': KEY_ID})
        D.private_write(directory / 'caller.json', key())
        events, stored = [], []
        def request(url, **kwargs):
            self.assertTrue(url.endswith('/secrets'))
            events.append(kwargs.get('method', 'GET'))
            if kwargs.get('body'):
                stored[:] = kwargs['body']; return None
            return [{'name': row['name'], 'digest': D.sha(row['value'].encode())} for row in stored]
        with mock.patch.object(D, 'key_ids', return_value=[KEY_ID]), mock.patch.object(D, 'management_token', return_value='private-fixture'), \
             mock.patch.object(D, 'supabase_identity'), mock.patch.object(D, 'json_request', side_effect=request), mock.patch.object(D, 'gcloud') as cloud:
            result = D.install_caller_secret(directory)
        cloud.assert_not_called()
        self.assertEqual(events, ['POST', 'GET'])
        self.assertEqual(set(result['secret_names']), {D.SECRET_NAME, 'STORE_VERIFIER_URL'})
        self.assertNotIn('synthetic-fixture', json.dumps(result))


class ReadbackAndActivationTests(unittest.TestCase):
    def test_full_source_map_readback_and_tampering(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            sources = {'functions/store-sync/index.ts': 'import "../_shared/store-purchases.ts";',
                       'functions/_shared/store-purchases.ts': 'export const version = 1;'}
            for name, source in sources.items():
                path = root / 'supabase' / name; path.parent.mkdir(parents=True, exist_ok=True); path.write_text(source)
            data = eszip(sources)
            report = D.compare_eszip(data, 'store-sync', root)
            self.assertEqual(len(report['modules']), 2)
            self.assertNotIn('export const', json.dumps(report))
            for bad in [data[:-1], b'ESZIP2.4' + data[8:], eszip({**sources, 'functions/_shared/app-store.ts': 'node-only'}),
                        eszip({**sources, 'functions/store-sync/index.ts': 'stale implementation'})]:
                with self.assertRaises(D.OpsError): D.compare_eszip(bad, 'store-sync', root)

    def test_health_rejects_arbitrary_fields_unsupported_runtime_or_missing_capability(self):
        D.validate_health(health(), REVISION, maintenance=True)
        cases = [dict(health(), private='do not log'), dict(health(), ready=True), dict(health(), revision=REVISION + '-old')]
        bad = health(); bad['runtime']['capabilities']['certificate_raw'] = False; cases.append(bad)
        bad = health(); bad['runtime']['node'] = 'unknown'; cases.append(bad)
        bad = health(); bad['runtime']['ocsp_freshness']['applied'] = False; cases.append(bad)
        bad = health(); bad['runtime']['ocsp_freshness']['patched_sha256'] = 'a' * 64; cases.append(bad)
        for value in cases:
            with self.assertRaises(D.OpsError): D.validate_health(value, REVISION, maintenance=True)

    def test_admission_readiness_requires_both_channels_paused_and_original_caps(self):
        with mock.patch.object(D, 'supabase_identity'), mock.patch.object(D, 'verify_admission_migration'), \
             mock.patch.object(D, 'json_request', return_value=[{'state': db()}]) as request:
            self.assertEqual(D.database_readiness('fixture'), db())
            self.assertTrue(request.call_args.kwargs['body']['read_only'])
        for change in [lambda v: v['channels'][0].update(enabled=True), lambda v: v['channels'][1].update(enabled=True),
                       lambda v: v['channels'][0]['limits'].update(month=1_000_000), lambda v: v['channels'].reverse(),
                       lambda v: v['channels'][0]['usage']['month'].update(starts=-1)]:
            value = db(); change(value)
            with mock.patch.object(D, 'supabase_identity'), mock.patch.object(D, 'verify_admission_migration'), \
                 mock.patch.object(D, 'json_request', return_value=[{'state': value}]):
                with self.assertRaises(D.OpsError): D.database_readiness('fixture')

    def test_applied_admission_migration_must_match_reviewed_local_file(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            path = root / 'supabase/migrations/202610070033_purchase_verification_transport.sql'
            path.parent.mkdir(parents=True); path.write_bytes(b'fixture migration')
            expected = D.sha(path.read_bytes())
            with mock.patch.object(D, 'ROOT', root), mock.patch.object(D, 'json_request', return_value=[{'version': '202610070033', 'sha256': expected}]):
                self.assertEqual(D.verify_admission_migration('fixture'), expected)
            for rows in [[], [{'version': '202610070033', 'sha256': 'b' * 64}],
                         [{'version': '202610070034', 'sha256': expected}]]:
                with mock.patch.object(D, 'ROOT', root), mock.patch.object(D, 'json_request', return_value=rows):
                    with self.assertRaises(D.OpsError): D.verify_admission_migration('fixture')

    def test_activation_etag_and_image_bound_order_leaves_admission_paused(self):
        before = service(); after = service(maintenance=False, revision=D.SERVICE + '-00002-two')
        after['etag'] = 'new-etag'; after['template']['containers'][0]['env'].sort(key=lambda item: item['name'])
        evidence = {'version': 1, 'scope': D.SCOPE, 'observed_at': D.now(),
                    'service': D.verified_service(before, REVISION, IMAGE, maintenance=True), 'project_iam': {},
                    'iam_sha256': D.sha(D.canonical(iam())), 'admission': db(), 'auth_probe_sha256': 'probe', 'activation_ready': True}
        events = []
        def request(url, **kwargs):
            events.append('patch')
            self.assertEqual(kwargs['method'], 'PATCH')
            self.assertEqual(kwargs['body']['etag'], before['etag'])
            self.assertEqual(kwargs['body']['template']['containers'][0]['image'], IMAGE)
            self.assertEqual(kwargs['body']['template']['containers'][0]['env'][0]['value'], 'false')
            return {'name': f'projects/{D.PROJECT}/locations/{D.REGION}/operations/fixture-operation', 'done': True}
        with mock.patch.object(D, 'readiness', return_value=evidence), mock.patch.object(D, 'cloud_token', return_value='fixture'), \
             mock.patch.object(D, 'cloud_service', side_effect=[before, after]), mock.patch.object(D, 'service_iam', return_value=iam()), \
             mock.patch.object(D, 'json_request', side_effect=request), mock.patch.object(D, 'project_policy'), \
             mock.patch.object(D, 'verify_identities'), \
             mock.patch.object(D, 'management_token', return_value='fixture'), \
             mock.patch.object(D, 'database_readiness', side_effect=lambda t: events.append('still-paused') or db()), \
             mock.patch.object(D, 'probe_health', side_effect=lambda *a, **kw: events.append('active-health') or health(maintenance=False)):
            result = D.activate(REVISION, {'image': IMAGE}, evidence, {'probe': 'fixture'})
        self.assertEqual(events, ['patch', 'still-paused', 'active-health'])
        self.assertFalse(result['admission_enabled'])

    def test_changed_evidence_refuses_before_any_activation_patch(self):
        evidence = {'observed_at': D.now(), 'scope': D.SCOPE, 'service': {'etag': 'old'}}
        with mock.patch.object(D, 'readiness', return_value={**evidence, 'service': {'etag': 'changed'}}), \
             mock.patch.object(D, 'json_request') as request:
            with self.assertRaisesRegex(D.OpsError, 'evidence_changed'):
                D.activate(REVISION, {'image': IMAGE}, evidence, {'probe': 'fixture'})
            request.assert_not_called()

    def test_receipt_free_probe_is_bound_to_actual_response_and_unchanged_edge(self):
        def response(probe_id, credential):
            self.assertEqual(credential, 'synthetic-service-role')
            return {'version': 1, 'probe_id': probe_id, 'observed_at': D.now(), 'health': health()}
        with mock.patch.object(D, 'management_token', return_value='fixture'), mock.patch.object(D, 'supabase_identity'), \
             mock.patch.object(D, 'function_readback', return_value={'function': 'store-verifier-health', 'version': 1}), \
             mock.patch.object(D, 'staging_service_role', return_value='synthetic-service-role'), \
             mock.patch.object(D, 'invoke_health_probe', side_effect=response):
            result = D.probe_health(REVISION)
        self.assertEqual(result['health']['revision'], REVISION)
        self.assertNotIn('synthetic-service-role', json.dumps(result))

    def test_only_the_three_purchase_edge_functions_can_deploy(self):
        with mock.patch.object(D, 'management_token') as token, mock.patch.object(D.subprocess, 'run') as command:
            for functions in ([], ['chat'], ['store-sync', 'paper-worker'], ['store-sync', 'store-sync']):
                with self.assertRaises(D.OpsError): D.deploy_functions(functions)
            token.assert_not_called(); command.assert_not_called()


if __name__ == '__main__':
    unittest.main()
