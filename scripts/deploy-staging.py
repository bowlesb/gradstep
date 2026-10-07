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
parser.add_argument('--rotate-pipeline-secret', action='store_true', help='Generate a new worker secret and update the function and Vault')
parser.add_argument('--chat-web-search', choices=['on', 'off'], help='Override infra chat_web_search (Anthropic web search in chat)')
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

storage_config = request(base + '/config/storage', mgmt)
if storage_config['fileSizeLimit'] < config['paper_bucket']['file_size_limit']:
    request(base + '/config/storage', mgmt, {'fileSizeLimit': config['paper_bucket']['file_size_limit']}, method='PATCH')
    print('Raised the project upload limit to', config['paper_bucket']['file_size_limit'], 'bytes')
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

if 'PIPELINE_SECRET' not in env or args.rotate_pipeline_secret:
    value = secrets.token_urlsafe(48)
    lines = [l for l in env_path.read_text().splitlines() if not l.startswith('PIPELINE_SECRET=')]
    env_path.write_text('\n'.join(lines).rstrip('\n') + f'\nPIPELINE_SECRET={value}\n')
    os.chmod(env_path, 0o600)
    env['PIPELINE_SECRET'] = value
    print('Generated a new dedicated pipeline secret in the local environment file')
web_search = args.chat_web_search or ('on' if config.get('chat_web_search') else 'off')
function_secrets = [{'name': 'ADMIN_ORIGINS', 'value': ','.join(config['admin_origins'])},
                    {'name': 'PIPELINE_SECRET', 'value': env['PIPELINE_SECRET']},
                    {'name': 'CHAT_WEB_SEARCH', 'value': web_search}]
# App Store purchases: which Apple environments this deployment accepts (staging:
# Sandbox, i.e. TestFlight and sandbox testers; never Xcode StoreKit testing).
store = config.get('app_store')
if store:
    function_secrets += [{'name': 'APP_STORE_BUNDLE_ID', 'value': store['bundle_id']},
                         {'name': 'APP_STORE_ENVIRONMENTS', 'value': ','.join(store['environments'])},
                         {'name': 'APP_STORE_ONLINE_CHECKS', 'value': 'true' if store.get('online_checks', True) else 'false'}]
    if store.get('app_apple_id'): function_secrets.append({'name': 'APP_STORE_APP_APPLE_ID', 'value': str(store['app_apple_id'])})
for name in ['MATHPIX_APP_ID', 'MATHPIX_APP_KEY', 'ANTHROPIC_API_KEY', 'TAVILY_API_KEY']:
    if providers.get(name): function_secrets.append({'name': name, 'value': providers[name]})
request(base + '/secrets', mgmt, function_secrets)
print('Set function secrets:', ', '.join(s['name'] for s in function_secrets), f'(chat web search {web_search})')

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
sql("create extension if not exists pg_net with schema extensions")
sql("create extension if not exists pg_cron with schema pg_catalog")
# Secrets are written in standalone SELECT statements (constants are
# normalized in pg_stat_statements; never batched with DDL that may be logged).
for name, value in [('science_reader_pipeline_url', worker_url), ('science_reader_pipeline_secret', env['PIPELINE_SECRET'])]:
    sql(f"select vault.update_secret((select id from vault.secrets where name={literal(name)}),{literal(value)}) where exists(select 1 from vault.secrets where name={literal(name)})")
    sql(f"select vault.create_secret({literal(value)},{literal(name)}) where not exists(select 1 from vault.secrets where name={literal(name)})")
if args.rotate_pipeline_secret:
    sql("select extensions.pg_stat_statements_reset()")
    print('Rotated the pipeline secret and reset query statistics')
sql(f"""select cron.schedule('science-reader-pipeline',{literal(config['pipeline_schedule'])},$cron$
 select net.http_post(url:=(select decrypted_secret from vault.decrypted_secrets where name='science_reader_pipeline_url'),
  body:='{{"reason":"cron"}}'::jsonb,
  headers:=jsonb_build_object('content-type','application/json','x-pipeline-secret',
   (select decrypted_secret from vault.decrypted_secrets where name='science_reader_pipeline_secret')),
  timeout_milliseconds:=5000)
$cron$)""")
print('Scheduled pipeline worker', config['pipeline_schedule'])
