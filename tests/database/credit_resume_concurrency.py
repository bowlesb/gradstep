"""Credit resume (migration 040) against concurrent grants, reservations, the policy row and itself, on real sessions."""
import json
import os
import select
import subprocess
import time
import uuid


def verify(bin_path, db, base):
    if list(base) != ['-h', '127.0.0.1', '-p', '55431'] or not db.startswith('science_reader_test_'):
        raise ValueError('Refusing non-disposable/non-loopback credit resume target')
    env = {k: v for k, v in os.environ.items() if not k.startswith('PG')}
    sessions = []

    def sql(source):
        result = subprocess.run([str(bin_path / 'psql'), *base, '-X', '-qAt', '-v', 'ON_ERROR_STOP=1', '-d', db],
                                input=source, text=True, capture_output=True, timeout=15, env=env)
        if result.returncode: raise AssertionError(result.stderr)
        return result.stdout.strip().splitlines()[-1]

    class Session:
        def __init__(self):
            self.process = subprocess.Popen([str(bin_path / 'psql'), *base, '-X', '-qAt', '-v', 'ON_ERROR_STOP=1', '-d', db],
                                            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)
            self.buffer = b''
            sessions.append(self)
            self.pid = int(self.complete("set statement_timeout='12s'; set lock_timeout='8s'; select pg_backend_pid();")[-1])

        def send(self, source):
            marker = 'barrier_' + uuid.uuid4().hex
            self.process.stdin.write((source + f" select '{marker}';\n").encode())
            self.process.stdin.flush()
            return marker

        def until(self, marker):
            deadline, lines = time.monotonic() + 15, []
            while time.monotonic() < deadline:
                while b'\n' in self.buffer:
                    raw, self.buffer = self.buffer.split(b'\n', 1)
                    line = raw.decode().strip()
                    if line == marker: return lines
                    if line: lines.append(line)
                if select.select([self.process.stdout], [], [], .05)[0]:
                    data = os.read(self.process.stdout.fileno(), 65536)
                    if not data: raise AssertionError(self.process.stderr.read().decode())
                    self.buffer += data
            raise AssertionError('Credit resume SQL barrier timeout')

        def complete(self, source): return self.until(self.send(source))

        def close(self):
            if self.process.stdin and not self.process.stdin.closed: self.process.stdin.close()
            try: self.process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                self.process.terminate(); self.process.wait(timeout=3)
            self.process.stdout.close(); self.process.stderr.close()

    def blocked(waiter, *holders):
        # A second waiter on the same row queues behind the first waiter's tuple lock.
        deadline = time.monotonic() + 3
        pids = ','.join(str(holder.pid) for holder in holders)
        while time.monotonic() < deadline:
            if sql(f'select pg_blocking_pids({waiter.pid}) && array[{pids}];') == 't': return
            if waiter.process.poll() is not None: raise AssertionError(waiter.process.stderr.read().decode())
            time.sleep(.02)
        raise AssertionError('Expected credit resume lock wait was not observed')

    def waiting_import(credits, need, source):
        """An account whose one import waits on credits for a shared paper needing `need` credits."""
        owner, item = str(uuid.uuid4()), str(uuid.uuid4())
        sql(f"insert into auth.users values('{owner}');"
            f" select set_config('request.jwt.claim.sub','{owner}',false); select public.v2_begin_import('{item}','{source}',0);")
        paper = sql(f"select paper_id from app_private.pipeline_imports where account_id='{owner}' and import_id='{item}';")
        sql(f"update app_private.pipeline_papers set stage='needs_credits',resume_stage='ocr_fund',error_code='insufficient_credits',page_count={need},"
            f" claim_id=null,lease_until=null where id='{paper}';"
            f" update app_private.import_requests set phase='failed',retryable=true,error_code='insufficient_credits' where account_id='{owner}' and id='{item}';"
            f" update app_private.pipeline_imports set retry_requested=false where account_id='{owner}' and import_id='{item}'; select 1;")
        if credits:
            sql(f"select public.worker_grant_credits('{owner}','adjustment','resume-race-{owner}',{credits},now()-interval '1 minute',null,'race');")
        return owner, item

    def phase(owner, item):
        return sql(f"select phase from app_private.import_requests where account_id='{owner}' and id='{item}';")

    original = json.loads(sql('select row_to_json(p) from app_private.pipeline_policy p;'))
    limits = json.loads(sql('select json_build_array(account_active_imports,environment_active_imports) from app_private.library_policy;'))
    period = "date_trunc('month',now() at time zone 'UTC')::date"
    budget = sql(f"select coalesce((select json_build_array(limit_microusd,work_enabled)::text from app_private.platform_budgets where period={period}),'null');")
    try:
        sql(f"select public.worker_set_pipeline_enabled(true); select public.worker_set_platform_budget({period},10000000,true);"
            " update app_private.pipeline_policy set credit_resume_swept_at='-infinity';"
            " update app_private.library_policy set account_active_imports=1000,environment_active_imports=100000; select 1;")

        # A reservation holding the account commits while the sweep waits for it: the sweep decides on the
        # balance after the wait (12 - 5 = 7 < 10), not on its unlocked snapshot (12).
        owner, item = waiting_import(12, 10, '2501.00001')
        spender, sweep = Session(), Session()
        spender.complete(f"begin; select public.worker_reserve_operation('{owner}','{uuid.uuid4()}','chat',decode(repeat('ab',32),'hex'),'beta-credits-v1',5,1000);")
        pending = sweep.send('select public.worker_pipeline_resume_credits(0,100);')
        blocked(sweep, spender)
        spender.complete('commit;')
        result = json.loads(sweep.until(pending)[-1])
        assert phase(owner, item) == 'failed', result
        print('PASS a concurrent reservation is seen after the account wait; nothing resumes beyond the balance', flush=True)

        # A grant waits behind a sweep that holds the account while the sweep waits for the policy row
        # (taken by a deploy retry's order: accounts -> papers -> policy). No cycle; both complete, and the
        # grant's credits are used by the next sweep.
        owner, item = waiting_import(3, 10, '2501.00002')
        policy, sweep, granter = Session(), Session(), Session()
        policy.complete('begin; select 1 from app_private.pipeline_policy where singleton for update;')
        # The snapshot only captures accounts whose balance covers a waiting import: make this one covered.
        sql(f"select public.worker_grant_credits('{owner}','adjustment','resume-race-2-{owner}',7,now()-interval '1 minute',null,'race');")
        pending = sweep.send('select public.worker_pipeline_resume_credits(0,100);')
        blocked(sweep, policy)
        granted = granter.send(f"select public.worker_grant_credits('{owner}','adjustment','resume-race-3-{owner}',50,now()-interval '1 minute',null,'race');")
        blocked(granter, sweep)
        policy.complete('commit;')
        result = json.loads(sweep.until(pending)[-1])
        granter.until(granted)
        assert result['resumed'] >= 1 and phase(owner, item) == 'accepted', result
        assert sql(f"select sum(balance) from app_private.credit_buckets where account_id='{owner}';") == '60'
        print('PASS a grant queued behind a sweep (sweep waiting on the policy row) completes; no lock cycle', flush=True)

        # Two sweeps released together restart the import once.
        owner, item = waiting_import(10, 10, '2501.00003')
        holder, first, second = Session(), Session(), Session()
        holder.complete(f"begin; select id from app_private.accounts where id='{owner}' for update;")
        one = first.send('select public.worker_pipeline_resume_credits(0,100);')
        two = second.send('select public.worker_pipeline_resume_credits(0,100);')
        blocked(first, holder, second); blocked(second, holder, first)
        seq_before = sql(f"select state_seq from app_private.import_requests where account_id='{owner}' and id='{item}';")
        holder.complete('commit;')
        results = [json.loads(first.until(one)[-1]), json.loads(second.until(two)[-1])]
        assert sum(r['resumed'] for r in results) >= 1 and phase(owner, item) == 'accepted', results
        assert int(sql(f"select state_seq from app_private.import_requests where account_id='{owner}' and id='{item}';")) == int(seq_before) + 1
        print('PASS concurrent sweeps restart a waiting import exactly once', flush=True)

        # An account closed while the sweep waited is not touched.
        owner, item = waiting_import(10, 10, '2501.00004')
        closing, sweep = Session(), Session()
        closing.complete(f"begin; select public.worker_delete_account_begin('{owner}');")
        pending = sweep.send('select public.worker_pipeline_resume_credits(0,100);')
        blocked(sweep, closing)
        closing.complete('commit;')
        sweep.until(pending)
        assert sql(f"select count(*) from app_private.import_requests where account_id='{owner}' and phase<>'failed';") == '0'
        print('PASS a sweep rechecks closure after waiting for the account', flush=True)
    finally:
        for session in sessions: session.close()
        enabled = 'true' if original['enabled'] else 'false'
        swept = original['credit_resume_swept_at'].replace("'", "''")
        sql(f"update app_private.pipeline_policy set enabled={enabled},credit_resume_swept_at='{swept}'; select 1;")
        sql(f'update app_private.library_policy set account_active_imports={limits[0]},environment_active_imports={limits[1]}; select 1;')
        if budget != 'null':
            limit, work = json.loads(budget)
            sql(f"update app_private.platform_budgets set limit_microusd={limit},work_enabled={'true' if work else 'false'} where period={period}; select 1;")
        else:
            sql(f"delete from app_private.platform_budgets where period={period} and spent_microusd=0 and reserved_microusd=0; select 1;")
