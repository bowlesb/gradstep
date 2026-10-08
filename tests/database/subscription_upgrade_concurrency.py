"""Real upgrade/reservation/notification races in a disposable loopback database."""
import json
import os
import select
import subprocess
import time
import uuid


def verify(bin_path, db, base):
    if list(base) != ['-h', '127.0.0.1', '-p', '55431'] or not db.startswith('science_reader_test_'):
        raise ValueError('Refusing a non-disposable/non-loopback subscription test target')
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
                    value = line.decode().strip()
                    if value == marker:
                        return result
                    if value:
                        result.append(value)
                if select.select([self.process.stdout], [], [], .05)[0]:
                    chunk = os.read(self.process.stdout.fileno(), 65536)
                    if not chunk:
                        raise AssertionError(self.process.stderr.read().decode())
                    self.buffer += chunk
            raise AssertionError('Subscription race barrier timed out')

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
        raise AssertionError('Actual RPC did not wait at the intended account/purchase barrier')

    def fixture(environment):
        account = str(uuid.uuid4())
        tid = str(uuid.uuid4().int % (10 ** 29))
        identity = str(uuid.uuid4().int % (10 ** 29))
        sql(f"insert into auth.users(id) values('{account}');")
        old = {'environment': environment, 'transaction_id': tid, 'original_transaction_id': tid,
               'product_id': 'com.sciencereader.ios.standard.monthly', 'type': 'Auto-Renewable Subscription',
               'purchase_date': now - 10 * 86400_000, 'expires_date': now + 20 * 86400_000,
               'signed_date': now, 'app_account_token': account, 'app_transaction_id': identity, 'reason': 'PURCHASE'}
        upgrade = dict(old, transaction_id=str(uuid.uuid4().int % (10 ** 29)), product_id='com.sciencereader.ios.pro.monthly',
                       purchase_date=now, expires_date=now + 30 * 86400_000)
        sql('set role service_role; ' + record(account, old))
        bucket = sql(f"select bucket_id from app_private.store_transactions where environment='{environment}' and transaction_id='{tid}';")
        return account, old, upgrade, bucket

    def record(account, value):
        return f"select public.worker_record_store_transaction('{account}',{literal(value)});"

    def reserve(account, operation):
        return (f"select public.worker_reserve_operation('{account}','{operation}','chat',sha256('upgrade-race-{operation}'),"
                "'beta-credits-v1',50,250000);")

    try:
        sql("set role service_role; select public.worker_set_platform_budget(date_trunc('month',now() at time zone 'UTC')::date,25000000,true);")
        for environment in ('Production', 'Sandbox'):
            expected = 2600 if environment == 'Production' else 1000
            for reservation_first in (True, False):
                account, old, upgrade, bucket = fixture(environment)
                operation = str(uuid.uuid4())
                funding, purchase = Session(), Session()
                if reservation_first:
                    funding.complete('begin; set role service_role; ' + reserve(account, operation))
                    marker = purchase.send('begin; set role service_role; ' + record(account, upgrade))
                    blocked(purchase, funding)
                    funding.complete('commit;')
                    granted = json.loads(purchase.until(marker)[-1])
                    purchase.complete('commit;')
                else:
                    granted = json.loads(purchase.complete('begin; set role service_role; ' + record(account, upgrade))[-1])
                    marker = funding.send('begin; set role service_role; ' + reserve(account, operation))
                    blocked(funding, purchase)
                    purchase.complete('commit;')
                    funding.until(marker)
                    funding.complete('commit;')
                assert granted['credits'] == expected - 800, granted
                assert sql(f"select balance=800 and reserved=50 and revoked_at is null and "
                           f"expires_at=to_timestamp({old['expires_date']}::numeric/1000) from app_private.credit_buckets where id='{bucket}';") == 't'
                assert sql(f"select bucket_id='{bucket}'::uuid and credits=50 from app_private.reservation_allocations "
                           f"where account_id='{account}' and operation_id='{operation}';") == 't'
                sql(f"set role service_role; select public.worker_settle_operation('{account}','{operation}',20,100000);")
                assert sql(f"select sum(balance)={expected - 20} and sum(reserved)=0 from app_private.credit_buckets where account_id='{account}';") == 't'
                print(f'PASS {environment}: actual reservation and upgrade RPCs serialize ({"reservation" if reservation_first else "upgrade"} first); original hold/expiry and partial settlement preserved', flush=True)

            # A live app report and Apple notification of the same upgrade race.
            account, old, upgrade, bucket = fixture(environment)
            app, notification = Session(), Session()
            outcome = json.loads(app.complete('begin; set role service_role; ' + record(account, upgrade))[-1])
            notification_id = str(uuid.uuid4())
            notice = (f"select public.worker_record_store_notification('{environment}','{notification_id}',"
                      f"'DID_CHANGE_RENEWAL_PREF','UPGRADE',now(),{literal(upgrade)});")
            marker = notification.send('begin; set role service_role; ' + notice)
            blocked(notification, app)
            app.complete('commit;')
            duplicate = json.loads(notification.until(marker)[-1])
            notification.complete('commit;')
            assert outcome['credits'] == expected - 800 and duplicate['outcome'] == 'already_recorded', (outcome, duplicate)
            assert json.loads(sql('set role service_role; ' + notice))['duplicate'] is True
            assert sql(f"select count(*)=2 and sum(balance)={expected} from app_private.credit_buckets where account_id='{account}';") == 't'
            assert sql(f"select count(*)=2 from app_private.credit_ledger where account_id='{account}' and kind='grant';") == 't'
            print(f'PASS {environment}: concurrent app/notification upgrade grants once, duplicate notification grants nothing, prior credits retained', flush=True)
    finally:
        for session in sessions:
            session.close()
