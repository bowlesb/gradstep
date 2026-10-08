import copy
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location('workflow_job_refresh', ROOT / 'scripts/refresh-workflow-job-image.py')
REFRESH = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(REFRESH)
OLD = REFRESH.IMAGE + ':54744c0-1791385453'
NEW = REFRESH.IMAGE + '@sha256:' + 'a' * 64


def job():
    return {'name': REFRESH.NAME, 'uid': 'fixture-stable-job-id', 'etag': 'fixture-etag',
            'generation': '7', 'observedGeneration': '7', 'terminalCondition': {'state': 'CONDITION_SUCCEEDED'},
            'reconciling': False, 'creator': 'private-fixture-operator', 'labels': {'keep': 'exact'},
            'annotations': {'private-marker': 'private-fixture'}, 'client': 'gcloud', 'clientVersion': 'fixture',
            'launchStage': 'GA', 'template': {'taskCount': 1, 'parallelism': 1,
                'annotations': {'private-marker': 'preserve-template'}, 'template': {
                    'maxRetries': 0, 'timeout': '2700s', 'serviceAccount': REFRESH.RUNTIME,
                    'volumes': [{'name': 'keep', 'emptyDir': {}}],
                    'containers': [{'name': 'checks', 'image': OLD, 'args': ['--suite=daily', '--record', '--notify'],
                        'resources': {'limits': {'cpu': '1', 'memory': '512Mi'}},
                        'env': [{'name': 'SUPABASE_PROJECT_REF', 'value': REFRESH.SUPABASE},
                                {'name': 'WORKFLOW_ALERT_EMAIL', 'value': 'private-owner-fixture@example.invalid'},
                                {'name': 'SUPABASE_SERVICE_ROLE_KEY', 'valueSource': {'secretKeyRef': {
                                    'secret': 'gradstep-supabase-service-role-key', 'version': 'latest'}}},
                                {'name': 'DO_NOT_LOG', 'value': 'private-fixture-value'}],
                        'buildInfo': {'sourceLocation': 'output-only-old-image'}}]}}}


class Fixture:
    def __init__(self):
        self.job = job()
        self.iam = {'version': 3, 'etag': 'iam-etag', 'bindings': [{'role': 'roles/run.jobsExecutorWithOverrides',
                     'members': ['serviceAccount:private-scheduler-fixture']}]}
        self.schedulers = {REFRESH.scheduler_url(name): {
            'name': f'projects/{REFRESH.PROJECT}/locations/{REFRESH.REGION}/jobs/{name}',
            'schedule': cron, 'timeZone': 'Etc/UTC', 'state': 'ENABLED',
            'httpTarget': {'uri': REFRESH.URL + ':run', 'body': 'private-fixed-override-body',
                           'oauthToken': {'serviceAccountEmail': 'private-scheduler-fixture'}},
            'retryConfig': {'retryCount': 0}, 'userUpdateTime': '2026-10-07T00:00:00Z',
            'lastAttemptTime': '2026-10-08T06:00:00Z', 'scheduleTime': '2026-10-08T12:00:00Z', 'status': {},
        } for name, cron in REFRESH.SCHEDULES.items()}
        self.calls, self.patch = [], None
        self.lost_ack = False
        self.after_patch = lambda: None

    def __call__(self, url, *, method='GET', payload=None):
        REFRESH.request_scope(url, method, payload)
        self.calls.append((method, url))
        if method == 'PATCH':
            self.patch = copy.deepcopy(payload)
            self.job = {**self.job, **copy.deepcopy(payload), 'etag': 'new-etag', 'generation': '8', 'observedGeneration': '8'}
            # Ordinary execution timestamps may advance; trigger configuration must remain identical.
            for value in self.schedulers.values(): value['lastAttemptTime'] = '2026-10-08T12:00:00Z'
            self.after_patch()
            if self.lost_ack: raise REFRESH.RefreshError('workflow_image_transport_failed')
            return {'name': f'projects/{REFRESH.PROJECT}/locations/{REFRESH.REGION}/operations/fixture', 'done': False}
        if '/operations/' in url: return {'done': True, 'response': copy.deepcopy(self.job)}
        if url == REFRESH.URL: return copy.deepcopy(self.job)
        if ':getIamPolicy' in url: return copy.deepcopy(self.iam)
        return copy.deepcopy(self.schedulers[url])


class WorkflowImageRefreshTests(unittest.TestCase):
    def test_plan_is_read_only_scoped_and_excludes_all_private_values(self):
        api = Fixture()
        plan = REFRESH.make_plan(api, NEW, OLD)
        self.assertTrue(all(method == 'GET' for method, _ in api.calls))
        self.assertEqual(len(api.calls), 5)
        self.assertEqual(plan['image'], OLD); self.assertEqual(plan['target_image'], NEW)
        self.assertNotIn('private-', json.dumps(plan)); self.assertNotIn('latest', json.dumps(plan))
        self.assertTrue(plan['alert_email_configured'])
        with self.assertRaisesRegex(REFRESH.RefreshError, 'plan_scope'):
            REFRESH.validate_plan({**plan, 'unrecognized': 'must-not-be-copied-to-evidence'})
        for image in (REFRESH.IMAGE + ':floating', NEW.replace('/gradstep/', '/other/'), NEW + '?x=1'):
            with self.assertRaises(REFRESH.RefreshError): REFRESH.make_plan(Fixture(), image, OLD)
        with self.assertRaisesRegex(REFRESH.RefreshError, 'old_image_mismatch'):
            REFRESH.make_plan(Fixture(), NEW, REFRESH.IMAGE + ':unexpected')

    def test_apply_changes_exactly_one_image_and_preserves_settings_iam_schedules_and_alerts(self):
        api = Fixture(); plan = REFRESH.make_plan(api, NEW, OLD)
        original = REFRESH.writable(api.job)
        with tempfile.TemporaryDirectory() as directory:
            receipt = Path(directory) / 'receipt.json'
            result = REFRESH.apply(api, plan, receipt, sleep=lambda _: None)
            self.assertEqual(result['status'], 'verified')
            self.assertFalse(result['executed']); self.assertFalse(result['notification_sent'])
            self.assertEqual(receipt.stat().st_mode & 0o777, 0o600)
            self.assertNotIn('private-', receipt.read_text())
            self.assertEqual(json.loads(receipt.read_text())['plan'], plan)
            expected = copy.deepcopy(original); expected['etag'] = 'fixture-etag'
            expected['template']['template']['containers'][0]['image'] = NEW
            self.assertEqual(api.patch, expected)
            self.assertNotIn('buildInfo', api.patch['template']['template']['containers'][0])
            self.assertEqual([call for call in api.calls if call[0] != 'GET'], [('PATCH', REFRESH.URL + '?allowMissing=false')])
            self.assertEqual(api.patch['template']['template']['containers'][0]['env'], original['template']['template']['containers'][0]['env'])

    def test_stale_plan_or_execution_tokens_refuse_before_any_write(self):
        for mutate in [lambda api: api.job.update(etag='changed'),
                       lambda api: api.job.update(uid='recreated-job'),
                       lambda api: api.job['template']['template']['containers'][0]['env'][-1].update(value='changed'),
                       lambda api: api.iam.update(etag='changed'),
                       lambda api: next(iter(api.schedulers.values()))['httpTarget'].update(body='changed')]:
            api = Fixture(); plan = REFRESH.make_plan(api, NEW, OLD); mutate(api)
            with tempfile.TemporaryDirectory() as directory:
                receipt = Path(directory) / 'receipt.json'
                with self.assertRaisesRegex(REFRESH.RefreshError, 'plan_stale'): REFRESH.apply(api, plan, receipt)
                self.assertFalse(receipt.exists()); self.assertIsNone(api.patch)
        for field in ['startExecutionToken', 'runExecutionToken', 'unknownNewWritableSetting']:
            api = Fixture(); api.job[field] = 'must-not-pass'
            with self.assertRaisesRegex(REFRESH.RefreshError, 'unknown_job_field'): REFRESH.make_plan(api, NEW, OLD)

    def test_lost_patch_ack_is_one_send_with_durable_intent_then_read_only_verification(self):
        api = Fixture(); plan = REFRESH.make_plan(api, NEW, OLD); api.lost_ack = True
        with tempfile.TemporaryDirectory() as directory:
            receipt = Path(directory) / 'receipt.json'
            with self.assertRaisesRegex(REFRESH.RefreshError, 'transport_failed'): REFRESH.apply(api, plan, receipt)
            self.assertTrue(receipt.exists()); before = len(api.calls)
            proof = REFRESH.verify(api, json.loads(receipt.read_text())['plan'])
            self.assertEqual(proof['status'], 'verified')
            self.assertTrue(all(method == 'GET' for method, _ in api.calls[before:]))
            self.assertEqual(sum(method == 'PATCH' for method, _ in api.calls), 1)

    def test_failed_preservation_readback_never_rolls_back_or_retries(self):
        for mutate in [lambda api: api.job['template']['template']['containers'][0]['env'][-1].update(value='unexpected'),
                       lambda api: api.iam.update(etag='changed'),
                       lambda api: next(iter(api.schedulers.values()))['retryConfig'].update(retryCount=1)]:
            api = Fixture(); plan = REFRESH.make_plan(api, NEW, OLD); api.after_patch = lambda: mutate(api)
            with tempfile.TemporaryDirectory() as directory:
                with self.assertRaisesRegex(REFRESH.RefreshError, 'preserved_configuration_mismatch'):
                    REFRESH.apply(api, plan, Path(directory) / 'receipt.json', sleep=lambda _: None)
            self.assertEqual(sum(method == 'PATCH' for method, _ in api.calls), 1)

    def test_scope_cannot_execute_notify_mutate_schedules_or_create_missing_job(self):
        for url, method, payload in [(REFRESH.URL + ':run', 'POST', {}), (REFRESH.URL, 'DELETE', None),
                    (REFRESH.URL + '?allowMissing=true', 'PATCH', {}),
                    (REFRESH.URL + ':setIamPolicy', 'POST', {}),
                    (REFRESH.scheduler_url('gradstep-checks-daily'), 'PATCH', {}),
                    ('https://api.resend.com/emails', 'POST', {}),
                    ('https://run.googleapis.com/v2/projects/other/locations/us-west1/operations/x', 'GET', None)]:
            with self.assertRaisesRegex(REFRESH.RefreshError, 'request_scope'): REFRESH.request_scope(url, method, payload)
        for field in ['startExecutionToken', 'runExecutionToken']:
            payload = REFRESH.writable(job()); payload['etag'] = 'etag'; payload[field] = 'must-not-execute'
            payload['template']['template']['containers'][0]['image'] = NEW
            with self.assertRaisesRegex(REFRESH.RefreshError, 'patch_scope'):
                REFRESH.request_scope(REFRESH.URL + '?allowMissing=false', 'PATCH', payload)
        for change in [lambda value: value['template'].update(taskCount=2),
                       lambda value: value['template']['template'].update(maxRetries=1),
                       lambda value: value['template']['template'].update(timeout='3600s'),
                       lambda value: value['template']['template'].update(serviceAccount='other'),
                       lambda value: value.update(reconciling=True)]:
            value = job(); change(value)
            with self.assertRaises(REFRESH.RefreshError): REFRESH.writable(value)


if __name__ == '__main__':
    unittest.main()
