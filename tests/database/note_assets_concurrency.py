"""Notes images (migration 095) under independent concurrent connections: one remaining object slot, the same
PUT repeated at once, conflicting digests for one blob ID, and downloads racing the monthly allowance. No Storage."""
from concurrent.futures import ThreadPoolExecutor
import json
import os
import subprocess
import uuid


def verify(bin_path, db, base):
    if list(base) != ['-h', '127.0.0.1', '-p', '55431'] or not db.startswith('science_reader_test_'):
        raise ValueError('Refusing a non-disposable/non-loopback test target')
    env = {k: v for k, v in os.environ.items() if not k.startswith('PG')}

    def sql(source, check=True):
        result = subprocess.run([str(bin_path / 'psql'), *base, '-X', '-qAt', '-v', 'ON_ERROR_STOP=1', '-d', db],
                                input="set statement_timeout='15s'; " + source, capture_output=True,
                                text=True, env=env, timeout=20)
        if check and result.returncode:
            raise AssertionError(result.stderr)
        return result

    def rows(source):
        return [line for line in sql(source).stdout.splitlines() if line.strip()]

    def attempt(statement):
        # Hold the transaction briefly so separately connected contenders overlap.
        result = sql(f"begin; set local role service_role; select {statement}; select pg_sleep(.1); commit;", check=False)
        if result.returncode == 0:
            return json.loads([l for l in result.stdout.splitlines() if l.startswith('{')][0])
        for code in ('note_asset_quota', 'note_asset_conflict', 'note_transfer_limit'):
            if code in result.stderr:
                return code
        raise AssertionError(result.stderr)

    account = str(uuid.uuid4())
    rows(f"insert into auth.users(id) values('{account}');")
    digest = lambda byte: f"decode(repeat('{byte}',32),'hex')"
    reserve = lambda blob, byte='aa', size=100: f"public.worker_note_asset_reserve('{account}','{blob}',{digest(byte)},{size})"
    try:
        # One slot left: exactly one of eight different objects is admitted.
        rows(f"set role service_role; select {reserve(uuid.uuid4())};")
        rows("update app_private.note_asset_policy set account_objects=2;")
        with ThreadPoolExecutor(max_workers=8) as pool:
            outcomes = list(pool.map(lambda _: attempt(reserve(uuid.uuid4())), range(8)))
        assert sum(isinstance(o, dict) for o in outcomes) == 1 and outcomes.count('note_asset_quota') == 7, outcomes
        rows("update app_private.note_asset_policy set account_objects=4000;")

        # The same PUT eight times at once: one object, one first write, seven repeats of it.
        same = str(uuid.uuid4())
        with ThreadPoolExecutor(max_workers=8) as pool:
            outcomes = list(pool.map(lambda _: attempt(reserve(same, 'bb')), range(8)))
        assert all(isinstance(o, dict) and o['state'] == 'pending' for o in outcomes), outcomes
        assert sum(not o['retry'] for o in outcomes) == 1, outcomes
        assert rows(f"select count(*)||':'||max(attempts) from app_private.note_assets where account_id='{account}' and blob_id='{same}';") == ['1:8']

        # Eight different digests for one new blob ID: exactly one wins; the rest conflict.
        contested = str(uuid.uuid4())
        with ThreadPoolExecutor(max_workers=8) as pool:
            outcomes = list(pool.map(lambda i: attempt(reserve(contested, f'{i + 1:02x}')), range(8)))
        assert sum(isinstance(o, dict) for o in outcomes) == 1 and outcomes.count('note_asset_conflict') == 7, outcomes

        # Downloads racing the account's monthly allowance (three downloads' worth): exactly three admitted.
        rows(f"set role service_role; select public.worker_note_asset_confirm('{account}','{same}',{digest('bb')},100);")
        rows(f"update app_private.note_asset_policy set account_download_bytes_month=300;")
        with ThreadPoolExecutor(max_workers=8) as pool:
            outcomes = list(pool.map(lambda _: attempt(f"public.worker_note_asset_download('{account}','{same}')"), range(8)))
        assert sum(isinstance(o, dict) for o in outcomes) == 3 and outcomes.count('note_transfer_limit') == 5, outcomes
        assert rows(f"select bytes||':'||requests from app_private.note_asset_transfer_months where scope_id='{account}' and kind='download';") == ['300:3']
        assert rows("select (t.bytes=s.b and t.objects=s.n)::text from app_private.note_asset_totals t,"
                    "(select coalesce(sum(byte_count),0) b,count(*) n from app_private.note_assets) s;") == ['true']
    finally:
        rows("update app_private.note_asset_policy set account_objects=4000,account_download_bytes_month=536870912;")
    print('PASS note assets: one slot, repeated PUT, conflicting digests and download allowance under concurrency', flush=True)
