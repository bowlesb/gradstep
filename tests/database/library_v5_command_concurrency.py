"""True-session dataset-epoch fences for v5 library commands (migration 042).

Synthetic disposable loopback DB only. A rotation is the same UPDATE of
library_v4_config that restore quarantine performs. Barriers are SQL results
and pg_blocking_pids, never guessed sleeps.
"""
import json
import os
import pathlib
import select
import subprocess
import time
import uuid


def verify(bin_path, db, base):
    if list(base) != ['-h', '127.0.0.1', '-p', '55431'] or not db.startswith('science_reader_test_'):
        raise ValueError('Refusing a non-disposable/non-loopback command test target')
    env = {k: v for k, v in os.environ.items() if not k.startswith('PG')}
    sessions = []

    def sql(source):
        result = subprocess.run([str(bin_path / 'psql'), *base, '-X', '-qAt', '-v', 'ON_ERROR_STOP=1', '-d', db],
                                input=source, text=True, capture_output=True, timeout=15, env=env)
        if result.returncode:
            raise AssertionError(result.stderr)
        return result.stdout.strip().splitlines()[-1]

    def claims(account):
        return f"set role authenticated; select set_config('request.jwt.claim.sub','{account}',false);"

    class Session:
        def __init__(self):
            self.process = subprocess.Popen(
                [str(bin_path / 'psql'), *base, '-X', '-qAt', '-v', 'ON_ERROR_STOP=1', '-d', db],
                stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)
            self.buffer = b''
            sessions.append(self)
            self.pid = int(self.complete("set statement_timeout='10s'; set lock_timeout='5s'; select pg_backend_pid();")[-1])

        def send(self, source):
            self.process.stdin.write((source + '\n').encode())
            self.process.stdin.flush()

        def until(self, marker):
            deadline = time.monotonic() + 12
            lines = []
            while time.monotonic() < deadline:
                while b'\n' in self.buffer:
                    line, self.buffer = self.buffer.split(b'\n', 1)
                    text = line.decode().strip()
                    if text == marker:
                        return lines
                    if text:
                        lines.append(text)
                if select.select([self.process.stdout], [], [], .1)[0]:
                    chunk = os.read(self.process.stdout.fileno(), 65536)
                    if not chunk:
                        raise AssertionError(self.process.stderr.read().decode())
                    self.buffer += chunk
            raise AssertionError('SQL barrier timed out')

        def complete(self, source):
            marker = 'barrier_' + uuid.uuid4().hex
            self.send(source + f" select '{marker}';")
            return self.until(marker)

        def error(self, expected):
            code = self.process.wait(timeout=12)
            detail = self.process.stderr.read().decode()
            assert code != 0 and expected in detail, detail

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
        deadline = time.monotonic() + 3
        while time.monotonic() < deadline:
            if sql(f"select {holder.pid}=any(pg_blocking_pids({waiter.pid}));") == 't':
                return
            if waiter.process.poll() is not None:
                raise AssertionError(waiter.process.stderr.read().decode())
            time.sleep(.02)
        raise AssertionError('Expected dataset-epoch lock wait was not observed')

    def epoch():
        return sql('select upload_dataset_epoch from app_private.library_v4_config;')

    def begin(dataset, operation, source, cursor):
        return f"select public.v5_begin_import('{dataset}','{operation}','{source}',{cursor},null);"

    def state(account, operation):
        return sql(f"""select jsonb_build_object('seq',(select last_seq from app_private.library_sync_state where account_id='{account}'),
          'receipt',exists(select 1 from app_private.library_commands where account_id='{account}' and id='{operation}'),
          'import',exists(select 1 from app_private.import_requests where account_id='{account}' and id='{operation}'));""")

    first, second = str(uuid.uuid4()), str(uuid.uuid4())
    sql(f"insert into auth.users values('{first}'),('{second}'); select 'created';")
    rotate = 'update app_private.library_v4_config set upload_dataset_epoch=gen_random_uuid();'

    try:
        # A command's epoch fence is held to COMMIT: a concurrent rotation waits
        # for it, so the command belongs entirely to the dataset it checked.
        old = epoch()
        committed = str(uuid.uuid4())
        writer, rotator = Session(), Session()
        writer.complete('begin; ' + claims(first))
        response = json.loads(writer.complete(begin(old, committed, '2410.05101', 0))[-1])
        assert response['result']['status'] == 'applied' and response['dataset_epoch'] == old
        rotator.send('begin; ' + rotate)
        blocked_by(rotator, writer)
        writer.complete('commit;')
        rotator.complete('commit;')
        new = epoch()
        assert new != old
        assert json.loads(state(first, committed)) == {'seq': 1, 'receipt': True, 'import': True}
        late = str(uuid.uuid4())
        writer.send(claims(first) + begin(old, late, '2410.05102', 1))
        writer.error('library_resync_required')
        assert json.loads(state(first, late)) == {'seq': 1, 'receipt': False, 'import': False}
        writer.close(); rotator.close()
        print('PASS a rotation waits for an epoch-checked command to commit; later old-epoch commands are refused', flush=True)

        # The opposite order: the early unlocked check still sees the committed
        # epoch, the v2 work runs, then the final fence waits for the rotation,
        # re-reads the new epoch and rolls back every effect of the command.
        rotator, writer = Session(), Session()
        rotator.complete('begin; ' + rotate)
        raced = str(uuid.uuid4())
        writer.send(claims(first) + begin(new, raced, '2410.05103', 1))
        blocked_by(writer, rotator)
        rotator.complete('commit;')
        writer.error('library_resync_required')
        assert json.loads(state(first, raced)) == {'seq': 1, 'receipt': False, 'import': False}
        rotator.close()
        print('PASS a command racing a rotation rolls back its receipt, import and journal sequence', flush=True)

        # The fence is a shared row lock: an open command does not block another
        # fence (writers do still share v2's existing rate-window rows), only a rotation.
        current = epoch()
        one, two, rotator = Session(), Session(), Session()
        one.complete('begin; ' + claims(second))
        a = json.loads(one.complete(begin(current, str(uuid.uuid4()), '2410.05104', 0))[-1])
        assert a['result']['status'] == 'applied'
        assert two.complete(f"begin; select app_private.library_command_epoch('{current}',true);")[-1] == current
        rotator.send('begin; ' + rotate)
        # A multi-holder row lock is awaited one holder at a time.
        blocked_by(rotator, one)
        one.complete('commit;')
        blocked_by(rotator, two)
        two.complete('commit;')
        rotator.complete('rollback;')
        assert epoch() == current
        one.close(); two.close(); rotator.close()
        print('PASS fences are shared; a rotation waits for every open fence', flush=True)
    finally:
        for session in sessions:
            if not session.process.stdout.closed:
                session.close()


if __name__ == '__main__':
    repository = pathlib.Path(__file__).resolve().parents[2]
    binaries = pathlib.Path(os.environ.get('SCIENCE_READER_PG_BIN',
        '/Users/benbowlwes/textbrain/scripts/.pgtools/postgresql-18.4.0-aarch64-apple-darwin/bin'))
    base = ['-h', '127.0.0.1', '-p', '55431']
    database = 'science_reader_test_' + uuid.uuid4().hex[:12]
    environment = {k: v for k, v in os.environ.items() if not k.startswith('PG')}

    def run(binary, args, **kwargs):
        return subprocess.run([str(binaries / binary), *base, *args], env=environment, check=True, **kwargs)

    run('createdb', [database])
    try:
        for source in [repository / 'tests/database/bootstrap.sql', *sorted((repository / 'supabase/migrations').glob('*.sql'))]:
            run('psql', ['-X', '-qAt', '-v', 'ON_ERROR_STOP=1', '-d', database, '-f', str(source)], capture_output=True, text=True)
        verify(binaries, database, base)
    except subprocess.CalledProcessError as error:
        raise AssertionError(error.stderr or error.stdout or str(error)) from error
    finally:
        run('dropdb', ['--force', database])
