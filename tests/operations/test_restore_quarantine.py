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


class QuarantineDatabaseCase(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.database = 'science_reader_test_' + uuid.uuid4().hex[:12]
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
                  'paper_read_policy': ['enabled'], 'executor_authority': ['enabled'],
                  'pipeline_policy': ['enabled'], 'pdf_upload_policy': ['enabled'],
                  'tag_policy': ['enabled'], 'provider_spending_policy': ['enabled']}
        for table, names in fields.items():
            for row in expected.get(table, []):
                for name in names:
                    row[name] = False
        for row in expected.get('executor_authority', []):
            row['recovery_required'] = True
            row['revision'] += 1
            if 'original_admitted' in row:
                row['original_admitted'] = False
        for row in expected.get('store_verifier_policy', []):
            if row['enabled']:
                row['enabled'] = False
                row['revision'] += 1
        RESTORE.quarantine(self.sql)
        self.assertEqual(self.rows(), expected)
        # Each restore fences a prior admission CAS, even if the copied authority
        # was already disabled. It never releases holds or resets usage counters.
        for row in expected.get('executor_authority', []):
            row['revision'] += 1
        RESTORE.quarantine(self.sql)
        self.assertEqual(self.rows(), expected)


class RestoreQuarantineTests(QuarantineDatabaseCase):

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

    def execution_evidence(self, held=True):
        self.sql("""create table app_private.executor_authority (
            singleton boolean primary key, enabled boolean not null,
            recovery_required boolean not null, revision bigint not null,
            epoch uuid not null, active_policy_id uuid, project_ref text,
            recovery_evidence_sha256 bytea);
          insert into app_private.executor_authority values
            (true,true,false,7,'77777777-7777-7777-7777-777777777777',
             '88888888-8888-8888-8888-888888888888','fixtureprojectonlyxx',decode(repeat('ab',32),'hex'));
          create table app_private.execution_attempts (
            id uuid primary key, epoch uuid, binding jsonb,
            useful_deadline timestamptz, report_deadline timestamptz);
          create table app_private.execution_quiescence (
            attempt_id uuid, resource text, receipt_id uuid,
            facts jsonb, accepted_at timestamptz);
        """)
        if held:
            self.sql("""insert into app_private.execution_attempts values
                ('99999999-9999-9999-9999-999999999999','77777777-7777-7777-7777-777777777777',
                 '{"child_id":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"}',
                 '2000-01-01T00:00:00Z','2000-01-01T00:02:00Z');
              insert into app_private.execution_quiescence values
                ('99999999-9999-9999-9999-999999999999','executor',
                 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb','{"fixture":"joined"}','2000-01-01T00:03:00Z');
            """)

    def test_pre011_snapshot_without_optional_tables(self):
        self.assert_quarantined()
        self.assertEqual(set(self.rows()), {'platform_budgets'})

    def test_purchase_verifier_restore_disables_channels_without_refunding_starts(self):
        self.sql("""create table app_private.store_verifier_policy (
            channel text primary key, enabled boolean not null, revision bigint not null,
            month_limit integer not null, clock_floor timestamptz not null);
          insert into app_private.store_verifier_policy values
            ('app',true,7,3000,'2026-10-08T01:00:00Z'),
            ('notification',false,4,1000,'2026-10-08T01:00:00Z');
          create table app_private.store_verifier_windows (
            channel text, unit text, starts integer, denied integer);
          insert into app_private.store_verifier_windows values ('app','month',193,17),('notification','month',5,1);
          create table app_private.store_verifier_starts (
            id uuid, channel text, outcome text, finished_at timestamptz);
          insert into app_private.store_verifier_starts values
            ('11111111-1111-1111-1111-111111111111','app','started',null),
            ('22222222-2222-2222-2222-222222222222','notification','verified','2026-10-08T01:00:00Z');
        """)
        self.assert_quarantined()
        self.assertEqual([row['revision'] for row in self.rows()['store_verifier_policy']], [8, 4])
        self.assertEqual(next(row['starts'] for row in self.rows()['store_verifier_windows'] if row['channel'] == 'app'), 193)

    def test_malformed_purchase_verifier_policy_rolls_back_all_quarantine_changes(self):
        self.policies()
        self.sql("create table app_private.store_verifier_policy (channel text, enabled boolean); insert into app_private.store_verifier_policy values ('app',true);")
        before = self.rows()
        with self.assertRaisesRegex(RuntimeError, 'revision'):
            RESTORE.quarantine(self.sql)
        self.assertEqual(self.rows(), before)

    def test_library_dataset_epoch_rotates_on_every_restore(self):
        self.sql("""create table app_private.library_v4_config (
            singleton boolean primary key, dataset_epoch uuid not null, search_version text not null);
          insert into app_private.library_v4_config values
            (true,'11111111-1111-1111-1111-111111111111','fixture-normalization');
        """)
        before = self.rows()['library_v4_config'][0]
        RESTORE.quarantine(self.sql)
        first = self.rows()['library_v4_config'][0]
        RESTORE.quarantine(self.sql)
        second = self.rows()['library_v4_config'][0]
        self.assertEqual(first['search_version'], before['search_version'])
        self.assertEqual(second['search_version'], before['search_version'])
        self.assertEqual(len({before['dataset_epoch'], first['dataset_epoch'], second['dataset_epoch']}), 3)
        self.assertTrue(all(not row['work_enabled'] for row in self.rows()['platform_budgets']))

    def test_incompatible_library_config_rolls_back_quarantine(self):
        self.sql('create table app_private.library_v4_config (singleton boolean primary key);')
        before = self.rows()
        with self.assertRaisesRegex(RuntimeError, 'dataset_epoch'):
            RESTORE.quarantine(self.sql)
        self.assertEqual(self.rows(), before)

    def test_both_library_capability_epochs_rotate_without_changing_normalization(self):
        self.sql("""create table app_private.library_v4_config (
            singleton boolean primary key, dataset_epoch uuid not null,
            upload_dataset_epoch uuid not null, search_version text not null,
            check(dataset_epoch<>upload_dataset_epoch));
          insert into app_private.library_v4_config values
            (true,'11111111-1111-1111-1111-111111111111',
             '22222222-2222-2222-2222-222222222222','fixture-normalization');
        """)
        snapshots = [self.rows()['library_v4_config'][0]]
        for _ in range(2):
            RESTORE.quarantine(self.sql)
            snapshots.append(self.rows()['library_v4_config'][0])
        self.assertEqual(len({row[key] for row in snapshots
                              for key in ('dataset_epoch', 'upload_dataset_epoch')}), 6)
        self.assertTrue(all(row['search_version'] == 'fixture-normalization' for row in snapshots))
        self.assertTrue(all(not row['work_enabled'] for row in self.rows()['platform_budgets']))

    def test_incompatible_upload_epoch_rolls_back_all_quarantine_changes(self):
        self.sql("""create table app_private.library_v4_config (
            singleton boolean primary key, dataset_epoch uuid not null,
            upload_dataset_epoch integer not null);
          insert into app_private.library_v4_config values
            (true,'11111111-1111-1111-1111-111111111111',7);
        """)
        before = self.rows()
        with self.assertRaisesRegex(RuntimeError, 'upload_dataset_epoch'):
            RESTORE.quarantine(self.sql)
        self.assertEqual(self.rows(), before)

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

    def test_executor_quarantine_preserves_epoch_and_unresolved_socket_hold(self):
        self.policies()
        self.recovery_evidence()
        self.execution_evidence()
        self.assert_quarantined()
        row = self.rows()['executor_authority'][0]
        self.assertEqual(row['revision'], 9)
        self.assertTrue(row['recovery_required'])
        self.assertEqual(len(self.rows()['execution_attempts']), 1)
        self.assertEqual([r['resource'] for r in self.rows()['execution_quiescence']], ['executor'])

    def test_empty_execution_snapshot_still_requires_predecessor_reconciliation(self):
        self.execution_evidence(held=False)
        self.assert_quarantined()
        self.assertEqual(self.rows()['execution_attempts'], [])
        self.assertTrue(self.rows()['executor_authority'][0]['recovery_required'])

    def test_already_quarantined_authority_still_fences_old_admission_revision(self):
        self.execution_evidence()
        self.sql('update app_private.executor_authority set enabled=false,recovery_required=true;')
        self.assert_quarantined()
        self.assertEqual(self.rows()['executor_authority'][0]['revision'], 9)

    def test_incompatible_executor_table_rolls_back_all_prior_gate_changes(self):
        self.policies()
        self.execution_evidence()
        self.sql('alter table app_private.executor_authority drop column recovery_required;')
        before = self.rows()
        with self.assertRaisesRegex(RuntimeError, 'recovery_required'):
            RESTORE.quarantine(self.sql)
        self.assertEqual(self.rows(), before)

    def test_original_admission_quarantine_preserves_pins_and_evidence(self):
        self.policies()
        self.recovery_evidence()
        self.execution_evidence()
        self.sql("""alter table app_private.executor_authority
            add column original_admitted boolean not null default false,
            add column original_policy_id uuid,
            add column original_deployment_id text,
            add column admitted_host_id uuid,
            add column admitted_boot_id uuid,
            add constraint original_authority_enabled check(not original_admitted or
              (enabled and not recovery_required and original_policy_id is not null
                and admitted_host_id is not null and admitted_boot_id is not null));
          update app_private.executor_authority set original_admitted=true,
            original_policy_id='cccccccc-cccc-cccc-cccc-cccccccccccc',
            original_deployment_id='original-restore-fixture',
            admitted_host_id='dddddddd-dddd-dddd-dddd-dddddddddddd',
            admitted_boot_id='eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee';
        """)
        self.assert_quarantined()
        row = self.rows()['executor_authority'][0]
        self.assertFalse(row['original_admitted'])
        self.assertEqual(row['original_policy_id'], 'cccccccc-cccc-cccc-cccc-cccccccccccc')
        self.assertEqual(row['revision'], 9)

    def test_incompatible_original_admission_column_rolls_back_all_gates(self):
        self.policies()
        self.execution_evidence()
        self.sql("""alter table app_private.executor_authority
            add column original_admitted integer not null default 1;""")
        before = self.rows()
        with self.assertRaisesRegex(RuntimeError, 'original_admitted'):
            RESTORE.quarantine(self.sql)
        self.assertEqual(self.rows(), before)

    def test_current_pipeline_and_upload_gates_are_disabled_without_losing_policy_evidence(self):
        self.sql("""create table app_private.pipeline_policy(singleton boolean primary key,enabled boolean not null,lease_seconds integer not null);
          insert into app_private.pipeline_policy values(true,true,180);
          create table app_private.pdf_upload_policy(singleton boolean primary key,enabled boolean not null,part_attempts integer not null);
          insert into app_private.pdf_upload_policy values(true,true,3);
          create table app_private.tag_policy(singleton boolean primary key,enabled boolean not null,page_limit integer not null);
          insert into app_private.tag_policy values(true,true,2);
          create table app_private.provider_spending_policy(singleton boolean primary key,enabled boolean not null,liability bigint not null);
          insert into app_private.provider_spending_policy values(true,true,500);""")
        self.assert_quarantined()

    def test_incompatible_upload_gate_rolls_back_current_and_legacy_gate_changes(self):
        self.sql("""create table app_private.pipeline_policy(singleton boolean primary key,enabled boolean not null);
          insert into app_private.pipeline_policy values(true,true);
          create table app_private.pdf_upload_policy(singleton boolean primary key,enabled integer not null);
          insert into app_private.pdf_upload_policy values(true,1);""")
        before = self.rows()
        with self.assertRaisesRegex(RuntimeError, 'enabled'):
            RESTORE.quarantine(self.sql)
        self.assertEqual(self.rows(), before)

    def test_incompatible_provider_gate_rolls_back_every_admission_gate(self):
        self.sql("""create table app_private.pipeline_policy(singleton boolean primary key,enabled boolean not null);
          insert into app_private.pipeline_policy values(true,true);
          create table app_private.pdf_upload_policy(singleton boolean primary key,enabled boolean not null);
          insert into app_private.pdf_upload_policy values(true,true);
          create table app_private.tag_policy(singleton boolean primary key,enabled boolean not null);
          insert into app_private.tag_policy values(true,true);
          create table app_private.provider_spending_policy(singleton boolean primary key,enabled integer not null);
          insert into app_private.provider_spending_policy values(true,1);""")
        before = self.rows()
        with self.assertRaisesRegex(RuntimeError, 'enabled'):
            RESTORE.quarantine(self.sql)
        self.assertEqual(self.rows(), before)


class CurrentSchemaQuarantineTests(QuarantineDatabaseCase):
    """Exercise current library cursors against the real application schema.

    Retired 012/013 executor migrations were never applied and their sources were
    removed from the repository. Minimal legacy-policy fixtures above preserve
    the compatibility contract; current schema integration replaces those stale
    references instead of fetching historical migrations at test runtime.
    """
    ACCOUNT = '39000000-0000-0000-0000-000000000001'

    @classmethod
    def setUpClass(cls):
        super().setUpClass()
        sources = [ROOT / 'tests/database/bootstrap.sql',
                   *sorted((ROOT / 'supabase/migrations').glob('*.sql'))]
        for source in sources:
            cls.run_pg('psql', ['-X', '-qAt', '-v', 'ON_ERROR_STOP=1', '-d', cls.database, '-f', str(source)])

    def actor_sql(self, source):
        return self.sql(f"set role authenticated; set request.jwt.claim.sub='{self.ACCOUNT}'; " + source)

    def test_real_schema_preserves_personal_data_and_rejects_pre_restore_cursors(self):
        self.sql(f"insert into auth.users(id) values ('{self.ACCOUNT}');")
        self.sql('update app_private.pipeline_policy set enabled=true;update app_private.pdf_upload_policy set enabled=true;'
                 'update app_private.tag_policy set enabled=true;update app_private.provider_spending_policy set enabled=true;')
        for i in range(1, 4):
            self.actor_sql(f"select public.v2_begin_import(gen_random_uuid(),'2407.0390{i}',{i-1},1);")
        baseline = json.loads(self.actor_sql('select public.v4_library_page(null,1);'))
        query = json.loads(self.actor_sql("select public.v4_library_query('{}',null,1);"))
        upload_full = json.loads(self.actor_sql('select public.v5_library_page(null,1);'))
        upload_compact = json.loads(self.actor_sql('select public.v5_library_compact_page(null,1);'))
        upload_query = json.loads(self.actor_sql("select public.v5_library_query('{}',null,1);"))
        self.assertIsNotNone(baseline['next_cursor'])
        self.assertIsNotNone(query['next_cursor'])
        before = self.rows()
        RESTORE.quarantine(self.sql)
        after = self.rows()
        expected = copy.deepcopy(before)
        old_epoch = before['library_v4_config'][0]['dataset_epoch']
        new_epoch = after['library_v4_config'][0]['dataset_epoch']
        self.assertNotEqual(old_epoch, new_epoch)
        expected['library_v4_config'][0]['dataset_epoch'] = new_epoch
        old_upload_epoch = before['library_v4_config'][0]['upload_dataset_epoch']
        new_upload_epoch = after['library_v4_config'][0]['upload_dataset_epoch']
        self.assertEqual(len({old_epoch, new_epoch, old_upload_epoch, new_upload_epoch}), 4)
        expected['library_v4_config'][0]['upload_dataset_epoch'] = new_upload_epoch
        for table, names in {'platform_budgets': ['work_enabled'],
                             'acquisition_policy': ['metadata_enabled', 'original_enabled', 'verification_enabled'],
                             'paper_read_policy': ['enabled'], 'pipeline_policy': ['enabled'],
                             'pdf_upload_policy': ['enabled'], 'tag_policy': ['enabled'],
                             'provider_spending_policy': ['enabled']}.items():
            for row in expected[table]:
                for name in names:
                    row[name] = False
        self.assertEqual(after, expected, 'personal rows, sequence, holds and usage survive quarantine exactly')
        for statement, error in [
            (f"select public.v4_library_page('{json.dumps(baseline['next_cursor'])}'::jsonb,1);", 'library_resync_required'),
            (f"select public.v4_library_changes('{old_epoch}',0);", 'library_resync_required'),
            (f"select public.v4_library_metadata('{old_epoch}',array[]::uuid[]);", 'library_resync_required'),
            (f"select public.v4_library_query('{{}}','{json.dumps(query['next_cursor'])}'::jsonb,1);", 'library_query_restart_required'),
            (f"select public.v5_library_page('{json.dumps(upload_full['next_cursor'])}'::jsonb,1);", 'library_resync_required'),
            (f"select public.v5_library_changes('{old_upload_epoch}',0);", 'library_resync_required'),
            (f"select public.v5_library_compact_page('{json.dumps(upload_compact['next_cursor'])}'::jsonb,1);", 'library_resync_required'),
            (f"select public.v5_library_compact_changes('{old_upload_epoch}',0);", 'library_resync_required'),
            (f"select public.v5_library_metadata('{old_upload_epoch}',array[]::uuid[]);", 'library_resync_required'),
            (f"select public.v5_library_query('{{}}','{json.dumps(upload_query['next_cursor'])}'::jsonb,1);", 'library_query_restart_required'),
        ]:
            with self.subTest(statement=statement), self.assertRaisesRegex(RuntimeError, error):
                self.actor_sql(statement)
        fresh = json.loads(self.actor_sql('select public.v4_library_page();'))
        self.assertEqual(fresh['dataset_epoch'], new_epoch)
        self.assertEqual(len(fresh['entries']), 3)
        self.assertEqual(json.loads(self.actor_sql('select public.v5_library_page();'))['dataset_epoch'], new_upload_epoch)


if __name__ == '__main__':
    unittest.main()
