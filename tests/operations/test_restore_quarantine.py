"""Exercise restore quarantine against disposable localhost PostgreSQL fixtures.

No checkpoint, credentials, provider, or existing application database is read.
Only the uniquely named fixture database is created/changed/dropped. Run with:
    python3 -m unittest discover -s tests/operations -p test_restore_quarantine.py -v
"""
import copy
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import unittest
import uuid

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'scripts'))
SPEC = importlib.util.spec_from_file_location('restore_local', ROOT / 'scripts/restore-local.py')
RESTORE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(RESTORE)


class RestoreQuarantineTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.database = 'science_reader_quarantine_' + uuid.uuid4().hex[:12]
        # Explicit localhost arguments and no inherited remote PG configuration.
        cls.base = ['-h', '127.0.0.1', '-p', '55431']
        cls.env = {key: value for key, value in os.environ.items() if not key.startswith('PG')}
        cls.env['PGCONNECT_TIMEOUT'] = '5'
        cls.run_pg('createdb', [cls.database])
        cls.addClassCleanup(cls.run_pg, 'dropdb', [cls.database])

    @classmethod
    def run_pg(cls, binary, args, source=None):
        result = subprocess.run([str(RESTORE.PG_BIN / binary), *cls.base, *args],
                                input=source, env=cls.env, text=True, capture_output=True, timeout=20)
        if result.returncode:
            raise RuntimeError(f'Local quarantine fixture {binary} failed: {result.stderr.strip()}')
        return result.stdout.strip()

    def sql(self, source):
        return self.run_pg('psql', ['-X', '-qAt', '-v', 'ON_ERROR_STOP=1', '-d', self.database], source)

    def setUp(self):
        self.sql("""drop schema if exists app_private cascade;
          create schema app_private;
          create table app_private.platform_budgets (
            name text primary key, work_enabled boolean not null, reserved bigint not null);
          insert into app_private.platform_budgets values ('enabled',true,73),('paused',false,91);
        """)

    def policies(self, acquisition=True, reads=True):
        if acquisition:
            self.sql("""create table app_private.acquisition_policy (
              singleton boolean primary key, metadata_enabled boolean not null,
              original_enabled boolean not null, verification_enabled boolean not null,
              gateway_environment text not null, source_requests_day integer not null,
              active_verification_profile uuid);
              insert into app_private.acquisition_policy values
                (true,true,true,true,'staging',41,'11111111-1111-1111-1111-111111111111');
            """)
        if reads:
            self.sql("""create table app_private.paper_read_policy (
              singleton boolean primary key, enabled boolean not null,
              environment_daily integer not null, account_daily integer not null);
              insert into app_private.paper_read_policy values (true,true,77,13);
            """)

    def recovery_evidence(self):
        # Minimal fixtures retain the actual recovery-sensitive field names;
        # no worker functions or migration DDL are installed in this database.
        self.sql("""create table app_private.arxiv_network_gate (
            singleton boolean primary key, token uuid, generation bigint,
            hard_deadline timestamptz, next_allowed_at timestamptz);
          insert into app_private.arxiv_network_gate values
            (true,'22222222-2222-2222-2222-222222222222',7,'2099-01-01T00:00:00Z','2099-01-01T00:00:03Z');
          create table app_private.acquisition_steps (
            operation_id uuid primary key, outcome text, network_token uuid,
            network_byte_ceiling bigint, network_closed_at timestamptz);
          insert into app_private.acquisition_steps values
            ('33333333-3333-3333-3333-333333333333','uncertain','22222222-2222-2222-2222-222222222222',5242880,null);
          create table app_private.paper_asset_reservations (
            id uuid primary key, state text, held_bytes bigint,
            deletion_generation bigint, deletion_lease_until timestamptz);
          insert into app_private.paper_asset_reservations values
            ('44444444-4444-4444-4444-444444444444','deleting',5000,4,'2099-01-01T01:00:00Z'),
            ('55555555-5555-5555-5555-555555555555','upload_uncertain',5242880,0,null);
          create table app_private.paper_read_grants (
            operation_id uuid primary key, day date, first_byte bigint, last_byte bigint,
            byte_ceiling bigint, expires_at timestamptz);
          insert into app_private.paper_read_grants values
            ('66666666-6666-6666-6666-666666666666','2026-10-03',11,1010,1000,'2099-01-01T02:00:00Z');
          create table app_private.acquisition_transfer_windows (
            period date, scope text, kind text, charged bigint);
          insert into app_private.acquisition_transfer_windows values
            ('2026-10-01','environment','reader_bytes',1000),
            ('2026-09-01','environment','source_bytes',5242880);
        """)

    def rows(self):
        tables = self.sql("select tablename from pg_tables where schemaname='app_private' order by tablename;").splitlines()
        return {table: json.loads(self.sql(
            f"select coalesce(jsonb_agg(to_jsonb(t) order by to_jsonb(t)::text),'[]') from app_private.{table} t;"
        )) for table in tables}

    def assert_quarantined(self):
        before = self.rows()
        expected = copy.deepcopy(before)
        fields = {'platform_budgets': ['work_enabled'],
                  'acquisition_policy': ['metadata_enabled', 'original_enabled', 'verification_enabled'],
                  'paper_read_policy': ['enabled']}
        for table, names in fields.items():
            for row in expected.get(table, []):
                for name in names:
                    row[name] = False
        RESTORE.quarantine(self.sql)
        self.assertEqual(self.rows(), expected)
        # Repeating quarantine neither releases grants nor resets counters.
        RESTORE.quarantine(self.sql)
        self.assertEqual(self.rows(), expected)

    def test_pre011_snapshot_without_optional_tables(self):
        self.assert_quarantined()
        self.assertEqual(set(self.rows()), {'platform_budgets'})

    def test_enabled_011_gates_close_without_changing_recovery_evidence(self):
        self.policies()
        self.recovery_evidence()
        self.assert_quarantined()

    def test_optional_tables_are_checked_independently(self):
        for acquisition in [False, True]:
            with self.subTest(acquisition_table=acquisition):
                self.setUp()
                self.policies(acquisition=acquisition, reads=not acquisition)
                self.assert_quarantined()

    def test_incompatible_present_table_fails_and_rolls_back_every_gate(self):
        self.policies()
        self.sql('alter table app_private.paper_read_policy drop column enabled;')
        before = self.rows()
        with self.assertRaisesRegex(RuntimeError, 'enabled'):
            RESTORE.quarantine(self.sql)
        self.assertEqual(self.rows(), before)


if __name__ == '__main__':
    unittest.main()
