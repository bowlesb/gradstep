"""Real-session provider admission/reconciliation races; never calls a provider."""
import json
import os
import select
import subprocess
import time
import uuid


def verify(bin_path, db, base):
    if list(base) != ['-h', '127.0.0.1', '-p', '55431'] or not db.startswith('science_reader_test_'):
        raise ValueError('Refusing a non-disposable/non-loopback provider test target')
    env = {key: value for key, value in os.environ.items() if not key.startswith('PG')}
    sessions = []

    def sql(source):
        result = subprocess.run([str(bin_path / 'psql'), *base, '-X', '-qAt', '-v', 'ON_ERROR_STOP=1', '-d', db],
                                input=source, capture_output=True, text=True, env=env, timeout=15)
        if result.returncode:
            raise AssertionError(result.stderr)
        return result.stdout.strip().splitlines()[-1]

    class Session:
        def __init__(self):
            self.process = subprocess.Popen([str(bin_path / 'psql'), *base, '-X', '-qAt', '-v', 'ON_ERROR_STOP=1', '-d', db],
                                            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)
            self.buffer = b''
            sessions.append(self)
            self.pid = int(self.complete("set statement_timeout='10s'; set lock_timeout='8s'; select pg_backend_pid();")[-1])

        def send(self, source):
            marker = 'barrier_' + uuid.uuid4().hex
            self.process.stdin.write((source + f" select '{marker}';\n").encode())
            self.process.stdin.flush()
            return marker

        def until(self, marker):
            deadline = time.monotonic() + 12
            result = []
            while time.monotonic() < deadline:
                while b'\n' in self.buffer:
                    line, self.buffer = self.buffer.split(b'\n', 1)
                    line = line.decode().strip()
                    if line == marker:
                        return result
                    if line:
                        result.append(line)
                if select.select([self.process.stdout], [], [], .05)[0]:
                    chunk = os.read(self.process.stdout.fileno(), 65536)
                    if not chunk:
                        raise AssertionError(self.process.stderr.read().decode())
                    self.buffer += chunk
            raise AssertionError('Provider accounting SQL barrier timed out')

        def complete(self, source):
            return self.until(self.send(source))

        def close(self):
            if self.process.stdin and not self.process.stdin.closed:
                self.process.stdin.close()
            try:
                self.process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                self.process.terminate()
                self.process.wait(timeout=3)
            self.process.stdout.close()
            self.process.stderr.close()

    def blocked(waiter, holder):
        deadline = time.monotonic() + 3
        while time.monotonic() < deadline:
            if sql(f'select {holder.pid}=any(pg_blocking_pids({waiter.pid}));') == 't':
                return
            if waiter.process.poll() is not None:
                raise AssertionError(waiter.process.stderr.read().decode())
            time.sleep(.02)
        raise AssertionError('Independent provider transaction did not wait at the intended lock barrier')

    def identity():
        account, operation = str(uuid.uuid4()), str(uuid.uuid4())
        sql(f"insert into auth.users(id) values('{account}'); select 'created';")
        return account, operation

    def reserve(account, operation, ceiling=100_000):
        return sql(f"set role service_role; select public.worker_reserve_operation('{account}','{operation}','metadata',"
                   f"sha256('{operation}'),'beta-credits-v1',0,{ceiling});")

    def begin(account, operation, attempt, provider='anthropic', ceiling=100_000):
        route, model, units = ('reference_lookup', 'search-basic', '{"credits":1}') if provider == 'tavily' else ('chat', 'claude-sonnet-5-5', '{"output_tokens":100}')
        return (f"select public.worker_provider_attempt_begin('{account}','{operation}','{attempt}','{provider}','{route}',"
                f"'{model}',sha256('{attempt}'),{ceiling},'{units}');")

    def finish(account, operation, attempt, state='succeeded', amount='20000'):
        failure = "'transport_unknown'" if state == 'unknown' else 'null'
        return (f"select public.worker_provider_attempt_finish('{account}','{operation}','{attempt}','{state}',null,{amount},"
                f"'{{}}',{failure});")

    def settle(account, operation):
        return f"select public.worker_settle_operation('{account}','{operation}',0,0);"

    def budget():
        return json.loads(sql("select json_build_array(spent_microusd,reserved_microusd) from app_private.platform_budgets "
                              "where period=date_trunc('month',now() at time zone 'UTC')::date;"))

    def import_paper(account, source):
        return ("set role authenticated; "
                f"select set_config('request.jwt.claim.sub','{account}',false); "
                f"select public.v2_begin_import('{uuid.uuid4()}','{source}',0); reset role;")

    def funding_fixture(accounts):
        # Account/import entry points are real. The already-verified PDF is a
        # deterministic DB fixture; no file is downloaded or sent to Mathpix.
        source = '2610.' + str(uuid.uuid4().int % 100000).zfill(5)
        document, claim = str(uuid.uuid4()), str(uuid.uuid4())
        for account in accounts:
            sql(import_paper(account, source) + " select 'imported';")
        paper = sql(f"select id from app_private.pipeline_papers where source_id='{source}' and owner_id is null;")
        sql(f"insert into app_private.documents(id,sha256,scope,reuse_evidence,byte_count,page_count) "
            f"values('{document}',sha256('{document}'),'shared_catalog','{{\"fixture\":true}}',1000,2); "
            f"update app_private.pipeline_papers set document_id='{document}',eligible=true,page_count=2,stage='ocr_fund',"
            f"claim_id='{claim}',generation=1,lease_until=clock_timestamp()+interval '5 minutes' where id='{paper}'; "
            f"set role service_role; select public.worker_pipeline_admit_processing('{paper}','{claim}',1); select 'prepared';")
        return source, paper, claim

    def fund(paper, claim):
        return (f"set role service_role; select public.worker_pipeline_fund('{paper}','{claim}',1,2,"
                f"sha256('funding-options'),sha256('{paper}'));")

    def grant(account):
        sql(f"set role service_role; select public.worker_grant_credits('{account}','adjustment','fund-race-{account}',"
            "100,now()-interval '1 day',null,'Local funding concurrency fixture');")

    def funding_outcome(paper):
        return json.loads(sql(f"select json_build_object('accounts',coalesce(json_agg(funder_account_id),'[]'),"
                              f"'count',count(*)) from app_private.ocr_attempts where paper_id='{paper}';"))

    def release_funding(paper, claim):
        sql(f"set role service_role; select public.worker_pipeline_abandon_funding('{paper}','{claim}',1,'fixture_not_sent'); "
            f"select public.worker_pipeline_release('{paper}','{claim}',1); select public.worker_asset_maintenance();")

    # Fixtures live only in the disposable test DB. Financial rows are append-only
    # and deliberately are not bypassed/deleted as a cleanup shortcut.
    sql("insert into app_private.platform_budgets(period,limit_microusd,work_enabled) values(date_trunc('month',now() at time zone 'UTC')::date,30000000,true) "
        "on conflict(period) do update set work_enabled=true,limit_microusd=greatest(platform_budgets.limit_microusd,platform_budgets.spent_microusd+platform_budgets.reserved_microusd+5000000); "
        "update app_private.provider_spending_policy set enabled=true; select 'enabled';")
    try:
        first, second = Session(), Session()
        a, ao = identity()
        b, bo = identity()
        reserve(a, ao, 0)
        reserve(b, bo, 0)
        allowance = str(uuid.uuid4())
        sql(f"set role service_role; select public.worker_provider_allowance_configure('{allowance}',now()-interval '1 day',"
            "now()+interval '1 day',1,0,now(),'provider-concurrency-fixture',true);")
        at, bt = str(uuid.uuid4()), str(uuid.uuid4())
        admitted = json.loads(first.complete('begin; set role service_role; ' + begin(a, ao, at, 'tavily', 0))[-1])
        assert admitted['granted'] is True
        waiting = second.send('set role service_role; ' + begin(b, bo, bt, 'tavily', 0))
        blocked(second, first)
        assert sql(f"select reserved_units from app_private.provider_allowance_periods where id='{allowance}';") == '0', 'uncommitted grant is invisible'
        first.complete('commit;')
        denied = json.loads(second.until(waiting)[-1])
        assert denied['granted'] is False and denied['reason'] == 'provider_allowance_exhausted', denied
        assert sql(f"select spent_units||','||reserved_units from app_private.provider_allowance_periods where id='{allowance}';") == '0,1'
        # Unknown then customer settlement cannot free the last prepaid unit.
        sql('set role service_role; ' + finish(a, ao, at, 'unknown', 'null') + settle(a, ao) + settle(b, bo) + "select 'settled';")
        assert sql(f"select reserved_units from app_private.provider_allowance_periods where id='{allowance}';") == '1'
        print('PASS independent accounts race for last prepaid unit; unknown stays reserved after zero-credit settlement', flush=True)

        c, co = identity()
        reserve(c, co)
        ct = str(uuid.uuid4())
        assert json.loads(first.complete('begin; ' + begin(c, co, ct))[-1])['granted'] is True
        waiting = second.send(begin(c, co, ct))
        blocked(second, first)
        first.complete('commit;')
        duplicate = json.loads(second.until(waiting)[-1])
        assert duplicate['granted'] is False and duplicate['reason'] == 'attempt_replayed', duplicate
        assert sql(f"select count(*) from app_private.provider_attempt_events where attempt_id='{ct}' and state='admitted';") == '1'
        sql('set role service_role; ' + finish(c, co, ct, 'rejected', '0') + settle(c, co) + "select 'closed';")
        print('PASS simultaneous same-attempt admission grants exactly once after the first commit', flush=True)

        for first_action in ('settle', 'finish'):
            d, do = identity()
            baseline = budget()
            reserve(d, do)
            dt = str(uuid.uuid4())
            sql('set role service_role; ' + begin(d, do, dt) + finish(d, do, dt, 'unknown', 'null') + "select 'unknown';")
            settle_sql, finish_sql = settle(d, do), finish(d, do, dt)
            first_sql, second_sql = (settle_sql, finish_sql) if first_action == 'settle' else (finish_sql, settle_sql)
            first.complete('begin; ' + first_sql)
            waiting = second.send(second_sql)
            blocked(second, first)
            first.complete('commit;')
            second.until(waiting)
            assert budget() == [baseline[0] + 20_000, baseline[1]], (first_action, budget(), baseline)
            assert sql(f"select provider_liability_microusd from app_private.metered_operations where account_id='{d}' and id='{do}';") == '0'
            assert sql(f"select count(*) from app_private.provider_usage_events where provider_event_id='attempt:{dt}';") == '1'
            print(f'PASS concurrent {first_action}-first outcome leaves one known expense and zero unresolved dollar liability', flush=True)

        owner, _ = identity()
        sql(f"insert into app_private.app_roles(account_id,role) values('{owner}','owner'); select 'owner';")
        for unavailable in ('closed', 'suspended'):
            lead, backup = sorted([identity()[0], identity()[0]])
            grant(lead)
            grant(backup)
            _, paper, claim = funding_fixture([lead, backup])
            # Stable ordering makes the first candidate both the first account
            # lock and the first possible payer (not an accident of UUID order).
            sql(f"update app_private.import_requests set created_at=now()-interval '1 minute' where account_id='{lead}'; select 'ordered';")
            before = budget()
            transition = (f"select public.worker_delete_account_begin('{lead}');" if unavailable == 'closed' else
                          f"select public.worker_admin_set_sign_in('{owner}','{uuid.uuid4()}','{lead}',true,'Local funding race');")
            first.complete('begin; set role service_role; ' + transition)
            pending = second.send(fund(paper, claim))
            blocked(second, first)
            # The funder has captured the committed importer set but cannot
            # inspect the first account's new status until its writer commits.
            assert funding_outcome(paper)['count'] == 0
            first.complete('commit;')
            result = json.loads(second.until(pending)[-1])
            assert result['funding'] == 'funded', result
            assert funding_outcome(paper) == {'accounts': [backup], 'count': 1}
            assert sql(f"select count(*) from app_private.metered_operations where account_id='{lead}';") == '0'
            assert budget() == [before[0], before[1] + 10_000], (before, budget())
            release_funding(paper, claim)
            assert budget() == before
            print(f'PASS first importer {unavailable} during funding; second eligible account funds once without a lock inversion', flush=True)

        existing, _ = identity()
        added, _ = identity()
        grant(added)  # The original interested account deliberately has no credits.
        source, paper, claim = funding_fixture([existing])
        before = budget()
        first.complete(f"begin; reset role; select 1 from app_private.accounts where id='{existing}' for update;")
        pending = second.send(fund(paper, claim))
        blocked(second, first)  # Snapshot is taken; the paper fence has not been acquired.
        third = Session()
        third.complete('begin; ' + import_paper(added, source) + ' commit;')
        assert sql(f"select count(*) from app_private.pipeline_imports where paper_id='{paper}';") == '2'
        first.complete('commit;')
        deferred = json.loads(second.until(pending)[-1])
        assert deferred['funding'] == 'waiting' and deferred['stage'] == 'ocr_fund', deferred
        assert funding_outcome(paper)['count'] == 0
        assert budget() == before, 'An account absent from the locked snapshot cannot be charged'
        assert sql(f"select count(*) from app_private.metered_operations where account_id='{added}';") == '0'
        assert json.loads(sql(fund(paper, claim)))['funding'] == 'funded'
        assert funding_outcome(paper) == {'accounts': [added], 'count': 1}
        release_funding(paper, claim)
        assert budget() == before
        print('PASS newly committed importer after account snapshot defers funding; a fresh fenced attempt selects it safely', flush=True)
    finally:
        for session in sessions:
            session.close()
