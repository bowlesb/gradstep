"""Separate PostgreSQL transactions exercise one-use grants and lock order."""
import json
import os
import select
import subprocess
import time
import uuid


def verify(bin_path, db, base):
    if list(base) != ['-h', '127.0.0.1', '-p', '55431'] or not db.startswith('science_reader_test_'):
        raise ValueError('Refusing non-disposable purchase verifier target')
    env = {k: v for k, v in os.environ.items() if not k.startswith('PG')}
    command = [str(bin_path / 'psql'), *base, '-X', '-qAt', '-v', 'ON_ERROR_STOP=1', '-d', db]
    sessions = []

    def sql(source):
        completed = subprocess.run(command, input=source, capture_output=True, text=True, env=env, timeout=15)
        if completed.returncode:
            raise AssertionError(completed.stderr)
        return completed.stdout.strip().splitlines()[-1]

    class Session:
        def __init__(self):
            self.process = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)
            self.buffer = b''
            sessions.append(self)
            self.pid = int(self.complete("set statement_timeout='10s'; set lock_timeout='5s'; select pg_backend_pid();")[-1])

        def send(self, source):
            self.process.stdin.write((source + '\n').encode())
            self.process.stdin.flush()

        def until(self, marker):
            lines = []
            deadline = time.monotonic() + 12
            while time.monotonic() < deadline:
                while b'\n' in self.buffer:
                    line, self.buffer = self.buffer.split(b'\n', 1)
                    value = line.decode().strip()
                    if value == marker:
                        return lines
                    if value:
                        lines.append(value)
                if select.select([self.process.stdout], [], [], .05)[0]:
                    chunk = os.read(self.process.stdout.fileno(), 65536)
                    if not chunk:
                        raise AssertionError(self.process.stderr.read().decode())
                    self.buffer += chunk
            raise AssertionError('Purchase verification SQL barrier timed out')

        def complete(self, source):
            marker = 'barrier_' + uuid.uuid4().hex
            self.send(source + f" select '{marker}';")
            return self.until(marker)

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
        raise AssertionError('Expected independent SQL lock wait was not observed')

    def attempt():
        # Same RFC9562 shape as the server adapter, never a user supplied ID.
        return str(uuid.UUID(f'{int(time.time() * 1000):012x}7{uuid.uuid4().hex[:3]}8{uuid.uuid4().hex[:15]}'))

    def start(channel, account=None, identity=None):
        owner = f"'{account}'" if account else 'null'
        return f"select public.worker_start_store_verifier('{channel}',{owner},'{identity or attempt()}',20,'app-store-sandbox-v1');"

    def result(lines):
        return json.loads(lines[-1])

    def reset_usage():
        # Fixture-only setup between independent scenarios; production has no
        # reset RPC. It deliberately does not modify financial/store tables.
        sql("delete from app_private.store_verifier_account_hours; delete from app_private.store_verifier_windows; "
            "delete from app_private.store_verifier_starts; select 'reset';")

    accounts = [str(uuid.uuid4()) for _ in range(4)]
    sql('insert into auth.users(id) values' + ','.join(f"('{a}')" for a in accounts) + "; select 'created';")
    sql("set role service_role; select public.worker_set_store_verifier_enabled('app',1,true); "
        "select public.worker_set_store_verifier_enabled('notification',1,true);")
    a, b = Session(), Session()
    try:
        # Collision across separate channel locks: the unique attempt is the
        # final barrier, not an optimistic existence check.
        identity = attempt()
        assert result(a.complete('begin; set role service_role; ' + start('app', accounts[0], identity)))['granted']
        b.send('begin; set role service_role; ' + start('notification', identity=identity) + " select 'collision_done';")
        blocked(b, a)
        a.complete('commit;')
        assert result(b.until('collision_done'))['reason'] == 'attempt_replayed'
        b.complete('commit;')
        assert sql('select count(*) from app_private.store_verifier_starts;') == '1'
        assert sql("select coalesce(sum(starts),0) from app_private.store_verifier_windows where channel='notification';") == '0'
        print('PASS same-attempt cross-channel collision grants one send, including lost first acknowledgement', flush=True)

        # Last account slot and last global day slot, each with a held winner.
        for scenario in ('account', 'day', 'notification'):
            reset_usage()
            channel = 'notification' if scenario == 'notification' else 'app'
            account = None if channel == 'notification' else accounts[0]
            sql('set role service_role; ' + start(channel, account))
            if scenario == 'account':
                sql('update app_private.store_verifier_account_hours set starts=49; select 1;')
            else:
                unit, used = ('hour', 59) if scenario == 'notification' else ('day', 299)
                sql(f"update app_private.store_verifier_windows set starts={used} where channel='{channel}' and unit='{unit}'; select 1;")
            assert result(a.complete('begin; ' + start(channel, account)))['granted']
            second_account = account if scenario != 'day' else accounts[1]
            b.send('begin; ' + start(channel, second_account) + " select 'boundary_done';")
            blocked(b, a)
            a.complete('commit;')
            assert result(b.until('boundary_done'))['reason'] == ('account_limit' if scenario == 'account' else 'channel_limit')
            b.complete('commit;')
        print('PASS concurrent account, day and anonymous notification final-slot boundaries', flush=True)

        # Closure first and admission first, using the application's real
        # account deletion operation, not only a direct closed_at update.
        reset_usage()
        a.complete(f"begin; select public.worker_delete_account_begin('{accounts[2]}');")
        b.send('begin; ' + start('app', accounts[2]) + " select 'closed_done';")
        blocked(b, a)
        a.complete('commit;')
        assert result(b.until('closed_done'))['reason'] == 'account_unavailable'
        b.complete('commit;')
        assert result(a.complete('begin; ' + start('app', accounts[3])))['granted']
        b.send(f"begin; select public.worker_delete_account_begin('{accounts[3]}'); select 'delete_done';")
        blocked(b, a)
        a.complete('commit;')
        b.until('delete_done'); b.complete('commit;')
        assert sql("select starts from app_private.store_verifier_windows where channel='app' and unit='month';") == '1'
        assert result(a.complete(start('app', accounts[3])))['reason'] == 'account_unavailable'
        print('PASS actual account deletion versus start in both orders; aggregate liability survives closure', flush=True)

        # A late completion cannot recreate a pruned attempt or take any
        # policy/account lock. This also exercises SKIP LOCKED during cleanup.
        reset_usage()
        identity = attempt()
        sql('set role service_role; ' + start('app', accounts[0], identity))
        sql("update app_private.store_verifier_starts set started_at=started_at-interval '960 hours',expires_at=expires_at-interval '960 hours'; select 1;")
        a.complete(f"begin; select public.worker_finish_store_verifier('{identity}','verification_unavailable',100);")
        assert b.complete('select public.worker_prune_store_verifier();')[-1] == '0'
        a.complete('commit;')
        b.complete('begin; select public.worker_prune_store_verifier();')
        a.send(f"select public.worker_finish_store_verifier('{identity}','verification_unavailable',100); select 'finish_done';")
        blocked(a, b)
        b.complete('commit;')
        assert a.until('finish_done')[-1] == 'f'
        assert sql('select count(*) from app_private.store_verifier_starts;') == '0'
        assert sql("select starts from app_private.store_verifier_windows where channel='app' and unit='month';") == '1'
        print('PASS completion versus pruning in both orders; no recreated attempt or refunded quota', flush=True)
    finally:
        for session in sessions:
            session.close()
