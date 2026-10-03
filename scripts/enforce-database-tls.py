#!/usr/bin/env python3
"""Enforce TLS on a recorded reader project. Supabase briefly restarts its DB."""
import argparse
import json
from pathlib import Path
import subprocess
import time
import urllib.request

ROOT=Path(__file__).resolve().parents[1]
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('environment',choices=['staging','production'])
args=parser.parse_args()
config=json.loads((ROOT/'infra/account.json').read_text())
project=config['projects'][args.environment]['id']
organization=config['organization']['slug']
if organization!='mhiweqpcwyqtyorgqhla' or project in ['uskwoaldovvpuyqeymqy','wbfbmfwealmspjwowpqh']:
    raise SystemExit('Refusing an unapproved project')
token=subprocess.run(['security','find-generic-password','-s','Supabase CLI','-w'],capture_output=True,text=True,check=True).stdout.strip()

def api(path,payload=None,method='GET'):
    request=urllib.request.Request('https://api.supabase.com/v1/'+path,
        data=None if payload is None else json.dumps(payload).encode(),method=method,
        headers={'Authorization':'Bearer '+token,'Content-Type':'application/json'})
    with urllib.request.urlopen(request,timeout=30) as response:
        body=response.read()
        return json.loads(body) if body else None

remote=api('projects/'+project)
if remote.get('organization_id')!=organization or remote.get('name')!='science-reader-'+args.environment:
    raise SystemExit('Remote project identity mismatch')
path='projects/'+project+'/ssl-enforcement'
status=api(path)
if not status['currentConfig']['database'] or not status['appliedSuccessfully']:
    api(path,{'requestedConfig':{'database':True}},'PUT')
    print('Requested TLS enforcement for '+args.environment,flush=True)
for attempt in range(30):
    status=api(path)
    if status['currentConfig']['database'] and status['appliedSuccessfully']:
        print('Verified: database TLS enforcement enabled for '+args.environment)
        break
    time.sleep(5)
else:
    raise SystemExit('Enforcement requested but application is not yet confirmed; re-run to reconcile')
