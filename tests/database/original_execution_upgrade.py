"""Populated 012→013 preservation in the caller's disposable local database.

The parent loads the immutable prefix through 012. This module never creates or
drops a database, starts a worker, or supplies real process/Storage attestations.
"""
import concurrent.futures
import importlib.util
import json
import pathlib
import uuid


_PATH = pathlib.Path(__file__).with_name('original_execution_concurrency.py')
_SPEC = importlib.util.spec_from_file_location('original_upgrade_race_helpers', _PATH)
_HELPERS = importlib.util.module_from_spec(_SPEC)
_SPEC.loader.exec_module(_HELPERS)
Database, quoted, json_sql = _HELPERS.Database, _HELPERS.quoted, _HELPERS.json_sql
METADATA, OBSERVER, ADMITTER, EXECUTOR = (_HELPERS.METADATA, _HELPERS.OBSERVER,
                                       _HELPERS.ADMITTER, _HELPERS.EXECUTOR)


def _new_id():
    return str(uuid.uuid4())


def _policy(kind, marker):
    return {'version': 1, 'kind': kind, 'connection_model': 'direct-owned-socket-v1', 'max_executors': 1,
            'runner_sha256': marker * 64, 'transport_sha256': 'b' * 64, 'observer_sha256': 'c' * 64,
            'admission_sha256': 'd' * 64, 'max_useful_seconds': 120, 'max_report_seconds': 120}


def _metadata_args(database, job, *, scoped=False):
    claim = _new_id()
    binding = database.json('select test.executor_binding();')
    if scoped:
        authority = database.json('select to_jsonb(a) from app_private.executor_authority a;')
        binding.update(version=2, host_id=authority['admitted_host_id'], boot_id=authority['admitted_boot_id'],
                       deployment_id=authority['admitted_deployment_id'],
                       scope={'kind': 'linux-systemd-cgroup-v1', 'scope_id': claim,
                              'invocation_id': '1' * 32, 'cgroup_device': '0', 'cgroup_inode': '1234',
                              'capture_sha256': '1' * 64})
    return {'job_id': job, 'claim_id': claim, 'binding': binding}


def _claim(args):
    return (f"public.worker_claim_metadata_stage_v2({quoted(args['job_id'])},"
            f"{quoted(args['claim_id'])},'staging',{json_sql(args['binding'])})")


def _state(database, args):
    return database.call(OBSERVER, f"public.worker_metadata_execution_state({quoted(args['job_id'])},"
                                  f"{quoted(args['claim_id'])})")


def _close(database, execution, resource, receipt=None, *, scoped=False):
    receipt = receipt or _new_id()
    if scoped:
        scope = execution['binding']['scope']
        facts = {'binding_sha256': execution['binding_sha256'], 'scope_id': scope['scope_id'],
                 'capture_sha256': scope['capture_sha256'], 'fence_sha256': '2' * 64,
                 'observation_sha256': '3' * 64}
        if resource == 'arxiv_connection':
            facts.update(framing='unknown', peer_eof=False, actual_bytes=None, body_sha256=None,
                         status_code=None, retry_after_seconds=0)
        expression = (f"public.worker_record_metadata_quiescence({quoted(execution['id'])},{quoted(receipt)},"
                      f"{quoted(resource)},'owned_scope_retired_v1',{json_sql(facts)})")
        return database.call(OBSERVER, expression)
    return database.json(f'select test.executor_close({json_sql(execution)},{quoted(resource)},true,{quoted(receipt)});')


def _retire(database):
    revision = database.value('select revision from app_private.executor_authority;')
    return database.call(ADMITTER, f'public.worker_retire_metadata_executor({int(revision)})')


def _seed_eligible_lookup(database, source):
    job = database.value(f'select test.executor_job({quoted(source)});')
    attempts, receipts = [], []
    for stage in ('atom', 'license'):
        database.sql("update app_private.arxiv_network_gate set next_allowed_at='-infinity';")
        args = _metadata_args(database, job)
        granted = database.call(METADATA, _claim(args))
        assert granted['granted'] is True
        execution = granted['execution']
        # The historical v1 contract permits source closure before executor
        # closure. Preserve its exact receipt bytes, not a rewritten v2 proof.
        source_receipt = _close(database, execution, 'arxiv_connection')
        if stage == 'atom':
            body = {'revision': 1, 'metadata': {'title': 'Populated original upgrade fixture',
                    'authors': ['Synthetic Author'], 'categories': ['cs.LG'], 'updated_at': '2024-03-02'},
                    'atom_updated_at': '2024-03-02T00:00:00Z'}
        else:
            body = {'eligible': True, 'license_uri': 'https://creativecommons.org/licenses/by/4.0/',
                    'evidence': {'source_id': source, 'source_revision': 1,
                    'source_url': 'https://arxiv.org/abs/' + source + 'v1',
                    'license_uri': 'https://creativecommons.org/licenses/by/4.0/', 'evidence_format': 'arXivRaw',
                    'evidence_sha256': 'f' * 64, 'observed_at': '2026-10-04T01:00:00Z',
                    'latest_version_at': '2024-03-02T00:00:00Z'}}
        database.call(METADATA, f"public.worker_finish_metadata_stage_v2({quoted(job)},{quoted(args['claim_id'])},"
                               f"{execution['generation']},{quoted(execution['id'])},decode(repeat('f',64),'hex'),{json_sql(body)})")
        executor_receipt = _close(database, execution, 'executor')
        attempts.append((args, execution))
        receipts.extend(((execution, 'arxiv_connection', source_receipt['receipt_id']),
                         (execution, 'executor', executor_receipt['receipt_id'])))
    return job, attempts, receipts


def _columns(database):
    return database.json("select jsonb_object_agg('app_private.'||table_name,columns) from "
                         "(select table_name,jsonb_agg(column_name order by ordinal_position) columns "
                         "from information_schema.columns where table_schema='app_private' group by table_name) c;")


def _refused_migration_preserves(database, migration):
    columns = _columns(database)
    before = {table: database.rows(table, columns=names) for table, names in columns.items()}
    result = database.sql(migration, required=False)
    assert result.returncode and 'original_migration_requires_disabled_workers' in result.stderr
    assert _columns(database) == columns, 'refused migration changed the old schema'
    assert {table: database.rows(table, columns=names) for table, names in columns.items()} == before


def verify(bin_path, db, base, root):
    database, root = Database(bin_path, db, base), pathlib.Path(root).resolve()
    candidate = root / 'supabase/migrations/202610040013_original_execution.sql.pending'
    if not candidate.is_file():
        raise AssertionError('the explicit local original migration candidate is missing')
    migration = candidate.read_text()
    assert database.value("select not exists(select 1 from information_schema.columns where table_schema='app_private' "
                          "and table_name='executor_authority' and column_name='original_policy_id');") == 't'
    # Reuse only the existing 012 helper definitions, not its independent test
    # transactions. Refuse if the explicit boundary is changed or removed.
    metadata_fixture = (root / 'tests/database/test_metadata_execution.sql').read_text()
    if '\nbegin;\n' not in metadata_fixture:
        raise AssertionError('012 fixture helper boundary changed')
    database.sql(metadata_fixture.split('\nbegin;\n', 1)[0])
    database.sql('select test.executor_enable();')
    v1_policy = database.value('select active_policy_id from app_private.executor_authority;')
    lookup, history, receipts = _seed_eligible_lookup(database, '2404.71001')

    legacy = _new_id()
    database.sql(f"insert into app_private.acquisition_jobs(id,kind,source_id,requested_revision,input_sha256,"
                 f"metadata_id,version_id,source_revision,eligibility,license_uri,evidence,stage,status,slots_held) "
                 f"select {quoted(legacy)},'original',source_id,requested_revision,sha256('legacy-unissued-original'::bytea),"
                 f"metadata_id,version_id,source_revision,eligibility,license_uri,evidence,'reserve','queued',24 "
                 f"from app_private.acquisition_jobs where id={quoted(lookup)};")
    _retire(database)
    v2_policy = _new_id()
    definition = json.dumps(_policy('metadata-linux-scope-v1', '9'), separators=(',', ':'), sort_keys=True)
    database.call(ADMITTER, f'public.worker_install_metadata_executor_policy({quoted(v2_policy)},{quoted(definition)})')
    revision = database.value('select revision from app_private.executor_authority;')
    database.call(ADMITTER, f"public.worker_activate_metadata_executor_v2({revision},'abcdefghijklmnopqrst',"
                           f"{quoted(v2_policy)},'c1200000-0000-0000-0000-000000000001',"
                           f"'c1200000-0000-0000-0000-000000000002','original-upgrade-fixture',decode(repeat('e',64),'hex'))")
    v2_job = database.value("select test.executor_job('2404.71002');")
    database.sql("update app_private.arxiv_network_gate set next_allowed_at='-infinity';")
    v2_args = _metadata_args(database, v2_job, scoped=True)
    v2_grant = database.call(METADATA, _claim(v2_args))
    assert v2_grant['granted'] is True
    v2 = v2_grant['execution']
    early = database.sql(f"select test.executor_close({json_sql(v2)},'arxiv_connection');", required=False)
    assert early.returncode and 'executor_retirement_required' in early.stderr
    v2_executor_receipt = _close(database, v2, 'executor', scoped=True)
    # Isolate the authority check from every legacy switch, then isolate each
    # switch below after positively retiring the authority.
    database.sql('update app_private.acquisition_policy set metadata_enabled=false;')
    _refused_migration_preserves(database, migration)
    _retire(database)
    assert database.value('select not enabled and recovery_required from app_private.executor_authority;') == 't'
    for switch in ('metadata_enabled', 'original_enabled', 'verification_enabled'):
        database.sql(f'update app_private.acquisition_policy set {switch}=true;')
        try:
            _refused_migration_preserves(database, migration)
        finally:
            database.sql(f'update app_private.acquisition_policy set {switch}=false;')
    database.sql('update app_private.paper_read_policy set enabled=true;')
    try:
        _refused_migration_preserves(database, migration)
    finally:
        database.sql('update app_private.paper_read_policy set enabled=false;')
    print('PASS 013 refuses enabled authority and each old worker switch without schema/data mutation', flush=True)

    columns = _columns(database)
    before = {table: database.rows(table, columns=names) for table, names in columns.items()}
    states = {args['claim_id']: _state(database, args) for args, _ in history}
    states[v2_args['claim_id']] = _state(database, v2_args)
    run = uuid.uuid4().hex[:10]
    migration_name = 'original-upgrade-' + run
    # Existing account/catalog writers may hold a referenced job's KEY SHARE
    # lock. The additive DDL must wait and preserve the committed old records.
    with database.transaction(f"select 1 from app_private.library_policy for update;"
                              f"select 1 from app_private.acquisition_jobs where id={quoted(lookup)} for key share;",
                              'original-upgrade-writer-' + run) as writer:
        with concurrent.futures.ThreadPoolExecutor(max_workers=1) as pool:
            applying = pool.submit(database.sql, migration, migration_name)
            database.wait(migration_name, blocker=writer.pid, future=applying)
            writer.release()
            applying.result()
    for table, names in columns.items():
        assert database.rows(table, columns=names) == before[table], table + ' changed existing 012 values'
    for args, _ in history + [(v2_args, v2)]:
        assert _state(database, args) == states[args['claim_id']], 'metadata DTO changed across 013'
        replay = database.call(METADATA, _claim(args))
        assert replay['granted'] is False and replay['execution']['id'] == states[args['claim_id']]['execution']['id']
    assert database.value('select not original_admitted and original_policy_id is null and original_deployment_id is null '
                          'from app_private.executor_authority;') == 't'
    assert database.value(f"select execution_contract='legacy-011' and slots_held=24 from app_private.acquisition_jobs where id={quoted(legacy)};") == 't'
    print('PASS 013 populated upgrade preserves every old column, metadata DTO, policy, charge and receipt through FK contention', flush=True)

    # Exact old proof replay must neither allocate an alias receipt nor move
    # cooldown/refund facts after the new resource mapping has been installed.
    immutable = ('app_private.execution_attempts', 'app_private.execution_quiescence',
                 'app_private.acquisition_steps', 'app_private.acquisition_transfer_windows',
                 'app_private.arxiv_network_gate')
    saved = {table: database.rows(table) for table in immutable}
    for execution, resource, receipt in receipts:
        assert _close(database, execution, resource, receipt)['replayed'] is True
    assert _close(database, v2, 'executor', v2_executor_receipt['receipt_id'], scoped=True)['replayed'] is True
    assert {table: database.rows(table) for table in immutable} == saved
    _close(database, v2, 'arxiv_connection')
    assert _state(database, v2_args)['execution']['pending_resources'] == []
    assert database.value(f"select count(*) from app_private.execution_quiescence where attempt_id={quoted(v2['id'])};") == '2'
    print('PASS 013 preserves old v1 replay and v2 executor-first/mixed-proof closure without alias rows', flush=True)

    # New v1 work after upgrade must retain the same source-first semantics.
    revision = database.value('select revision from app_private.executor_authority;')
    database.call(ADMITTER, f"public.worker_activate_metadata_executor({revision},'abcdefghijklmnopqrst',"
                           f"{quoted(v1_policy)},decode(repeat('e',64),'hex'))")
    fresh_job = database.value("select test.executor_job('2404.71003');")
    database.sql("update app_private.arxiv_network_gate set next_allowed_at='-infinity';")
    fresh_args = _metadata_args(database, fresh_job)
    fresh = database.call(METADATA, _claim(fresh_args))['execution']
    _close(database, fresh, 'arxiv_connection')
    assert _state(database, fresh_args)['execution']['pending_resources'] == ['executor']
    _close(database, fresh, 'executor')
    _retire(database)
    print('PASS 013 leaves fresh metadata-v1 source-first closure usable under its unchanged policy', flush=True)

    # The original helper definitions are deliberately loaded only after the
    # historical-data comparison. They cannot conceal a migration rewrite.
    database.sql((root / 'tests/database/original_execution_helpers.sql').read_text())
    database.sql('select test.original_enable();')
    database.reject(EXECUTOR, f'public.worker_prepare_original_v1({quoted(_new_id())},{quoted(lookup)})',
                    'legacy_original')
    assert database.rows('app_private.acquisition_jobs', f't.id={quoted(legacy)}',
                         columns=columns['app_private.acquisition_jobs']) == [r for r in before['app_private.acquisition_jobs'] if r['id'] == legacy]
    assert database.value(f"select count(*) from app_private.acquisition_jobs where kind='original' and version_id="
                          f"(select version_id from app_private.acquisition_jobs where id={quoted(legacy)});") == '1'
    print('PASS 013 refuses an active unissued legacy original without rewriting its unique identity/headroom', flush=True)
