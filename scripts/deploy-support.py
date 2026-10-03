#!/usr/bin/env python3
"""Deploy the verified private-support service to an explicit owned project.

Uses only the selected environment's service credential. Does not create users,
change billing, invoke providers, or print credentials.
"""
import argparse
import json
import os
from pathlib import Path
import subprocess
import urllib.error
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument('environment', choices=['staging', 'production'])
args = parser.parse_args()
manifest = json.loads((ROOT/'infra/account.json').read_text())
project = manifest['projects'][args.environment]['id']
config = json.loads((ROOT/'infra'/f'{args.environment}.json').read_text())
env = dict(line.split('=',1) for line in (ROOT/f'.env.{args.environment}').read_text().splitlines() if '=' in line)
assert project not in ['uskwoaldovvpuyqeymqy','wbfbmfwealmspjwowpqh']
assert manifest['organization']['slug']=='mhiweqpcwyqtyorgqhla' and env['SUPABASE_PROJECT_REF']==project
management = subprocess.run(['security','find-generic-password','-s','Supabase CLI','-w'],capture_output=True,text=True,check=True).stdout.strip()

def request(url, headers, body=None, method=None, allow_missing=False):
    headers={**headers,'Content-Type':'application/json'}
    req=urllib.request.Request(url, data=None if body is None else json.dumps(body).encode(), headers=headers, method=method)
    try:
        with urllib.request.urlopen(req,timeout=60) as response:
            raw=response.read()
            return json.loads(raw) if raw else None
    except urllib.error.HTTPError as error:
        if allow_missing and error.code in (400,404):
            # Storage's missing bucket is 400 with an embedded 404 status.
            raw=json.loads(error.read())
            if str(raw.get('statusCode',''))=='404' or error.code==404: return None
        raise RuntimeError(f'Infrastructure request failed: HTTP {error.code}') from None

mgmt={'Authorization':'Bearer '+management}
base='https://api.supabase.com/v1/projects/'+project
remote=request(base,mgmt)
if remote['organization_id']!='mhiweqpcwyqtyorgqhla' or remote['name']!='science-reader-'+args.environment:
    raise SystemExit('Refusing a remote project identity mismatch')
storage_headers={'Authorization':'Bearer '+env['SUPABASE_SERVICE_ROLE_KEY'],'apikey':env['SUPABASE_SERVICE_ROLE_KEY']}
bucket_url=env['SUPABASE_URL']+'/storage/v1/bucket'
bucket=request(bucket_url+'/support',storage_headers,allow_missing=True)
expected=config['support_bucket']
if bucket is None:
    request(bucket_url,storage_headers,expected)
    bucket=request(bucket_url+'/support',storage_headers)
if bucket['public'] or bucket['file_size_limit']!=expected['file_size_limit'] or sorted(bucket.get('allowed_mime_types') or [])!=sorted(expected['allowed_mime_types']):
    raise SystemExit('Unexpected support bucket settings; review drift before deploying')
print('Verified private support bucket and file restrictions')
request(base+'/secrets',mgmt,[{'name':'ADMIN_ORIGINS','value':','.join(config['admin_origins'])}])
subprocess.run([str(ROOT/'node_modules/.bin/supabase'),'functions','deploy','support-assets','--project-ref',project,'--use-api','--import-map','supabase/functions/deno.json'],
    cwd=ROOT,env={**os.environ,'SUPABASE_ACCESS_TOKEN':management},check=True)
print('Support service deployed to',args.environment)
