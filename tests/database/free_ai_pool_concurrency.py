"""The free AI pool under concurrency (migration 0150): many free readers, separately connected, reserve at once against
a small pool. The owner's promise is that free-funded worst-case spend never passes the pool. No model calls."""
from concurrent.futures import ThreadPoolExecutor
import json
import os
import subprocess
import uuid

GEMINI = ('{"profile_version":"chat-profiles-v1","profile":"gemini-medium-standard","model":"gemini-3.8-flash","effort":"medium",'
          '"length":"standard","tariff":"openrouter-google-flash-vertex-us-20261017","max_output_tokens":10000,'
          '"input_estimate_tokens":120000,"max_searches":0,"title_model":"claude-haiku-5-5","title_max_tokens":40,'
          '"title_ceiling_microusd":3000,"follow_ups_model":"claude-haiku-5-5","follow_ups_max_tokens":160,'
          '"follow_ups_ceiling_microusd":9000}')


def verify(bin_path, db, base):
    if list(base) != ['-h', '127.0.0.1', '-p', '55431'] or not db.startswith('science_reader_test_'):
        raise ValueError('Refusing a non-disposable/non-loopback test target')
    env = {k: v for k, v in os.environ.items() if not k.startswith('PG')}

    def sql(source):
        result = subprocess.run([str(bin_path / 'psql'), *base, '-X', '-qAt', '-v', 'ON_ERROR_STOP=1', '-d', db],
                                input="set statement_timeout='20s'; " + source, capture_output=True,
                                text=True, env=env, timeout=30)
        if result.returncode:
            return None, result.stderr
        return [line for line in result.stdout.splitlines() if line.strip()], None

    readers = [str(uuid.uuid4()) for _ in range(12)]
    rows, error = sql("insert into auth.users(id,email) values " + ','.join(f"('{r}','r{i}@gradstep.test.org')" for i, r in enumerate(readers)) + "; "
                      "select public.worker_set_platform_budget(date_trunc('month',now() at time zone 'UTC')::date,10000000,true); "
                      "update app_private.ai_controls set free_pool_microusd=app_private.free_pool_used()+500000,free_account_microusd=5000000;")
    assert error is None, error
    pool = int(sql("select free_pool_microusd from app_private.ai_controls;")[0][-1])
    before = int(sql("select app_private.free_pool_used();")[0][-1])

    def reserve(reader):
        operation = str(uuid.uuid4())
        # Hold the transaction briefly so the contenders overlap.
        rows, error = sql(f"begin; set local role service_role; select public.worker_reserve_chat('{reader}','{operation}',"
                          f"sha256('{operation}'),'beta-credits-v1',10,120000,'{GEMINI}'::jsonb); select pg_sleep(.1); commit;")
        if error:
            assert 'insufficient_credits' in error, error
            return False
        return not json.loads(rows[0])['replayed']

    with ThreadPoolExecutor(max_workers=12) as pool_threads:
        admitted = sum(pool_threads.map(reserve, readers))
    used = int(sql("select app_private.free_pool_used();")[0][-1])
    assert admitted == 4, f'exactly the requests that fit the pool are admitted ({admitted})'
    assert used <= pool and used - before == admitted * 120000, (used, pool, before)
    funded = int(sql("select count(*) from app_private.metered_operations where free_funded and account_id in ("
                     + ','.join(f"'{r}'" for r in readers) + ");")[0][-1])
    assert funded == admitted, funded
    print(f'PASS free AI pool: {admitted} of 12 concurrent free requests admitted; free worst case {used} <= pool {pool}', flush=True)
