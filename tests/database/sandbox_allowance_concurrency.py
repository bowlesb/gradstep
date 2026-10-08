"""Actual concurrent Sandbox allowance sessions, only in a disposable loopback DB."""
import datetime as dt
import json
import os
import select
import subprocess
import time
import uuid


def verify(bin_path, db, base):
    if list(base) != ['-h', '127.0.0.1', '-p', '55431'] or not db.startswith('science_reader_test_'):
        raise ValueError('Refusing a non-disposable/non-loopback Sandbox test target')
    env = {k: v for k, v in os.environ.items() if not k.startswith('PG')}
    sessions = []
    now = int(dt.datetime.now(dt.timezone.utc).timestamp() * 1000)

    def literal(value):
        return "'" + (value if isinstance(value, str) else json.dumps(value, separators=(',', ':'))).replace("'", "''") + "'"

    def sql(source):
        result = subprocess.run([str(bin_path / 'psql'), *base, '-X', '-qAt', '-v', 'ON_ERROR_STOP=1', '-d', db],
                                input=source, text=True, capture_output=True, timeout=15, env=env)
        if result.returncode: raise AssertionError(result.stderr)
        return result.stdout.strip()

    class Session:
        def __init__(self):
            self.process = subprocess.Popen([str(bin_path / 'psql'), *base, '-X', '-qAt', '-v', 'ON_ERROR_STOP=1', '-d', db],
                                            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)
            self.buffer = b''
            sessions.append(self)
            self.pid = int(self.complete("set statement_timeout='10s'; set lock_timeout='5s'; select pg_backend_pid();")[-1])

        def send(self, source):
            self.process.stdin.write((source + '\n').encode()); self.process.stdin.flush()

        def until(self, marker):
            deadline = time.monotonic() + 12
            lines = []
            while time.monotonic() < deadline:
                while b'\n' in self.buffer:
                    line, self.buffer = self.buffer.split(b'\n', 1)
                    value = line.decode().strip()
                    if value == marker: return lines
                    if value: lines.append(value)
                if select.select([self.process.stdout], [], [], .1)[0]:
                    chunk = os.read(self.process.stdout.fileno(), 65536)
                    if not chunk: raise AssertionError(self.process.stderr.read().decode())
                    self.buffer += chunk
            raise AssertionError('Sandbox SQL barrier timed out')

        def complete(self, source):
            marker = 'barrier_' + uuid.uuid4().hex
            self.send(source + f" select '{marker}';")
            return self.until(marker)

        def close(self):
            if not self.process.stdin.closed: self.process.stdin.close()
            try: self.process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                self.process.terminate(); self.process.wait(timeout=3)
            self.process.stdout.close(); self.process.stderr.close()

    def transaction(account, identity, quantity=2, *, environment='Sandbox', revoked=False):
        tid = str(uuid.uuid4().int % (10 ** 30))
        value = {'environment': environment, 'transaction_id': tid, 'original_transaction_id': tid,
                 'product_id': 'com.sciencereader.ios.credits.400', 'type': 'Consumable', 'quantity': quantity,
                 'purchase_date': now - 60_000, 'signed_date': now, 'app_account_token': account,
                 'ownership': 'PURCHASED', 'app_transaction_id': identity}
        if revoked: value['revocation_date'] = now
        return value

    def record(account, value):
        return f"select public.worker_record_store_transaction('{account}',{literal(value)});"

    def notification(value):
        return f"select public.worker_record_store_notification('Sandbox','{uuid.uuid4()}','REFUND_REVERSED',null,now(),{literal(value)});"

    def new_account():
        account = str(uuid.uuid4()); sql(f"insert into auth.users values('{account}');"); return account

    def blocked_by(waiter, holder):
        deadline = time.monotonic() + 3
        while time.monotonic() < deadline:
            if sql(f'select {holder.pid}=any(pg_blocking_pids({waiter.pid}));') == 't': return
            time.sleep(.01)
        raise AssertionError('Competing Sandbox grant did not wait for the first admission transaction')

    def race(first_sql, second_sql, *, independent_production=False):
        first, second = Session(), Session()
        first_result = first.complete('begin; set role service_role; ' + first_sql)
        second.complete('begin; set role service_role;')
        marker = 'after_second_' + uuid.uuid4().hex
        second.send(second_sql + f" select '{marker}';")
        blocked_by(second, first)
        if independent_production:
            account = new_account()
            result = json.loads(sql('set role service_role; ' + record(account, transaction(account, None, 10, environment='Production'))))
            assert result['credits'] == 4000, result
        first.complete('commit;')
        second_result = second.until(marker)
        second.complete('commit;')
        return json.loads(first_result[-1]), json.loads(second_result[-1])

    try:
        # Different original IDs and app accounts bypassed018's row locks while
        # sharing one Apple identity. The second must now wait and receive only200.
        a, b = new_account(), new_account()
        identity = str(uuid.uuid4().int % (10 ** 30))
        one, two = transaction(a, identity), transaction(b, identity)
        results = race(record(a, one), record(b, two), independent_production=True)
        assert [r['credits'] for r in results] == [800, 200], results
        assert sql(f"select sum(credits) from app_private.store_transactions where environment='Sandbox' and app_transaction_id='{identity}';") == '1000'
        print('PASS distinct-account/original Sandbox identity race; Production not blocked by Sandbox gate')

        # Switching Apple IDs must not reset one app account's free allowance.
        c = new_account()
        one = transaction(c, str(uuid.uuid4().int % (10 ** 30)))
        two = transaction(c, str(uuid.uuid4().int % (10 ** 30)))
        results = race(record(c, one), record(c, two))
        assert [r['credits'] for r in results] == [800, 200], results
        print('PASS same-account/different-Apple-ID Sandbox allowance race')

        # First-seen refunds have no buckets; their reversal can be the first
        # actual grant. App and notification routes must use exactly the same gate.
        d, e = new_account(), new_account()
        identity = str(uuid.uuid4().int % (10 ** 30))
        one, two = transaction(d, identity, revoked=True), transaction(e, identity, revoked=True)
        sql('set role service_role; ' + record(d, one) + record(e, two))
        for value in (one, two):
            del value['revocation_date']; value['signed_date'] += 1000
        race(record(d, one), notification(two))
        assert sql(f"select sum(credits) from app_private.store_transactions where environment='Sandbox' and app_transaction_id='{identity}';") == '1000'
        print('PASS concurrent app/notification first-grant refund reversals share the identity allowance')

        # Restoring an already-recorded purchase and a new notification resolve
        # owner binding under the gate. Old-account grant history remains counted.
        old, new = new_account(), new_account()
        identity = str(uuid.uuid4().int % (10 ** 30))
        old_purchase = transaction(old, identity)
        sql('set role service_role; ' + record(old, old_purchase) + f"select public.worker_delete_account_begin('{old}');")
        renewal = transaction(old, identity)
        renewal['original_transaction_id'] = old_purchase['original_transaction_id']
        race(record(new, old_purchase), notification(renewal))
        assert sql(f"select sum(credits) from app_private.store_transactions where environment='Sandbox' and app_transaction_id='{identity}';") == '1000'
        assert sql(f"select account_id from app_private.store_transactions where environment='Sandbox' and transaction_id='{renewal['transaction_id']}';") == new
        print('PASS deleted-account restore versus notification preserves ownership and Apple allowance')
    finally:
        for session in sessions: session.close()
