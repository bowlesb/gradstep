"""Apply the capacity migration to existing encrypted rows, then reconstruct usage."""
import subprocess
import uuid


def verify(bin_path, db, base, root):
    target = db + '_upgrade'
    def run(binary, args, **kwargs):
        return subprocess.run([str(bin_path / binary), *base, *args], check=True, **kwargs)
    def sql(source):
        return run('psql', ['-X', '-qAt', '-v', 'ON_ERROR_STOP=1', '-d', target], input=source, text=True, capture_output=True).stdout.strip()
    run('createdb', [target])
    try:
        sql((root / 'tests/database/bootstrap.sql').read_text())
        migrations = sorted((root / 'supabase/migrations').glob('*.sql'))
        for source in migrations:
            if source.name >= '202610030009':
                break
            sql(source.read_text())
        account, device, event = (str(uuid.uuid4()) for _ in range(3))
        claims = f"set role authenticated; select set_config('request.jwt.claim.sub','{account}',false);"
        sql(f"insert into auth.users values('{account}'); {claims} select public.v1_bootstrap_keys('{device}',decode(repeat('11',32),'hex'),decode(repeat('22',60),'hex'),decode(repeat('33',32),'hex'),decode(repeat('44',92),'hex'),decode(repeat('aa',32),'hex')); select public.v1_append_event('{device}','{event}',1,1,decode(repeat('55',120),'hex'),decode(repeat('33',32),'hex'));")
        before = sql(f"select row_to_json(e) from app_private.sync_events e where account_id='{account}';")
        for source in migrations:
            if source.name >= '202610030009':
                sql(source.read_text())
        assert sql(f"select row_to_json(e) from app_private.sync_events e where account_id='{account}';") == before
        assert sql('select ciphertext_bytes,event_count from app_private.sync_environment_storage;') == '120|1'
        assert sql(f"select ciphertext_bytes,event_count from app_private.sync_account_storage where account_id='{account}';") == '120|1'
        assert sql(f"{claims} select public.v1_append_event('{device}','{event}',1,1,decode(repeat('55',120),'hex'),decode(repeat('33',32),'hex'));").splitlines()[-1] == '1'
        assert sql('select ciphertext_bytes,event_count from app_private.sync_environment_storage;') == '120|1'
        print('PASS upgrade from existing encrypted history: exact bytes, cursor, replay and backfilled accounting')
    finally:
        run('dropdb', [target])
