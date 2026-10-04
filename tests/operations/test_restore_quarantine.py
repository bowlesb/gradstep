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
                  'paper_read_policy': ['enabled'], 'executor_authority': ['enabled']}
        for table, names in fields.items():
            for row in expected.get(table, []):
                for name in names:
                    row[name] = False
        for row in expected.get('executor_authority', []):
            row['recovery_required'] = True
            row['revision'] += 1
            if 'original_admitted' in row:
                row['original_admitted'] = False
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


class ExecutorSchemaQuarantineTests(QuarantineDatabaseCase):
    """Run the same restore hook against actual 001--012 relations and RPCs.

    Policy hashes and child identities are deliberately synthetic. These tests
    exercise database fencing, not admission of any real network executor.
    """
    POLICY_ID = 'c1200000-0000-0000-0000-000000000099'
    JOB_ID = 'c1200000-0000-0000-0000-000000000098'
    CLAIM_ID = 'c1200000-0000-0000-0000-000000000097'

    @classmethod
    def setUpClass(cls):
        super().setUpClass()
        migration_dir = ROOT / 'supabase/migrations'
        applied_candidate = migration_dir / '202610030012_metadata_execution.sql'
        candidate = applied_candidate if applied_candidate.is_file() else migration_dir / '202610030012_metadata_execution.sql.pending'
        sources = [ROOT / 'tests/database/bootstrap.sql',
                   *sorted(p for p in migration_dir.glob('*.sql') if p.name < '202610030012'), candidate]
        for source in sources:
            cls.run_pg('psql', ['-X', '-qAt', '-v', 'ON_ERROR_STOP=1', '-d', cls.database, '-f', str(source)])

    def setUp(self):
        template = type(self).database
        self.database = 'science_reader_test_' + uuid.uuid4().hex[:12]
        self.run_pg('createdb', ['-T', template, self.database])
        self.addCleanup(self.run_pg, 'dropdb', [self.database])
        self.sql(f"""
          set role science_reader_executor_admitter;
          select public.worker_install_metadata_executor_policy('{self.POLICY_ID}',
            jsonb_build_object('version',1,'kind','metadata-owned-child-v1',
              'connection_model','direct-owned-socket-v1','max_executors',1,
              'runner_sha256',repeat('a',64),'transport_sha256',repeat('b',64),
              'observer_sha256',repeat('c',64),'admission_sha256',repeat('d',64),
              'max_useful_seconds',120,'max_report_seconds',120)::text);
          select public.worker_activate_metadata_executor(1,'abcdefghijklmnopqrst',
            '{self.POLICY_ID}',decode(repeat('e',64),'hex'));
          reset role;
          insert into auth.users values('c1200000-0000-0000-0000-000000000096');
          select set_config('request.jwt.claim.sub','c1200000-0000-0000-0000-000000000096',false);
          select public.v2_begin_import('c1200000-0000-0000-0000-000000000095','2403.50001',0,1);
          set role science_reader_metadata_executor;
          select public.worker_prepare_acquisition('{self.JOB_ID}','2403.50001',1);
          select public.worker_link_import_acquisition('c1200000-0000-0000-0000-000000000096',
            'c1200000-0000-0000-0000-000000000095',1,1,'{self.JOB_ID}');
        """)

    def role_json(self, role, statement):
        return json.loads(self.sql(f'set role {role}; {statement}'))

    def authority(self):
        return self.role_json('science_reader_executor_admitter', 'select public.worker_metadata_authority_state();')

    def assert_activation_rejected(self, revision, category):
        with self.assertRaisesRegex(RuntimeError, category):
            self.role_json('science_reader_executor_admitter', f"""
              select public.worker_activate_metadata_executor({revision},'abcdefghijklmnopqrst',
                '{self.POLICY_ID}',decode(repeat('f',64),'hex'));
            """)

    def assert_no_new_grant(self):
        result = self.role_json('science_reader_metadata_executor', f"""
          select public.worker_claim_metadata_stage_v2('{self.JOB_ID}',gen_random_uuid(),'staging','{{}}');
        """)
        self.assertFalse(result['granted'])
        self.assertEqual(result['action'], 'disabled')

    def test_empty_actual_schema_still_blocks_restored_admission(self):
        before = self.authority()
        self.assertEqual(before['outstanding_executors'], 0)
        self.assertTrue(before['enabled'])
        self.assert_quarantined()
        after = self.authority()
        self.assertEqual(after['epoch'], before['epoch'])
        self.assertEqual(after['revision'], before['revision'] + 2)
        self.assertTrue(after['recovery_required'])
        self.assertFalse(after['enabled'])
        self.assert_activation_rejected(before['revision'], 'stale_executor_authority')
        self.assert_no_new_grant()
        self.assertEqual(self.authority(), after)

    def test_actual_unsettled_connection_survives_and_prevents_activation(self):
        binding = json.loads(self.sql("""
          select jsonb_build_object('version',1,'project_ref',a.project_ref,
            'environment',a.environment,'epoch',a.epoch,'policy_id',p.id,
            'runner_sha256',encode(p.runner_sha256,'hex'),
            'transport_sha256',encode(p.transport_sha256,'hex'),
            'observer_sha256',encode(p.observer_sha256,'hex'),
            'deployment_id','local-restore-fixture',
            'host_id','c1200000-0000-0000-0000-000000000001',
            'boot_id','c1200000-0000-0000-0000-000000000002',
            'process_id',123,'process_start_id','123456',
            'child_id','c1200000-0000-0000-0000-000000000003')
          from app_private.executor_authority a join app_private.executor_policies p on p.id=a.active_policy_id;
        """))
        result = self.role_json('science_reader_metadata_executor', f"""
          select public.worker_claim_metadata_stage_v2('{self.JOB_ID}','{self.CLAIM_ID}',
            'staging','{json.dumps(binding)}');
        """)
        self.assertTrue(result['granted'])
        execution = result['execution']
        facts = json.dumps({'binding_sha256': execution['binding_sha256'], 'disposition': 'exited'})
        self.role_json('science_reader_execution_observer', f"""
          select public.worker_record_metadata_quiescence('{execution['id']}',gen_random_uuid(),
            'executor','owned_child_joined','{facts}');
        """)
        before = self.authority()
        self.assertEqual(before['outstanding_executors'], 0)
        self.assertEqual(before['outstanding_connections'], 1)
        self.assert_quarantined()
        after = self.authority()
        self.assertEqual(after['epoch'], before['epoch'])
        self.assertEqual(after['outstanding_connections'], 1)
        self.assert_activation_rejected(before['revision'], 'stale_executor_authority')
        self.assert_activation_rejected(after['revision'], 'executor_recovery_required')
        self.assert_no_new_grant()
        replay = self.role_json('science_reader_metadata_executor', f"""
          select public.worker_claim_metadata_stage_v2('{self.JOB_ID}','{self.CLAIM_ID}',
            'staging','{json.dumps(binding)}');
        """)
        self.assertFalse(replay['granted'])
        self.assertEqual(replay['action'], 'reconcile')
        self.assertEqual(replay['execution']['pending_resources'], ['arxiv_connection'])
        self.assertEqual(self.authority(), after)


class OriginalSchemaQuarantineTests(QuarantineDatabaseCase):
    """Restore the actual additive 013 schema, with synthetic SQL evidence only."""

    @classmethod
    def setUpClass(cls):
        super().setUpClass()
        migration_dir = ROOT / 'supabase/migrations'
        sources = [ROOT / 'tests/database/bootstrap.sql',
                   *sorted(p for p in migration_dir.glob('*.sql') if p.name < '202610030012')]
        for name in ['202610030012_metadata_execution.sql', '202610040013_original_execution.sql']:
            applied = migration_dir / name
            sources.append(applied if applied.is_file() else migration_dir / (name + '.pending'))
        sources.append(ROOT / 'tests/database/original_execution_helpers.sql')
        cls.run_pg('psql', ['-X', '-qAt', '-v', 'ON_ERROR_STOP=1', '-d', cls.database],
                   f'alter database {cls.database} set timezone to \'UTC\';')
        for source in sources:
            cls.run_pg('psql', ['-X', '-qAt', '-v', 'ON_ERROR_STOP=1', '-d', cls.database, '-f', str(source)])

    def setUp(self):
        template = type(self).database
        self.database = 'science_reader_test_' + uuid.uuid4().hex[:12]
        self.run_pg('createdb', ['-T', template, self.database])
        self.addCleanup(self.run_pg, 'dropdb', [self.database])
        # Database settings are not copied by CREATE DATABASE ... TEMPLATE.
        self.sql(f'alter database {self.database} set timezone to \'UTC\';')
        self.sql('select test.original_enable();')

    @staticmethod
    def json_sql(value):
        return "'" + json.dumps(value).replace("'", "''") + "'::jsonb"

    def authority(self):
        return json.loads(self.sql('set role science_reader_executor_admitter; '
                                   'select public.worker_original_authority_state();'))

    def assert_activation_rejected(self, authority, revision, category):
        with self.assertRaisesRegex(RuntimeError, category):
            self.sql(f"""set role science_reader_executor_admitter;
              select public.worker_activate_original_executor_v1(
                {revision},'{authority['project_ref']}',
                '{authority['metadata_policy_id']}','{authority['original_policy_id']}',
                '{authority['host_id']}','{authority['boot_id']}',
                '{authority['metadata_deployment_id']}','{authority['original_deployment_id']}',
                decode(repeat('e',64),'hex'));
            """)

    def test_actual_original_quarantine_retains_scope_hold_and_all_pins(self):
        fixture = json.loads(self.sql("select test.original_job('2403.50002');"))
        arguments = json.loads(self.sql(
            f"select test.original_claim_args({self.json_sql(fixture)},'original_download');"))
        granted = json.loads(self.sql(f'select test.original_grant({self.json_sql(arguments)});'))
        self.assertTrue(granted['granted'])
        execution = granted['execution']
        closed = json.loads(self.sql(
            f"select test.original_close({self.json_sql(execution)},'executor');"))
        self.assertEqual(closed['execution']['pending_resources'], ['arxiv_connection'])
        self.assertEqual(len(closed['execution']['receipts']), 1)
        before = self.authority()
        self.assertTrue(before['original_admitted'])
        self.assertTrue(before['enabled'])
        self.assertEqual(before['unsettled_attempts'], 1)

        # Compare every application-private row, including both policy pins,
        # job/reservation identities, receipt bytes, source gate and charges.
        self.assert_quarantined()
        after = self.authority()
        self.assertFalse(after['original_admitted'])
        self.assertFalse(after['enabled'])
        self.assertTrue(after['recovery_required'])
        self.assertEqual(after['revision'], before['revision'] + 2)
        self.assertEqual(after['epoch'], before['epoch'])
        self.assertEqual(after['unsettled_attempts'], 1)
        for key in ['metadata_policy_id', 'original_policy_id', 'host_id', 'boot_id',
                    'metadata_deployment_id', 'original_deployment_id']:
            self.assertEqual(after[key], before[key])
        self.assert_activation_rejected(before, before['revision'], 'stale_executor_authority')
        self.assert_activation_rejected(after, after['revision'], 'executor_recovery_required')

        replay = json.loads(self.sql(f'select test.original_grant({self.json_sql(arguments)});'))
        self.assertFalse(replay['granted'])
        self.assertEqual(replay['action'], 'reconcile')
        self.assertEqual(replay['execution'], closed['execution'])
        fresh = copy.deepcopy(arguments)
        fresh['claim_id'] = str(uuid.uuid4())
        fresh['binding']['scope']['scope_id'] = fresh['claim_id']
        fresh['binding']['child_id'] = str(uuid.uuid4())
        fresh['binding']['process_id'] += 1
        refused = json.loads(self.sql(f'select test.original_grant({self.json_sql(fresh)});'))
        self.assertFalse(refused['granted'])
        self.assertEqual(refused['action'], 'disabled')
        self.assertEqual(self.authority(), after)


if __name__ == '__main__':
    unittest.main()
