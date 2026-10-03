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
import urllib.error
import urllib.request
from migration_ledger import source_ledger, verify_applied_prefix

ROOT = Path(__file__).resolve().parents[1]


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def http_error_308(self, req, fp, code, msg, headers):
        raise RuntimeError('Migration request refused an HTTP redirect')

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        # Even same-origin redirects may change the intended operation. Never
        # forward the Management credential or print an untrusted Location.
        raise RuntimeError('Migration request refused an HTTP redirect')


def management_request(opener, token, path, payload=None):
    if not re.fullmatch(r'projects/[a-z]{20}(?:/database/query)?', path):
        raise RuntimeError('Invalid migration Management path')
    request = urllib.request.Request('https://api.supabase.com/v1/' + path,
        data=None if payload is None else json.dumps(payload).encode(),
        headers={'Authorization': 'Bearer ' + token, 'Content-Type': 'application/json'})
    try:
        with opener.open(request, timeout=60) as response:
            raw = response.read(1048577)
    except urllib.error.HTTPError as error:
        # No SQL, response body, credential, or request URL enters diagnostics.
        # A lost/error response can be ambiguous: the next invocation checks
        # the committed ledger before deciding whether to apply anything.
        raise RuntimeError(f'Migration request failed: HTTP {error.code}; inspect the ledger before retrying') from None
    except (urllib.error.URLError, TimeoutError, OSError):
        raise RuntimeError('Migration request transport failed; inspect the ledger before retrying') from None
    if len(raw) > 1048576:
        raise RuntimeError('Migration response exceeded its limit; inspect the ledger before retrying')
    try:
        return json.loads(raw)
    except (ValueError, UnicodeError):
        raise RuntimeError('Migration response was not JSON; inspect the ledger before retrying') from None


def applied_ledger(rows):
    if not isinstance(rows, list) or any(not isinstance(row, dict) or set(row) != {'version', 'sha256'}
                                       or not isinstance(row['version'], str) or not isinstance(row['sha256'], str) for row in rows):
        raise RuntimeError('Remote migration ledger is malformed')
    applied = {row['version']: row['sha256'] for row in rows}
    if len(applied) != len(rows):
        raise RuntimeError('Remote migration ledger contains duplicate versions')
    return applied


def main():
    paths = sorted((ROOT / 'supabase/migrations').glob('*.sql'))
    sources = source_ledger(ROOT / 'supabase/migrations')
    if [path.name.split('_', 1)[0] for path in paths] != sorted(sources):
        raise SystemExit('Migration sources changed during preflight')
    parser = argparse.ArgumentParser()
    parser.add_argument('environment', choices=['staging', 'production'])
    args = parser.parse_args()
    manifest = json.loads((ROOT / 'infra/account.json').read_text())
    project = manifest['projects'][args.environment]['id']
    organization = manifest['organization']['slug']
    if organization != 'mhiweqpcwyqtyorgqhla' or project in ['uskwoaldovvpuyqeymqy', 'wbfbmfwealmspjwowpqh']:
        raise SystemExit('Refusing an unapproved project')
    credential = subprocess.run(['security', 'find-generic-password', '-s', 'Supabase CLI', '-w'],
                                capture_output=True, text=True)
    if credential.returncode or not credential.stdout.strip():
        raise RuntimeError('Supabase CLI Keychain credential unavailable')
    token = credential.stdout.strip()
    opener = urllib.request.build_opener(NoRedirect())

    def api(path, payload=None):
        return management_request(opener, token, path, payload)

    remote = api('projects/' + project)
    if not isinstance(remote, dict) or remote.get('organization_id') != organization or remote.get('name') != 'science-reader-' + args.environment:
        raise SystemExit('Remote project identity mismatch')

    def query(sql, read_only=False):
        return api('projects/' + project + '/database/query', {'query': sql, 'read_only': read_only})

    query("""create schema if not exists science_reader_migrations;
revoke all on schema science_reader_migrations from public,anon,authenticated;
create table if not exists science_reader_migrations.versions(version text primary key,sha256 text not null,applied_at timestamptz not null default now());
alter table science_reader_migrations.versions enable row level security;""")
    applied = applied_ledger(query('select version,sha256 from science_reader_migrations.versions', True))
    if applied:
        verify_applied_prefix(applied, sources)
    for path in paths:
        version = path.name.split('_', 1)[0]
        raw = path.read_bytes()
        digest = hashlib.sha256(raw).hexdigest()
        source = raw.decode('utf-8')
        if sources.get(version) != digest:
            raise SystemExit('Migration source changed during deployment')
        if version in applied:
            if applied[version] != digest:
                raise SystemExit('Applied migration changed: ' + path.name)
            print('Verified', path.name)
            continue
        if not source.rstrip().lower().endswith('commit;'):
            raise SystemExit('Migration missing explicit transaction')
        combined = source.rstrip()[:-7] + f"insert into science_reader_migrations.versions(version,sha256) values('{version}','{digest}');\ncommit;"
        query(combined)
        # Do not treat an HTTP acknowledgement alone as deployment evidence.
        observed = applied_ledger(query('select version,sha256 from science_reader_migrations.versions', True))
        verify_applied_prefix(observed, sources)
        if observed.get(version) != digest:
            raise RuntimeError('Migration acknowledgement did not match the committed ledger')
        applied = observed
        print('Applied and verified', path.name)


if __name__ == '__main__':
    main()
