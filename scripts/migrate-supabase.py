#!/usr/bin/env python3
"""Apply immutable migrations to an explicitly recorded Science Reader project.

Each migration and its content hash commit in one transaction. A retry checks
the ledger before executing, including after an ambiguous network failure.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import urllib.request
from migration_ledger import source_ledger, verify_applied_prefix

ROOT = Path(__file__).resolve().parents[1]
paths = sorted((ROOT/'supabase/migrations').glob('*.sql'))
sources = source_ledger(ROOT/'supabase/migrations')
if [path.name.split('_',1)[0] for path in paths] != sorted(sources):
    raise SystemExit('Migration sources changed during preflight')
parser = argparse.ArgumentParser()
parser.add_argument('environment', choices=['staging', 'production'])
args = parser.parse_args()
manifest = json.loads((ROOT/'infra/account.json').read_text())
project = manifest['projects'][args.environment]['id']
organization = manifest['organization']['slug']
if organization != 'mhiweqpcwyqtyorgqhla' or project in ['uskwoaldovvpuyqeymqy','wbfbmfwealmspjwowpqh']:
    raise SystemExit('Refusing an unapproved project')
token = subprocess.run(['security','find-generic-password','-s','Supabase CLI','-w'],capture_output=True,text=True,check=True).stdout.strip()

def api(path, payload=None):
    request = urllib.request.Request('https://api.supabase.com/v1/'+path,
        data=None if payload is None else json.dumps(payload).encode(),
        headers={'Authorization':'Bearer '+token,'Content-Type':'application/json'})
    with urllib.request.urlopen(request,timeout=60) as response:
        return json.load(response)

remote = api('projects/'+project)
if remote.get('organization_id') != organization or remote.get('name') != 'science-reader-'+args.environment:
    raise SystemExit('Remote project identity mismatch')

def query(sql, read_only=False):
    return api('projects/'+project+'/database/query',{'query':sql,'read_only':read_only})

query("""create schema if not exists science_reader_migrations;
revoke all on schema science_reader_migrations from public,anon,authenticated;
create table if not exists science_reader_migrations.versions(version text primary key,sha256 text not null,applied_at timestamptz not null default now());
alter table science_reader_migrations.versions enable row level security;""")
applied = {row['version']:row['sha256'] for row in query('select version,sha256 from science_reader_migrations.versions',True)}
if applied:
    verify_applied_prefix(applied, sources)
for path in paths:
    version=path.name.split('_',1)[0]
    if not re.fullmatch(r'[0-9]+',version): raise SystemExit('Invalid migration filename')
    raw=path.read_bytes(); digest=hashlib.sha256(raw).hexdigest(); source=raw.decode('utf-8')
    if sources.get(version)!=digest: raise SystemExit('Migration source changed during deployment')
    if version in applied:
        if applied[version]!=digest: raise SystemExit('Applied migration changed: '+path.name)
        print('Verified',path.name);continue
    if not source.rstrip().lower().endswith('commit;'): raise SystemExit('Migration missing explicit transaction')
    combined=source.rstrip()[:-7]+f"insert into science_reader_migrations.versions(version,sha256) values('{version}','{digest}');\ncommit;"
    query(combined)
    print('Applied',path.name)
