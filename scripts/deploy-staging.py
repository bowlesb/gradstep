#!/usr/bin/env python3
"""Deploy the paper pipeline, reader delivery and chat to an owned environment.

Applies migrations (via migrate-supabase.py), ensures the private paper bucket,
sets function secrets from local secret files, deploys Edge functions and
schedules the pipeline worker. --defer-activation leaves Vault/scheduling alone,
runs no workflow checks, and does not prove old invocations have stopped.
Never prints credentials.
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


def parse_args(argv=None):
    parser = argparse.ArgumentParser()
    parser.add_argument('environment', choices=['staging'])
    parser.add_argument('--skip-migrations', action='store_true')
    parser.add_argument('--defer-activation', action='store_true', help='Deploy while paused; leave Vault/scheduling unchanged and run no workflow checks')
    parser.add_argument('--functions', nargs='*', help='Subset of functions to deploy')
    parser.add_argument('--rotate-pipeline-secret', action='store_true', help='Generate a new worker secret and update the function and Vault')
    parser.add_argument('--chat-web-search', choices=['on', 'off'], help='Override infra chat_web_search (Anthropic web search in chat)')
    parser.add_argument('--skip-checks', action='store_true', help='Do not run the workflow checks after deploying (docs/architecture/WORKFLOW_CHECKS.md)')
    return parser.parse_args(argv)


def dotenv(path):
    values = {}
    for line in path.read_text().splitlines():
        if '=' in line and not line.lstrip().startswith('#'):
            k, v = line.split('=', 1); values[k.strip()] = v.strip().strip('"').strip("'")
    return values
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

def deploy(args):
    if args.defer_activation and args.rotate_pipeline_secret:
        raise SystemExit('--defer-activation cannot rotate the pipeline secret; coordinate that separately')
    manifest = json.loads((ROOT/'infra/account.json').read_text())
    project = manifest['projects'][args.environment]['id']
    config = json.loads((ROOT/'infra'/f'{args.environment}.json').read_text())
    env_path = ROOT/f'.env.{args.environment}'
    env = dotenv(env_path)
    if args.defer_activation and not env.get('PIPELINE_SECRET'):
        raise SystemExit('Deferred activation requires the existing pipeline secret; do not create or rotate it during cutover')
    providers = dotenv(ROOT/'.env.providers')
    assert project not in ['uskwoaldovvpuyqeymqy', 'wbfbmfwealmspjwowpqh']
    assert manifest['organization']['slug'] == 'mhiweqpcwyqtyorgqhla' and env['SUPABASE_PROJECT_REF'] == project
    management = subprocess.run(['security', 'find-generic-password', '-s', 'Supabase CLI', '-w'], capture_output=True, text=True, check=True).stdout.strip()

    mgmt = {'Authorization': 'Bearer ' + management}
    base = 'https://api.supabase.com/v1/projects/' + project
    remote = request(base, mgmt)
    if remote['organization_id'] != 'mhiweqpcwyqtyorgqhla' or remote['name'] != 'science-reader-' + args.environment:
        raise SystemExit('Refusing a remote project identity mismatch')

    # Routine deployment must not silently re-enable a maintenance cutover.
    # Deferred deployment does not itself stop an already-running old revision.
    if not args.defer_activation:
        worker_url = config.get('pipeline_worker_url')
        if not worker_url or not worker_url.startswith('https://'):
            raise SystemExit('infra pipeline_worker_url is required')
        health = request(worker_url.rstrip('/') + '/health', {})
        if not isinstance(health, dict) or health.get('ok') is not True or health.get('mode') != 'active':
            raise SystemExit('Worker activation is not verified; use --defer-activation during a reviewed cutover')

    if not args.skip_migrations:
        subprocess.run(['python3', str(ROOT/'scripts/migrate-supabase.py'), args.environment], check=True)

    # Purchase observation retention is a database-only scheduled task. Do not deploy
    # the new admission path if migration 038 or its active cleanup job is missing.
    selected_functions = args.functions if args.functions is not None else config['functions']
    if 'store-sync' in selected_functions:
        readiness = request(env['SUPABASE_URL'] + '/rest/v1/rpc/worker_store_verification_readiness',
                            {'Authorization': 'Bearer ' + env['SUPABASE_SERVICE_ROLE_KEY'], 'apikey': env['SUPABASE_SERVICE_ROLE_KEY']}, {})
        cleanup = readiness.get('cleanup', {})
        if not (cleanup.get('active') is True and cleanup.get('expected_command') is True and cleanup.get('schedule') == '17 * * * *'):
            raise SystemExit('Purchase observation cleanup is not ready; review migration 038 and its database cron before deploying store-sync')
        print('Verified bounded purchase diagnostics and hourly database cleanup')

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

    if args.defer_activation:
        print('Activation deferred: Vault and pipeline schedule unchanged; no workflow checks run')
    else:
        def sql(query):
            return request(base + '/database/query', mgmt, {'query': query})
        # The pipeline worker runs on Cloud Run (docs/architecture/PIPELINE_RELIABILITY.md); the Edge
        # paper-worker is retired. Never fall back to it silently.
        worker_url = config.get('pipeline_worker_url')
        if not worker_url or not worker_url.startswith('https://'): raise SystemExit('infra pipeline_worker_url is required')
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

    # Workflow checks (opt out with --skip-checks): the free deploy suite — pipeline URL, worker,
    # scheduler, secrets, functions, budget, stuck imports, add paper, library sync, credits. A chat
    # deploy adds the two cheapest paid checks (about $0.01): an answer and an Add paper outcome.
    if not args.defer_activation and not args.skip_checks:
        deployed = args.functions if args.functions is not None else config['functions']
        also = ['--also=chat.smoke,ingest.not-found'] if 'chat' in deployed else []
        print('Running workflow checks (deploy suite; --skip-checks to opt out)', flush=True)
        checks = subprocess.run(['node', str(ROOT/'scripts/workflow-checks.mjs'), '--suite=deploy', '--trigger=deploy-staging', '--record', *also], cwd=ROOT)
        if checks.returncode != 0:
            raise SystemExit('Deployed, but workflow checks FAILED (table above; report under .artifacts/workflow-checks/).')


def main(argv=None):
    deploy(parse_args(argv))


if __name__ == '__main__':
    main()
