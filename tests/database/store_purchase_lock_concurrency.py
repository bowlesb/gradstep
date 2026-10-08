"""Purchase/account/funding lock-order races in a disposable loopback database.

The transfer cases run the actual purchase, closure and funding RPCs. Historical
bucket ordering uses the exact composed account-lock prefix and is labeled so.
No Apple, provider, hosted database or Storage request is made.
"""
import json
import os
import select
import subprocess
import time
import uuid


def verify(bin_path, db, base):
    if list(base) != ['-h', '127.0.0.1', '-p', '55431'] or not db.startswith('science_reader_test_'):
        raise ValueError('Refusing a non-disposable/non-loopback purchase test target')
    env = {key: value for key, value in os.environ.items() if not key.startswith('PG')}
    sessions = []
    now = int(time.time() * 1000)

    def literal(value):
        return "'" + (value if isinstance(value, str) else json.dumps(value)).replace("'", "''") + "'"

    def sql(source):
        result = subprocess.run([str(bin_path / 'psql'), *base, '-X', '-qAt', '-v', 'ON_ERROR_STOP=1', '-d', db],
                                input=source, text=True, capture_output=True, timeout=15, env=env)
        if result.returncode:
            raise AssertionError(result.stderr)
        lines = result.stdout.strip().splitlines()
        return lines[-1] if lines else ''

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
            raise AssertionError('Purchase lock-order barrier timed out')

        def complete(self, source):
            return self.until(self.send(source))

        def close(self):
            if not self.process.stdin.closed:
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
            time.sleep(.01)
        raise AssertionError('Purchase transaction did not wait at the intended lock barrier')

    def expect_error(session, marker, code):
        try:
            session.until(marker)
        except AssertionError as error:
            assert code in str(error), error
        else:
            raise AssertionError(f'Expected {code}')

    def new_account():
        account = str(uuid.uuid4())
        sql(f"insert into auth.users(id) values('{account}'); select 'created';")
        return account

    def tx(account, environment, *, original=None, product='credits.400'):
        tid = str(uuid.uuid4().int % (10 ** 30))
        result = {'environment': environment, 'transaction_id': tid, 'original_transaction_id': original or tid,
                  'product_id': 'com.sciencereader.ios.' + product, 'type': 'Consumable', 'quantity': 1,
                  'purchase_date': now - 60_000, 'signed_date': now, 'app_account_token': account,
                  'ownership': 'PURCHASED', 'app_transaction_id': str(uuid.uuid4().int % (10 ** 30))}
        if product.endswith('.monthly'):
            result.update(type='Auto-Renewable Subscription', expires_date=now + 30 * 86400_000)
        return result

    def record(account, value):
        return f"select public.worker_record_store_transaction('{account}',{literal(value)});"

    def notification(value):
        return (f"select public.worker_record_store_notification('{value['environment']}','{uuid.uuid4()}',"
                f"'DID_RENEW',null,now(),{literal(value)});")

    def grant(account):
        sql(f"set role service_role; select public.worker_grant_credits('{account}','adjustment','purchase-race-{account}',"
            "100,now()-interval '1 day',null,'Local purchase/funding lock fixture');")

    def funding_fixture(accounts):
        source = '2610.' + str(uuid.uuid4().int % 100000).zfill(5)
        document, claim = str(uuid.uuid4()), str(uuid.uuid4())
        for account in accounts:
            sql(f"set role authenticated; select set_config('request.jwt.claim.sub','{account}',false); "
                f"select public.v2_begin_import('{uuid.uuid4()}','{source}',0);")
        paper = sql(f"select id from app_private.pipeline_papers where source_id='{source}' and owner_id is null;")
        sql(f"insert into app_private.documents(id,sha256,scope,reuse_evidence,byte_count,page_count) "
            f"values('{document}',sha256('{document}'),'shared_catalog','{{\"fixture\":true}}',1000,2); "
            f"update app_private.pipeline_papers set document_id='{document}',eligible=true,page_count=2,stage='ocr_fund',"
            f"claim_id='{claim}',generation=1,lease_until=clock_timestamp()+interval '5 minutes' where id='{paper}'; "
            f"set role service_role; select public.worker_pipeline_admit_processing('{paper}','{claim}',1);")
        return paper, claim

    def fund(paper, claim):
        return (f"set role service_role; select public.worker_pipeline_fund('{paper}','{claim}',1,2,"
                f"sha256('purchase-lock-options'),sha256('{paper}'));")

    original_limits = json.loads(sql('select json_build_array(account_active_imports,environment_active_imports) from app_private.library_policy;'))
    # Earlier concurrency modules intentionally retain accepted imports. Provide
    # only this fixture's extra capacity, restoring policy in finally.
    sql("update app_private.library_policy set account_active_imports=greatest(account_active_imports,1),"
        "environment_active_imports=greatest(environment_active_imports,10+(select count(*) from app_private.import_requests "
        "where desired_present and phase in ('accepted','resolving','acquiring'))); select 'fixture capacity';")
    sql("insert into app_private.platform_budgets(period,limit_microusd,work_enabled) "
        "values(date_trunc('month',now() at time zone 'UTC')::date,30000000,true) on conflict(period) do update "
        "set work_enabled=true,limit_microusd=greatest(platform_budgets.limit_microusd,"
        "platform_budgets.spent_microusd+platform_budgets.reserved_microusd+5000000); select 'enabled';")
    try:
        for environment in ('Production', 'Sandbox'):
            for previously_recorded in (True, False):
                old, new = sorted([new_account(), new_account()])
                purchase = tx(old, environment)
                if previously_recorded:
                    sql('set role service_role; ' + record(old, purchase))
                grant(new)
                paper, claim = funding_fixture([old, new])
                closure, funding, guard, restoring = Session(), Session(), Session(), Session()
                # NO KEY UPDATE deliberately permits the old FK KEY SHARE path.
                # The funder must wait here after it captures A and acquires A.
                guard.complete(f"begin; select id from app_private.accounts where id='{new}' for no key update;")
                closure.complete(f"begin; set role service_role; select public.worker_delete_account_begin('{old}');")
                fm = funding.send('begin; ' + fund(paper, claim))
                blocked(funding, closure)  # Both original interests were captured.
                closure.complete('commit;')
                blocked(funding, guard)  # Now funding holds A and waits for B.
                rm = restoring.send('begin; set role service_role; ' + record(new, purchase))
                blocked(restoring, funding)
                guard.complete('commit;')
                funded = json.loads(funding.until(fm)[-1])
                assert funded['funding'] == 'funded', funded
                funding.complete('commit;')
                restored = json.loads(restoring.until(rm)[-1])
                restoring.complete('commit;')
                expected = 'already_recorded' if previously_recorded else 'recorded'
                assert restored['outcome'] == expected, restored
                assert sql(f"select count(*) from app_private.ocr_attempts where paper_id='{paper}' and funder_account_id='{new}';") == '1'
                assert sql(f"select account_id||','||previous_account_id from app_private.store_owners "
                           f"where environment='{environment}' and original_transaction_id='{purchase['original_transaction_id']}';") == new + ',' + old
                assert sql(f"select account_id from app_private.store_transactions where environment='{environment}' "
                           f"and transaction_id='{purchase['transaction_id']}';") == (old if previously_recorded else new)
                sql(f"set role service_role; select public.worker_pipeline_abandon_funding('{paper}','{claim}',1,'fixture_not_sent'); "
                    f"select public.worker_pipeline_release('{paper}','{claim}',1); select public.worker_asset_maintenance();")
                print(f'PASS {environment} actual closure/funding/purchase RPCs: '
                      f'{"recorded restore" if previously_recorded else "first-seen deleted-token binding"} completes without account inversion', flush=True)

            # Preserve the complete historical-account lock union even though
            # an upgrade now leaves earlier buckets unchanged. Refunds still
            # operate on those buckets and must use the same account ordering.
            old, new = sorted([new_account(), new_account()])
            earlier = tx(old, environment, product='standard.monthly')
            earlier['purchase_date'] -= 86400_000
            sql('set role service_role; ' + record(old, earlier) + f"select public.worker_delete_account_begin('{old}');" + record(new, earlier))
            historical_bucket = sql(f"select to_jsonb(b) from app_private.credit_buckets b join app_private.store_transactions t on t.bucket_id=b.id "
                                    f"where t.environment='{environment}' and t.transaction_id='{earlier['transaction_id']}';")
            upgrade = tx(new, environment, original=earlier['original_transaction_id'], product='pro.monthly')
            upgrade['app_transaction_id'] = earlier['app_transaction_id']
            account_locker, purchasing = Session(), Session()
            account_locker.complete(f"begin; select id from app_private.accounts where id='{old}' for update;")
            pm = purchasing.send('begin; set role service_role; ' + record(new, upgrade))
            blocked(purchasing, account_locker)
            account_locker.complete(f"select id from app_private.accounts where id='{new}' for update; commit;")
            result = json.loads(purchasing.until(pm)[-1])
            purchasing.complete('commit;')
            assert result['credits'] == (1800 if environment == 'Production' else 200), result
            assert sql(f"select to_jsonb(b) from app_private.credit_buckets b join app_private.store_transactions t on t.bucket_id=b.id "
                       f"where t.environment='{environment}' and t.transaction_id='{earlier['transaction_id']}';") == historical_bucket
            print(f'PASS {environment} historical upgrade bucket owner is prelocked (composed funding account prefix); '
                  'prior credits unchanged', flush=True)

        # Unknown attribution preserves newest signed state. Account creation can
        # happen between requests, but a late account cannot be locked mid-request.
        unknown = str(uuid.uuid4())
        unattributed = tx(unknown, 'Production')
        initial = json.loads(sql('set role service_role; ' + notification(unattributed)))
        assert initial['outcome'] == 'unattributed', initial
        newer = dict(unattributed, signed_date=now + 1000, revocation_date=now)
        row_holder, reporting = Session(), Session()
        row_holder.complete("begin; select transaction_id from app_private.store_seen "
                            f"where environment='Production' and transaction_id='{unattributed['transaction_id']}' for update;")
        nm = reporting.send('set role service_role; ' + notification(newer))
        blocked(reporting, row_holder)  # Account snapshot was already captured.
        sql(f"insert into auth.users(id) values('{unknown}'); select 'created after snapshot';")
        row_holder.complete('commit;')
        expect_error(reporting, nm, 'store_account_changed')
        assert sql(f"select count(*) from app_private.store_owners where environment='Production' "
                   f"and original_transaction_id='{unattributed['original_transaction_id']}';") == '0'
        retry = json.loads(sql('set role service_role; ' + notification(newer)))
        assert retry['outcome'] == 'recorded' and retry['credits'] == 0, retry
        replay = json.loads(sql('set role service_role; ' + record(unknown, unattributed)))
        assert replay['outcome'] == 'already_recorded', replay
        assert sql(f"select credits from app_private.store_transactions where environment='Production' "
                   f"and transaction_id='{unattributed['transaction_id']}';") == '0'
        print('PASS unknown notification retains signed state; late account discovery defers without a new lock, retry respects refund precedence', flush=True)

        # An inconsistent original must fail before waiting for that other
        # original's gate, and before touching an existing transaction row.
        conflicting = dict(unattributed, original_transaction_id=str(uuid.uuid4().int % (10 ** 30)))
        gate_holder, conflicting_report = Session(), Session()
        gate_holder.complete("begin; select pg_advisory_xact_lock(741802,hashtext(" +
                             literal('Production:' + conflicting['original_transaction_id']) + "));")
        cm = conflicting_report.send('set role service_role; ' + record(unknown, conflicting))
        expect_error(conflicting_report, cm, 'store_transaction_conflict')
        gate_holder.complete('commit;')
        print('PASS inconsistent transaction/original binding is rejected before entering the other original gate', flush=True)
    finally:
        for session in sessions:
            session.close()
        sql(f'update app_private.library_policy set account_active_imports={original_limits[0]},environment_active_imports={original_limits[1]}; select 1;')
