"""Real disposable-PostgreSQL original-execution races; no external I/O.

Synthetic fixture evidence exercises SQL contracts only. Transaction barriers
are held until explicitly released, and every competing wait is observed in
pg_stat_activity/pg_blocking_pids before the next operation. No elapsed sleep is
used as evidence that an executor, connection, or Storage write has stopped.
"""
import concurrent.futures
import json
import os
import pathlib
import re
import subprocess
import time
import uuid


EXECUTOR = 'science_reader_original_executor'
METADATA = 'science_reader_metadata_executor'
VERIFIER = 'science_reader_pdf_verifier'
OBSERVER = 'science_reader_execution_observer'
ADMITTER = 'science_reader_executor_admitter'
ROOT = pathlib.Path(__file__).resolve().parents[2]


def quoted(value):
    return "'" + str(value).replace("'", "''") + "'"


def json_sql(value):
    return quoted(json.dumps(value, ensure_ascii=False, allow_nan=False)) + '::jsonb'


class Database:
    """A bounded helper restricted to the parent harness's disposable database."""

    def __init__(self, bin_path, db, base):
        if not re.fullmatch(r'science_reader_test_[0-9a-f]{12}', db):
            raise AssertionError('original tests require the supplied disposable fixture database')
        if (len(base) != 4 or base[0] != '-h' or base[1] not in ('127.0.0.1', '::1', 'localhost')
                or base[2] != '-p' or not str(base[3]).isdigit() or not 0 < int(base[3]) < 65536):
            raise AssertionError('original tests require an explicit loopback PostgreSQL connection')
        self.db = db
        self.command = [str(pathlib.Path(bin_path) / 'psql'), *base, '-X', '-qAt', '--no-password',
                        '-v', 'ON_ERROR_STOP=1', '-d', db]
        self.environment = {k: v for k, v in os.environ.items() if not k.startswith('PG')}
        self.environment.update(PGCONNECT_TIMEOUT='5', PGCLIENTENCODING='UTF8', LC_ALL='C')

    @staticmethod
    def prefix(name=None):
        limits = "set statement_timeout='12s'; set lock_timeout='10s'; set idle_in_transaction_session_timeout='15s';"
        return limits + (f'set application_name={quoted(name)};' if name else '')

    def sql(self, source, name=None, *, required=True, timeout=20):
        result = subprocess.run(self.command, input=self.prefix(name) + source, text=True,
                                capture_output=True, env=self.environment, timeout=timeout)
        if len(result.stdout.encode('utf-8')) + len(result.stderr.encode('utf-8')) > 8 * 1024 * 1024:
            raise AssertionError('bounded fixture SQL output exceeded')
        if required and result.returncode:
            raise AssertionError(result.stderr)
        return result.stdout.strip() if required else result

    def value(self, source, name=None):
        lines = self.sql(source, name).splitlines()
        if not lines:
            raise AssertionError('fixture SQL returned no value')
        return lines[-1]

    def json(self, source, name=None):
        return json.loads(self.value(source, name))

    def call(self, actor, expression, name=None):
        if actor not in (EXECUTOR, METADATA, VERIFIER, OBSERVER, ADMITTER):
            raise AssertionError('unrecognized synthetic capability')
        return self.json(f'set role {actor}; select {expression};', name)

    def reject(self, actor, expression, fragment):
        result = self.sql(f'set role {actor}; select {expression};', required=False)
        if result.returncode == 0 or fragment not in result.stderr:
            raise AssertionError(f'expected bounded refusal {fragment}: {result.stderr}')

    def wait(self, name, *, blocker=None, idle=False, process=None, future=None):
        def check_worker():
            if future is not None and future.done():
                result = future.result()  # Preserve the worker's actual exception.
                if isinstance(result, subprocess.CompletedProcess) and result.returncode:
                    raise AssertionError(result.stderr)
                raise AssertionError(f'{name} completed before its transaction barrier was observed')

        deadline = time.monotonic() + 7
        while time.monotonic() < deadline:
            check_worker()
            if process is not None and process.poll() is not None:
                raise AssertionError('transaction barrier exited before observation')
            # A queued tuple-lock waiter can block on another waiter rather
            # than directly on the original holder. Observe the finite actual
            # blocking graph in this fixture database, not just one edge.
            sessions = self.json("select coalesce(jsonb_agg(jsonb_build_object('pid',s.pid,"
                "'name',s.application_name,'state',s.state,'event',s.wait_event,'event_type',s.wait_event_type,"
                "'blockers',array(select b from unnest(pg_blocking_pids(s.pid)) b limit 17))),'[]') "
                "from (select pid,application_name,state,wait_event,wait_event_type from pg_stat_activity "
                f"where datname={quoted(self.db)} order by pid limit 33) s;")
            check_worker()
            if len(sessions) > 32 or any(len(item['blockers']) > 16 for item in sessions):
                raise AssertionError('fixture transaction blocking graph exceeded its finite bound')
            matches = [item for item in sessions if item['name'] == name]
            if len(matches) > 1:
                raise AssertionError('fixture transaction application name is not unique')
            if matches:
                target = matches[0]
                observed = (target['state'] == 'idle in transaction' and target['event'] == 'ClientRead'
                            if idle else target['event_type'] == 'Lock')
                if observed and blocker is None:
                    return target['pid']
                if observed:
                    by_pid = {item['pid']: item for item in sessions}
                    pending, visited = [target['pid']], set()
                    while pending:
                        pid = pending.pop()
                        if pid in visited:
                            continue
                        visited.add(pid)
                        for blocked_by in by_pid[pid]['blockers']:
                            if blocked_by not in by_pid:
                                continue
                            if blocked_by == int(blocker):
                                return target['pid']
                            if blocked_by not in visited:
                                pending.append(blocked_by)
            time.sleep(.015)
        check_worker()
        raise AssertionError(f'{name} did not reach its observed transaction barrier')

    def transaction(self, locked_sql, name):
        return Transaction(self, locked_sql, name)

    def rows(self, table, where='true', *, columns=None):
        if not re.fullmatch(r'app_private\.[a-z_][a-z0-9_]*', table):
            raise AssertionError('fixture snapshot table')
        if columns is None:
            query = f'select to_jsonb(t) v from {table} t where {where}'
        else:
            if not columns or any(not re.fullmatch(r'[a-z_][a-z0-9_]*', c) for c in columns):
                raise AssertionError('fixture snapshot columns')
            selection = ','.join(f't."{c}"' for c in columns)
            query = f'select to_jsonb(projected) v from (select {selection} from {table} t where {where}) projected'
        return self.json(f"select coalesce(jsonb_agg(v order by v::text),'[]'::jsonb) from "
                         f'({query}) snapshot;')


class Transaction:
    """One owned psql backend; explicit commit or rollback releases its locks."""

    def __init__(self, database, locked_sql, name):
        self.database, self.name, self.process, self.pid = database, name, None, None
        self.locked_sql = locked_sql

    def __enter__(self):
        self.process = subprocess.Popen(self.database.command, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                        stderr=subprocess.PIPE, text=True, env=self.database.environment)
        try:
            self.process.stdin.write(self.database.prefix(self.name) + 'begin;' + self.locked_sql + '\n')
            self.process.stdin.flush()
            self.pid = self.database.wait(self.name, idle=True, process=self.process)
            return self
        except BaseException:
            self._finish(False)
            raise

    def _finish(self, commit, tail=''):
        process, self.process = self.process, None
        if process is None:
            return
        try:
            stdout, stderr = process.communicate(input=tail + ('commit;\n' if commit else 'rollback;\n'), timeout=20)
        except subprocess.TimeoutExpired:
            process.kill()
            process.communicate(timeout=5)
            raise AssertionError('owned fixture transaction failed to retire within its test deadline')
        if len(stdout.encode('utf-8')) + len(stderr.encode('utf-8')) > 65536:
            raise AssertionError('transaction barrier output exceeded')
        if commit and process.returncode:
            raise AssertionError(stderr)

    def release(self, tail=''):
        self._finish(True, tail)

    def __exit__(self, *_):
        self._finish(False)


def claim_expression(args):
    if set(args) != {'job_id', 'claim_id', 'stage', 'expected_request_sha256', 'binding'}:
        raise AssertionError('original fixture claim-argument contract changed')
    return ('public.worker_claim_original_stage_v1('
            f"{quoted(args['job_id'])},{quoted(args['claim_id'])},'staging',{quoted(args['stage'])},"
            f"decode({quoted(args['expected_request_sha256'])},'hex'),{json_sql(args['binding'])})")


class Fixtures:
    def __init__(self, database):
        self.db = database

    def job(self, source):
        fixture = self.db.json(f'select test.original_job({quoted(source)});')
        assert set(fixture) == {'account_id', 'import_id', 'lookup_job_id', 'original_job_id', 'reservation_id'}
        return fixture

    def args(self, fixture, stage, claim=None):
        return self.db.json(f'select test.original_claim_args({json_sql(fixture)},{quoted(stage)},'
                            f'{quoted(claim or str(uuid.uuid4()))});')

    def claim(self, args, name=None):
        actor = VERIFIER if args['stage'] == 'original_verify' else EXECUTOR
        return self.db.call(actor, claim_expression(args), name)

    def close(self, execution, resource, known=True, receipt=None):
        return self.db.json(f'select test.original_close({json_sql(execution)},{quoted(resource)},'
                            f'{str(known).lower()},{quoted(receipt or str(uuid.uuid4()))});')

    def finish(self, execution, name=None):
        body = self.db.json(f'select test.original_result({json_sql(execution)});')
        actor, expression = self.finish_expression(execution, body)
        return self.db.call(actor, expression, name)

    @staticmethod
    def finish_expression(execution, body):
        common = (f"{quoted(execution['job_id'])},{quoted(execution['claim_id'])},{execution['generation']},"
                  f"{quoted(execution['id'])}")
        if execution['kind'] == 'original_verify':
            return VERIFIER, ('public.worker_finish_original_verification_v1('
                              f"{common},{execution['verification_generation']},{json_sql(body)})")
        return EXECUTOR, f'public.worker_finish_original_stage_v1({common},{json_sql(body)})'

    def complete(self, fixture, stage):
        return self.db.json(f'select test.original_complete({json_sql(fixture)},{quoted(stage)});')

    def publish_expression(self, fixture, operation=None):
        verification = self.db.value('select verification_result_id from app_private.paper_asset_reservations '
                                     f"where id={quoted(fixture['reservation_id'])};")
        return ('public.worker_publish_original_v1('
                f"{quoted(fixture['original_job_id'])},{quoted(operation or str(uuid.uuid4()))},"
                f"{quoted(fixture['reservation_id'])},{quoted(verification)})")

    def advance_to_publish(self, fixture):
        mapping = {'download': 'original_download', 'upload': 'original_upload',
                   'readback': 'original_readback', 'pending_verification': 'original_verify'}
        for _ in range(4):
            stage = self.db.value('select stage from app_private.acquisition_jobs '
                                  f"where id={quoted(fixture['original_job_id'])};")
            if stage == 'publish':
                break
            assert stage in mapping, stage
            self.complete(fixture, mapping[stage])
        assert self.db.value('select stage from app_private.acquisition_jobs '
                             f"where id={quoted(fixture['original_job_id'])};") == 'publish'

    def finish_chain(self, fixture):
        self.advance_to_publish(fixture)
        result = self.db.call(EXECUTOR, self.publish_expression(fixture))
        assert self.db.value('select status from app_private.acquisition_jobs '
                             f"where id={quoted(fixture['original_job_id'])};") == 'complete', result
        self.clear_cooldown()
        return result

    def bind(self, fixture):
        return self.db.call(EXECUTOR, self.bind_expression(fixture))

    @staticmethod
    def bind_expression(fixture):
        return ('public.worker_bind_lookup_original_v1('
                f"{quoted(fixture['lookup_job_id'])},{quoted(fixture['original_job_id'])})")

    @staticmethod
    def project_expression(fixture):
        return ('public.worker_project_import_acquisition('
                f"{quoted(fixture['account_id'])},{quoted(fixture['import_id'])},1)")

    def state(self, execution):
        return self.db.call(OBSERVER, 'public.worker_original_execution_state('
                            f"{quoted(execution['job_id'])},{quoted(execution['claim_id'])})")

    @staticmethod
    def expire_expression(execution):
        return ('public.worker_expire_original_stage_v1('
                f"{quoted(execution['job_id'])},{quoted(execution['claim_id'])},{execution['generation']},"
                f"{quoted(execution['id'])})")

    @staticmethod
    def activation_expression(authority):
        return ('public.worker_activate_original_executor_v1('
                f"{authority['revision']},{quoted(authority['project_ref'])},{quoted(authority['active_policy_id'])},"
                f"{quoted(authority['original_policy_id'])},{quoted(authority['admitted_host_id'])},"
                f"{quoted(authority['admitted_boot_id'])},{quoted(authority['admitted_deployment_id'])},"
                f"{quoted(authority['original_deployment_id'])},decode(repeat('e',64),'hex'))")

    def snapshot(self, fixture, *, global_facts=True):
        job, reservation = quoted(fixture['original_job_id']), quoted(fixture['reservation_id'])
        # One MVCC statement observes all facts whose mutation would constitute
        # a consumed claim. Account cancellation and policy changes are excluded.
        fields = f"""'job',(select to_jsonb(j) from app_private.acquisition_jobs j where id={job}),
          'reservation',(select to_jsonb(r) from app_private.paper_asset_reservations r where id={reservation}),
          'steps',(select coalesce(jsonb_agg(to_jsonb(s) order by operation_id),'[]') from app_private.acquisition_steps s where job_id={job}),
          'attempts',(select coalesce(jsonb_agg(to_jsonb(e) order by id),'[]') from app_private.execution_attempts e where job_id={job}),
          'receipts',(select coalesce(jsonb_agg(to_jsonb(q) order by q.attempt_id,q.resource),'[]') from app_private.execution_quiescence q
             join app_private.execution_attempts e on e.id=q.attempt_id where e.job_id={job})"""
        if global_facts:
            fields += """,'gate',(select to_jsonb(g) from app_private.arxiv_network_gate g),
             'windows',(select coalesce(jsonb_agg(to_jsonb(w) order by period,scope,kind),'[]') from app_private.acquisition_transfer_windows w)"""
        return self.db.json(f'select jsonb_build_object({fields});')

    def clear_cooldown(self):
        # Test scheduling only, after actual synthetic SQL resource receipts.
        # This does not establish closure or create a production timeout rule.
        assert self.db.value('select token is null from app_private.arxiv_network_gate;') == 't'
        self.db.sql("update app_private.arxiv_network_gate set next_allowed_at='-infinity';")

    def metadata_job(self, source):
        account, request, operation = (str(uuid.uuid4()) for _ in range(3))
        begin = self.db.json(f"insert into auth.users values({quoted(account)}); set role authenticated;"
                             f"select set_config('request.jwt.claim.sub',{quoted(account)},false);"
                             f"select public.v2_begin_import({quoted(request)},{quoted(source)},0,1);")
        prepared = self.db.call(METADATA, f'public.worker_prepare_acquisition({quoted(operation)},{quoted(source)},1)')
        job = prepared['job']['id']
        self.db.call(METADATA, f'public.worker_link_import_acquisition({quoted(account)},{quoted(request)},1,'
                              f"{begin['entry']['state_seq']},{quoted(job)})")
        claim = str(uuid.uuid4())
        binding = self.db.json(f'select test.original_meta_binding({quoted(claim)});')
        expression = f"public.worker_claim_metadata_stage_v2({quoted(job)},{quoted(claim)},'staging',{json_sql(binding)})"
        return {'job_id': job, 'claim_id': claim, 'expression': expression}

    def settle_metadata(self, execution):
        for resource in ('executor', 'arxiv_connection'):
            self.db.json(f'select test.original_meta_close({json_sql(execution)},{quoted(resource)});')
        self.clear_cooldown()

    def new_interest(self, fixture):
        account, request = str(uuid.uuid4()), str(uuid.uuid4())
        source = self.db.value(f"select source_id from app_private.acquisition_jobs where id={quoted(fixture['original_job_id'])};")
        result = self.db.json(f"insert into auth.users values({quoted(account)}); set role authenticated;"
                              f"select set_config('request.jwt.claim.sub',{quoted(account)},false);"
                              f"select public.v2_begin_import({quoted(request)},{quoted(source)},0,1);")
        added = dict(fixture, account_id=account, import_id=request)
        expression = (f"public.worker_link_import_acquisition({quoted(account)},{quoted(request)},1,"
                      f"{result['entry']['state_seq']},{quoted(fixture['lookup_job_id'])},{quoted(fixture['original_job_id'])})")
        return added, expression

    def add_interest(self, fixture):
        added, expression = self.new_interest(fixture)
        self.db.call(EXECUTOR, expression)
        return added

    def cancel(self, fixture):
        return self.db.json(f"set role authenticated; select set_config('request.jwt.claim.sub',{quoted(fixture['account_id'])},false);"
                            f"select public.v2_cancel_import({quoted(str(uuid.uuid4()))},{quoted(fixture['import_id'])},1);")


def verify(bin_path, db, base):
    database = Database(bin_path, db, base)
    fixture = Fixtures(database)
    run = uuid.uuid4().hex[:10]
    database.sql('select test.original_enable();')

    # Independent durable preparation commands coalesce a new original without
    # borrowing legacy headroom or collapsing the command identities.
    lookup = database.json("select test.original_lookup('2404.72001');")
    operations = [str(uuid.uuid4()) for _ in range(8)]
    with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
        prepared = list(pool.map(lambda op: database.call(EXECUTOR,
            f"public.worker_prepare_original_v1({quoted(op)},{quoted(lookup['lookup_job_id'])})"), operations))
    assert len({result['job']['id'] for result in prepared}) == 1
    job = prepared[0]['job']['id']
    assert database.value(f"select execution_contract='original-v1' and slots_held=28 from app_private.acquisition_jobs where id={quoted(job)};") == 't'
    assert database.value(f"select count(*) from app_private.acquisition_commands where id in ({','.join(quoted(x) for x in operations)});") == '8'
    print('PASS 013 eight-way prepare shares one28-slot original and preserves eight command receipts', flush=True)

    first = fixture.job('2404.72002')
    args = fixture.args(first, 'original_download')
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        grants = list(pool.map(lambda _: fixture.claim(args), range(2)))
    assert sum(result['granted'] is True for result in grants) == 1
    assert len({result['execution']['id'] for result in grants}) == 1
    execution = grants[0]['execution']
    with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
        receipts = list(pool.map(lambda _: fixture.close(execution, 'executor'), range(8)))
    assert len({result['receipt_id'] for result in receipts}) == 1
    assert sum(result['replayed'] is False for result in receipts) == 1
    assert database.value(f"select count(*) from app_private.execution_quiescence where attempt_id={quoted(execution['id'])};") == '1'
    fixture.close(execution, 'arxiv_connection')
    fixture.finish(execution)
    saved = fixture.snapshot(first)
    replay = fixture.claim(args)
    assert replay['granted'] is False and replay['execution']['id'] == execution['id']
    assert fixture.snapshot(first) == saved
    changed = dict(args, binding=dict(args['binding'], deployment_id='changed-synthetic-deployment'))
    database.reject(EXECUTOR, claim_expression(changed), 'operation_id_conflict')
    fixture.finish_chain(first)
    print('PASS 013 concurrent identical grant and equivalent proofs retain one permit/attempt/canonical receipt', flush=True)

    shared = fixture.job('2404.72003')
    metadata = fixture.metadata_job('2404.72004')
    original_args = fixture.args(shared, 'original_download')
    old_original = fixture.snapshot(shared, global_facts=False)
    old_metadata = database.rows('app_private.acquisition_jobs', f"t.id={quoted(metadata['job_id'])}")
    charges = lambda: database.json("select coalesce(jsonb_object_agg(kind,total),'{}') from "
                                    "(select kind,sum(charged) total from app_private.acquisition_transfer_windows "
                                    "where scope='environment' group by kind) w;")
    before_charge = charges()
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        original_future = pool.submit(fixture.claim, original_args)
        metadata_future = pool.submit(database.call, METADATA, metadata['expression'])
        original_result, metadata_result = original_future.result(), metadata_future.result()
    assert sum(result['granted'] is True for result in (original_result, metadata_result)) == 1
    winner = next(result['execution'] for result in (original_result, metadata_result) if result['granted'])
    after_charge = charges()
    assert after_charge.get('source_requests', 0) - before_charge.get('source_requests', 0) == 1
    assert after_charge.get('source_bytes', 0) - before_charge.get('source_bytes', 0) == winner['byte_ceiling']
    if original_result['granted']:
        assert database.rows('app_private.acquisition_jobs', f"t.id={quoted(metadata['job_id'])}") == old_metadata
        assert database.value(f"select count(*) from app_private.execution_attempts where job_id={quoted(metadata['job_id'])};") == '0'
        fixture.close(winner, 'executor')
        fixture.close(winner, 'arxiv_connection')
        fixture.finish(winner)
    else:
        assert fixture.snapshot(shared, global_facts=False) == old_original
        fixture.settle_metadata(winner)
    fixture.finish_chain(shared)
    print('PASS 013 metadata and original source schedulers share one gate/executor and never charge the loser', flush=True)

    waiting = fixture.job('2404.72005')
    transfer_lock = 'select 1 from app_private.acquisition_transfer_capacity where singleton for update;'
    for label, mutation, restoration, expected in (
        ('disabled', 'update app_private.acquisition_policy set original_enabled=false;',
         'update app_private.acquisition_policy set original_enabled=true;', 'disabled'),
        ('profile', 'update app_private.acquisition_policy set active_verification_profile=null;', None, 'disabled'),
        ('cap', 'update app_private.acquisition_policy set source_download_bytes_month=1;', None, None),
        ('cancel', None, None, 'no_interest'),
    ):
        policy = database.json('select to_jsonb(p) from app_private.acquisition_policy p;')
        args = fixture.args(waiting, 'original_download')
        before = fixture.snapshot(waiting)
        name = 'original-postwait-' + label + '-' + run
        with database.transaction(transfer_lock, 'original-transfer-' + label + '-' + run) as holder:
            with concurrent.futures.ThreadPoolExecutor(max_workers=1) as pool:
                claimant = pool.submit(database.sql, f'set role {EXECUTOR}; select {claim_expression(args)};', name, required=False)
                database.wait(name, blocker=holder.pid, future=claimant)
                if mutation:
                    database.sql(mutation)
                else:
                    fixture.cancel(waiting)
                holder.release()
                result = claimant.result()
        if expected is None:
            assert result.returncode and 'original_transfer_limit' in result.stderr
        else:
            assert result.returncode == 0, result.stderr
            denied = json.loads(result.stdout.strip().splitlines()[-1])
            assert denied['granted'] is False and denied['action'] == expected
        assert fixture.snapshot(waiting) == before
        if restoration:
            database.sql(restoration)
        elif label == 'profile':
            database.sql('update app_private.acquisition_policy set active_verification_profile='
                         f"{quoted(policy['active_verification_profile'])};")
        elif label == 'cap':
            database.sql('update app_private.acquisition_policy set source_download_bytes_month='
                         f"{int(policy['source_download_bytes_month'])};")
        else:
            waiting = fixture.add_interest(waiting)
    # A surviving independent import is not cancelled with the first account.
    survivor = fixture.add_interest(waiting)
    args = fixture.args(waiting, 'original_download')
    name = 'original-survivor-' + run
    with database.transaction(transfer_lock, 'original-survivor-lock-' + run) as holder:
        with concurrent.futures.ThreadPoolExecutor(max_workers=1) as pool:
            claimant = pool.submit(fixture.claim, args, name)
            database.wait(name, blocker=holder.pid, future=claimant)
            fixture.cancel(waiting)
            holder.release()
            admitted = claimant.result()
    assert admitted['granted'] is True
    fixture.close(admitted['execution'], 'executor')
    fixture.close(admitted['execution'], 'arxiv_connection')
    fixture.finish(admitted['execution'])
    fixture.finish_chain(survivor)
    print('PASS 013 final admission wait rechecks cancellation, policy/profile/cap, and surviving shared interest', flush=True)

    # Preparation has the old policy -> job order. Admission already owns the
    # job while waiting on transfer capacity and must only reread the policy.
    ordered = fixture.job('2404.72006')
    args = fixture.args(ordered, 'original_download')
    claim_name, prepare_name = 'original-order-claim-' + run, 'original-order-prepare-' + run
    with database.transaction(transfer_lock, 'original-order-transfer-' + run) as holder:
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
            claiming = pool.submit(fixture.claim, args, claim_name)
            claimant_pid = database.wait(claim_name, blocker=holder.pid, future=claiming)
            preparing = pool.submit(database.sql,
                'begin; select 1 from app_private.acquisition_policy for update;'
                f'set local role {EXECUTOR}; select public.worker_prepare_original_v1('
                f"{quoted(str(uuid.uuid4()))},{quoted(ordered['lookup_job_id'])}); commit;", prepare_name)
            database.wait(prepare_name, blocker=claimant_pid, future=preparing)
            holder.release()
            granted, prepared = claiming.result(), json.loads(preparing.result().splitlines()[-1])
    assert granted['granted'] is True and prepared['job']['id'] == ordered['original_job_id']
    fixture.close(granted['execution'], 'executor')
    fixture.close(granted['execution'], 'arxiv_connection')
    fixture.finish(granted['execution'])
    fixture.finish_chain(ordered)
    print('PASS 013 policy→job preparation and job→transfer grant converge without reversed policy locking', flush=True)

    # Exercise the actual fenced publisher while an actual account linker owns
    # library_policy. The linker must acquire the job FK's KEY SHARE without
    # waiting on the publisher's NO KEY UPDATE lock.
    publishing = fixture.job('2404.72007')
    fixture.advance_to_publish(publishing)
    subscriber, link = fixture.new_interest(publishing)
    publish = fixture.publish_expression(publishing)
    name = 'original-fk-publish-' + run
    with database.transaction(
        f"select 1 from app_private.accounts where id={quoted(subscriber['account_id'])} for no key update;"
        'select 1 from app_private.library_policy for update;', 'original-fk-link-' + run) as holder:
        with concurrent.futures.ThreadPoolExecutor(max_workers=1) as pool:
            writer = pool.submit(database.call, EXECUTOR, publish, name)
            database.wait(name, blocker=holder.pid, future=writer)
            holder.release(f'set local role {EXECUTOR}; select {link};')
            published = writer.result()
    assert published['status'] == 'complete'
    assert database.value('select original_job_id from app_private.acquisition_interests '
                          f"where account_id={quoted(subscriber['account_id'])} and import_id={quoted(subscriber['import_id'])};") == publishing['original_job_id']
    fixture.bind(publishing)
    projected = database.call(EXECUTOR, fixture.project_expression(subscriber))
    assert projected['entry']['phase'] == 'ready', projected
    fixture.clear_cooldown()
    print('PASS 013 real publication and account-link FK converge under library policy contention', flush=True)

    # A projector reads null output before waiting for policy. Real publication
    # plus binding commits while it waits; it must finish the old snapshot and
    # leave the later revision discoverable, rather than lock a fresh document
    # after policy or falsely claim its partial projection was current.
    projecting = fixture.job('2404.72008')
    fixture.advance_to_publish(projecting)
    publish = fixture.publish_expression(projecting)
    name = 'original-null-projector-' + run
    with database.transaction('select 1 from app_private.library_policy for update;',
                              'original-null-publisher-' + run) as holder:
        with concurrent.futures.ThreadPoolExecutor(max_workers=1) as pool:
            projector = pool.submit(database.call, EXECUTOR, fixture.project_expression(projecting), name)
            database.wait(name, blocker=holder.pid, future=projector)
            holder.release(f'set local role {EXECUTOR}; select {publish}; select {fixture.bind_expression(projecting)};')
            old_projection = projector.result()
    assert old_projection['entry']['phase'] == 'acquiring', old_projection
    assert database.value('select projected_original_revision<(select state_revision from app_private.acquisition_jobs '
                          f"where id={quoted(projecting['original_job_id'])}) from app_private.acquisition_interests "
                          f"where account_id={quoted(projecting['account_id'])} and import_id={quoted(projecting['import_id'])};") == 't'
    assert projecting['import_id'] in database.value('set role science_reader_original_executor; select public.worker_scan_acquisition_imports();')
    assert database.call(EXECUTOR, fixture.project_expression(projecting))['entry']['phase'] == 'ready'
    fixture.clear_cooldown()
    print('PASS 013 null→published projection preserves its snapshot and catches up through the durable scan', flush=True)

    # These two synthetic sources deliberately attest to identical bytes. The
    # only DTO override supplies the complete download receipt/descriptor body;
    # no immutable execution, request hash, binding, or SQL row is rewritten.
    duplicates = [fixture.job('2404.72009'), fixture.job('2404.72010')]
    for duplicate in duplicates:
        execution = fixture.claim(fixture.args(duplicate, 'original_download'))['execution']
        common_pdf = dict(execution, candidate_sha256='6' * 64)
        fixture.close(execution, 'executor')
        fixture.close(common_pdf, 'arxiv_connection')
        fixture.finish(common_pdf)
        fixture.advance_to_publish(duplicate)
        fixture.clear_cooldown()
    expressions = [fixture.publish_expression(item) for item in duplicates]
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        published = list(pool.map(lambda expression: database.call(EXECUTOR, expression), expressions))
    assert all(item['status'] == 'complete' for item in published)
    assert len({item['document_id'] for item in published}) == 1
    assert len({item['original_object_id'] for item in published}) == 1
    document, canonical = published[0]['document_id'], published[0]['original_object_id']
    assert database.value(f"select count(*) from app_private.stored_objects where document_id={quoted(document)};") == '1'
    assert database.value(f"select count(*) from app_private.version_documents where document_id={quoted(document)};") == '2'
    assert database.value(f"select count(*) from app_private.paper_verification_results where sha256=decode(repeat('6',64),'hex');") == '2'
    reservations = database.rows('app_private.paper_asset_reservations',
                                  f"t.id in ({','.join(quoted(item['reservation_id']) for item in duplicates)})")
    assert sorted(item['state'] for item in reservations) == ['published', 'quarantined']
    assert all(item['held_bytes'] == item['candidate_bytes'] == 1000 for item in reservations)
    for item, expression in zip(duplicates, expressions):
        before = fixture.snapshot(item)
        assert database.call(EXECUTOR, expression)['document_id'] == document
        assert fixture.snapshot(item) == before
    print('PASS 013 simultaneous exact-hash publishers share one canonical object and retain the losing reservation', flush=True)

    # Seed a distinct metadata observation for the same published version. An
    # old approval may be inserted while the new wrapper's lookup binder waits
    # on policy; the immutable old pin must win instead of being substituted.
    original = duplicates[0]
    observed_metadata = database.value("select public.worker_record_arxiv_metadata('2404.72009',1,"
        "'{\"title\":\"Later synthetic observation\",\"authors\":[\"Author\"],\"categories\":[\"cs.LG\"]}');")
    later_lookup, old_object, old_approval = (str(uuid.uuid4()) for _ in range(3))
    database.sql('insert into app_private.acquisition_jobs(id,kind,source_slot_id,slot_generation,source_id,requested_revision,input_sha256,'
                 'metadata_id,version_id,source_revision,eligibility,license_uri,evidence,stage,status,slots_held,execution_contract) '
                 f"select {quoted(later_lookup)},'lookup',source_slot_id,slot_generation+1,source_id,requested_revision,sha256('binder-race'::bytea),"
                 f"{quoted(observed_metadata)},version_id,source_revision,eligibility,license_uri,evidence,'complete','complete',24,'metadata-v2' "
                 f"from app_private.acquisition_jobs where id={quoted(original['lookup_job_id'])};"
                 'insert into app_private.stored_objects(id,bucket,path,document_id,state,sha256,byte_count,media_type,verified_at) '
                 f"values({quoted(old_object)},'paper-assets',{quoted('test/original-concurrency/' + old_object + '.pdf')},"
                 f"{quoted(document)},'verified',decode(repeat('6',64),'hex'),1000,'application/pdf',clock_timestamp());")
    evidence = database.json(f"select evidence from app_private.acquisition_jobs where id={quoted(later_lookup)};")
    before_original = fixture.snapshot(original)
    name = 'original-approval-binder-' + run
    with database.transaction(f"select 1 from app_private.documents where id={quoted(document)} for key share;"
                              'select 1 from app_private.library_policy for update;', 'original-approval-writer-' + run) as holder:
        with concurrent.futures.ThreadPoolExecutor(max_workers=1) as pool:
            binding = pool.submit(database.call, EXECUTOR,
                f"public.worker_bind_lookup_original_v1({quoted(later_lookup)},{quoted(original['original_job_id'])})", name)
            database.wait(name, blocker=holder.pid, future=binding)
            holder.release('select public.worker_approve_arxiv_asset('
                           f"{quoted(old_approval)},{quoted(observed_metadata)},{quoted(document)},{quoted(old_object)},"
                           f"'https://creativecommons.org/licenses/by/4.0/',{json_sql(evidence)});")
            rejected_binding = binding.result()
    assert rejected_binding['error_code'] == 'legacy_original_unverified' and rejected_binding['approval_id'] is None
    assert fixture.snapshot(original) == before_original
    assert database.value(f"select original_object_id from app_private.catalog_asset_approvals where id={quoted(old_approval)};") == old_object
    assert database.value(f"select object_id from app_private.paper_originals where document_id={quoted(document)};") == canonical
    print('PASS 013 late conflicting approval cannot replace the canonical original or the retained approval pin', flush=True)

    # The database's report deadline determines result authority, never resource
    # retirement. All resource receipts are already positive here. Both result
    # and expiry requests queue behind the authority lock until that deadline.
    database.sql('select test.original_enable(5);')
    expiring = fixture.job('2404.72011')
    execution = fixture.claim(fixture.args(expiring, 'original_download'))['execution']
    fixture.close(execution, 'executor')
    fixture.close(execution, 'arxiv_connection')
    body = database.json(f'select test.original_result({json_sql(execution)});')
    actor, result_expression = fixture.finish_expression(execution, body)
    before = fixture.snapshot(expiring)
    finish_name, expire_name = 'original-deadline-finish-' + run, 'original-deadline-expire-' + run
    with database.transaction('select 1 from app_private.executor_authority for update;',
                              'original-deadline-holder-' + run) as holder:
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
            finishing = pool.submit(database.sql, f'set role {actor}; select {result_expression};', finish_name, required=False)
            expiring_call = pool.submit(database.call, EXECUTOR, fixture.expire_expression(execution), expire_name)
            database.wait(finish_name, blocker=holder.pid, future=finishing)
            database.wait(expire_name, blocker=holder.pid, future=expiring_call)
            deadline = time.monotonic() + 7
            while database.value(f"select clock_timestamp()>={quoted(execution['report_deadline'])}::timestamptz;") != 't':
                if time.monotonic() >= deadline:
                    raise AssertionError('fixture report deadline did not arrive')
                time.sleep(.015)
            holder.release()
            late, expired = finishing.result(), expiring_call.result()
    assert late.returncode and any(code in late.stderr for code in ('stale_execution_attempt', 'operation_id_conflict'))
    assert expired['replayed'] is False and expired['step_result']['kind'] == 'original_expired_v1'
    after = fixture.snapshot(expiring)
    for field in ('attempts', 'receipts', 'gate', 'windows'):
        assert after[field] == before[field], field
    assert len(after['steps']) == len(before['steps'])
    assert after['job']['generation'] == before['job']['generation']
    assert after['job']['status'] == 'retry_wait' and after['reservation']['held_bytes'] == 5242880
    # Advance only fixture scheduling after positive closure, preserving the
    # immutable attempt/deadline. No resource is inferred from this adjustment.
    database.sql(f"update app_private.acquisition_jobs set next_attempt_at='-infinity' where id={quoted(expiring['original_job_id'])};")
    fixture.clear_cooldown()
    successor = fixture.claim(fixture.args(expiring, 'original_download'))['execution']
    assert successor['id'] != execution['id'] and successor['generation'] > execution['generation']
    successor_before = fixture.snapshot(expiring)
    assert database.call(EXECUTOR, fixture.expire_expression(execution))['replayed'] is True
    database.reject(actor, result_expression, 'operation_id_conflict')
    assert fixture.snapshot(expiring) == successor_before
    fixture.close(successor, 'executor')
    fixture.close(successor, 'arxiv_connection')
    fixture.finish(successor)
    fixture.finish_chain(expiring)
    database.sql('select test.original_enable();')
    print('PASS 013 deadline race commits one immutable outcome and old expiry/result cannot alter the successor', flush=True)

    # Upload process retirement does not prove that Storage has settled. The
    # missing object_write receipt retains this reservation and blocks every
    # subsequent original stage while unrelated metadata can still run.
    uncertain = fixture.job('2404.72012')
    fixture.complete(uncertain, 'original_download')
    upload_args = fixture.args(uncertain, 'original_upload')
    upload = fixture.claim(upload_args)['execution']
    fixture.close(upload, 'executor')
    assert fixture.state(upload)['execution']['pending_resources'] == ['object_write']
    protected = fixture.snapshot(uncertain, global_facts=False)
    body = database.json(f'select test.original_result({json_sql(upload)});')
    actor, expression = fixture.finish_expression(upload, body)
    database.reject(actor, expression, 'execution_retirement_required')
    wrong_stage = dict(upload_args, claim_id=str(uuid.uuid4()), stage='original_readback')
    wrong_stage['binding'] = dict(upload_args['binding'], scope=dict(upload_args['binding']['scope'], scope_id=wrong_stage['claim_id']))
    database.reject(EXECUTOR, claim_expression(wrong_stage), 'invalid_original_stage')
    database.reject(EXECUTOR, 'public.worker_publish_original_v1('
                    f"{quoted(uncertain['original_job_id'])},{quoted(str(uuid.uuid4()))},{quoted(uncertain['reservation_id'])},"
                    f"{quoted(str(uuid.uuid4()))})", 'original_verification_required')
    fixture.clear_cooldown()
    metadata = fixture.metadata_job('2404.72013')
    unrelated = database.call(METADATA, metadata['expression'])
    assert unrelated['granted'] is True
    fixture.settle_metadata(unrelated['execution'])
    assert fixture.snapshot(uncertain, global_facts=False) == protected
    failed = database.call(EXECUTOR, 'public.worker_fail_original_stage_v1('
                           f"{quoted(upload['job_id'])},{quoted(upload['claim_id'])},{upload['generation']},{quoted(upload['id'])},"
                           "'download_failed',false)")
    assert failed['status'] == 'blocked' and failed['retryable'] is False
    assert database.value('select state=\'upload_uncertain\' and held_bytes=max_bytes '
                          f"from app_private.paper_asset_reservations where id={quoted(uncertain['reservation_id'])};") == 't'
    revision = database.value('select revision from app_private.executor_authority;')
    database.call(ADMITTER, f'public.worker_retire_metadata_executor({revision})')
    retired = database.json('select to_jsonb(a) from app_private.executor_authority a;')
    database.reject(ADMITTER, fixture.activation_expression(retired), 'executor_recovery_required')
    assert database.json('select to_jsonb(a) from app_private.executor_authority a;') == retired
    held = fixture.snapshot(uncertain)
    assert any(item['id'] == upload['id'] for item in database.call(OBSERVER, 'public.worker_scan_unsettled_executions()'))
    print('PASS 013 upload write uncertainty retains full hold, blocks same-original/activation and permits unrelated metadata', flush=True)

    # A late receipt and another authority retirement may commit in either
    # order. The receipt closes only its original hold; replay cannot reenable
    # admission, move backoff/cooldown, refund twice, or mint an alias receipt.
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        closing = pool.submit(fixture.close, upload, 'object_write')
        retiring = pool.submit(database.call, ADMITTER, f"public.worker_retire_metadata_executor({retired['revision']})")
        receipt, _ = closing.result(), retiring.result()
    assert database.value('select not enabled and not original_admitted and recovery_required from app_private.executor_authority;') == 't'
    assert fixture.state(upload)['execution']['pending_resources'] == []
    assert not any(item['id'] == upload['id'] for item in database.call(OBSERVER, 'public.worker_scan_unsettled_executions()'))
    closed = fixture.snapshot(uncertain)
    for field in ('job', 'reservation', 'steps', 'attempts', 'gate', 'windows'):
        assert closed[field] == held[field], field
    assert len(closed['receipts']) == len(held['receipts']) + 1
    replay = fixture.close(upload, 'object_write')
    assert replay['replayed'] is True and replay['receipt_id'] == receipt['receipt_id']
    assert fixture.snapshot(uncertain) == closed
    print('PASS 013 receipt/retirement race settles the original resource once without reenable/refund/backoff movement', flush=True)
