#!/usr/bin/env python3
"""Narrow staging-only 011 contract check. Run only after reviewed hosted apply.

Uses the same .env.staging / macOS Supabase CLI Keychain identity as the existing
check-staging.py. No arXiv, Storage, verifier, OCR or device call is made. Durable
acquisition/import fixtures execute inside a deliberately rolled-back PL/pgSQL
subtransaction, so even a query exception cannot leave an open transaction or
immutable test receipts. One tagged Auth user is deleted in finally.

Usage (not an instruction to deploy or enable workers):
  python3 scripts/check-acquisition-contract.py --project-ref coxhjvqpflgxkleydati
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import secrets
import subprocess
import urllib.error
import urllib.parse
import urllib.request
import uuid
from migration_ledger import source_ledger, verify_applied_prefix

ROOT = Path(__file__).resolve().parents[1]
PROJECT = 'coxhjvqpflgxkleydati'
MIGRATION = '202610030011'
CANDIDATE_SHA256 = '30c2db5b6d1211dac4ccbbd93b732fb747a6dddcb06ceefc9970ba3bc3a09f03'


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def http_error_308(self, req, fp, code, msg, headers):
        raise RuntimeError('Hosted check refused an HTTP redirect')

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        # Management and service credentials must never be forwarded, including
        # to another URL on the same host. Do not print the Location header.
        raise RuntimeError('Hosted check refused an HTTP redirect')


def verify_remote_ledger(rows, sources):
    if not isinstance(rows, list) or any(not isinstance(row, dict) or set(row) != {'version', 'sha256'}
                                       or not isinstance(row['version'], str) or not isinstance(row['sha256'], str) for row in rows):
        raise RuntimeError('Hosted migration ledger is malformed')
    applied = {row['version']: row['sha256'] for row in rows}
    if len(applied) != len(rows):
        raise RuntimeError('Hosted migration ledger contains duplicate versions')
    verify_applied_prefix(applied, sources)
    if applied.get(MIGRATION) != CANDIDATE_SHA256 or max(applied) != MIGRATION:
        raise RuntimeError('Reviewed migration 011 is not applied with its expected hash')


def check_fixture_user(user, account, run_id):
    if not isinstance(user, dict) or user.get('id') != account:
        raise RuntimeError('Synthetic Auth identity mismatch')
    metadata = user.get('app_metadata')
    if not isinstance(metadata, dict) or metadata.get('science_reader_check') != 'acquisition-011' or metadata.get('check_run_id') != run_id:
        raise RuntimeError('Synthetic cleanup identity guard refused deletion')


def cleanup_fixture_sql(account, run_id):
    account = str(uuid.UUID(account))
    run_id = str(uuid.UUID(run_id))
    return f"""do $cleanup$ begin
      -- Recheck the Auth marker in the same transaction as account deletion;
      -- a prior REST response is not sufficient authority for a changed user.
      perform 1 from auth.users where id='{account}' for update;
      if not found or not exists(select 1 from auth.users where id='{account}'
       and raw_app_meta_data->>'science_reader_check'='acquisition-011'
       and raw_app_meta_data->>'check_run_id'='{run_id}') then raise exception 'synthetic_auth_marker_mismatch'; end if;
      if exists(select 1 from app_private.accounts where id='{account}' and auth_user_id is distinct from '{account}'::uuid)
       then raise exception 'synthetic_account_mapping_mismatch'; end if;
      if exists(select 1 from app_private.library_commands where account_id='{account}')
       or exists(select 1 from app_private.import_requests where account_id='{account}')
       or exists(select 1 from app_private.library_items where account_id='{account}') then raise exception 'synthetic_durable_state_not_empty'; end if;
      delete from app_private.api_rate_windows where scope_id='{account}';
      delete from app_private.accounts where id='{account}' and auth_user_id='{account}';
      if exists(select 1 from app_private.accounts where id='{account}')
       or exists(select 1 from app_private.library_sync_state where account_id='{account}') then raise exception 'synthetic_account_cleanup_incomplete'; end if;
    end $cleanup$;"""


def rollback_fixture(account):
    """Returns SQL and only synthetic IDs; safe to exercise on a local test DB."""
    account = str(uuid.UUID(account))
    operation, job, atom, license_claim, cancel = [str(uuid.uuid4()) for _ in range(5)]
    sql = f"""do $fixture$
    declare first jsonb; current_value jsonb; request jsonb; token uuid;
    begin
      begin
        perform set_config('request.jwt.claim.sub','{account}',true);
        first:=public.v2_begin_import('{operation}','2403.40001',0,1);
        if first->'entry'->>'phase'<>'accepted' then raise exception 'fixture_import_not_accepted'; end if;
        perform public.worker_prepare_acquisition('{job}','2403.40001',1);
        if public.worker_prepare_acquisition('{job}','2403.40001',1)->>'replayed'<>'true' then raise exception 'fixture_prepare_replay_failed'; end if;
        perform public.worker_link_import_acquisition('{account}','{operation}',1,1,'{job}');
        if public.worker_claim_arxiv_stage('{job}','{atom}','staging')->>'action'<>'disabled' then raise exception 'fixture_disabled_claim_failed'; end if;
        -- Only this uncommitted subtransaction sees the fixture switch/permit.
        -- No HTTP operation is performed; these are synthetic closure facts.
        update app_private.acquisition_policy set metadata_enabled=true where singleton;
        request:=public.worker_claim_arxiv_stage('{job}','{atom}','staging'); token:=(request->>'token')::uuid;
        if request->>'granted'<>'true' then raise exception 'fixture_claim_failed'; end if;
        if public.worker_claim_arxiv_stage('{job}','{atom}','staging')->>'granted'<>'false' then raise exception 'fixture_claim_replay_granted'; end if;
        perform public.worker_finish_arxiv_request(token,100,0);
        perform public.worker_finish_lookup('{job}','{atom}',1,
          '{{"revision":1,"metadata":{{"title":"Synthetic staging acquisition check","authors":["Fixture"],"categories":["cs.LG"],"published_at":"2024-03-01","updated_at":"2024-03-02"}},"atom_published_at":"2024-03-01T09:00:00.000Z","atom_updated_at":"2024-03-02T10:00:00.000Z"}}');
        perform public.worker_project_import_acquisition('{account}','{operation}',1);
        if public.worker_acquisition_state('{job}')->'job'->>'atom_updated_at'<>'2024-03-02T10:00:00.000Z' then raise exception 'fixture_timestamp_pin_failed'; end if;
        update app_private.arxiv_network_gate set next_allowed_at='-infinity' where singleton;
        request:=public.worker_claim_arxiv_stage('{job}','{license_claim}','staging');
        if request->>'granted'<>'true' then raise exception 'fixture_license_permit_failed'; end if;
        perform public.worker_finish_arxiv_request((request->>'token')::uuid,100,0);
        perform public.worker_finish_lookup('{job}','{license_claim}',2,'{{"eligible":false,"reason":"license_not_supported"}}');
        current_value:=public.worker_project_import_acquisition('{account}','{operation}',1);
        if current_value->'entry'->>'phase'<>'source_only' then raise exception 'fixture_source_only_failed'; end if;
        if exists(select 1 from app_private.paper_asset_reservations where job_id='{job}')
          or exists(select 1 from app_private.metered_operations where account_id='{account}') then raise exception 'fixture_unexpected_paid_or_original_work'; end if;
        perform public.v2_cancel_import('{cancel}','{operation}',1);
        current_value:=public.v2_begin_import('{operation}','2403.40001',0,1);
        if current_value->'entry'->>'phase'<>'cancelled' then raise exception 'fixture_replay_restored_cancelled_import'; end if;
        raise exception '__acquisition_contract_rollback__';
      exception when others then
        if sqlerrm<>'__acquisition_contract_rollback__' then raise; end if;
      end;
      if exists(select 1 from app_private.import_requests where account_id='{account}')
       or exists(select 1 from app_private.library_commands where account_id='{account}')
       or exists(select 1 from app_private.acquisition_jobs where id='{job}')
       or exists(select 1 from app_private.acquisition_commands where id='{job}')
       or (select last_seq from app_private.library_sync_state where account_id='{account}')<>0
       then raise exception 'fixture_rollback_incomplete'; end if;
    end $fixture$;"""
    return sql


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--project-ref', required=True, choices=[PROJECT])
    args = parser.parse_args()
    candidate = ROOT / 'supabase/migrations/202610030011_acquisition.sql'
    if hashlib.sha256(candidate.read_bytes()).hexdigest() != CANDIDATE_SHA256:
        raise RuntimeError('Local candidate hash differs from the reviewed check contract')
    sources = source_ledger(ROOT / 'supabase/migrations')
    env = dict(line.split('=', 1) for line in (ROOT / '.env.staging').read_text().splitlines() if '=' in line)
    parsed = urllib.parse.urlparse(env['SUPABASE_URL'])
    if env['SUPABASE_PROJECT_REF'] != args.project_ref or parsed.scheme != 'https' or parsed.netloc != PROJECT + '.supabase.co' or parsed.path not in ('', '/') or parsed.params or parsed.query or parsed.fragment:
        raise RuntimeError('Staging identity mismatch')
    base = env['SUPABASE_URL'].rstrip('/')
    keychain = subprocess.run(['security', 'find-generic-password', '-s', 'Supabase CLI', '-w'], capture_output=True, text=True)
    if keychain.returncode or not keychain.stdout.strip():
        raise RuntimeError('Supabase CLI Keychain credential unavailable')
    management = keychain.stdout.strip()
    opener = urllib.request.build_opener(NoRedirect())

    def request(url, body=None, headers=None, method='POST', expected=(200,)):
        req = urllib.request.Request(url, data=None if body is None else json.dumps(body).encode(), headers=headers or {}, method=method)
        try:
            with opener.open(req, timeout=30) as response:
                status = response.status
                raw = response.read(65537)
        except urllib.error.HTTPError as error:
            status = error.code
            if 300 <= status < 400:
                raise RuntimeError('Hosted check refused an HTTP redirect') from None
            raw = error.read(65537)
        except (urllib.error.URLError, TimeoutError) as error:
            raise RuntimeError('Hosted request transport failed; no response body logged') from None
        if len(raw) > 65536:
            raise RuntimeError('Hosted response exceeded check limit')
        try:
            result = json.loads(raw) if raw else None
        except ValueError:
            raise RuntimeError('Hosted response was not JSON') from None
        if status not in expected:
            code = result.get('code', 'unknown') if isinstance(result, dict) else 'unknown'
            raise RuntimeError(f'Hosted check returned HTTP {status}; code={str(code)[:64]}')
        return status, result

    def api(path, body=None, token=None, admin=False, method='POST', expected=(200,)):
        key = env['SUPABASE_SERVICE_ROLE_KEY'] if admin else env['SUPABASE_ANON_KEY']
        headers = {'apikey': key, 'Content-Type': 'application/json'}
        if token or admin:
            headers['Authorization'] = 'Bearer ' + (key if admin else token)
        return request(base + '/' + path, body, headers, method, expected)

    def query(sql, read_only=False):
        return request('https://api.supabase.com/v1/projects/' + PROJECT + '/database/query', {'query': sql, 'read_only': read_only},
                       {'Authorization': 'Bearer ' + management, 'Content-Type': 'application/json'})[1]

    def cleanup(account, run_id):
        status, user = api('auth/v1/admin/users/' + account, admin=True, method='GET', expected=(200, 404))
        if status == 200:
            # Never delete an unrelated user, even after an unexpected UUID
            # response or retry. The per-run marker must match exactly.
            check_fixture_user(user, account, run_id)
            query(cleanup_fixture_sql(account, run_id))
            api('auth/v1/admin/users/' + account, admin=True, method='DELETE', expected=(200, 204, 404))
            api('auth/v1/admin/users/' + account, admin=True, method='GET', expected=(404,))
        else:
            remaining = query(f"select exists(select 1 from app_private.accounts where id='{account}'::uuid) as present", True)
            if remaining != [{'present': False}]:
                raise RuntimeError('Synthetic Auth user is absent but retained account state needs review')
        print('Removed this run’s tagged synthetic account; immutable receipt guards remained enabled')

    guard = f"""do $guard$ begin
      if not exists(select 1 from science_reader_migrations.versions where version='{MIGRATION}' and sha256='{CANDIDATE_SHA256}') then raise exception 'reviewed_migration_011_not_applied'; end if;
      if not exists(select 1 from app_private.acquisition_policy where singleton and not metadata_enabled and not original_enabled and not verification_enabled and active_verification_profile is null)
       or not exists(select 1 from app_private.paper_read_policy where singleton and not enabled)
       or exists(select 1 from app_private.paper_verification_profiles)
       or exists(select 1 from app_private.arxiv_network_gate where token is not null)
       then raise exception 'acquisition_not_pristine_disabled'; end if;
      if not exists(select 1 from pg_roles where rolname='science_reader_pdf_verifier' and not rolcanlogin and not rolbypassrls and not rolsuper)
       or has_function_privilege('service_role','public.worker_claim_original_verification(uuid,uuid)','execute')
       or has_function_privilege('service_role','public.worker_begin_arxiv_request(uuid,uuid,bigint,text)','execute')
       or has_function_privilege('service_role','public.worker_mark_original_uploading(uuid,uuid,bigint)','execute')
       or not has_function_privilege('service_role','public.worker_claim_arxiv_stage(uuid,uuid,text,uuid)','execute')
       or has_function_privilege('authenticated','public.worker_original_reservation(uuid)','execute')
       or has_function_privilege('anon','public.worker_original_reservation(uuid)','execute')
       or not has_function_privilege('science_reader_pdf_verifier','public.worker_claim_original_verification(uuid,uuid)','execute')
       or has_function_privilege('science_reader_pdf_verifier','public.worker_publish_original(uuid,uuid,bigint,uuid)','execute')
       then raise exception 'acquisition_grants_incorrect'; end if;
    end $guard$;"""
    verify_remote_ledger(query('select version,sha256 from science_reader_migrations.versions order by version', True), sources)
    journal = ROOT / '.artifacts/acquisition-hosted-cleanup.json'
    journal.parent.mkdir(parents=True, exist_ok=True)
    if journal.exists():
        pending = json.loads(journal.read_text())
        if set(pending) != {'project', 'account', 'run_id'} or pending['project'] != PROJECT:
            raise RuntimeError('Synthetic cleanup journal identity mismatch')
        cleanup(str(uuid.UUID(pending['account'])), str(uuid.UUID(pending['run_id'])))
        journal.unlink()
    query(guard)
    print('PASS hosted migration prefix hashes, disabled policies, empty profile and scoped verifier grants')
    account = str(uuid.uuid4())
    run_id = str(uuid.uuid4())
    created_attempted = False
    try:
        # A caller-chosen Auth UUID (supported by AdminUserAttributes) permits
        # cleanup even if creation succeeds but its HTTP acknowledgement is lost.
        email = 'science-reader-acquisition-' + uuid.uuid4().hex + '@example.invalid'
        password = secrets.token_urlsafe(36)
        # Persist only synthetic IDs before the uncertain external create. A
        # retry can finish exact tagged cleanup after a lost response/process.
        with os.fdopen(os.open(journal, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), 'w') as handle:
            json.dump({'project': PROJECT, 'account': account, 'run_id': run_id}, handle)
        created_attempted = True
        _, user = api('auth/v1/admin/users', {'id': account, 'email': email, 'password': password, 'email_confirm': True,
                    'app_metadata': {'science_reader_check': 'acquisition-011', 'check_run_id': run_id}}, admin=True)
        check_fixture_user(user, account, run_id)
        _, session = api('auth/v1/token?grant_type=password', {'email': email, 'password': password})
        if not isinstance(session, dict) or not isinstance(session.get('access_token'), str) or not session['access_token']:
            raise RuntimeError('Synthetic Auth session missing')
        check_fixture_user(session.get('user'), account, run_id)
        token = session['access_token']
        _, authenticated_user = api('auth/v1/user', token=token, method='GET')
        check_fixture_user(authenticated_user, account, run_id)
        _, context = api('rest/v1/rpc/v1_account_context', {}, token=token)
        if not isinstance(context, dict) or context.get('account_id') != account:
            raise RuntimeError('Synthetic session/account mapping mismatch')
        missing = str(uuid.uuid4())
        api('rest/v1/rpc/v2_original_descriptor', {'p_item_id': missing}, expected=(401, 403))
        _, denial = api('rest/v1/rpc/v2_original_descriptor', {'p_item_id': missing}, token=token, expected=(400,))
        if denial.get('message') != 'original_unavailable':
            raise RuntimeError('Descriptor denial did not use the expected safe outcome')
        api('rest/v1/rpc/worker_acquisition_state', {'p_job_id': missing}, token=token, expected=(403,))
        api('rest/v1/rpc/worker_claim_original_verification', {'p_reservation_id': missing, 'p_claim_id': str(uuid.uuid4())}, admin=True, expected=(403,))
        _, state = api('rest/v1/rpc/worker_acquisition_state', {'p_job_id': missing}, admin=True)
        if state != {'job': None, 'step': None}:
            raise RuntimeError('Service state check returned unexpected data')
        print('PASS real REST anonymous/customer/verifier isolation and safe unavailable descriptor')
        query(rollback_fixture(account))
        query(guard)
        print('PASS hosted bounded metadata/source-only/cancel/replay fixtures rolled back; no acquisition or command rows retained')
    finally:
        if created_attempted:
            cleanup(account, run_id)
            journal.unlink()


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        # Our errors contain only bounded status/codes; do not expose raw Auth,
        # SQL, environment, token, email, password, or HTTP-response objects.
        if isinstance(error, RuntimeError):
            raise SystemExit(str(error)) from None
        raise SystemExit('Acquisition hosted contract check failed; sensitive details suppressed') from None
