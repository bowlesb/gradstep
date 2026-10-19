#!/usr/bin/env python3
"""Verify a signed reader backup and drill restore in a disposable local DB.

Never connects to a hosted target. No provider/network configuration is enabled.
Temporary decrypted archives and the disposable database are removed on exit.
The source signature is verified against the public key committed in this repo
before accepting a manifest or running any backed-up SQL.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import time
import uuid
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey
from migration_ledger import source_ledger, verify_applied_prefix

ROOT = Path(__file__).resolve().parents[1]
PG_BIN = Path(os.environ.get('SCIENCE_READER_PG_BIN', '/Users/benbowlwes/textbrain/scripts/.pgtools/postgresql-18.4.0-aarch64-apple-darwin/bin'))
BASE = ['-h','127.0.0.1','-p','55431']


def digest(path):
    value = hashlib.sha256()
    with path.open('rb') as source:
        for chunk in iter(lambda: source.read(1024*1024), b''):
            value.update(chunk)
    return value.hexdigest()


def decrypt(source, key, target, maximum):
    with os.fdopen(os.open(target, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), 'wb') as output:
        process = subprocess.Popen(['age','-d','-i',str(key),str(source)], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        count = 0
        try:
            while chunk := process.stdout.read(1024*1024):
                count += len(chunk)
                if count > maximum:
                    raise RuntimeError('Decrypted archive exceeds expected size')
                output.write(chunk)
            if process.wait(timeout=30):
                raise RuntimeError('Archive authentication failed')
        finally:
            if process.poll() is None:
                process.kill(); process.wait()


def quarantine(sql):
    """Disable admission without releasing restored authority or reservations.

    Older checkpoints lack some optional policy tables. Dynamic statements
    are deliberate: PostgreSQL must not resolve those relations on that path.
    The single DO statement rolls back every flag change if a present table is
    incompatible; the restore then fails and drops its disposable database.
    """
    sql("""do $restore_quarantine$
    begin
      update app_private.platform_budgets set work_enabled=false;
      if pg_catalog.to_regclass('app_private.library_v4_config') is not null then
        -- Backup epochs are restored too. Rotate before any compact/v5 client can
        -- combine a pre-restore cursor/cache with this rewound dataset.
        execute 'update app_private.library_v4_config set dataset_epoch=gen_random_uuid()';
        if exists (
          select 1 from pg_catalog.pg_attribute
          where attrelid=pg_catalog.to_regclass('app_private.library_v4_config')
            and attname='upload_dataset_epoch' and not attisdropped
        ) then
          execute 'update app_private.library_v4_config set upload_dataset_epoch=gen_random_uuid()';
        end if;
      end if;
      if pg_catalog.to_regclass('app_private.acquisition_policy') is not null then
        execute 'update app_private.acquisition_policy set metadata_enabled=false, original_enabled=false, verification_enabled=false';
      end if;
      if pg_catalog.to_regclass('app_private.paper_read_policy') is not null then
        execute 'update app_private.paper_read_policy set enabled=false';
      end if;
      if pg_catalog.to_regclass('app_private.pipeline_policy') is not null then
        execute 'update app_private.pipeline_policy set enabled=false';
      end if;
      if pg_catalog.to_regclass('app_private.pdf_upload_policy') is not null then
        execute 'update app_private.pdf_upload_policy set enabled=false';
      end if;
      if pg_catalog.to_regclass('app_private.tag_policy') is not null then
        execute 'update app_private.tag_policy set enabled=false';
      end if;
      if pg_catalog.to_regclass('app_private.provider_spending_policy') is not null then
        execute 'update app_private.provider_spending_policy set enabled=false';
      end if;
      if pg_catalog.to_regclass('app_private.podcast_policy') is not null then
        -- Podcast admission, worker grants, uploads, publication and delivery all
        -- compare this epoch: rotating it fences every pre-restore job, quote and
        -- grant. Outstanding provider and object liabilities stay recorded.
        execute 'update app_private.podcast_policy set catalog_enabled=false, delivery_enabled=false, generation_enabled=false,
          seed_enabled=false, fixtures_enabled=false, epoch=gen_random_uuid(), revision=revision+1';
      end if;
      if pg_catalog.to_regclass('app_private.store_verifier_policy') is not null then
        -- A restored enabled transport must not forward paid runtime work.
        -- Preserve attempts/counters; fence only policies whose state changes.
        execute 'update app_private.store_verifier_policy set enabled=false, revision=revision+1 where enabled';
      end if;
      if pg_catalog.to_regclass('app_private.executor_authority') is not null then
        if exists (
          select 1 from pg_catalog.pg_attribute
          where attrelid=pg_catalog.to_regclass('app_private.executor_authority')
            and attname='original_admitted' and not attisdropped
        ) then
          execute 'update app_private.executor_authority set enabled=false, original_admitted=false, recovery_required=true, revision=revision+1';
        else
          execute 'update app_private.executor_authority set enabled=false, recovery_required=true, revision=revision+1';
        end if;
      end if;
    end
    $restore_quarantine$;""")


def restore(checkpoint, environment, fixture=None):
    os.umask(0o077)
    start = time.monotonic()
    public_key = Ed25519PublicKey.from_public_bytes(bytes.fromhex((ROOT/f'infra/{environment}-backup-signing-public.txt').read_text().strip()))
    manifest_file = checkpoint/'manifest.json.age'
    if manifest_file.stat().st_size > 32*1024*1024:
        raise RuntimeError('Manifest exceeds limit')
    public_key.verify((checkpoint/'manifest.sig').read_bytes(), manifest_file.read_bytes())
    key = ROOT/f'secrets.{environment}-backup.age'
    db = 'science_reader_restore_'+uuid.uuid4().hex[:12]
    created = False; roles = []
    # Do not inherit arbitrary remote PGHOST/PGDATABASE/PGSERVICE configuration.
    env = {k:v for k,v in os.environ.items() if not k.startswith('PG')}
    env['PGCONNECT_TIMEOUT'] = '5'

    def run(binary, args, **kwargs):
        result = subprocess.run([str(PG_BIN/binary),*BASE,*args],env=env,capture_output=True,text=True,timeout=180,**kwargs)
        if result.returncode:
            # Store neither database contents nor SQL statements in tool logs.
            error_lines = [line for line in result.stderr.splitlines() if 'error:' in line.lower()]
            category = error_lines[0].split('ERROR:',1)[-1].strip() if error_lines else 'no error category'
            # Schema/type names are useful here; row details and statements stay hidden.
            safe_categories = ['schema "public" already exists','relation','does not exist','permission denied']
            category = category if any(value in category for value in safe_categories) and len(category)<240 else 'details withheld'
            raise RuntimeError(binary+' failed: '+category)
        return result.stdout

    def sql(query, database=db):
        return run('psql',['-X','-qAt','-v','ON_ERROR_STOP=1','-d',database],input=query)

    with tempfile.TemporaryDirectory(prefix='restore-',dir=ROOT/'.artifacts') as location:
        work = Path(location)
        decrypt(manifest_file,key,work/'manifest.json',32*1024*1024)
        manifest = json.loads((work/'manifest.json').read_bytes())
        config = json.loads((ROOT/'infra/account.json').read_text())
        if manifest['format'] != 1 or manifest['environment'] != environment or manifest['project_ref'] != config['projects'][environment]['id']:
            raise RuntimeError('Backup identity mismatch')
        verify_applied_prefix(manifest['migrations'], source_ledger(ROOT/'supabase/migrations'))
        archives = [manifest['database'],*[item['archive'] for item in manifest['objects']]]
        if len(archives)>20001 or sum(item['bytes'] for item in archives)>4*1024**3:
            raise RuntimeError('Restore exceeds manual drill limits')
        for archive in archives:
            name = archive['file']
            if name != 'database.dump.age' and not re.fullmatch(r'[0-9a-f-]{36}\.age',name):
                raise RuntimeError('Unsafe archive name')
            source = checkpoint/name
            if source.is_symlink() or digest(source) != archive['archive_sha256']:
                raise RuntimeError('Encrypted archive checksum mismatch')
            target = work/name.removesuffix('.age')
            decrypt(source,key,target,archive['bytes'])
            if target.stat().st_size != archive['bytes'] or digest(target) != archive['sha256']:
                raise RuntimeError('Plaintext archive checksum mismatch')
        for item in manifest['objects']:
            if item['sha256'] != item['archive']['sha256'] or item['bytes'] != item['archive']['bytes']:
                raise RuntimeError('Object manifest mismatch')
        try:
            existing_roles = set(sql('select rolname from pg_roles;',database='postgres').splitlines())
            for role in manifest['metadata']['roles']:
                if not re.fullmatch(r'[a-z_][a-z_0-9]*',role):
                    raise RuntimeError('Unsupported restored role name')
                if role not in existing_roles:
                    # Restore ACL references, never runnable credentials or
                    # inherited/elevated authority. Existing cluster roles are
                    # deliberately outside this disposable drill's ownership.
                    sql(f'create role "{role}" nologin noinherit nosuperuser nocreatedb nocreaterole noreplication nobypassrls;',database='postgres'); roles.append(role)
            run('createdb',[db]); created = True
            sql('drop schema public;')  # Empty template schema in this newly created local DB only.
            # --schema backups omit extension objects/schema. Library query indexes (032) still
            # depend on pg_trgm; install that known local prerequisite before restoring their DDL.
            # This disposable DB has no hosted credentials, scheduler or provider transport.
            sql('create schema extensions; create extension pg_trgm with schema extensions;')
            run('pg_restore',['--exit-on-error','--single-transaction','--no-owner','--dbname',db,str(work/'database.dump')])
            restored_migrations = json.loads(sql("select coalesce(jsonb_object_agg(version,sha256),'{}') from science_reader_migrations.versions;"))
            if restored_migrations != manifest['migrations']:
                raise RuntimeError('Restored migration ledger differs from signed manifest')
            for identity,count in manifest['metadata']['table_counts'].items():
                if not re.fullmatch(r'[a-z_][a-z_0-9]*\.[a-z_][a-z_0-9]*',identity):
                    raise RuntimeError('Unsafe table identity')
                actual = int(sql('select count(*) from '+identity+';').strip())
                if actual != count:
                    raise RuntimeError('Restored row count mismatch')
            # Quarantine is explicit even though this local target has no worker.
            # Keep network gate leases, uncertain grants and charged/reserved
            # capacity intact for a later deliberate recovery reconciliation.
            quarantine(sql)
            if sql("select count(*) from pg_tables where schemaname='app_private' and not rowsecurity;").strip() != '0':
                raise RuntimeError('Restored application table lacks RLS')
            expected = len(manifest['objects'])
            if int(sql("select count(*) from app_private.stored_objects where state='verified';").strip()) != expected:
                raise RuntimeError('Restored object references differ from checkpoint')
            # Test-only identities/data supplied on stdin by the synthetic check.
            if fixture:
                account, report, attachment, event = [fixture[k] for k in ['account','report','attachment','event']]
                if not all(re.fullmatch(r'[0-9a-f-]{36}',value) for value in [account,report,attachment,event]):
                    raise RuntimeError('Invalid fixture identity')
                rows = json.loads(sql(f"select jsonb_build_object('report',(select note from app_private.support_reports where id='{report}' and account_id='{account}'),'event',(select encode(ciphertext,'hex') from app_private.sync_events where id='{event}' and account_id='{account}'),'attachment',(select count(*) from app_private.support_attachments where report_id='{report}' and object_id='{attachment}'));") )
                if rows != {'report':fixture['note'],'event':fixture['ciphertext'],'attachment':1}:
                    raise RuntimeError('Restored fixture content mismatch')
                if digest(work/attachment) != fixture['image_sha256']:
                    raise RuntimeError('Restored screenshot differs')
            print(json.dumps({'restored':True,'environment':environment,'tables':len(manifest['metadata']['table_counts']),
                'objects':expected,'seconds':round(time.monotonic()-start,2),'scope':'local quarantine; hosted recovery not verified'}))
        finally:
            if created:
                run('dropdb',[db])
            for role in reversed(roles):
                sql(f'drop role "{role}";',database='postgres')


if __name__ == '__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('checkpoint',type=Path)
    parser.add_argument('--environment',choices=['staging','production'],default='staging')
    parser.add_argument('--fixture-stdin',action='store_true')
    args=parser.parse_args()
    try:
        import sys
        fixture=json.load(sys.stdin) if args.fixture_stdin else None
        restore(args.checkpoint.resolve(),args.environment,fixture)
    except Exception as error:
        raise SystemExit('Restore failed: '+(str(error) if isinstance(error,RuntimeError) else type(error).__name__))
