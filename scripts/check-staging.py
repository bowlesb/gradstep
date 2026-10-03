#!/usr/bin/env python3
"""Live Auth/PostgREST isolation test with disposable synthetic accounts.

No email is sent, no provider is invoked, and secrets/results containing tokens
are never printed. Cleanup only touches the UUIDs created by this invocation.
"""
import json
from pathlib import Path
import secrets
import subprocess
import urllib.request
import urllib.error
import uuid

ROOT = Path(__file__).resolve().parents[1]
env = dict(line.split('=', 1) for line in (ROOT / '.env.staging').read_text().splitlines() if '=' in line)
assert env['SUPABASE_PROJECT_REF'] == 'coxhjvqpflgxkleydati'
base = env['SUPABASE_URL']
management = subprocess.run(['security','find-generic-password','-s','Supabase CLI','-w'],capture_output=True,text=True,check=True).stdout.strip()
created = []

def request(path, body=None, token=None, admin=False, method='POST', expected=200):
    key = env['SUPABASE_SERVICE_ROLE_KEY'] if admin else env['SUPABASE_ANON_KEY']
    headers = {'apikey':key,'Content-Type':'application/json'}
    if admin or token: headers['Authorization'] = 'Bearer '+(key if admin else token)
    req = urllib.request.Request(base+'/'+path, data=None if body is None else json.dumps(body).encode(), headers=headers, method=method)
    try:
        with urllib.request.urlopen(req,timeout=30) as result:
            status = result.status; raw = result.read()
    except urllib.error.HTTPError as error:
        status = error.code; raw = error.read()
    if status != expected:
        # Print only a coarse error code; never print auth responses or bodies.
        try: code = json.loads(raw).get('code','unknown')
        except (ValueError,AttributeError): code='unknown'
        raise AssertionError(f'{path.split("?")[0]}: HTTP {status}, expected {expected}; code={code}')
    return json.loads(raw) if raw else None

def rpc(name, data, token, expected=200):
    return request('rest/v1/rpc/'+name,data,token=token,expected=expected)

def admin_query(sql):
    req=urllib.request.Request('https://api.supabase.com/v1/projects/'+env['SUPABASE_PROJECT_REF']+'/database/query',
        data=json.dumps({'query':sql}).encode(),headers={'Authorization':'Bearer '+management,'Content-Type':'application/json'})
    with urllib.request.urlopen(req,timeout=30) as response: return json.load(response)

try:
    sessions=[]
    for index in range(2):
        email='science-reader-test-'+uuid.uuid4().hex+'@example.invalid'; password=secrets.token_urlsafe(36)
        user=request('auth/v1/admin/users',{'email':email,'password':password,'email_confirm':True},admin=True)
        created.append(str(uuid.UUID(user['id'])))
        session=request('auth/v1/token?grant_type=password',{'email':email,'password':password})
        sessions.append(session['access_token'])
    a,b=sessions
    assert rpc('v1_account_context',{},a)['account_id']==created[0]
    assert rpc('v1_account_context',{},b)['account_id']==created[1]
    print('PASS hosted Auth and account mapping')
    device=str(uuid.uuid4()); token='\\x'+secrets.token_hex(32)
    params={'p_device_id':device,'p_public_key':'\\x'+secrets.token_hex(32),'p_recovery_package':'\\x'+secrets.token_hex(60),
            'p_management_token':token,'p_device_envelope':'\\x'+secrets.token_hex(92),'p_challenge':'\\x'+secrets.token_hex(32)}
    assert rpc('v1_bootstrap_keys',params,a) is True
    assert rpc('v1_bootstrap_keys',params,a) is False
    event={'p_device_id':device,'p_id':str(uuid.uuid4()),'p_epoch':1,'p_format':1,'p_ciphertext':'\\x'+secrets.token_hex(60),'p_management_token':token}
    assert rpc('v1_append_event',event,a)==1
    assert rpc('v1_append_event',event,a)==1
    assert len(rpc('v1_pull_events',{'p_after':0},a))==1
    assert rpc('v1_pull_events',{'p_after':0},b)==[]
    assert rpc('v1_key_state',{'p_device_id':device},b) is None
    print('PASS hosted encrypted-envelope isolation and exact replay')
    report={'p_id':str(uuid.uuid4()),'p_title':'Synthetic staging check','p_note':'Test fixture; no user content.',
            'p_app_version':'test','p_build':'test','p_os_version':'test','p_screen':'test'}
    assert rpc('v1_create_report',report,a)==report['p_id']
    assert rpc('v1_reports',{},b)==[]
    rpc('v1_report_thread',{'p_report_id':report['p_id']},b,403)
    rpc('v1_admin_overview',{},a,403)
    print('PASS hosted report privacy and operator denial')
    request('rest/v1/rpc/v1_library',{},expected=401)
    rpc('worker_claim_job',{},a,403)
    print('PASS anonymous and customer worker privileges denied')
finally:
    if created:
        ids=','.join("'"+identifier+"'::uuid" for identifier in created)
        admin_query(f"""begin;
delete from app_private.support_status_events where report_id in (select id from app_private.support_reports where account_id in ({ids}));
delete from app_private.support_messages where report_id in (select id from app_private.support_reports where account_id in ({ids}));
delete from app_private.support_attachments where account_id in ({ids});
delete from app_private.support_reports where account_id in ({ids});
delete from app_private.key_transitions where account_id in ({ids});
delete from app_private.enrollment_requests where account_id in ({ids});
delete from app_private.device_envelopes where account_id in ({ids});
delete from app_private.sync_events where account_id in ({ids});
delete from app_private.devices where account_id in ({ids});
delete from app_private.keyrings where account_id in ({ids});
delete from app_private.accounts where id in ({ids});
commit;""")
        for identifier in created: request('auth/v1/admin/users/'+identifier,admin=True,method='DELETE')
        print('Synthetic accounts and fixture content removed')
