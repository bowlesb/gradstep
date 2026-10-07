"""Actual-session purchase diagnostic cap, closure and cleanup races; loopback only."""
import json
import os
import select
import subprocess
import time
import uuid


def verify(bin_path, db, base):
    if list(base) != ['-h', '127.0.0.1', '-p', '55431'] or not db.startswith('science_reader_test_'):
        raise ValueError('Refusing a non-disposable/non-loopback purchase observation target')
    env = {key: value for key, value in os.environ.items() if not key.startswith('PG')}
    sessions = []

    def sql(source):
        result = subprocess.run([str(bin_path / 'psql'), *base, '-X', '-qAt', '-v', 'ON_ERROR_STOP=1', '-d', db],
                                input=source, text=True, capture_output=True, timeout=15, env=env)
        if result.returncode:
            raise AssertionError(result.stderr)
        return result.stdout.strip().splitlines()[-1]

    class Session:
        def __init__(self):
            self.process = subprocess.Popen([str(bin_path / 'psql'), *base, '-X', '-qAt', '-v', 'ON_ERROR_STOP=1', '-d', db],
                                            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)
            self.buffer = b''
            sessions.append(self)
            self.pid = int(self.complete("set statement_timeout='12s'; set lock_timeout='10s'; select pg_backend_pid();")[-1])

        def send(self, source):
            marker = 'purchase_barrier_' + uuid.uuid4().hex
            self.process.stdin.write((source + f" select '{marker}';\n").encode())
            self.process.stdin.flush()
            return marker

        def until(self, marker):
            deadline = time.monotonic() + 15
            lines = []
            while time.monotonic() < deadline:
                while b'\n' in self.buffer:
                    line, self.buffer = self.buffer.split(b'\n', 1)
                    value = line.decode().strip()
                    if value == marker:
                        return lines
                    if value:
                        lines.append(value)
                if select.select([self.process.stdout], [], [], .1)[0]:
                    chunk = os.read(self.process.stdout.fileno(), 65536)
                    if not chunk:
                        raise AssertionError(self.process.stderr.read().decode())
                    self.buffer += chunk
            raise AssertionError('Purchase SQL barrier timed out')

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

    def blocked_by(waiter, holder):
        deadline = time.monotonic() + 4
        while time.monotonic() < deadline:
            if sql(f"select {holder.pid}=any(pg_blocking_pids({waiter.pid}));") == 't':
                return
            if waiter.process.poll() is not None:
                raise AssertionError(waiter.process.stderr.read().decode())
            time.sleep(.02)
        raise AssertionError('Expected purchase admission lock wait was not observed')

    def begin(account, attempt=None):
        return ("set role service_role; select public.worker_store_verification_begin("
                f"'{account}','{attempt or uuid.uuid4()}',decode(repeat('38',32),'hex'));")

    accounts = [str(uuid.uuid4()) for _ in range(7)]
    account_sql = ','.join("'" + account + "'" for account in accounts)
    original = json.loads(sql('select to_jsonb(p) from app_private.store_verification_policy p;'))
    sql('insert into auth.users values' + ','.join(f"('{account}')" for account in accounts) + "; select 'ready';")
    try:
        # Independent accounts race for the one remaining global record.
        retained = int(sql('select count(*) from app_private.store_verification_observations;'))
        sql(f"update app_private.store_verification_policy set environment_rows={retained + 1}; select 'limited';")
        first, second = Session(), Session()
        answer = json.loads(first.complete('begin; ' + begin(accounts[0]))[-1])
        assert answer['granted'] is True
        marker = second.send('begin; ' + begin(accounts[1]))
        blocked_by(second, first)
        assert int(sql('select count(*) from app_private.store_verification_observations;')) == retained
        first.complete('commit;')
        refused = json.loads(second.until(marker)[-1])
        assert refused == {'granted': False, 'reason': 'observation_capacity'}, refused
        second.complete('commit;')
        sql(f"update app_private.store_verification_policy set environment_rows={original['environment_rows']}; select 'restored';")
        print('PASS purchase observations: concurrent last global slot grants once', flush=True)

        # An acknowledgement replay remains one actual admitted attempt.
        attempt = str(uuid.uuid4())
        first, second = Session(), Session()
        assert json.loads(first.complete('begin; ' + begin(accounts[2], attempt))[-1])['granted']
        marker = second.send('begin; ' + begin(accounts[2], attempt))
        blocked_by(second, first)
        first.complete('commit;')
        assert json.loads(second.until(marker)[-1]) == {'granted': False, 'reason': 'attempt_replayed'}
        second.complete('commit;')
        print('PASS purchase observations: simultaneous attempt replay admits once', flush=True)

        # Closure wins the account lock; waiting admission must recheck open status.
        closer, admission = Session(), Session()
        closer.complete(f"begin; update app_private.accounts set closed_at=clock_timestamp() where id='{accounts[3]}';")
        marker = admission.send('begin; ' + begin(accounts[3]))
        blocked_by(admission, closer)
        closer.complete('commit;')
        assert json.loads(admission.until(marker)[-1]) == {'granted': False, 'reason': 'account_unavailable'}
        admission.complete('commit;')
        print('PASS purchase observations: closure before admission allocates nothing', flush=True)

        # Admission wins first; closure erases its row, even if finish arrives later.
        attempt = str(uuid.uuid4())
        admission, closer = Session(), Session()
        assert json.loads(admission.complete('begin; ' + begin(accounts[4], attempt))[-1])['granted']
        marker = closer.send(f"begin; update app_private.accounts set closed_at=clock_timestamp() where id='{accounts[4]}';")
        blocked_by(closer, admission)
        admission.complete('commit;')
        closer.until(marker); closer.complete('commit;')
        sql(f"set role service_role; select public.worker_store_verification_finish('{accounts[4]}','{attempt}','verification_unavailable','revocation'); select 'finished';")
        assert sql(f"select count(*) from app_private.store_verification_observations where account_id='{accounts[4]}';") == '0'
        print('PASS purchase observations: closure after admission erases diagnostics and late finish cannot restore them', flush=True)

        # Cleanup holds policy, admission holds account while waiting for policy,
        # and closure waits for that account. Releasing cleanup must unwind this
        # chain without any policy -> account edge or guessed timing barrier.
        attempt = str(uuid.uuid4())
        assert json.loads(sql(begin(accounts[5], attempt)))['granted']
        sql(f"update app_private.store_verification_observations set admitted_at=now()-interval '31 days',expires_at=now()-interval '1 day' where id='{attempt}'; select 'expired';")
        cleaner, admission, closer = Session(), Session(), Session()
        assert cleaner.complete('begin; set role service_role; select public.worker_prune_store_verifications(50000);')[-1] == '1'
        marker_admit = admission.send('begin; ' + begin(accounts[6]))
        blocked_by(admission, cleaner)
        marker_close = closer.send(f"begin; update app_private.accounts set closed_at=clock_timestamp() where id='{accounts[6]}';")
        blocked_by(closer, admission)
        cleaner.complete('commit;')
        assert json.loads(admission.until(marker_admit)[-1])['granted']
        admission.complete('commit;')
        closer.until(marker_close); closer.complete('commit;')
        assert sql(f"select count(*) from app_private.store_verification_observations where account_id='{accounts[6]}';") == '0'
        print('PASS purchase observations: cleanup/admission/closure lock chain completes and erases account data', flush=True)
    finally:
        for session in sessions:
            session.close()
        sql(f"update app_private.store_verification_policy set environment_rows={original['environment_rows']},account_rows={original['account_rows']}; "
            f"update app_private.accounts set closed_at=clock_timestamp() where id in ({account_sql}); select 'cleaned';")
