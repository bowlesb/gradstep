#!/usr/bin/env python3
"""Deploy the paper pipeline, reader delivery and chat to an owned environment.

Applies migrations (via migrate-supabase.py), ensures the private paper bucket,
sets function secrets from local secret files, deploys Edge functions and
schedules the pipeline worker. Never prints credentials.
"""
import argparse
import json
import os
from pathlib import Path
import secrets
import subprocess
import urllib.error
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument('environment', choices=['staging'])
parser.add_argument('--skip-migrations', action='store_true')
parser.add_argument('--functions', nargs='*', help='Subset of functions to deploy')
args = parser.parse_args()
manifest = json.loads((ROOT/'infra/account.json').read_text())
project = manifest['projects'][args.environment]['id']
config = json.loads((ROOT/'infra'/f'{args.environment}.json').read_text())
env_path = ROOT/f'.env.{args.environment}'
def dotenv(path):
    values = {}
    for line in path.read_text().splitlines():
        if '=' in line and not line.lstrip().startswith('#'):
            k, v = line.split('=', 1); values[k.strip()] = v.strip().strip('"').strip("'")
    return values
env = dotenv(env_path)
providers = dotenv(ROOT/'.env.providers')
assert project not in ['uskwoaldovvpuyqeymqy', 'wbfbmfwealmspjwowpqh']
assert manifest['organization']['slug'] == 'mhiweqpcwyqtyorgqhla' and env['SUPABASE_PROJECT_REF'] == project
management = subprocess.run(['security', 'find-generic-password', '-s', 'Supabase CLI', '-w'], capture_output=True, text=True, check=True).stdout.strip()

def request(url, headers, body=None, method=None, allow_missing=False):
    headers = {**headers, 'Content-Type': 'application/json'}
    req = urllib.request.Request(url, data=None if body is None else json.dumps(body).encode(), headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=120) as response:
            raw = response.read()
            return json.loads(raw) if raw else None
    except urllib.error.HTTPError as error:
        if allow_missing and error.code in (400, 404):
            raw = json.loads(error.read() or b'{}')
            if str(raw.get('statusCode', '')) == '404' or error.code == 404: return None
        raise RuntimeError(f'Infrastructure request failed: HTTP {error.code}') from None

mgmt = {'Authorization': 'Bearer ' + management}
base = 'https://api.supabase.com/v1/projects/' + project
remote = request(base, mgmt)
if remote['organization_id'] != 'mhiweqpcwyqtyorgqhla' or remote['name'] != 'science-reader-' + args.environment:
    raise SystemExit('Refusing a remote project identity mismatch')

if not args.skip_migrations:
    subprocess.run(['python3', str(ROOT/'scripts/migrate-supabase.py'), args.environment], check=True)

storage_headers = {'Authorization': 'Bearer ' + env['SUPABASE_SERVICE_ROLE_KEY'], 'apikey': env['SUPABASE_SERVICE_ROLE_KEY']}
bucket_url = env['SUPABASE_URL'] + '/storage/v1/bucket'
expected = config['paper_bucket']
bucket = request(bucket_url + '/' + expected['id'], storage_headers, allow_missing=True)
if bucket is None:
    request(bucket_url, storage_headers, {k: v for k, v in expected.items() if v is not None})
    bucket = request(bucket_url + '/' + expected['id'], storage_headers)
if bucket['public'] or bucket['file_size_limit'] != expected['file_size_limit']:
    raise SystemExit('Unexpected paper bucket settings; review drift before deploying')
print('Verified private paper bucket')

if 'PIPELINE_SECRET' not in env:
    value = secrets.token_urlsafe(48)
    with open(env_path, 'a') as handle: handle.write(f'\nPIPELINE_SECRET={value}\n')
    os.chmod(env_path, 0o600)
    env['PIPELINE_SECRET'] = value
    print('Generated a dedicated pipeline secret in the local environment file')
function_secrets = [{'name': 'ADMIN_ORIGINS', 'value': ','.join(config['admin_origins'])},
                    {'name': 'PIPELINE_SECRET', 'value': env['PIPELINE_SECRET']}]
for name in ['MATHPIX_APP_ID', 'MATHPIX_APP_KEY', 'ANTHROPIC_API_KEY']:
    if providers.get(name): function_secrets.append({'name': name, 'value': providers[name]})
request(base + '/secrets', mgmt, function_secrets)
print('Set function secrets:', ', '.join(s['name'] for s in function_secrets))

for name in (args.functions if args.functions is not None else config['functions']):
    if not (ROOT/'supabase/functions'/name/'index.ts').exists():
        print('Skipping missing function', name); continue
    subprocess.run([str(ROOT/'node_modules/.bin/supabase'), 'functions', 'deploy', name, '--project-ref', project, '--use-api',
                    '--import-map', 'supabase/functions/deno.json'], cwd=ROOT, env={**os.environ, 'SUPABASE_ACCESS_TOKEN': management}, check=True)
    print('Deployed', name)

def sql(query):
    return request(base + '/database/query', mgmt, {'query': query})
worker_url = env['SUPABASE_URL'] + '/functions/v1/paper-worker'
def literal(value): return "'" + value.replace("'", "''") + "'"
sql(f"""create extension if not exists pg_net with schema extensions;
create extension if not exists pg_cron with schema pg_catalog;
do $$ declare existing uuid; begin
 select id into existing from vault.secrets where name='science_reader_pipeline_url';
 if existing is null then perform vault.create_secret({literal(worker_url)},'science_reader_pipeline_url');
 else perform vault.update_secret(existing,{literal(worker_url)}); end if;
 select id into existing from vault.secrets where name='science_reader_pipeline_secret';
 if existing is null then perform vault.create_secret({literal(env['PIPELINE_SECRET'])},'science_reader_pipeline_secret');
 else perform vault.update_secret(existing,{literal(env['PIPELINE_SECRET'])}); end if;
end $$;
select cron.schedule('science-reader-pipeline',{literal(config['pipeline_schedule'])},$cron$
 select net.http_post(url:=(select decrypted_secret from vault.decrypted_secrets where name='science_reader_pipeline_url'),
  body:='{{"reason":"cron"}}'::jsonb,
  headers:=jsonb_build_object('content-type','application/json','x-pipeline-secret',
   (select decrypted_secret from vault.decrypted_secrets where name='science_reader_pipeline_secret')),
  timeout_milliseconds:=5000)
$cron$);""")
print('Scheduled pipeline worker', config['pipeline_schedule'])
