import importlib.util
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location('podcast_ops', ROOT / 'scripts/podcast-ops.py')
OPS = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(OPS)
OWNER = '46000000-0000-4000-8000-00000000000f'
ENV = {'SUPABASE_PROJECT_REF': 'coxhjvqpflgxkleydati', 'SUPABASE_URL': 'https://coxhjvqpflgxkleydati.supabase.co', 'SUPABASE_SERVICE_ROLE_KEY': 'k'}


class PodcastOpsTests(unittest.TestCase):
    def call(self, argv):
        with mock.patch.object(OPS, 'env_values', return_value=ENV), mock.patch.object(OPS, 'rpc', return_value={'ok': True}) as rpc, \
             mock.patch('builtins.print'):
            OPS.main(argv)
        return rpc.call_args

    def test_seed_allowance_cannot_exceed_the_approved_two_dollars(self):
        with self.assertRaises(SystemExit):
            self.call(['seed-period', '--actor', OWNER, '--limit-usd', '2.01', '--enable', '--evidence', 'owner-decision-20261008'])
        name, params = self.call(['seed-period', '--actor', OWNER, '--limit-usd', '2', '--enable', '--evidence', 'owner-decision-20261008',
                                  '--period', '2026-10-01']).args[1:]
        self.assertEqual(name, 'worker_podcast_seed_period')
        self.assertEqual((params['p_limit_microusd'], params['p_enabled'], params['p_period']), (2_000_000, True, '2026-10-01'))

    def test_mutations_carry_actor_and_replayable_request_ids(self):
        rid = '46000000-0000-4000-8000-000000000123'
        name, params = self.call(['seed', '--actor', OWNER, '--approval', '46000000-0000-4000-8000-000000000999',
                                  '--reason', 'CC BY 4.0 verified', '--request-id', rid]).args[1:]
        self.assertEqual(name, 'worker_podcast_seed_admit')
        self.assertEqual((params['p_actor'], params['p_request_id'], params['p_fixture']), (OWNER, rid, False))
        name, params = self.call(['policy', '--actor', OWNER, '--set', 'seed_enabled=true', '--set', 'max_active_environment=2',
                                  '--reason', 'Seed pilot']).args[1:]
        self.assertEqual(params['p_changes'], {'seed_enabled': True, 'max_active_environment': 2})
        with self.assertRaises(SystemExit):
            self.call(['policy', '--actor', OWNER, '--set', 'price=1', '--reason', 'Nope'])
        name, params = self.call(['policy', '--actor', OWNER, '--set', 'allowed_profiles=podcast-5min-v1:1, podcast-10min-v1:1',
                                  '--reason', 'Offer two lengths']).args[1:]
        self.assertEqual(params['p_changes'], {'allowed_profiles': ['podcast-5min-v1:1', 'podcast-10min-v1:1']})
        with self.assertRaises(SystemExit):
            self.call(['policy', '--actor', OWNER, '--set', 'allowed_profiles=podcast-5min-v1', '--reason', 'No version'])
        with self.assertRaises(SystemExit):
            self.call(['seed', '--actor', 'not-a-uuid', '--approval', rid, '--reason', 'x' * 10])

    def test_read_only_commands(self):
        self.assertEqual(self.call(['status']).args[1], 'worker_podcast_status')
        self.assertEqual(self.call(['candidates', '--limit', '5']).args[1:], ('worker_podcast_seed_candidates', {'p_limit': 5}))
        self.assertEqual(self.call(['kick']).args[1], 'worker_podcast_kick_due')


if __name__ == '__main__':
    unittest.main()
