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
    finally:
        for session in sessions:
            session.close()
