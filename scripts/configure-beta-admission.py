#!/usr/bin/env python3
"""Staging only. Verify migration 091, enable its invitation hook, then lift the global signup block.

Dry-run unless --apply. No provider credentials, redirect changes or invitations/emails.
Any failed live verification restores the global block. Never print service responses or credentials.
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import time
import urllib.error
import urllib.request
import uuid

ROOT = Path(__file__).resolve().parents[1]
PROJECT = 'coxhjvqpflgxkleydati'
HOOK = 'pg-functions://postgres/public/hook_beta_before_user_created'


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        raise RuntimeError('redirect_refused')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--apply', action='store_true')
    args = parser.parse_args()
    token = subprocess.run(['security', 'find-generic-password', '-s', 'Supabase CLI', '-w'],
                           capture_output=True, text=True, check=True).stdout.strip()
    opener = urllib.request.build_opener(NoRedirect())
    def request(url, credential, body=None, method=None, anon=False):
        headers = {'Content-Type': 'application/json', 'apikey' if anon else 'Authorization': credential if anon else 'Bearer '+credential}
        req = urllib.request.Request(url, data=None if body is None else json.dumps(body).encode(),
                                     method=method, headers=headers)
        try:
            with opener.open(req, timeout=30) as response: status, raw = response.status, response.read(262145)
        except urllib.error.HTTPError as error: status, raw = error.code, error.read(262145)
        if len(raw) > 262144: raise RuntimeError('response_limit')
        return status, json.loads(raw)
    base = 'https://api.supabase.com/v1/projects/'+PROJECT
    def management(path, body=None, method=None):
        status, data = request(base+path, token, body, method)
        if status not in (200, 201): raise RuntimeError('management_http_'+str(status))
        return data
    remote = management('')
    if remote.get('name') != 'science-reader-staging' or remote.get('organization_id') != 'mhiweqpcwyqtyorgqhla':
        raise RuntimeError('project_identity_mismatch')
    source = ROOT/'supabase/migrations/202610190091_durable_beta_admission.sql'
    rows = management('/database/query', {'read_only': True, 'query':
        "select sha256 from science_reader_migrations.versions where version='202610190091'"})
    if rows != [{'sha256': hashlib.sha256(source.read_bytes()).hexdigest()}]: raise RuntimeError('migration_not_verified')
    # Managed postgres cannot SET ROLE to the Auth service role. Check its ACL explicitly;
    # the subsequent public signup probe exercises execution by the actual Auth service.
    denied = management('/database/query', {'read_only': False, 'query':
        "select public.hook_beta_before_user_created('{}') as result, "
        "has_function_privilege('supabase_auth_admin','public.hook_beta_before_user_created(jsonb)','execute') as executable"})
    if denied != [{'result': {'error': {'http_code': 403, 'message': 'beta_invitation_required'}}, 'executable': True}]:
        raise RuntimeError('hook_role_or_denial_invalid')
    auth = management('/config/auth')
    if auth.get('hook_before_user_created_uri') not in (None, '', HOOK): raise RuntimeError('different_hook_requires_review')
    if auth.get('mailer_autoconfirm') is not False or auth.get('external_anonymous_users_enabled') is True:
        raise RuntimeError('unverified_signup_configuration')
    if not args.apply:
        print(json.dumps({'mode': 'dry-run', 'migration_verified': True, 'hook_denial_verified': True,
                          'hook': HOOK, 'public_signup': False})); return
    try:
        management('/config/auth', {'hook_before_user_created_enabled': True, 'hook_before_user_created_uri': HOOK}, 'PATCH')
        enabled = management('/config/auth')
        if enabled.get('hook_before_user_created_enabled') is not True or enabled.get('hook_before_user_created_uri') != HOOK:
            raise RuntimeError('hook_readback_failed')
        management('/config/auth', {'disable_signup': False}, 'PATCH')
        final = management('/config/auth')
        if final.get('disable_signup') is not False or final.get('hook_before_user_created_enabled') is not True or final.get('hook_before_user_created_uri') != HOOK:
            raise RuntimeError('admission_readback_failed')
        env = dict(line.split('=', 1) for line in (ROOT/'.env.staging').read_text().splitlines() if '=' in line and not line.startswith('#'))
        if env['SUPABASE_PROJECT_REF'] != PROJECT or env['SUPABASE_URL'] != 'https://'+PROJECT+'.supabase.co':
            raise RuntimeError('environment_mismatch')
        probe = {'email': 'uninvited-'+uuid.uuid4().hex+'@example.invalid', 'password': uuid.uuid4().hex}
        # Management readback precedes propagation to Auth instances. Only the still-closed
        # signup policy may be retried; any other unexpected result immediately closes access.
        deadline = time.monotonic()+90
        while True:
            status, body = request(env['SUPABASE_URL']+'/auth/v1/signup', env['SUPABASE_ANON_KEY'], probe, anon=True)
            if status == 422 and body.get('error_code', body.get('code')) == 'signup_disabled' and time.monotonic() < deadline:
                time.sleep(5); continue
            break
        if status != 403 or body.get('msg', body.get('message')) != 'beta_invitation_required':
            code = body.get('error_code', body.get('code', 'unknown'))
            safe = code if isinstance(code, str) and code.replace('_', '').isalnum() and len(code) < 100 else 'unknown'
            raise RuntimeError('unknown_signup_not_denied_by_hook_'+str(status)+'_'+safe)
        print(json.dumps({'mode': 'applied', 'migration_verified': True, 'hook': HOOK,
                          'unknown_signup_status': status, 'public_signup': False, 'email_confirmation': True}))
    except BaseException:
        management('/config/auth', {'disable_signup': True}, 'PATCH')
        if management('/config/auth').get('disable_signup') is not True: raise RuntimeError('rollback_unverified')
        raise


if __name__ == '__main__':
    try: main()
    except Exception as error:
        raise SystemExit(str(error) if isinstance(error, RuntimeError) else type(error).__name__)
