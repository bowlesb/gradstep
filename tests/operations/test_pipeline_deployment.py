import copy
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location('pipeline_deploy', ROOT / 'scripts/deploy-pipeline-worker.py')
DEPLOY = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(DEPLOY)


def service():
    return {
        'metadata': {'annotations': {'run.googleapis.com/maxScale': '3', 'private-marker': 'secret-fixture'}},
        'spec': {'template': {'metadata': {'annotations': {
            'run.googleapis.com/cpu-throttling': 'true', 'autoscaling.knative.dev/maxScale': '3'}},
            'spec': {'containerConcurrency': 1, 'timeoutSeconds': 900, 'containers': [{
                'resources': {'limits': {'cpu': '1000m', 'memory': '2Gi'}},
                'env': [{'name': 'DO_NOT_PRINT', 'value': 'secret-fixture'}]}]}}},
        'status': {'latestReadyRevisionName': 'fixture-1', 'traffic': [{'revisionName': 'fixture-1', 'percent': 100}]},
    }


class PipelineDeploymentTests(unittest.TestCase):
    def test_request_billing_and_both_instance_scopes_are_explicit(self):
        args = DEPLOY.deployment_args('gradstep', 'us-west1', 'image-fixture', 'account-fixture', 'secret-reference-fixture')
        self.assertIn('--cpu-throttling', args)
        self.assertNotIn('--no-cpu-throttling', args)
        for flag, value in {'--max': '3', '--max-instances': '3', '--min': '0', '--min-instances': '0',
                            '--cpu': '1', '--memory': '2Gi', '--concurrency': '1', '--timeout': '900'}.items():
            self.assertEqual(args.count(flag), 1)
            self.assertEqual(args[args.index(flag) + 1], value)
        source = (ROOT / 'services/pipeline-worker/server.ts').read_text()
        import re
        hard_limit = int(re.search(r'HARD_RUN_LIMIT_MS = ([\d_]+)', source).group(1).replace('_', ''))
        self.assertLess(hard_limit, int(args[args.index('--timeout') + 1]) * 1000)

    def test_readback_requires_expected_billing_limits_resources_and_live_traffic(self):
        policy = DEPLOY.deployment_policy(service())
        DEPLOY.verify_policy(policy)
        self.assertNotIn('secret-fixture', json.dumps(policy))
        self.assertNotIn('env', policy)
        for key, value in {'cpu_throttling': 'false', 'service_min': '1', 'service_max': '20',
                           'revision_min': '1', 'revision_max': '4', 'concurrency': 80, 'timeout_seconds': 3600,
                           'cpu': '2', 'memory': '4Gi', 'container_count': 2, 'revision': None,
                           'traffic': [{'revision': 'old-revision', 'percent': 100}]}.items():
            with self.subTest(key=key):
                with self.assertRaisesRegex(RuntimeError, 'pipeline_configuration_mismatch'):
                    DEPLOY.verify_policy(dict(policy, **{key: value}))
        for value in ({}, {'spec': {}}, {'spec': {'template': {}}}):
            with self.assertRaisesRegex(RuntimeError, 'pipeline_configuration_mismatch'):
                DEPLOY.verify_policy(DEPLOY.deployment_policy(value))

    def test_image_context_includes_thread_entry_without_credentials_or_other_apps(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            worker = root / 'services/pipeline-worker'; worker.mkdir(parents=True)
            shared = root / 'supabase/functions/_shared'; shared.mkdir(parents=True)
            for name in ('Dockerfile', 'package.json', 'package-lock.json', 'server.ts', 'run.ts'):
                (worker / name).write_text('fixture')
            (shared / 'pipeline.ts').write_text('fixture')
            (shared / 'private.test.ts').write_text('test must not ship')
            (root / '.env.staging').write_text('secret-fixture')
            target = root / 'context'; target.mkdir()
            with mock.patch.object(DEPLOY, 'ROOT', root), mock.patch.object(DEPLOY.tempfile, 'mkdtemp', return_value=str(target)):
                self.assertEqual(DEPLOY.context(), target)
            self.assertEqual(sorted(str(p.relative_to(target)) for p in target.rglob('*') if p.is_file()),
                             ['Dockerfile', 'package-lock.json', 'package.json', 'run.ts', 'server.ts',
                              'supabase/functions/_shared/pipeline.ts'])
            docker = (ROOT / 'services/pipeline-worker/Dockerfile').read_text()
            self.assertIn('COPY server.ts run.ts ./services/pipeline-worker/', docker)


if __name__ == '__main__': unittest.main()
