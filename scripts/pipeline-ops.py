#!/usr/bin/env python3
"""Operator controls for the staging paper pipeline. Never prints credentials.

  status                      pipeline/budget/papers summary (read-only SQL)
  budget --usd N [--disable]  set this month's platform provider budget
  enable | disable            turn the pipeline worker on/off
  grant ACCOUNT CREDITS KEY   recorded operator credit grant (idempotent per KEY)
  kick                        invoke the worker once
  resolve ATTEMPT (--job ID | --pages N)
                              reconcile an uncertain paid submission: a found
                              Mathpix job resumes polling; otherwise release the
                              hold (no customer charge; N billed pages recorded)
"""
import argparse
import datetime
import json
from pathlib import Path
import subprocess
import urllib.error
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
def dotenv(path):
    values = {}
    for line in path.read_text().splitlines():
        if '=' in line and not line.lstrip().startswith('#'):
            k, v = line.split('=', 1); values[k.strip()] = v.strip().strip('"').strip("'")
    return values
env = dotenv(ROOT/'.env.staging')
manifest = json.loads((ROOT/'infra/account.json').read_text())
project = manifest['projects']['staging']['id']
assert env['SUPABASE_PROJECT_REF'] == project and project not in ['uskwoaldovvpuyqeymqy', 'wbfbmfwealmspjwowpqh']

def http(url, headers, body=None, method='POST'):
    req = urllib.request.Request(url, data=None if body is None else json.dumps(body).encode(), method=method,
                                 headers={**headers, 'Content-Type': 'application/json'})
    try:
        with urllib.request.urlopen(req, timeout=60) as response:
            raw = response.read(); return json.loads(raw) if raw else None
    except urllib.error.HTTPError as error:
        detail = error.read(2000).decode(errors='replace')
        try: detail = json.loads(detail).get('message', detail)
        except ValueError: pass
        raise SystemExit(f'HTTP {error.code}: {detail[:300]}') from None

def rpc(name, params):
    key = env['SUPABASE_SERVICE_ROLE_KEY']
    return http(env['SUPABASE_URL'] + '/rest/v1/rpc/' + name, {'Authorization': 'Bearer ' + key, 'apikey': key}, params)

def sql(query):
    token = subprocess.run(['security', 'find-generic-password', '-s', 'Supabase CLI', '-w'], capture_output=True, text=True, check=True).stdout.strip()
    return http(f'https://api.supabase.com/v1/projects/{project}/database/query', {'Authorization': 'Bearer ' + token}, {'query': query, 'read_only': True})

parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
sub = parser.add_subparsers(dest='command', required=True)
sub.add_parser('status'); sub.add_parser('enable'); sub.add_parser('disable'); sub.add_parser('kick')
b = sub.add_parser('budget'); b.add_argument('--usd', type=float, required=True); b.add_argument('--disable', action='store_true')
g = sub.add_parser('grant'); g.add_argument('account'); g.add_argument('credits', type=int); g.add_argument('key')
r = sub.add_parser('resolve'); r.add_argument('attempt'); r.add_argument('--job'); r.add_argument('--pages', type=int)
args = parser.parse_args()

if args.command == 'status':
    print(json.dumps(sql("""select jsonb_build_object(
 'policy',(select to_jsonb(p)-'arxiv_next_request_at' from app_private.pipeline_policy p),
 'budgets',(select coalesce(jsonb_agg(to_jsonb(b) order by period desc),'[]') from app_private.platform_budgets b),
 'papers',(select coalesce(jsonb_agg(jsonb_build_object('id',id,'source',source_id||coalesce('v'||revision,''),'stage',stage,'error',error_code,
   'failures',failures,'next',next_attempt_at,'leased',lease_until is not null) order by updated_at desc),'[]') from app_private.pipeline_papers),
 'attempts',(select coalesce(jsonb_agg(jsonb_build_object('paper',paper_id,'state',state,'pages',page_limit,'reported',pages_reported,'job',provider_job_id,'error',error_code) order by created_at desc),'[]') from app_private.ocr_attempts),
 'operations',(select coalesce(jsonb_agg(jsonb_build_object('kind',kind,'state',state,'credits',actual_credits,'ceiling',credit_ceiling,'usd',actual_microusd/1e6,'created',created_at) order by created_at desc),'[]')
   from (select * from app_private.metered_operations order by created_at desc limit 30) o)) as status""")[0]['status'], indent=1, default=str))
elif args.command == 'budget':
    period = datetime.date.today().replace(day=1).isoformat()
    print(rpc('worker_set_platform_budget', {'p_period': period, 'p_limit_microusd': int(round(args.usd * 1_000_000)), 'p_enabled': not args.disable}))
elif args.command in ('enable', 'disable'):
    print(rpc('worker_set_pipeline_enabled', {'p_enabled': args.command == 'enable'}))
elif args.command == 'grant':
    print(rpc('worker_grant_credits', {'p_account_id': args.account, 'p_source': 'adjustment', 'p_external_key': 'operator:' + args.key,
        'p_credits': args.credits, 'p_starts_at': '2026-01-01T00:00:00Z', 'p_expires_at': None, 'p_reason': 'Operator beta grant'}))
elif args.command == 'resolve':
    if (args.job is None) == (args.pages is None): raise SystemExit('Pass exactly one of --job or --pages')
    print(rpc('worker_pipeline_resolve_uncertain', {'p_attempt_id': args.attempt, 'p_provider_job_id': args.job, 'p_pages_billed': args.pages}))
elif args.command == 'kick':
    print(http(env['SUPABASE_URL'] + '/functions/v1/paper-worker', {'x-pipeline-secret': env['PIPELINE_SECRET']}, {'reason': 'operator'}))
