import copy
import datetime as dt
import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location('readiness', ROOT / 'scripts/pipeline_readiness.py')
READY = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(READY)
REVISION = READY.SERVICE + '-00042-fixture'
IMAGE = READY.REGION + '-docker.pkg.dev/' + READY.PROJECT + '/cloud-run-source-deploy/' + READY.SERVICE + '@sha256:' + 'a' * 64


def service(revision=REVISION, maintenance=True):
    return {'name': READY.SERVICE_NAME, 'uid': 'fixture-uid', 'etag': 'fixture-etag', 'generation': '42', 'observedGeneration': '42',
            'uri': READY.SERVICE_URL, 'latestReadyRevision': revision, 'latestCreatedRevision': revision,
            'terminalCondition': {'state': 'CONDITION_SUCCEEDED'}, 'reconciling': False,
            'scaling': {'minInstanceCount': 0, 'maxInstanceCount': 3},
            'trafficStatuses': [{'revision': revision, 'percent': 100}],
            'template': {'revision': revision, 'serviceAccount': READY.SERVICE + '@gradstep.iam.gserviceaccount.com',
                         'scaling': {'minInstanceCount': 0, 'maxInstanceCount': 3}, 'timeout': '900s', 'maxInstanceRequestConcurrency': 1,
                         'containers': [{'image': 'mutable-image-tag', 'resources': {'cpuIdle': True, 'limits': {'cpu': '1', 'memory': '2Gi'}},
                                         'env': [{'name': 'PIPELINE_MAINTENANCE', 'value': 'true' if maintenance else 'false'},
                                                 {'name': 'PRIVATE_FIXTURE', 'value': 'must-not-appear-in-report'}] +
                                                [{'name': name, 'valueSource': {'secretKeyRef': {
                                                  'secret': 'gradstep-' + name.lower().replace('_', '-'), 'version': '7'}}}
                                                 for name in READY.SECRET_NAMES]}]}}


def database():
    return {'migration_prefix_verified': True, 'required_hashes': {name: 'a' * 64 for name in READY.REQUIRED_MIGRATIONS},
            'state': {'budget': {'period': '2026-10-01', 'enabled': False, 'spent_microusd': 100, 'reserved_microusd': 900, 'limit_microusd': 30_000_000},
                      'pipeline_enabled': False, 'tags_enabled': False, 'provider_enabled': True, 'native_search_enabled': False,
                      'pipeline_claims': 0, 'tag_claims': 2, 'legacy_open_chat': 0, 'provider_unresolved': 3,
                      'provider_liability_microusd': 900, 'asset_writes_unresolved': 0, 'asset_enforced': True,
                      'inventory_verified_at': '2026-10-07T00:00:00Z', 'inventory_discrepancies': 0, 'inventory_scan_active': False,
                      'reader_mode': 'dual', 'purchase_cleanup': {'active': True, 'expected_command': True, 'schedule': '17 * * * *'}}}


def report():
    return {'format': 1, 'scope': READY.SCOPE, 'revision': REVISION, 'image_digest': IMAGE,
            'database_sha256': READY.digest(database()), 'configuration_sha256': 'b' * 64, 'blockers': [],
            'ready_for_activation': True, 'external_evidence': {'manifest_sha256': 'c' * 64}}


class PipelineReadinessTests(unittest.TestCase):
    def test_scope_and_exact_configuration_are_required(self):
        READY.verify_service(service(), REVISION, True)
        drift = [lambda s: s.update(name='projects/other/locations/us-west1/services/gradstep-pipeline'),
                 lambda s: s.update(uri='https://outside.example'), lambda s: s.update(etag=''),
                 lambda s: s.update(reconciling=True), lambda s: s.update(latestCreatedRevision='pending-revision'),
                 lambda s: s['scaling'].update(maxInstanceCount=20),
                 lambda s: s['template'].update(maxInstanceRequestConcurrency=80),
                 lambda s: s['template']['containers'][0]['resources'].update(cpuIdle=False),
                 lambda s: s['template']['containers'][0]['env'][0].update(value='false'),
                 lambda s: s.update(trafficStatuses=[{'revision': 'old-revision', 'percent': 100}])]
        for change in drift:
            value = service(); change(value)
            with self.subTest(value=READY.service_policy(value)):
                with self.assertRaises(READY.ReadinessError): READY.verify_service(value, REVISION, True)
        with self.assertRaises(READY.ReadinessError): READY.require_scope('textbrain', READY.REGION)
        with self.assertRaises(READY.ReadinessError): READY.require_scope(READY.PROJECT, 'another-region')

    def test_activation_requires_pinned_known_secret_versions_without_exposing_values(self):
        expected = {name: '7' for name in READY.SECRET_NAMES}
        self.assertEqual(READY.verify_service(service(), REVISION, True)['secret_versions'], expected)
        for change in (lambda row: row['valueSource']['secretKeyRef'].update(version='latest'),
                       lambda row: row['valueSource']['secretKeyRef'].update(secret='projects/other/secrets/gradstep-supabase-url'),
                       lambda row: row.update(value='must-not-return-private-value')):
            value = service(); change(value['template']['containers'][0]['env'][2])
            self.assertNotIn('must-not-return-private-value', json.dumps(READY.service_policy(value)))
            with self.assertRaisesRegex(READY.ReadinessError, 'secret_versions'):
                READY.verify_service(value, REVISION, True)
        for duplicate in (True, False):
            value = service(); env = value['template']['containers'][0]['env']
            if duplicate: env.append(copy.deepcopy(env[-1]))
            else: env.pop()
            with self.assertRaisesRegex(READY.ReadinessError, 'secret_versions'):
                READY.verify_service(value, REVISION, True)

    def test_unknown_liability_is_retained_and_reported_not_a_zeroing_instruction(self):
        state = database()
        self.assertEqual(READY.database_blockers(state), [])
        self.assertEqual(state['state']['provider_liability_microusd'], 900)
        for key, value in [('pipeline_enabled', True), ('tags_enabled', True), ('native_search_enabled', True),
                           ('pipeline_claims', 1), ('legacy_open_chat', 1), ('asset_writes_unresolved', 1),
                           ('inventory_discrepancies', 1), ('asset_enforced', False), ('inventory_scan_active', True)]:
            changed = copy.deepcopy(state); changed['state'][key] = value
            self.assertTrue(READY.database_blockers(changed), key)
        state['state']['budget']['enabled'] = True
        self.assertIn('budget_not_paused', READY.database_blockers(state))
        self.assertEqual(READY.database_blockers({'migration_prefix_verified': False}), ['required_migrations_missing'])

    def test_read_only_report_never_treats_empty_queues_as_termination_evidence_or_exposes_env(self):
        calls = []
        def request(url, **kwargs):
            calls.append((url, kwargs))
            self.assertIsNone(kwargs.get('payload'))
            self.assertIsNone(kwargs.get('method'))
            return {'ok': True, 'mode': 'maintenance', 'revision': REVISION} if url.endswith('/health') else service()
        with mock.patch.object(READY, 'credential', return_value='credential-fixture'), \
             mock.patch.object(READY, 'json_request', side_effect=request), \
             mock.patch.object(READY, 'immutable_image', return_value=IMAGE), \
             mock.patch.object(READY, 'database_observation', return_value=database()):
            result, _, _ = READY.observe(READY.PROJECT, READY.REGION, REVISION)
        self.assertFalse(result['ready_for_activation'])
        self.assertEqual(result['blockers'], ['operator_drain_evidence_required'])
        self.assertEqual(result['external_evidence']['status'], 'required')
        self.assertEqual(result['database']['state']['provider_liability_microusd'], 900)
        self.assertNotIn('must-not-appear-in-report', json.dumps(result))
        self.assertNotIn('credential-fixture', json.dumps(result))
        self.assertEqual(len(calls), 2)

    def test_database_observation_uses_only_read_only_management_queries(self):
        sources = {name: 'a' * 64 for name in READY.REQUIRED_MIGRATIONS}
        calls = []
        def request(url, **kwargs):
            calls.append(kwargs)
            body = kwargs.get('payload')
            if body is None:
                return {'organization_id': READY.ORGANIZATION, 'name': 'science-reader-staging'}
            self.assertIs(body['read_only'], True)
            if body['query'] == READY.STATE_SQL: return [{'state': database()['state']}]
            return [{'version': key, 'sha256': value} for key, value in sources.items()]
        with mock.patch.object(READY, 'json_request', side_effect=request), \
             mock.patch.object(READY.LEDGER, 'source_ledger', return_value=sources), \
             mock.patch.object(READY.LEDGER, 'verify_applied_prefix') as verify:
            self.assertEqual(READY.database_observation('credential')['state'], database()['state'])
            verify.assert_called_once_with(sources, sources)
        self.assertEqual(len(calls), 3)

    def test_evidence_is_scoped_to_exact_revision_database_config_and_hashed_local_documents(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); folder = root / '.artifacts/rollout-evidence'; folder.mkdir(parents=True)
            documents = []
            for kind in sorted(READY.EVIDENCE_KINDS):
                path = folder / (kind + '.txt'); path.write_text('reviewed synthetic evidence for ' + kind)
                documents.append({'kind': kind, 'path': str(path.relative_to(root)), 'sha256': hashlib.sha256(path.read_bytes()).hexdigest()})
            expected = report()
            evidence = {key: expected[key] for key in ('scope', 'revision', 'image_digest', 'database_sha256', 'configuration_sha256')}
            evidence.update(format=1, decision='approved', observed_at=dt.datetime.now(dt.timezone.utc).isoformat(), documents=documents)
            manifest = folder / 'approval.json'
            with mock.patch.object(READY, 'ROOT', root):
                manifest.write_text(json.dumps(evidence))
                result = READY.verify_evidence(manifest, expected)
                self.assertIn('operator_attestation', result['status'])
                for field in ('revision', 'image_digest', 'database_sha256', 'configuration_sha256'):
                    wrong = dict(expected, **{field: 'changed'})
                    with self.assertRaisesRegex(READY.ReadinessError, 'stale_' + field): READY.verify_evidence(manifest, wrong)
                changed = copy.deepcopy(evidence); changed['documents'][0]['sha256'] = '0' * 64
                manifest.write_text(json.dumps(changed))
                with self.assertRaisesRegex(READY.ReadinessError, 'document_changed'): READY.verify_evidence(manifest, expected)
                manifest.write_text(json.dumps(dict(evidence, decision='pending')))
                with self.assertRaises(READY.ReadinessError): READY.verify_evidence(manifest, expected)
                outside = root / 'outside.txt'; outside.write_text('outside fixture')
                changed = copy.deepcopy(evidence); changed['documents'][0]['path'] = 'outside.txt'
                manifest.write_text(json.dumps(changed))
                with self.assertRaisesRegex(READY.ReadinessError, 'document_scope'): READY.verify_evidence(manifest, expected)

    def test_activation_has_one_conditional_patch_then_waits_and_verifies_same_image_and_new_active_health(self):
        value, observation = service(), report(); calls = []
        new_revision = READY.SERVICE + '-00043-fixture'
        operation = f'projects/{READY.PROJECT}/locations/{READY.REGION}/operations/fixture-operation'
        def request(url, **kwargs):
            calls.append((url, kwargs))
            if kwargs.get('method') == 'PATCH':
                payload = kwargs['payload']
                self.assertEqual(payload['etag'], value['etag'])
                self.assertEqual(payload['template']['revision'], '')
                self.assertEqual(payload['template']['containers'][0]['image'], IMAGE)
                self.assertEqual(payload['template']['containers'][0]['env'][-1], {'name': 'PIPELINE_MAINTENANCE', 'value': 'false'})
                return {'name': operation, 'done': False}
            if '/operations/' in url: return {'done': True, 'response': {'name': READY.SERVICE_NAME, 'latestReadyRevision': new_revision}}
            if url.endswith('/health'): return {'ok': True, 'mode': 'active', 'revision': new_revision}
            active = service(new_revision, False); active['template']['containers'][0]['image'] = IMAGE
            return active
        with mock.patch.object(READY, 'observe', return_value=(observation, value, 'credential')) as observe, \
             mock.patch.object(READY, 'json_request', side_effect=request), \
             mock.patch.object(READY, 'immutable_image', return_value=IMAGE), mock.patch.object(READY.time, 'sleep'):
            result = READY.activate(READY.PROJECT, READY.REGION, REVISION, Path('proof-fixture'))
        observe.assert_called_once()
        self.assertEqual(result['activated_revision'], new_revision)
        self.assertTrue(result['policies_and_scheduler_unchanged'])
        self.assertFalse(result['workflow_checks_run'])
        self.assertEqual([call[1].get('method') for call in calls], ['PATCH', None, None, None])
        self.assertTrue('PIPELINE_MAINTENANCE' in json.dumps(value))
        self.assertEqual(value['template']['containers'][0]['env'][0]['value'], 'true', 'observation is immutable')

    def test_readback_cannot_accept_another_deployment_or_changed_runtime_configuration(self):
        revision = READY.SERVICE + '-00043-fixture'
        for variant in ('different_revision', 'different_secret', 'different_environment', 'missing_operation_response'):
            calls = []
            def request(url, **kwargs):
                calls.append((url, kwargs))
                if kwargs.get('method') == 'PATCH':
                    return {'done': True} if variant == 'missing_operation_response' else {
                        'done': True, 'response': {'name': READY.SERVICE_NAME, 'latestReadyRevision': revision}}
                updated = service(revision if variant != 'different_revision' else READY.SERVICE + '-00044-concurrent', False)
                updated['template']['containers'][0]['image'] = IMAGE
                if variant == 'different_secret': updated['template']['containers'][0]['env'][2]['valueSource']['secretKeyRef']['version'] = '8'
                if variant == 'different_environment': updated['template']['containers'][0]['env'][1]['value'] = 'changed'
                return updated
            with mock.patch.object(READY, 'observe', return_value=(report(), service(), 'credential')), \
                 mock.patch.object(READY, 'json_request', side_effect=request), \
                 mock.patch.object(READY, 'immutable_image', return_value=IMAGE):
                with self.assertRaises(READY.ReadinessError):
                    READY.activate(READY.PROJECT, READY.REGION, REVISION, 'proof')
            self.assertEqual(sum(call[1].get('method') == 'PATCH' for call in calls), 1)
            self.assertTrue(all(not call[0].endswith('/health') for call in calls), 'fail before treating changed runtime as active')

    def test_failed_preconditions_or_etag_conflict_do_not_retry_mutation_or_release_holds(self):
        denied = dict(report(), ready_for_activation=False, blockers=['asset_writes_unresolved_not_zero'])
        with mock.patch.object(READY, 'observe', return_value=(denied, service(), 'credential')), \
             mock.patch.object(READY, 'json_request') as request:
            with self.assertRaisesRegex(READY.ReadinessError, 'preconditions'): READY.activate(READY.PROJECT, READY.REGION, REVISION, 'proof')
            request.assert_not_called()
        with mock.patch.object(READY, 'observe', return_value=(report(), service(), 'credential')), \
             mock.patch.object(READY, 'json_request', side_effect=READY.ReadinessError('readiness_http_409')) as request:
            with self.assertRaisesRegex(READY.ReadinessError, '409'): READY.activate(READY.PROJECT, READY.REGION, REVISION, 'proof')
            self.assertEqual(request.call_count, 1, 'an ambiguous/conflicting PATCH is never retried automatically')

    def test_network_authority_rejects_other_projects_services_hosts_and_credentialed_health(self):
        for url, options in [('http://run.googleapis.com/v2/' + READY.SERVICE_NAME, {}),
                             ('https://api.supabase.com/v1/projects/another-project/database/query', {}),
                             ('https://run.googleapis.com/v2/projects/textbrain/locations/us-west1/services/gradstep-pipeline', {}),
                             ('https://outside.example/health', {}), (READY.SERVICE_URL + '/health', {'token': 'secret'})]:
            with mock.patch.object(READY.urllib.request, 'build_opener') as opener:
                with self.assertRaises(READY.ReadinessError): READY.json_request(url, **options)
                opener.assert_not_called()


if __name__ == '__main__': unittest.main()
