"""Real retry/closure/policy and candidate-snapshot races on disposable PostgreSQL."""
import json
import os
import select
import subprocess
import time
import uuid


def verify(bin_path, db, base):
    if list(base) != ['-h', '127.0.0.1', '-p', '55431'] or not db.startswith('science_reader_test_'):
        raise ValueError('Refusing non-disposable/non-loopback retry target')
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
            raise AssertionError('Retry SQL barrier timeout')

        def complete(self, source): return self.until(self.send(source))

        def close(self):
            if self.process.stdin and not self.process.stdin.closed: self.process.stdin.close()
            try: self.process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                self.process.terminate(); self.process.wait(timeout=3)
            self.process.stdout.close(); self.process.stderr.close()

    def blocked(waiter, holder):
        deadline = time.monotonic() + 3
        while time.monotonic() < deadline:
            if sql(f'select {holder.pid}=any(pg_blocking_pids({waiter.pid}));') == 't': return
            if waiter.process.poll() is not None: raise AssertionError(waiter.process.stderr.read().decode())
            time.sleep(.02)
        raise AssertionError('Expected retry lock wait was not observed')

    def account():
        value = str(uuid.uuid4())
        sql(f"insert into auth.users values('{value}'); select 1;")
        return value

    def failed_import(owner, source, private=False, attach=None):
        # Use the normal import command for all immutable intent/state fields.
        item = str(uuid.uuid4())
        sql(f"select set_config('request.jwt.claim.sub','{owner}',false); select public.v2_begin_import('{item}','{source}',0);")
        if attach:
            paper = attach
            sql(f"update app_private.pipeline_imports set paper_id='{paper}' where account_id='{owner}' and import_id='{item}'; select 1;")
        elif private:
            paper = str(uuid.uuid4())
            sql(f"insert into app_private.pipeline_papers(id,owner_id,source_id,revision,stage,eligible) values('{paper}','{owner}','{source}',1,'download',false);"
                f" update app_private.pipeline_imports set paper_id='{paper}' where account_id='{owner}' and import_id='{item}'; select 1;")
        else:
            paper = sql(f"select paper_id from app_private.pipeline_imports where account_id='{owner}' and import_id='{item}';")
        sql(f"update app_private.pipeline_papers set stage='failed',resume_stage='download',error_code='download_failed',claim_id=null,lease_until=null where id='{paper}';"
            f" update app_private.pipeline_papers set auto_retry_at=clock_timestamp()-interval '1 second' where id='{paper}';"
            f" update app_private.import_requests set phase='failed',retryable=true,error_code='download_failed' where account_id='{owner}' and id='{item}'; select 1;")
        return paper, item

    original_policy = json.loads(sql('select row_to_json(p) from app_private.pipeline_policy p;'))
    original_limits = json.loads(sql('select json_build_array(account_active_imports,environment_active_imports) from app_private.library_policy;'))
    try:
        sql("select public.worker_set_pipeline_enabled(true); update app_private.pipeline_policy set auto_retry_swept_at='-infinity'; select 1;")
        # Composed transaction lock-order check: a held paper delays closure.
        # Retry must not hold policy while waiting for that account. Normal
        # worker HTTP calls commit between stages; this deliberately composes
        # fenced paper + arXiv slot to prove the broader ordering contract.
        owner = account()
        failed, item = failed_import(owner, '2412.03501', private=True)
        active, claim = str(uuid.uuid4()), str(uuid.uuid4())
        sql(f"insert into app_private.pipeline_papers(id,owner_id,source_id,revision,stage,eligible,claim_id,generation,lease_until)"
            f" values('{active}','{owner}','2412.03502',1,'download',false,'{claim}',1,clock_timestamp()+interval '10 minutes'); select 1;")
        worker, closer, retry = Session(), Session(), Session()
        worker.complete(f"begin; select app_private.pipeline_fenced('{active}','{claim}',1);")
        closed = closer.send(f"select public.worker_delete_account_begin('{owner}');")
        blocked(closer, worker)
        retried = retry.send('select public.worker_pipeline_auto_retry(0,100);')
        blocked(retry, closer)
        worker.complete("select public.worker_pipeline_arxiv_slot(1,45000); commit;")
        closer.until(closed)
        result = json.loads(retry.until(retried)[-1])
        assert result['swept'] is True and result['retried'] == 0, result
        assert sql(f"select count(*) from app_private.import_requests where account_id='{owner}';") == '0'
        assert sql(f"select auto_retry_at is null from app_private.pipeline_papers where id='{failed}';") == 't'
        print('PASS retry leaves policy unlocked while awaiting closure in the composed paper/policy transaction', flush=True)

        # Direct account->paper ordering now used by funding. On027 the retry
        # held this paper while awaiting the funder's account, forming a cycle.
        owner = account()
        paper, item = failed_import(owner, '2412.03505', private=True)
        funder, pending_retry = Session(), Session()
        funder.complete(f"begin; select id from app_private.accounts where id='{owner}' for update;")
        waiting = pending_retry.send('select public.worker_pipeline_auto_retry(0,100);')
        blocked(pending_retry, funder)
        funder.complete(f"select id from app_private.pipeline_papers where id='{paper}' for update;"
                        f" update app_private.pipeline_papers set stage='ocr_fund',resume_stage=null where id='{paper}'; commit;")
        result = json.loads(pending_retry.until(waiting)[-1])
        assert result['retried'] == 0 and result['healed'] == 1, result
        assert sql(f"select auto_retries from app_private.pipeline_papers where id='{paper}';") == '0'
        print('PASS account-first funder can lock its paper while retry waits, and retry rechecks stage', flush=True)

        # Pause after the candidate snapshot by holding its account. A new
        # account/import added while it waits must not be discovered under locks.
        first, late = account(), account()
        paper, first_item = failed_import(first, '2412.03503')
        blocker, sweep = Session(), Session()
        blocker.complete(f"begin; select id from app_private.accounts where id='{first}' for update;")
        pending = sweep.send('select public.worker_pipeline_auto_retry(0,100);')
        blocked(sweep, blocker)
        _, late_item = failed_import(late, '2412.03503', attach=paper)
        blocker.complete('commit;')
        result = json.loads(sweep.until(pending)[-1])
        assert result['retried'] == 1, result
        assert sql(f"select phase from app_private.import_requests where account_id='{first}' and id='{first_item}';") == 'accepted'
        assert sql(f"select phase from app_private.import_requests where account_id='{late}' and id='{late_item}';") == 'failed'
        # The first restart moves the paper; the ordinary next sweep heals the
        # captured-later import without changing its intent revision.
        intent = sql(f"select intent_revision from app_private.import_requests where account_id='{late}' and id='{late_item}';")
        sql(f"update app_private.pipeline_papers set stage='download',resume_stage=null where id='{paper}'; select 1;")
        healed = json.loads(sql('select public.worker_pipeline_auto_retry(0,100);'))
        assert healed['healed'] >= 1
        assert sql(f"select phase||':'||intent_revision from app_private.import_requests where account_id='{late}' and id='{late_item}';") == f'accepted:{intent}'
        print('PASS retry processes only its captured accounts; later interest heals in a subsequent sweep', flush=True)

        # Deploy retry uses the same account-before-paper order and rechecks
        # closure rather than touching the old import after a lock wait.
        owner = account()
        paper, item = failed_import(owner, '2412.03504', private=True)
        closing, deploy = Session(), Session()
        closing.complete(f"begin; select public.worker_delete_account_begin('{owner}');")
        marker = deploy.send("select public.worker_pipeline_retry_failed('retry-race-v1',1000);")
        blocked(deploy, closing)
        closing.complete('commit;')
        result = json.loads(deploy.until(marker)[-1])
        assert result['retried'] == 0, result
        assert sql(f"select count(*) from app_private.import_requests where account_id='{owner}';") == '0'
        print('PASS deploy retry rechecks closed accounts after the captured-account lock wait', flush=True)

        #201 wanted metadata failures exceed the200-candidate snapshot. The final deferred paper keeps its
        # same-deploy retry (since 043 it also has its own automatic-retry timer; this checks the deploy path).
        owner = account()
        sql('update app_private.library_policy set account_active_imports=1000,environment_active_imports=10000; select 1;')
        sql(f"""select set_config('request.jwt.claim.sub','{owner}',false);
          do $$ declare n integer; request uuid; paper uuid; begin
           for n in 1..201 loop
            request:=gen_random_uuid();
            perform public.v2_begin_import(request,'2412.'||lpad((3510+n)::text,5,'0'),0);
            select paper_id into paper from app_private.pipeline_imports where account_id='{owner}' and import_id=request;
            update app_private.pipeline_papers set stage='failed',resume_stage='metadata',error_code='metadata_unavailable' where id=paper;
            update app_private.import_requests set phase='failed',retryable=true,error_code='metadata_unavailable' where account_id='{owner}' and id=request;
           end loop;
          end $$; select 1;""")
        first_pass = json.loads(sql("select public.worker_pipeline_retry_failed('candidate-cap-v1',1000);"))
        assert first_pass['retried'] == 200 and first_pass['deferred'] == 1, first_pass
        assert sql(f"select count(*) from app_private.pipeline_imports pi join app_private.pipeline_papers pp on pp.id=pi.paper_id"
                   f" where pi.account_id='{owner}' and pp.deploy_retry is distinct from 'candidate-cap-v1' and pp.stage='failed';") == '1'
        second_pass = json.loads(sql("select public.worker_pipeline_retry_failed('candidate-cap-v1',1000);"))
        assert second_pass['retried'] == 1 and second_pass['deferred'] == 0, second_pass
        assert sql(f"select count(*) from app_private.import_requests where account_id='{owner}' and phase='accepted';") == '201'
        print('PASS candidate-cap deferral preserves a same-deploy retry for metadata failures', flush=True)
    finally:
        for session in sessions: session.close()
        enabled = 'true' if original_policy['enabled'] else 'false'
        swept = original_policy['auto_retry_swept_at'].replace("'", "''")
        arxiv = original_policy['arxiv_next_request_at'].replace("'", "''")
        sql(f"update app_private.pipeline_policy set enabled={enabled},auto_retry_swept_at='{swept}',arxiv_next_request_at='{arxiv}'; select 1;")
        sql(f'update app_private.library_policy set account_active_imports={original_limits[0]},environment_active_imports={original_limits[1]}; select 1;')
