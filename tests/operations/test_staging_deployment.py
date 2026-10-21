import contextlib
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location('staging_deploy', ROOT / 'scripts/deploy-staging.py')
DEPLOY = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(DEPLOY)
PROJECT = 'coxhjvqpflgxkleydati'


class StagingDeploymentTests(unittest.TestCase):
    def run_fixture(self, arguments, *, cleanup=True, health='active', secret=True, migration_fails=False, feed_secret=False,
                    config_extra=None, providers='OPENROUTER_CHAT_API_KEY=secret-fixture\n'):
        events = []
        self.secret_names = []
        output = io.StringIO()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'infra').mkdir()
            (root / 'infra/account.json').write_text(json.dumps({'projects': {'staging': {'id': PROJECT}},
                                                                'organization': {'slug': 'mhiweqpcwyqtyorgqhla'}}))
            config = {'functions': ['chat', 'add-reference', 'store-sync'], 'paper_bucket': {'id': 'paper-assets', 'public': False,
                      'file_size_limit': 67108864}, 'pipeline_worker_url': 'https://fixture-worker.example',
                      'pipeline_schedule': '* * * * *', 'chat_web_search': True, 'admin_origins': ['https://fixture-admin.example'],
                      **(config_extra or {})}
            (root / 'infra/staging.json').write_text(json.dumps(config))
            env = 'SUPABASE_PROJECT_REF=' + PROJECT + '\nSUPABASE_URL=https://fixture-db.example\nSUPABASE_SERVICE_ROLE_KEY=secret-fixture\n'
            if secret: env += 'PIPELINE_SECRET=secret-fixture\n'
            if feed_secret: env += 'FEED_REFRESH_SECRET=secret-fixture-feed\n'
            (root / '.env.staging').write_text(env)
            (root / '.env.providers').write_text(providers)
            for name in config['functions']:
                path = root / 'supabase/functions' / name
                path.mkdir(parents=True)
                (path / 'index.ts').write_text('// fixture only')

            def run(command, **kwargs):
                if command[0] == 'security':
                    events.append('credential')
                    return subprocess.CompletedProcess(command, 0, 'secret-fixture')
                if 'migrate-supabase.py' in command[1]:
                    events.append('migrate')
                    if migration_fails: raise subprocess.CalledProcessError(1, command)
                elif command[0] == 'node' and 'check-arxiv-egress.mjs' in command[1]:
                    events.append('egress_scan'); self.assertIn('--block', command)
                elif command[0] == 'node': events.append(('workflow', command))
                else: events.append(('deploy', command[3]))
                return subprocess.CompletedProcess(command, 0, '')

            def request(url, headers, body=None, method=None, **kwargs):
                if url.endswith('/' + PROJECT):
                    events.append('remote_identity')
                    return {'organization_id': 'mhiweqpcwyqtyorgqhla', 'name': 'science-reader-staging'}
                if url.endswith('/health'):
                    events.append('health')
                    return {'ok': True, 'mode': health}
                if url.endswith('worker_store_verification_readiness'):
                    events.append('purchase_readiness')
                    return {'cleanup': {'active': cleanup, 'expected_command': True, 'schedule': '17 * * * *'}}
                if url.endswith('/config/storage'):
                    events.append('storage_config')
                    return {'fileSizeLimit': 67108864}
                if url.endswith('/bucket/paper-assets'):
                    events.append('bucket_read')
                    return config['paper_bucket']
                if 'note_bucket' in config and url.endswith('/bucket/note-assets'):
                    events.append('note_bucket_read')
                    return {**config['note_bucket'], **getattr(self, 'remote_note_drift', {})}
                if url.endswith('/secrets'):
                    events.append('function_secrets')
                    self.secret_names = [entry['name'] for entry in body]
                    return None
                if url.endswith('/database/query'):
                    events.append(('sql', body['query']))
                    return []
                raise AssertionError('Unexpected fixture request')

            with mock.patch.object(DEPLOY, 'ROOT', root), mock.patch.object(DEPLOY.subprocess, 'run', side_effect=run), \
                 mock.patch.object(DEPLOY, 'request', side_effect=request), contextlib.redirect_stdout(output):
                try:
                    DEPLOY.main(['staging', *arguments])
                    error = None
                except (SystemExit, subprocess.CalledProcessError) as caught:
                    error = caught
            self.assertEqual((root / '.env.staging').read_text(), env, 'fixture must not rotate local credentials')
        self.assertNotIn('secret-fixture', output.getvalue())
        return events, error

    def test_edge_first_deferred_deploy_never_migrates_schedules_or_runs_paid_workflows(self):
        events, error = self.run_fixture(['--defer-activation', '--skip-migrations', '--functions', 'chat', 'add-reference'])
        self.assertIsNone(error)
        self.assertEqual([event for event in events if isinstance(event, tuple)], [('deploy', 'chat'), ('deploy', 'add-reference')])
        self.assertNotIn('migrate', events)
        self.assertNotIn('health', events, 'deferred deployment does not assert that the old worker is stopped')
        self.assertLess(events.index('remote_identity'), events.index('function_secrets'))
        self.assertLess(events.index('function_secrets'), events.index(('deploy', 'chat')))

    def test_note_images_bucket_is_verified_private_before_its_function_deploys(self):
        note = {'id': 'note-assets', 'name': 'note-assets', 'public': False, 'file_size_limit': 2097180,
                'allowed_mime_types': ['application/octet-stream']}
        arguments = ['--defer-activation', '--skip-migrations', '--functions', 'note-assets']
        events, error = self.run_fixture(arguments, config_extra={'note_bucket': note, 'functions': ['note-assets']})
        self.assertIsNone(error)
        self.assertLess(events.index('note_bucket_read'), events.index(('deploy', 'note-assets')))
        for drift in ({'public': True}, {'file_size_limit': 4194304}, {'allowed_mime_types': ['image/png']}):
            self.remote_note_drift = drift
            events, error = self.run_fixture(arguments, config_extra={'note_bucket': note, 'functions': ['note-assets']})
            self.assertIsInstance(error, SystemExit)
            self.assertNotIn('function_secrets', events); self.assertNotIn(('deploy', 'note-assets'), events)
        self.remote_note_drift = {}
        events, error = self.run_fixture(['--defer-activation', '--skip-migrations', '--functions', 'chat'], config_extra={'note_bucket': note})
        self.assertIsNone(error); self.assertNotIn('note_bucket_read', events)

    def test_egress_scan_blocks_first_and_functions_refuse_arxiv(self):
        events, error = self.run_fixture(['--defer-activation', '--skip-migrations', '--functions', 'chat'])
        self.assertIsNone(error)
        self.assertEqual(events.index('egress_scan'), 0, 'the block-mode scan runs before any credential, request or deploy')
        self.assertIn('EGRESS_ARXIV', self.secret_names)

    def test_every_model_route_uses_the_one_openrouter_key_and_never_a_direct_provider_key(self):
        # Owner, 2026-10-18: all remote inference goes through OpenRouter; no direct-provider fallback.
        # Retired direct keys in .env.providers never reach the functions.
        legacy = 'OPENROUTER_CHAT_API_KEY=secret-fixture\nANTHROPIC_API_KEY=secret-fixture-an\nDEEPSEEK_API_KEY=secret-fixture-ds\n'
        events, error = self.run_fixture(['--defer-activation', '--skip-migrations', '--functions', 'chat'], providers=legacy)
        self.assertIsNone(error)
        self.assertIn('OPENROUTER_CHAT_API_KEY', self.secret_names)
        self.assertNotIn('ANTHROPIC_API_KEY', self.secret_names); self.assertNotIn('DEEPSEEK_API_KEY', self.secret_names)
        self.assertIn('CHAT_DEEPSEEK', self.secret_names)
        for mode in ['hidden', 'on']:
            events, error = self.run_fixture(['--defer-activation', '--skip-migrations', '--functions', 'chat'], config_extra={'chat_deepseek': mode})
            self.assertIsNone(error)
            self.assertIn('CHAT_DEEPSEEK', self.secret_names); self.assertNotIn('DEEPSEEK_API_KEY', self.secret_names)
        # Without the OpenRouter key nothing is deployed: refused before any secret is set or function deployed.
        for providers in ['', 'ANTHROPIC_API_KEY=secret-fixture-an\nDEEPSEEK_API_KEY=secret-fixture-ds\n']:
            events, error = self.run_fixture(['--defer-activation', '--skip-migrations', '--functions', 'chat'], providers=providers)
            self.assertIsInstance(error, SystemExit); self.assertNotIn('function_secrets', events)
            self.assertFalse(any(isinstance(e, tuple) for e in events))

    def test_purchase_cleanup_still_gates_deferred_deploy_after_migration(self):
        events, error = self.run_fixture(['--defer-activation', '--functions', 'store-sync'])
        self.assertIsNone(error)
        self.assertLess(events.index('migrate'), events.index('purchase_readiness'))
        self.assertLess(events.index('purchase_readiness'), events.index(('deploy', 'store-sync')))
        self.assertFalse(any(isinstance(e, tuple) and e[0] in ('sql', 'workflow') for e in events))
        events, error = self.run_fixture(['--defer-activation', '--functions', 'store-sync'], cleanup=False)
        self.assertIsInstance(error, SystemExit)
        self.assertNotIn('function_secrets', events)
        self.assertFalse(any(isinstance(e, tuple) for e in events))

    def test_routine_deploy_checks_activation_then_migrates_deploys_schedules_and_checks(self):
        events, error = self.run_fixture(['--functions', 'chat'])
        self.assertIsNone(error)
        self.assertLess(events.index('health'), events.index('migrate'))
        self.assertLess(events.index('migrate'), events.index(('deploy', 'chat')))
        first_sql = next(i for i, event in enumerate(events) if isinstance(event, tuple) and event[0] == 'sql')
        workflow = next(i for i, event in enumerate(events) if isinstance(event, tuple) and event[0] == 'workflow')
        self.assertGreater(first_sql, events.index(('deploy', 'chat')))
        self.assertGreater(workflow, first_sql)
        self.assertIn('--also=chat.smoke,ingest.not-found', events[workflow][1])

    def test_paused_or_legacy_worker_stops_routine_activation_before_any_mutation(self):
        for health in ('maintenance', None):
            events, error = self.run_fixture(['--functions', 'chat'], health=health)
            self.assertIsInstance(error, SystemExit)
            self.assertNotIn('migrate', events)
            self.assertNotIn('function_secrets', events)
            self.assertFalse(any(isinstance(e, tuple) for e in events))

    def test_migration_failure_prevents_function_secret_deploy_and_activation_steps(self):
        events, error = self.run_fixture(['--defer-activation', '--functions', 'chat'], migration_fails=True)
        self.assertIsInstance(error, subprocess.CalledProcessError)
        self.assertNotIn('function_secrets', events)
        self.assertFalse(any(isinstance(e, tuple) for e in events))

    def test_deferred_secret_creation_or_rotation_is_refused_before_requests(self):
        for arguments, secret in [(['--defer-activation', '--rotate-pipeline-secret'], True), (['--defer-activation'], False)]:
            events, error = self.run_fixture(arguments, secret=secret)
            self.assertIsInstance(error, SystemExit)
            self.assertEqual([e for e in events if e != 'egress_scan'], [], 'at most the local scan; no request')

    def test_feed_refresh_secret_reaches_the_function_and_vault_only_when_present(self):
        events, error = self.run_fixture(['--functions', 'chat'])
        self.assertIsNone(error)
        self.assertNotIn('FEED_REFRESH_SECRET', self.secret_names)
        self.assertFalse(any(isinstance(e, tuple) and e[0] == 'sql' and 'science_reader_feed' in e[1] for e in events))
        events, error = self.run_fixture(['--functions', 'chat'], feed_secret=True)
        self.assertIsNone(error)
        self.assertIn('FEED_REFRESH_SECRET', self.secret_names)
        feed_sql = [e[1] for e in events if isinstance(e, tuple) and e[0] == 'sql' and 'science_reader_feed' in e[1]]
        self.assertEqual(len(feed_sql), 4, 'URL and secret, each updated or created')
        self.assertTrue(any('https://fixture-db.example/functions/v1/feed-refresh' in query for query in feed_sql))
        pipeline_vault = next(i for i, e in enumerate(events) if isinstance(e, tuple) and e[0] == 'sql' and 'science_reader_pipeline_secret' in e[1])
        feed_vault = next(i for i, e in enumerate(events) if isinstance(e, tuple) and e[0] == 'sql' and 'science_reader_feed_url' in e[1])
        self.assertLess(pipeline_vault, feed_vault)

    def test_deferred_deploy_cannot_create_the_feed_refresh_secret(self):
        events, error = self.run_fixture(['--defer-activation', '--skip-migrations', '--functions', 'feed-refresh'])
        self.assertIsInstance(error, SystemExit)
        self.assertNotIn('function_secrets', events)
        self.assertFalse(any(isinstance(e, tuple) for e in events))


if __name__ == '__main__': unittest.main()
