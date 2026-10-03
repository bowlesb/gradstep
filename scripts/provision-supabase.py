#!/usr/bin/env python3
"""Provision only the approved, dedicated Science Reader environment.

Never prints credentials. A protected env file is written before the remote
creation request so interrupted provisioning can be reconciled by project name.
"""
import argparse
import json
import os
from pathlib import Path
import secrets
import subprocess
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument('environment', choices=['staging', 'production'])
args = parser.parse_args()
manifest_path = ROOT / 'infra/account.json'
manifest = json.loads(manifest_path.read_text())
slug = manifest['organization']['slug']
if slug != 'mhiweqpcwyqtyorgqhla':
    raise SystemExit('Organization does not match the dedicated Science Reader organization')
token = subprocess.run(['security', 'find-generic-password', '-s', 'Supabase CLI', '-w'], capture_output=True, text=True, check=True).stdout.strip()

def protected_write(path, content):
    temporary = path.with_name(path.name + '.pending')
    descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(descriptor, 'w') as file:
        file.write(content); file.flush(); os.fsync(file.fileno())
    os.replace(temporary, path)

def api(endpoint, payload=None):
    request = urllib.request.Request('https://api.supabase.com/v1/' + endpoint,
        data=None if payload is None else json.dumps(payload).encode(),
        headers={'Authorization': 'Bearer ' + token, 'Content-Type': 'application/json'})
    with urllib.request.urlopen(request, timeout=60) as response:
        return json.load(response)

org = api('organizations/' + slug)
if org['plan'] != 'pro':
    raise SystemExit('The approved Pro organization is required before provisioning')
name = 'science-reader-' + args.environment
secret_path = ROOT / ('.env.' + args.environment)
if secret_path.exists():
    env = dict(line.split('=', 1) for line in secret_path.read_text().splitlines() if '=' in line and not line.startswith('#'))
else:
    env = {'SUPABASE_DB_PASSWORD': secrets.token_urlsafe(40), 'BACKUP_PASSPHRASE': secrets.token_urlsafe(40)}
    descriptor = os.open(secret_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, 'w') as file:
        file.write(''.join(k + '=' + v + '\n' for k, v in env.items()))
        file.flush(); os.fsync(file.fileno())
projects = api('projects')
matches = [p for p in projects if p.get('organization_id') == slug and p['name'] == name]
if len(matches) > 1:
    raise SystemExit('Ambiguous project name; reconciliation required')
project = matches[0] if matches else api('projects', {
    'name': name, 'organization_slug': slug, 'db_pass': env['SUPABASE_DB_PASSWORD'],
    'desired_instance_size': 'micro', 'region_selection': {'type': 'specific', 'code': 'us-west-2'},
})
if project['id'] in ['uskwoaldovvpuyqeymqy', 'wbfbmfwealmspjwowpqh']:
    raise SystemExit('Refusing a TextBrain project')
manifest['projects'][args.environment] = {k: project.get(k) for k in ['id', 'name', 'region', 'status']}
manifest_path.write_text(json.dumps(manifest, indent=2) + '\n')
env['SUPABASE_PROJECT_REF'] = project['id']
env['SUPABASE_URL'] = 'https://' + project['id'] + '.supabase.co'
os.chmod(secret_path, 0o600)
protected_write(secret_path, ''.join(k + '=' + v + '\n' for k, v in env.items()))
print(json.dumps(manifest['projects'][args.environment]))
