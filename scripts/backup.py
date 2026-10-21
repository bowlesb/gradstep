#!/usr/bin/env python3
"""Encrypted, snapshot-consistent manual backup of a recorded reader project.

Does not write plaintext dumps or objects, create remote records, or contact any
provider. Only a fully verified checkpoint becomes visible outside .incomplete.
Scheduled least-privilege credentials/remote destination are a separate step.
"""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import re
import select
import shutil
import subprocess
import tempfile
import time
import urllib.parse
import urllib.request
import uuid
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat
from migration_ledger import source_ledger, verify_applied_prefix
from pg_tools import pg_bin  # SCIENCE_READER_PG_BIN, PATH, or the documented local tools

ROOT = Path(__file__).resolve().parents[1]
PG_BIN = pg_bin()
SCHEMAS = ['app_private', 'public', 'auth', 'storage', 'science_reader_migrations']
MAX_BYTES = 2 * 1024**3


def protected_bytes(path, value):
    with os.fdopen(os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), 'wb') as stream:
        stream.write(value); stream.flush(); os.fsync(stream.fileno())


def encrypt_stream(source, target, recipient, *, expected_length=None, expected_hash=None, deadline):
    digest = hashlib.sha256(); count = 0
    with os.fdopen(os.open(target, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), 'wb') as destination:
        process = subprocess.Popen(['age', '-r', recipient], stdin=subprocess.PIPE, stdout=destination, stderr=subprocess.PIPE)
        try:
            while True:
                if time.monotonic() > deadline:
                    raise RuntimeError('Backup time limit exceeded')
                chunk = source.read(1024 * 1024)
                if not chunk:
                    break
                count += len(chunk)
                if count > (expected_length if expected_length is not None else MAX_BYTES):
                    raise RuntimeError('Backup input exceeded declared limit')
                digest.update(chunk); process.stdin.write(chunk)
            process.stdin.close()
            error = process.stderr.read(8192)
            if process.wait(timeout=30) or error:
                raise RuntimeError('age encryption did not complete cleanly')
            if expected_length is not None and count != expected_length:
                raise RuntimeError('Backup input length mismatch')
            if expected_hash is not None and digest.hexdigest() != expected_hash:
                raise RuntimeError('Backup input checksum mismatch')
            destination.flush(); os.fsync(destination.fileno())
        except BaseException:
            process.kill(); process.wait(); raise
    archive_digest = hashlib.sha256()
    with target.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            archive_digest.update(chunk)
    return {'file': target.name, 'bytes': count, 'sha256': digest.hexdigest(), 'archive_sha256': archive_digest.hexdigest()}


class Snapshot:
    def __init__(self, env):
        self.env = env
        self.errors = tempfile.TemporaryFile()
        self.process = subprocess.Popen([str(PG_BIN/'psql'), '-X', '-qAt', '-v', 'ON_ERROR_STOP=1'],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=self.errors, env=env, text=True)
        self.process.stdin.write("set idle_in_transaction_session_timeout='15min'; begin isolation level repeatable read read only; select pg_export_snapshot();\n")
        self.process.stdin.flush()
        if not select.select([self.process.stdout], [], [], 30)[0]:
            self.close(); raise RuntimeError('Snapshot connection timed out')
        self.id = self.process.stdout.readline().strip()
        if not re.fullmatch(r'[0-9A-F]+-[0-9A-F]+-[0-9]+', self.id):
            self.close(); raise RuntimeError('Could not establish a database snapshot')

    def query(self, sql):
        command = "begin isolation level repeatable read read only; set transaction snapshot '" + self.id + "'; " + sql + '; rollback;'
        result = subprocess.run([str(PG_BIN/'psql'), '-X', '-qAt', '-v', 'ON_ERROR_STOP=1'],
            input=command, env=self.env, capture_output=True, text=True, timeout=60)
        if result.returncode:
            raise RuntimeError('Snapshot query failed')
        return json.loads(result.stdout)

    def close(self):
        if self.process.poll() is None:
            try:
                self.process.stdin.write('rollback;\n\\q\n'); self.process.stdin.flush()
                self.process.wait(timeout=10)
            except (BrokenPipeError, subprocess.TimeoutExpired):
                self.process.kill(); self.process.wait()
        self.errors.close()


def backup(environment, output):
    os.umask(0o077)
    config = json.loads((ROOT/'infra/account.json').read_text())
    project = config['projects'][environment]['id']
    if config['organization']['slug'] != 'mhiweqpcwyqtyorgqhla' or project in ['uskwoaldovvpuyqeymqy', 'wbfbmfwealmspjwowpqh']:
        raise RuntimeError('Refusing an unapproved project')
    values = dict(line.split('=', 1) for line in (ROOT/('.env.'+environment)).read_text().splitlines() if '=' in line and not line.startswith('#'))
    if values['SUPABASE_PROJECT_REF'] != project or values['SUPABASE_URL'] != f'https://{project}.supabase.co':
        raise RuntimeError('Project identity mismatch')
    recipient = (ROOT/f'infra/{environment}-backup-recipient.txt').read_text().strip()
    if not re.fullmatch(r'age1[0-9a-z]{58}', recipient):
        raise RuntimeError('Invalid backup recipient')
    signing_key = Ed25519PrivateKey.from_private_bytes((ROOT/f'secrets.{environment}-backup-signing').read_bytes())
    if signing_key.public_key().public_bytes(Encoding.Raw, PublicFormat.Raw).hex() != (ROOT/f'infra/{environment}-backup-signing-public.txt').read_text().strip():
        raise RuntimeError('Backup signing identity mismatch')
    env = {**os.environ, 'PGHOST': 'aws-0-us-west-2.pooler.supabase.com', 'PGPORT': '5432',
        'PGUSER': 'postgres.'+project, 'PGDATABASE': 'postgres', 'PGPASSWORD': values['SUPABASE_DB_PASSWORD'],
        'PGSSLMODE': 'verify-full', 'PGSSLROOTCERT': str(ROOT/'infra/supabase-ca-2021.crt'), 'PGCONNECT_TIMEOUT': '15',
        'PGOPTIONS': '-c statement_timeout=720000 -c lock_timeout=30000'}
    output.mkdir(parents=True, exist_ok=True, mode=0o700)
    backup_id = datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ')+'-'+uuid.uuid4().hex[:12]
    pending = output/(backup_id+'.incomplete'); pending.mkdir(mode=0o700)
    snapshot = None; deadline = time.monotonic()+720
    try:
        snapshot = Snapshot(env)
        versions = snapshot.query("select coalesce(jsonb_object_agg(version,sha256),'{}') from science_reader_migrations.versions")
        verify_applied_prefix(versions, source_ledger(ROOT/'supabase/migrations'))
        metadata = snapshot.query("select jsonb_build_object('server_version',current_setting('server_version'),'captured_at',now(),'roles',(select jsonb_agg(rolname order by rolname) from pg_roles where rolname !~ '^pg_'),'tables',(select jsonb_agg(jsonb_build_object('schema',schemaname,'table',tablename) order by schemaname,tablename) from pg_tables where schemaname in ('app_private','auth','storage','science_reader_migrations','public')))")
        counts = []
        for table in metadata['tables']:
            schema, name = table['schema'], table['table']
            if not re.fullmatch(r'[a-z_][a-z_0-9]*', schema) or not re.fullmatch(r'[a-z_][a-z_0-9]*', name):
                raise RuntimeError('Unsupported table identifier')
            counts.append(f"select '{schema}.{name}' as identity,count(*) as count from \"{schema}\".\"{name}\"")
        metadata['table_counts'] = snapshot.query("select jsonb_object_agg(identity,count) from ("+' union all '.join(counts)+') counts')
        objects = snapshot.query("select coalesce(jsonb_agg(jsonb_build_object('id',id,'bucket',bucket,'path',path,'bytes',byte_count,'sha256',encode(sha256,'hex'),'media_type',media_type) order by id),'[]') from app_private.stored_objects where state='verified'")
        # Encrypted note images (migration 095) have their own inventory; ready objects are named by its row ID.
        if snapshot.query("select to_jsonb(to_regclass('app_private.note_assets') is not null)"):
            objects += snapshot.query("select coalesce(jsonb_agg(jsonb_build_object('id',id,'bucket','note-assets','path',account_id::text||'/'||blob_id::text,'bytes',byte_count,'sha256',encode(sha256,'hex'),'media_type','application/octet-stream') order by id),'[]') from app_private.note_assets where state='ready'")
        if len(objects) > 20000 or sum(item['bytes'] for item in objects) > MAX_BYTES:
            raise RuntimeError('Object checkpoint exceeds manual backup size limit')
        with tempfile.TemporaryFile() as dump_errors:
            dump = subprocess.Popen([str(PG_BIN/'pg_dump'), '--format=custom', '--compress=6', '--snapshot='+snapshot.id,
                *['--schema='+name for name in SCHEMAS]], env=env, stdout=subprocess.PIPE, stderr=dump_errors)
            try:
                database = encrypt_stream(dump.stdout, pending/'database.dump.age', recipient, deadline=deadline)
                if dump.wait(timeout=30):
                    raise RuntimeError('Database dump failed')
            finally:
                if dump.poll() is None:
                    dump.kill(); dump.wait()
        for item in objects:
            if item['bucket'] not in ['paper-assets','paper-uploads','podcast-assets','private-content','support','note-assets'] or not re.fullmatch(r'[0-9a-f-]{36}', item['id']):
                raise RuntimeError('Unexpected object identity')
            path = item['path']
            if path.startswith('/') or any(part in ['', '.', '..'] for part in path.split('/')) or '\\' in path:
                raise RuntimeError('Unsafe stored object path')
            url = values['SUPABASE_URL']+'/storage/v1/object/'+item['bucket']+'/'+urllib.parse.quote(path, safe='/')
            request = urllib.request.Request(url, headers={'Authorization':'Bearer '+values['SUPABASE_SERVICE_ROLE_KEY'], 'apikey':values['SUPABASE_SERVICE_ROLE_KEY']})
            # A redirect must never receive the service credential.
            class NoRedirect(urllib.request.HTTPRedirectHandler):
                def redirect_request(self, req, fp, code, msg, headers, newurl):
                    return None
            with urllib.request.build_opener(NoRedirect()).open(request, timeout=30) as response:
                item['archive'] = encrypt_stream(response, pending/(item['id']+'.age'), recipient,
                    expected_length=item['bytes'], expected_hash=item['sha256'], deadline=deadline)
        snapshot.close(); snapshot = None
        manifest = {'format':1, 'id':backup_id, 'environment':environment, 'project_ref':project, 'recipient':recipient,
            'schemas':SCHEMAS, 'migrations':versions, 'metadata':metadata, 'database':database, 'objects':objects,
            'scope':'database-and-verified-objects; hosted secrets/configuration require separate recovery'}
        import io
        encrypt_stream(io.BytesIO(json.dumps(manifest, sort_keys=True).encode()), pending/'manifest.json.age', recipient, deadline=deadline)
        protected_bytes(pending/'manifest.sig', signing_key.sign((pending/'manifest.json.age').read_bytes()))
        completed = output/backup_id; pending.rename(completed)
        print(json.dumps({'checkpoint':str(completed.relative_to(ROOT) if completed.is_relative_to(ROOT) else completed), 'objects':len(objects), 'database_bytes':database['bytes'], 'encrypted':True}))
        return completed
    finally:
        if snapshot is not None:
            snapshot.close()
        if pending.exists():
            # Only this run's encrypted, unpublished partial checkpoint.
            shutil.rmtree(pending)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('environment', choices=['staging','production'])
    parser.add_argument('--output', type=Path, default=ROOT/'.artifacts/backups')
    args = parser.parse_args()
    try:
        backup(args.environment, args.output.resolve())
    except Exception as error:
        # Do not print service responses, URLs, SQL data, or environment values.
        raise SystemExit('Backup failed: '+(str(error) if isinstance(error, RuntimeError) else type(error).__name__))
