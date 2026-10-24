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
                'env': [{'name': name, 'valueFrom': {'secretKeyRef': {'name': 'gradstep-' + name.lower().replace('_', '-'), 'key': '7'}}}
                        for name in DEPLOY.SECRETS] + [{'name': 'DO_NOT_PRINT', 'value': 'secret-fixture'}]}]}}},
        'status': {'latestReadyRevisionName': 'fixture-1', 'traffic': [{'revisionName': 'fixture-1', 'percent': 100}]},
    }


class PipelineDeploymentTests(unittest.TestCase):
    def test_old_revision_read_does_not_relax_new_revision_openrouter_requirement(self):
        old = service()
        env = old['spec']['template']['spec']['containers'][0]['env']
        env[:] = [row for row in env if row['name'] != 'OPENROUTER_CHAT_API_KEY']
        self.assertIsNotNone(DEPLOY.deployment_policy(old, previous_revision=True)['secret_versions'])
        self.assertIsNone(DEPLOY.deployment_policy(old)['secret_versions'])

    def test_created_secret_versions_are_pinned_and_ambiguous_acknowledgement_never_uses_latest(self):
        versions, calls = {}, []
        def gcloud(*args, **kwargs):
            calls.append((args, kwargs))
            if args[:3] == ('secrets', 'versions', 'add'):
                self.assertIn('--format=value(name)', args)
                self.assertEqual(kwargs['input'], 'private-fixture')
                versions[args[3]] = str(len(versions) + 5)
                return mock.Mock(stdout=f'projects/{DEPLOY.READINESS.PROJECT_NUMBER}/secrets/{args[3]}/versions/{versions[args[3]]}\n')
            return mock.Mock(stdout='')
        values = {name: 'private-fixture' for name in DEPLOY.SECRETS}
        with mock.patch.object(DEPLOY.subprocess, 'run', return_value=mock.Mock(returncode=0)), \
             mock.patch.object(DEPLOY, 'gcloud', side_effect=gcloud):
            mapping = DEPLOY.upload_secrets('gradstep', values, 'account-fixture')
        self.assertEqual(mapping, ','.join(f'{name}={secret}:{versions[secret]}'
                         for name in values for secret in ['gradstep-' + name.lower().replace('_', '-')]))
        self.assertNotIn('latest', mapping); self.assertNotIn('private-fixture', mapping)
        for value in ('', 'projects/other/secrets/gradstep-supabase-url/versions/5',
                      'projects/gradstep/secrets/gradstep-supabase-url/versions/latest',
                      'projects/gradstep/secrets/another-secret/versions/5'):
            with mock.patch.object(DEPLOY.subprocess, 'run', return_value=mock.Mock(returncode=0)), \
                 mock.patch.object(DEPLOY, 'gcloud', return_value=mock.Mock(stdout=value)) as send:
                with self.assertRaisesRegex(RuntimeError, 'version_unverified'):
                    DEPLOY.upload_secrets('gradstep', values, 'account-fixture')
                self.assertEqual(send.call_count, 1, 'ambiguous version creation is not retried or changed to latest')
        with mock.patch.object(DEPLOY.subprocess, 'run', return_value=mock.Mock(returncode=0)), \
             mock.patch.object(DEPLOY, 'gcloud', side_effect=DEPLOY.subprocess.CalledProcessError(1, ['gcloud', 'secrets', 'versions', 'add'])) as send:
            with self.assertRaises(DEPLOY.subprocess.CalledProcessError):
                DEPLOY.upload_secrets('gradstep', values, 'account-fixture')
            self.assertEqual(send.call_count, 1, 'a failed version creation is not retried or followed by activation')

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
            for name in ('Dockerfile', 'package.json', 'package-lock.json', 'server.ts', 'run.ts', 'podcast-run.ts', 'podcast-encode.ts',
                         'interest-run.ts', 'interest-embed.ts'):
                (worker / name).write_text('fixture')
            (worker / 'model').mkdir()
            (worker / 'model/vocab.txt').write_text('fixture')
            (worker / 'model/gte-small.onnx').write_text('a local model must not ship; the Dockerfile fetches it by checksum')
            (shared / 'metadata-pipeline.ts').write_text('fixture')
            (shared / 'private.test.ts').write_text('test must not ship')
            (root / '.env.staging').write_text('secret-fixture')
            target = root / 'context'; target.mkdir()
            with mock.patch.object(DEPLOY, 'ROOT', root), mock.patch.object(DEPLOY.tempfile, 'mkdtemp', return_value=str(target)):
                self.assertEqual(DEPLOY.context(), target)
            self.assertEqual(sorted(str(p.relative_to(target)) for p in target.rglob('*') if p.is_file()),
                             ['Dockerfile', 'interest-embed.ts', 'interest-run.ts', 'model/vocab.txt', 'package-lock.json', 'package.json',
                              'podcast-encode.ts', 'podcast-run.ts', 'run.ts', 'server.ts', 'supabase/functions/_shared/metadata-pipeline.ts'])
            docker = (ROOT / 'services/pipeline-worker/Dockerfile').read_text()
            self.assertIn('COPY server.ts run.ts podcast-run.ts podcast-encode.ts interest-run.ts interest-embed.ts ./services/pipeline-worker/', docker)
            # The interest index model: fetched at build time, pinned by SHA-256 (docs/architecture/INTEREST_INDEX.md).
            self.assertIn('ADD --checksum=sha256:398a29991324e0b383afa13375d681ced3079c83e097fb1ebd9290d7498523b3', docker)

    def test_no_direct_provider_identity_or_key_reaches_the_worker(self):
        # Owner, 2026-10-21: OpenRouter exclusively. Speech no longer has a Vertex identity; no direct key is accepted.
        args = DEPLOY.deployment_args('gradstep', 'us-west1', 'image', 'account', 'mapping')
        self.assertEqual(args[args.index('--update-env-vars') + 1], 'PIPELINE_MAINTENANCE=false,EGRESS_ARXIV=block')
        for name in ('PODCAST_SPEECH_SERVICE_ACCOUNT', 'PODCAST_GCP_PROJECT', 'ANTHROPIC_API_KEY', 'DEEPSEEK_API_KEY'):
            with self.assertRaises(ValueError):
                DEPLOY.deployment_args('gradstep', 'us-west1', 'image', 'account', 'mapping', extra_env={name: 'x'})
        self.assertEqual(set(DEPLOY.SECRETS), {'SUPABASE_URL', 'SUPABASE_SERVICE_ROLE_KEY', 'PIPELINE_SECRET', 'OPENROUTER_CHAT_API_KEY'})


class PipelineActivationOrderTests(unittest.TestCase):
    def test_deferred_flags_are_explicit_and_readback_cannot_mislabel_an_active_revision(self):
        for deferred in (False, True):
            args = DEPLOY.deployment_args('gradstep', 'us-west1', 'image', 'account', 'mapping', deferred=deferred)
            self.assertEqual(args[args.index('--update-env-vars') + 1], 'PIPELINE_MAINTENANCE=' + str(deferred).lower() + ',EGRESS_ARXIV=block')
            value = service()
            value['spec']['template']['spec']['containers'][0]['env'].append({'name': 'PIPELINE_MAINTENANCE', 'value': str(deferred).lower()})
            policy = DEPLOY.deployment_policy(value)
            DEPLOY.verify_policy(policy, maintenance=deferred)
            with self.assertRaisesRegex(RuntimeError, 'maintenance'):
                DEPLOY.verify_policy(policy, maintenance=not deferred)
            self.assertNotIn('secret-fixture', json.dumps(policy))

    def test_deferred_cli_only_deploys_no_retry_or_workflow_call(self):
        events = []
        with mock.patch.object(DEPLOY, 'deploy', side_effect=lambda p, r, **kw: events.append(('deploy', kw)) or 'label'), \
             mock.patch.object(DEPLOY, 'retry_failed', side_effect=lambda label: events.append('retry')), \
             mock.patch.object(DEPLOY, 'workflow_checks', side_effect=lambda: events.append('checks')):
            DEPLOY.main(['deploy', '--project', 'gradstep', '--defer-activation'])
        self.assertEqual(events, [('deploy', {'deferred': True})])

    def test_normal_cli_never_retries_legacy_jobs_and_skip_checks_still_deploys(self):
        for extra, expected in [([], ['deploy', 'checks']), (['--skip-checks'], ['deploy'])]:
            events = []
            with mock.patch.object(DEPLOY, 'deploy', side_effect=lambda p, r, **kw: events.append('deploy') or 'label'), \
                 mock.patch.object(DEPLOY, 'retry_failed', side_effect=lambda label: events.append('retry')), \
                 mock.patch.object(DEPLOY, 'workflow_checks', side_effect=lambda: events.append('checks')):
                DEPLOY.main(['deploy', '--project', 'gradstep', *extra])
            self.assertEqual(events, expected)

    def test_ordinary_deploy_cannot_clear_maintenance_or_unknown_legacy_revision(self):
        for switch in (None, 'true'):
            value = service()
            if switch:
                value['spec']['template']['spec']['containers'][0]['env'].append({'name': 'PIPELINE_MAINTENANCE', 'value': switch})
            with mock.patch.object(DEPLOY, 'describe_service', return_value=value), mock.patch.object(DEPLOY, 'secrets') as secrets:
                with self.assertRaisesRegex(RuntimeError, 'maintenance'):
                    DEPLOY.deploy('gradstep', 'us-west1')
                secrets.assert_not_called()

    def test_legacy_latest_secret_references_block_deployment_readiness_even_with_an_active_switch(self):
        value = service()
        value['spec']['template']['spec']['containers'][0]['env'].append({'name': 'PIPELINE_MAINTENANCE', 'value': 'false'})
        value['spec']['template']['spec']['containers'][0]['env'][0]['valueFrom']['secretKeyRef']['key'] = 'latest'
        with mock.patch.object(DEPLOY, 'describe_service', return_value=value), mock.patch.object(DEPLOY, 'secrets') as secrets:
            with self.assertRaisesRegex(RuntimeError, 'secret_versions'):
                DEPLOY.deploy('gradstep', 'us-west1')
            secrets.assert_not_called()

    def test_deferred_cutover_checks_maintenance_and_only_updates_destination(self):
        events = []
        with mock.patch.object(DEPLOY, 'verify_health', side_effect=lambda value: events.append(('health', value))), \
             mock.patch.object(DEPLOY, 'cutover', side_effect=lambda value: events.append(('cutover', value))), \
             mock.patch.object(DEPLOY, 'workflow_checks', side_effect=lambda: events.append('checks')):
            DEPLOY.main(['cutover', '--url', DEPLOY.READINESS.SERVICE_URL, '--defer-activation'])
        self.assertEqual(events, [('health', True), ('cutover', DEPLOY.READINESS.SERVICE_URL)])

    def test_explicit_retry_or_checks_cannot_run_while_maintenance_gate_is_set(self):
        with mock.patch.object(DEPLOY, 'verify_health', side_effect=RuntimeError('maintenance')), \
             mock.patch.object(DEPLOY, 'secrets') as secrets, mock.patch.object(DEPLOY.subprocess, 'run') as run:
            for action in (lambda: DEPLOY.retry_failed('fixture'), DEPLOY.workflow_checks):
                with self.assertRaisesRegex(RuntimeError, 'maintenance'): action()
            secrets.assert_not_called(); run.assert_not_called()


if __name__ == '__main__': unittest.main()
