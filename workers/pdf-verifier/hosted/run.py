#!/usr/bin/env python3
"""Operate one reviewed staging PDF compatibility probe; never grant admission.

This script performs remote mutations only when explicitly invoked. The default
test suite imports its helpers with fake transports. Credentials remain in
memory; the recovery journal contains only synthetic identities and hashes.

Management contracts: https://supabase.com/docs/reference/api/v1-get-a-function
and https://supabase.com/docs/reference/api/v1-delete-a-function .
"""
import argparse
import hashlib
import http.client
import importlib.util
import json
import math
import os
from pathlib import Path
import re
import secrets
import ssl
import subprocess
import tempfile
import time
import uuid

ROOT = Path(__file__).resolve().parents[3]
PROJECT = 'coxhjvqpflgxkleydati'
ORGANIZATION = 'mhiweqpcwyqtyorgqhla'
HOST = PROJECT + '.supabase.co'
MANAGEMENT = 'api.supabase.com'
MARKER = 'pdf-verifier-probe'
MAX_REQUESTS = 40
FAILURE_STAGES = {'initialization', 'fixture_decode', 'fixture_hash', 'verification', 'result_check'}
FAILURE_CODES = {'invalid_profile', 'verifier_build_mismatch', 'verifier_abi_mismatch', 'invalid_verifier_memory',
                 'invalid_verifier_import', 'invalid_verifier_memory_export', 'one_verification_at_a_time',
                 'probe_fixture_mismatch', 'probe_result_mismatch', 'unknown'}
ERROR_CLASSES = {'Error', 'TypeError', 'RangeError', 'SyntaxError', 'ReferenceError', 'URIError', 'EvalError',
                 'AggregateError', 'DOMException', 'WebAssembly.CompileError', 'WebAssembly.LinkError',
                 'WebAssembly.RuntimeError', 'non_error'}
OUTCOMES = {'verified', 'malformed', 'encrypted', 'unsupported', 'parser_resource_limit', 'resource_limit',
            'internal_error', 'input_limit', 'page_limit', 'binding_mismatch'}
spec = importlib.util.spec_from_file_location('pdf_probe_package', Path(__file__).with_name('package.py'))
package = importlib.util.module_from_spec(spec)
spec.loader.exec_module(package)


class ProbeError(RuntimeError):
    """Only fixed local codes are printed or recorded, never remote content."""


def require(value, code):
    if not value:
        raise ProbeError(code)


def identifier(value):
    require(isinstance(value, str), 'invalid_identity')
    try:
        parsed = str(uuid.UUID(value))
    except ValueError:
        raise ProbeError('invalid_identity') from None
    require(parsed == value and value != str(uuid.UUID(int=0)), 'invalid_identity')
    return value


def digest(value):
    require(isinstance(value, str) and re.fullmatch('[0-9a-f]{64}', value), 'invalid_digest')
    return value


def finite(value, minimum=0, maximum=2 ** 53 - 1):
    require(type(value) in (int, float) and math.isfinite(value) and minimum <= value <= maximum, 'invalid_measurement')
    return value


def json_bytes(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':'), allow_nan=False).encode()


def read_json(path, limit=262144):
    with path.open('rb') as stream:
        raw = stream.read(limit + 1)
    require(len(raw) <= limit, 'local_json_limit')
    try:
        return json.loads(raw)
    except (ValueError, UnicodeError):
        raise ProbeError('invalid_local_json') from None


def save_json(path, value):
    """Atomic durable journal/evidence checkpoint before an uncertain mutation."""
    path.parent.mkdir(parents=True, exist_ok=True)
    require(not path.is_symlink(), 'unsafe_local_path')
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(dir=path.parent, prefix='.' + path.name, delete=False) as stream:
            temporary = Path(stream.name)
            stream.write(json_bytes(value))
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
        temporary = None
        descriptor = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(descriptor)
        finally:
            os.close(descriptor)
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


class JSONTransport:
    """Exact-host HTTPS, no redirects/retries, actual-byte and wall bounds."""
    def __init__(self, connect=None, clock=time.monotonic):
        self.connect = connect or (lambda host, timeout: http.client.HTTPSConnection(
            host, timeout=timeout, context=ssl.create_default_context()))
        self.clock = clock

    def request(self, host, path, method='GET', body=None, headers=None, expected=(200,), limit=65536, timeout=45):
        require(host in (MANAGEMENT, HOST) and isinstance(path, str) and path.startswith('/')
                and not path.startswith('//') and not any(c in path for c in ('\r', '\n', '#', '..')), 'invalid_remote_path')
        require(method in ('GET', 'POST', 'DELETE') and 0 < limit <= 262144 and 0 < timeout <= 60, 'invalid_transport_bounds')
        raw = None if body is None else json_bytes(body)
        require(raw is None or len(raw) <= 16384, 'request_limit')
        request_headers = {'Accept': 'application/json', 'Accept-Encoding': 'identity', **(headers or {})}
        if raw is not None:
            request_headers['Content-Type'] = 'application/json'
        deadline = self.clock() + timeout
        connection = None
        socket_owner = None
        response = None

        def remaining():
            value = deadline - self.clock()
            require(value > 0, 'transport_timeout')
            owner = connection.sock or socket_owner
            if owner is not None and owner.fileno() >= 0:
                owner.settimeout(value)
            return value

        try:
            connection = self.connect(host, timeout)
            connection.request(method, path, body=raw, headers=request_headers)
            # HTTPResponse may detach a Connection: close socket from its
            # connection. Retain that same owner to tighten every read's
            # timeout to the remaining total allowance, including body reads.
            socket_owner = connection.sock
            remaining()
            response = connection.getresponse()
            status = response.status
            require(not 300 <= status < 400, 'redirect_refused')
            encoding = response.getheader('Content-Encoding')
            require(encoding is None or encoding.strip().lower() == 'identity', 'response_encoding')
            declared = response.getheader('Content-Length')
            if declared is not None:
                require(declared.isdigit() and int(declared) <= limit, 'response_limit')
            data = bytearray()
            while True:
                remaining()
                part = response.read1(min(16384, limit + 1 - len(data)))
                if not part:
                    break
                data.extend(part)
                require(len(data) <= limit, 'response_limit')
            remaining()
            require(declared is None or len(data) == int(declared), 'response_incomplete')
            require(status in expected, 'http_' + str(status))
            try:
                value = json.loads(data.decode('utf-8')) if data else None
            except (ValueError, UnicodeError):
                raise ProbeError('invalid_remote_json') from None
            # Keep only bounded, noncredential runtime request identifiers.
            observed = {}
            for name in ('sb-request-id', 'x-request-id', 'x-deno-execution-id'):
                value_header = response.getheader(name)
                if value_header and re.fullmatch('[A-Za-z0-9_-]{1,160}', value_header):
                    observed[name] = value_header
            return status, value, observed
        except ProbeError:
            raise
        except Exception:
            raise ProbeError('transport_uncertain') from None
        finally:
            # A close-delimited HTTPResponse can own the detached socket;
            # closing HTTPConnection alone does not close that response file.
            if response is not None:
                try:
                    response.close()
                except Exception:
                    pass
            if connection is not None:
                try:
                    connection.close()
                except Exception:
                    pass


class API:
    def __init__(self, transport, management, anon, service):
        self.transport, self.management, self.anon, self.service = transport, management, anon, service

    def management_request(self, suffix='', method='GET', body=None, expected=(200,), limit=65536):
        return self.transport.request(MANAGEMENT, '/v1/projects/' + PROJECT + suffix, method, body,
                                      {'Authorization': 'Bearer ' + self.management}, expected, limit)

    def auth(self, path, method='GET', body=None, admin=False, token=None, expected=(200,)):
        require(path in ('/admin/users', '/token?grant_type=password', '/user')
                or re.fullmatch('/admin/users/[0-9a-f-]{36}', path), 'invalid_auth_path')
        key = self.service if admin else self.anon
        headers = {'apikey': key}
        if admin or token:
            headers['Authorization'] = 'Bearer ' + (key if admin else token)
        return self.transport.request(HOST, '/auth/v1' + path, method, body, headers, expected)

    def functions(self):
        _, rows, _ = self.management_request('/functions', limit=262144)
        require(isinstance(rows, list) and len(rows) <= 2000, 'invalid_function_list')
        ids, slugs = set(), set()
        for row in rows:
            require(isinstance(row, dict) and isinstance(row.get('slug'), str), 'invalid_function_list')
            key = identifier(row.get('id'))
            require(key not in ids and row['slug'] not in slugs, 'invalid_function_list')
            ids.add(key)
            slugs.add(row['slug'])
        return rows

    def function(self, slug):
        matches = [row for row in self.functions() if row['slug'] == slug]
        require(len(matches) <= 1, 'invalid_function_list')
        if not matches:
            return None
        _, row, _ = self.management_request('/functions/' + slug)
        require(isinstance(row, dict) and row.get('id') == matches[0]['id'], 'function_identity_changed')
        return row

    def query(self, query, read_only=False):
        return self.management_request('/database/query', 'POST', {'query': query, 'read_only': read_only}, expected=(200, 201))[1]


def check_project(manifest, env, remote):
    require(manifest.get('organization', {}).get('slug') == ORGANIZATION
            and manifest.get('projects', {}).get('staging', {}).get('id') == PROJECT, 'local_project_mismatch')
    require(env.get('SUPABASE_PROJECT_REF') == PROJECT and env.get('SUPABASE_URL', '').rstrip('/') == 'https://' + HOST,
            'staging_environment_mismatch')
    require(isinstance(remote, dict) and remote.get('id') == PROJECT and remote.get('organization_id') == ORGANIZATION
            and remote.get('name') == 'science-reader-staging', 'remote_project_mismatch')


def user_matches(user, journal):
    require(isinstance(user, dict) and user.get('id') == journal['user_id']
            and user.get('email') == 'pdf-probe-' + journal['run_id'] + '@science-reader.invalid', 'synthetic_user_mismatch')
    metadata = user.get('app_metadata')
    require(isinstance(metadata, dict) and metadata.get('science_reader_check') == MARKER
            and metadata.get('check_run_id') == journal['run_id']
            and metadata.get('source_manifest_sha256') == journal['source_manifest_sha256'], 'synthetic_user_marker_mismatch')


def function_identity(row, journal):
    require(isinstance(row, dict) and row.get('slug') == journal['function_slug']
            and row.get('name') == journal['function_slug'] and row.get('status') in ('ACTIVE', 'THROTTLED')
            and type(row.get('version')) is int and row['version'] == 1 and row.get('verify_jwt') is False,
            'function_identity_mismatch')
    require(type(row.get('created_at')) is int and type(row.get('updated_at')) is int
            and journal['created_at'] - 5000 <= row['created_at'] <= journal['expires_at']
            and row['created_at'] <= row['updated_at'] <= journal['expires_at'], 'function_time_mismatch')
    bundle = row.get('ezbr_sha256')
    if bundle is not None:
        digest(bundle)
    return {'id': identifier(row.get('id')), 'slug': row['slug'], 'name': row['name'], 'version': row['version'],
            'created_at': row['created_at'], 'updated_at': row['updated_at'], 'ezbr_sha256': bundle, 'verify_jwt': False}


def cleanup_account_sql(journal):
    """Auth's trigger creates a pristine account; do not disable its guards."""
    user = identifier(journal['user_id'])
    run = identifier(journal['run_id'])
    source = digest(journal['source_manifest_sha256'])
    return f"""do $cleanup$
    declare c record; present boolean;
    begin
      perform 1 from auth.users where id='{user}' for update;
      if not found or not exists(select 1 from auth.users where id='{user}'
        and email='pdf-probe-{run}@science-reader.invalid'
        and raw_app_meta_data->>'science_reader_check'='pdf-verifier-probe'
        and raw_app_meta_data->>'check_run_id'='{run}'
        and raw_app_meta_data->>'source_manifest_sha256'='{source}')
        then raise exception 'probe_auth_marker_mismatch'; end if;
      perform 1 from app_private.accounts where id='{user}' for update;
      if exists(select 1 from app_private.accounts where id='{user}'
        and (auth_user_id is distinct from '{user}'::uuid or closed_at is not null))
        then raise exception 'probe_account_mapping_mismatch'; end if;
      if exists(select 1 from app_private.library_sync_state where account_id='{user}'
        and (last_seq<>0 or retained_after<>0 or v2_writes_started))
        then raise exception 'probe_account_not_pristine'; end if;
      -- Refuse any private, financial, library, support or ownership state.
      -- The only automatic child permitted is the zeroed library cursor.
      for c in select table_name,column_name from information_schema.columns
        where table_schema='app_private' and udt_name='uuid'
        and column_name in ('account_id','owner_id','author_id','actor_id','funding_account_id','scope_id')
        and table_name<>'library_sync_state'
      loop
        execute format('select exists(select 1 from app_private.%I where %I=$1)',c.table_name,c.column_name)
          into present using '{user}'::uuid;
        if present then raise exception 'probe_account_not_pristine'; end if;
      end loop;
      delete from app_private.accounts where id='{user}' and auth_user_id='{user}';
      if exists(select 1 from app_private.accounts where id='{user}')
        or exists(select 1 from app_private.library_sync_state where account_id='{user}')
        then raise exception 'probe_account_cleanup_incomplete'; end if;
    end $cleanup$;"""


def account_absence_sql(user):
    user = identifier(user)
    return f"select exists(select 1 from app_private.accounts where id='{user}') or exists(select 1 from app_private.library_sync_state where account_id='{user}') as present"


def validate_journal(value, run_id):
    require(isinstance(value, dict) and value.get('format') == 1 and value.get('project') == PROJECT
            and value.get('organization') == ORGANIZATION and value.get('run_id') == identifier(run_id), 'invalid_journal')
    identifier(value.get('user_id'))
    digest(value.get('source_manifest_sha256'))
    require(value.get('function_slug') == MARKER + '-' + run_id[:8]
            and type(value.get('created_at')) is int and type(value.get('expires_at')) is int
            and value['expires_at'] - value['created_at'] == 1200000, 'invalid_journal')
    for key in ('auth_attempted', 'auth_confirmed', 'deploy_attempted', 'deploy_confirmed', 'auth_absent', 'function_absent', 'cleanup_complete'):
        require(type(value.get(key)) is bool, 'invalid_journal')
    require(value['auth_confirmed'] <= value['auth_attempted'] and value['deploy_confirmed'] <= value['deploy_attempted'], 'invalid_journal')
    if value.get('function_identity') is not None:
        pinned = value['function_identity']
        require(function_identity({**pinned, 'status': 'ACTIVE'}, value) == pinned and value['deploy_confirmed'], 'invalid_journal')
    return value


def cleanup(api, journal, path):
    """Clean independent resources even if one identity cannot be established."""
    failures = []
    journal.update({'phase': 'cleaning', 'auth_absent': False, 'function_absent': False, 'cleanup_complete': False})
    save_json(path, journal)
    try:
        current = api.function(journal['function_slug'])
        if current is None:
            require(not journal['deploy_attempted'] or journal['deploy_confirmed'], 'deployment_outcome_unproven')
        else:
            require(journal['deploy_confirmed'] and journal['function_identity'] is not None, 'deployment_identity_unproven')
            observed = function_identity(current, journal)
            require(observed == journal['function_identity'], 'function_identity_changed')
            # Identity is pinned durably before DELETE. The API has no CAS
            # delete: a changed name/id/version/hash stops this operator.
            try:
                api.management_request('/functions/' + journal['function_slug'], 'DELETE', expected=(200,))
            except ProbeError:
                pass  # A lost DELETE ack gets one status read, never a retry.
            require(api.function(journal['function_slug']) is None, 'function_cleanup_unconfirmed')
        journal['function_absent'] = True
        save_json(path, journal)
    except ProbeError as error:
        failures.append(str(error))
    try:
        status, user, _ = api.auth('/admin/users/' + journal['user_id'], admin=True, expected=(200, 404))
        if status == 200:
            require(journal['auth_attempted'], 'unowned_auth_identity')
            user_matches(user, journal)
            journal['auth_confirmed'] = True  # Reconcile a lost create acknowledgment.
            save_json(path, journal)
            # The Auth create trigger inserts accounts; no bootstrap API is
            # called. Only its pristine synthetic row may be removed here.
            api.query(cleanup_account_sql(journal))
            try:
                api.auth('/admin/users/' + journal['user_id'], 'DELETE', admin=True, expected=(200, 204))
            except ProbeError:
                pass
            api.auth('/admin/users/' + journal['user_id'], admin=True, expected=(404,))
        else:
            require(not journal['auth_attempted'] or journal['auth_confirmed'], 'auth_creation_outcome_unproven')
        require(api.query(account_absence_sql(journal['user_id']), read_only=True) == [{'present': False}], 'account_cleanup_unconfirmed')
        journal['auth_absent'] = True
        save_json(path, journal)
    except ProbeError as error:
        failures.append(str(error))
    journal['cleanup_complete'] = not failures and journal['function_absent'] and journal['auth_absent']
    journal['phase'] = 'cleaned' if journal['cleanup_complete'] else 'cleanup_required'
    save_json(path, journal)
    return failures


def checked_package(built, run_id, user_id):
    work = ROOT / '.artifacts/pdf-verifier/hosted' / run_id
    require(built.get('directory') == str(work.relative_to(ROOT)) and built.get('function') == MARKER + '-' + run_id[:8], 'package_identity_mismatch')
    manifest_path = work / 'source-manifest.json'
    require(hashlib.sha256(manifest_path.read_bytes()).hexdigest() == digest(built.get('source_manifest_sha256')), 'package_manifest_mismatch')
    manifest = read_json(manifest_path)
    config = manifest.get('config', {})
    require(config == built.get('config') and config.get('project') == PROJECT and config.get('runID') == run_id
            and config.get('userID') == user_id and config.get('buildSHA256') == package.BUILD_SHA256
            and config.get('expiresAt', 0) - config.get('createdAt', 0) == 1200000
            and manifest.get('build_sha256') == package.BUILD_SHA256
            and manifest.get('fixture_manifest_sha256') == package.FIXTURE_MANIFEST_SHA256, 'package_config_mismatch')
    files = manifest.get('source_files')
    require(isinstance(files, dict) and set(files) == {'index.ts', 'hosted/handler.ts', 'runtime.ts', 'wasm.ts', 'verifier.mjs', 'assets.ts'}, 'package_files_mismatch')
    total = 0
    for name, expected in files.items():
        raw = (work / 'supabase/functions' / built['function'] / name).read_bytes()
        total += len(raw)
        require(hashlib.sha256(raw).hexdigest() == digest(expected), 'package_source_mismatch')
    require(total == manifest.get('source_bytes') == built.get('source_bytes') and total <= 3000000, 'package_size_mismatch')
    return work, manifest


def deploy_cli(work, slug, management):
    # No main project config, --prune, secrets command, debug output, or token
    # argument. Capture CLI text in memory and never persist/echo its contents.
    env = {key: value for key, value in os.environ.items() if key in ('PATH', 'HOME', 'TMPDIR', 'LANG', 'LC_ALL', 'SSL_CERT_FILE', 'SSL_CERT_DIR')}
    env['SUPABASE_ACCESS_TOKEN'] = management
    command = [str(ROOT / 'node_modules/.bin/supabase'), 'functions', 'deploy', slug,
               '--project-ref', PROJECT, '--use-api', '--workdir', str(work), '--jobs', '1', '--log-level', 'none']
    try:
        completed = subprocess.run(command, cwd=work, env=env, stdin=subprocess.DEVNULL,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=180, check=False)
        require(completed.returncode == 0, 'deployment_uncertain')
    except ProbeError:
        raise
    except Exception:
        raise ProbeError('deployment_uncertain') from None


def execution_context(value, name, journal, ordinals, failed=False):
    require(isinstance(value, dict) and value.get('run_id') == journal['run_id'] and value.get('fixture') == name
            and value.get('build_sha256') == package.BUILD_SHA256 and value.get('hosted_admitted') is False
            and value.get('cpu_ms') is None and value.get('peak_memory_bytes') is None, 'invalid_probe_result')
    isolate = identifier(value.get('isolate_id'))
    ordinal = value.get('ordinal')
    require(type(ordinal) is int and 1 <= ordinal <= MAX_REQUESTS and ordinal == ordinals.get(isolate, 0) + 1
            and type(value.get('cold')) is bool and value['cold'] == (isolate not in ordinals), 'invalid_probe_ordinal')
    runtime = value.get('runtime')
    require(isinstance(runtime, dict) and all(isinstance(runtime.get(key), str) and 0 < len(runtime[key]) <= 160
            for key in ('deno', 'v8', 'typescript')), 'invalid_runtime_identity')
    execution = value.get('execution_id')
    if execution is not None:
        identifier(execution)
    deployment = value.get('deployment_id')
    require(deployment is None or deployment == PROJECT + '_' + journal['function_identity']['id'] + '_1', 'invalid_deployment_identity')
    initialization = value.get('initialization_wall_ms')
    if initialization is not None or not failed:
        initialization = finite(initialization)
    return {'run_id': journal['run_id'], 'fixture': name, 'execution_id': execution, 'deployment_id': deployment,
            'isolate_id': isolate, 'ordinal': ordinal, 'runtime': {key: runtime[key] for key in ('deno', 'v8', 'typescript')},
            'cold': value['cold'], 'initialization_wall_ms': initialization,
            'cpu_ms': None, 'peak_memory_bytes': None, 'hosted_admitted': False}


def validate_failure(value, name, journal, ordinals):
    fields = {'error', 'run_id', 'fixture', 'execution_id', 'deployment_id', 'isolate_id', 'ordinal', 'build_sha256',
              'runtime', 'cold', 'initialization_wall_ms', 'diagnostic', 'cpu_ms', 'peak_memory_bytes', 'hosted_admitted'}
    require(isinstance(value, dict) and set(value) == fields and value['error'] == 'probe_failed', 'invalid_probe_diagnostic')
    context = execution_context(value, name, journal, ordinals, failed=True)
    diagnostic = value['diagnostic']
    require(isinstance(diagnostic, dict) and set(diagnostic) == {'stage', 'code', 'error_class', 'observed_outcome', 'observed_pages'},
            'invalid_probe_diagnostic')
    require(isinstance(diagnostic['stage'], str) and diagnostic['stage'] in FAILURE_STAGES
            and isinstance(diagnostic['code'], str) and diagnostic['code'] in FAILURE_CODES
            and isinstance(diagnostic['error_class'], str) and diagnostic['error_class'] in ERROR_CLASSES, 'invalid_probe_diagnostic')
    outcome, pages = diagnostic['observed_outcome'], diagnostic['observed_pages']
    require(outcome is None or isinstance(outcome, str) and outcome in OUTCOMES, 'invalid_probe_diagnostic')
    require(pages is None or type(pages) is int and 0 <= pages <= 2_147_483_647, 'invalid_probe_diagnostic')
    require(diagnostic['stage'] == 'result_check' or outcome is None and pages is None, 'invalid_probe_diagnostic')
    ordinals[context['isolate_id']] = context['ordinal']
    return {**context, 'error': 'probe_failed', 'diagnostic': {key: diagnostic[key] for key in
            ('stage', 'code', 'error_class', 'observed_outcome', 'observed_pages')}}


def validate_execution(value, fixture, journal, identity, ordinals):
    context = execution_context(value, fixture['name'], journal, ordinals)
    result = value.get('result')
    expected_pages = fixture.get('pages') if fixture['expected'] == 'verified' else None
    require(isinstance(result, dict) and result.get('outcome') == fixture['expected'] and result.get('pages') == expected_pages
            and result.get('bytes') == fixture['bytes'] and result.get('sha256') == fixture['sha256']
            and result.get('profileID') == identity['profile']['id'] and result.get('profileSHA256') == identity['profile_sha256']
            and result.get('wasmSHA256') == identity['wasm_sha256'], 'fixture_result_mismatch')
    memory = value.get('memory_snapshot')
    if memory is not None:
        require(isinstance(memory, dict), 'invalid_memory_snapshot')
        memory = {key: finite(memory.get(key)) for key in ('rss', 'heapTotal', 'heapUsed', 'external')}
    ordinals[context['isolate_id']] = context['ordinal']
    return {**context,
            'result': {key: result[key] for key in ('outcome', 'sha256', 'bytes', 'profileID', 'profileSHA256', 'wasmSHA256')},
            'pages': expected_pages, 'verification_wall_ms': finite(result.get('elapsedMS')), 'memory_snapshot': memory,
            'wasm_linear_memory_bytes_checked_by_runtime': identity['profile']['wasm_memory_bytes'],
            'cpu_ms': None, 'peak_memory_bytes': None, 'hosted_admitted': False}


def invoke_cases(api, journal, token, evidence, evidence_path, identity, fixtures):
    path = '/functions/v1/' + journal['function_slug']
    base = {'run_id': journal['run_id'], 'fixture': 'pages-1'}
    invalid_run = str(uuid.UUID(int=0))
    requests = [('no_auth', base, None, 401), ('bad_run', {**base, 'run_id': invalid_run}, token, 400),
                ('extra_input', {**base, 'url': 'forbidden-input'}, token, 400)]
    for name in package.CASES:
        requests.append((name, {'run_id': journal['run_id'], 'fixture': name}, token, 200))
        if name == 'object-stream-oom':
            requests.append(('pages-1-after-oom', base, token, 200))
    require(len(requests) <= MAX_REQUESTS, 'request_count_limit')
    ordinals = {}
    for label, body, bearer, expected in requests:
        require(int(time.time() * 1000) < journal['expires_at'], 'probe_expired')
        attempt = {'case': label, 'expected_status': expected, 'state': 'dispatching'}
        evidence['requests'].append(attempt)
        save_json(evidence_path, evidence)  # A crash retains the ambiguous attempt; it is never retried.
        headers = {'apikey': api.anon}
        if bearer is not None:
            headers['Authorization'] = 'Bearer ' + bearer
        started = time.monotonic()
        try:
            status, value, observed = api.transport.request(HOST, path, 'POST', body, headers, expected=(200, 400, 401, 403, 404, 410, 429, 500, 502, 503, 504), timeout=60)
            attempt.update({'http_status': status, 'client_wall_ms': (time.monotonic() - started) * 1000, 'response_ids': observed})
            if status == 500 and expected == 200:
                attempt['diagnostic'] = validate_failure(value, body['fixture'], journal, ordinals)
            require(status == expected, 'unexpected_probe_status')
            if expected == 200:
                attempt['measurement'] = validate_execution(value, fixtures[body['fixture']], journal, identity, ordinals)
            else:
                require(value == {'error': 'unauthorized' if expected == 401 else 'invalid_request'}, 'denial_response_mismatch')
            attempt['state'] = 'passed'
        except ProbeError as error:
            attempt.update({'state': 'failed_or_uncertain', 'error': str(error), 'client_wall_ms': (time.monotonic() - started) * 1000})
            save_json(evidence_path, evidence)
            raise
        save_json(evidence_path, evidence)


def run_probe(api, run_id, user_id, deploy=deploy_cli, builder=package.build):
    identifier(run_id)
    identifier(user_id)
    require(run_id != user_id, 'distinct_probe_identities_required')
    created = int(time.time() * 1000)
    built = builder(run_id, user_id, created)
    work, manifest = checked_package(built, run_id, user_id)
    path, evidence_path = work / 'cleanup-journal.json', work / 'evidence.json'
    journal = {'format': 1, 'project': PROJECT, 'organization': ORGANIZATION, 'run_id': run_id, 'user_id': user_id,
               'function_slug': built['function'], 'source_manifest_sha256': built['source_manifest_sha256'],
               'created_at': created, 'expires_at': created + 1200000, 'function_identity': None,
               'auth_attempted': False, 'auth_confirmed': False, 'deploy_attempted': False, 'deploy_confirmed': False,
               'auth_absent': False, 'function_absent': False, 'cleanup_complete': False, 'phase': 'prepared'}
    # Preflight must not create a journal that falsely claims an existing user
    # or function as ours. No mutation has occurred if either identity exists.
    require(api.function(journal['function_slug']) is None, 'function_already_exists')
    api.auth('/admin/users/' + user_id, admin=True, expected=(404,))
    require(api.query(account_absence_sql(user_id), read_only=True) == [{'present': False}], 'account_already_exists')
    save_json(path, journal)
    evidence = {'scope': 'fixed-fixture hosted compatibility only', 'hosted_admitted': False,
                'source_manifest_sha256': built['source_manifest_sha256'], 'build_sha256': package.BUILD_SHA256,
                'fixture_manifest_sha256': package.FIXTURE_MANIFEST_SHA256, 'project': PROJECT, 'run_id': run_id,
                'requests': [], 'cleanup_verified': False, 'cpu_ms': None, 'peak_memory_bytes': None}
    save_json(evidence_path, evidence)
    failure = None
    try:
        password = secrets.token_urlsafe(48)
        email = 'pdf-probe-' + run_id + '@science-reader.invalid'
        journal.update({'auth_attempted': True, 'phase': 'auth_creating'})
        save_json(path, journal)
        _, user, _ = api.auth('/admin/users', 'POST', {'id': user_id, 'email': email, 'password': password, 'email_confirm': True,
            'app_metadata': {'science_reader_check': MARKER, 'check_run_id': run_id, 'source_manifest_sha256': built['source_manifest_sha256']}}, admin=True, expected=(200, 201))
        user_matches(user, journal)
        journal.update({'auth_confirmed': True, 'phase': 'auth_created'})
        save_json(path, journal)
        _, session, _ = api.auth('/token?grant_type=password', 'POST', {'email': email, 'password': password})
        password = None
        require(isinstance(session, dict), 'invalid_auth_session')
        user_matches(session.get('user'), journal)
        token = session.get('access_token')
        require(isinstance(token, str) and re.fullmatch('[A-Za-z0-9_.-]{20,4096}', token), 'invalid_auth_session')
        session = None
        _, current_user, _ = api.auth('/user', token=token)
        user_matches(current_user, journal)
        # Recheck absent immediately before this one deploy; no existing
        # function can be intentionally overwritten by the script.
        require(api.function(journal['function_slug']) is None, 'function_already_exists')
        checked_package(built, run_id, user_id)
        journal.update({'deploy_attempted': True, 'phase': 'deploying'})
        save_json(path, journal)
        deploy(work, journal['function_slug'], api.management)
        journal['deploy_confirmed'] = True
        save_json(path, journal)
        journal['function_identity'] = function_identity(api.function(journal['function_slug']), journal)
        journal['phase'] = 'deployed'
        save_json(path, journal)
        evidence['function'] = journal['function_identity']
        save_json(evidence_path, evidence)
        identity = json.loads(package.checked(package.ARTIFACTS / 'dist/identity.json', package.BUILD_SHA256))
        original = json.loads(package.checked(package.ARTIFACTS / 'fixtures/manifest.json', package.FIXTURE_MANIFEST_SHA256))
        fixtures = {fixture['name']: fixture for fixture in original if fixture['name'] in package.CASES}
        require(set(fixtures) == set(package.CASES), 'fixture_set_mismatch')
        invoke_cases(api, journal, token, evidence, evidence_path, identity, fixtures)
        token = None
    except ProbeError as error:
        failure = str(error)
    except Exception:
        failure = 'operator_failed'
    finally:
        failures = cleanup(api, journal, path)
        evidence['cleanup_verified'] = journal['cleanup_complete']
        evidence['cleanup_failures'] = failures
        evidence['failure'] = failure
        save_json(evidence_path, evidence)
    require(not failures, 'cleanup_required_journal_retained')
    require(failure is None, failure or 'probe_failed')
    return work


def load_credentials():
    # No dotenv evaluation, shell substitution, CLI arguments, or credential
    # output. Reject missing values before contacting either exact host.
    env = dict(line.split('=', 1) for line in (ROOT / '.env.staging').read_text().splitlines() if '=' in line and not line.startswith('#'))
    require(env.get('SUPABASE_PROJECT_REF') == PROJECT and env.get('SUPABASE_URL', '').rstrip('/') == 'https://' + HOST, 'staging_environment_mismatch')
    for key in ('SUPABASE_ANON_KEY', 'SUPABASE_SERVICE_ROLE_KEY'):
        require(isinstance(env.get(key), str) and env[key] and '\n' not in env[key] and '\r' not in env[key], 'missing_staging_credential')
    try:
        process = subprocess.run(['security', 'find-generic-password', '-s', 'Supabase CLI', '-w'],
                                 capture_output=True, text=True, timeout=15, check=False)
        require(process.returncode == 0 and process.stdout.strip(), 'keychain_credential_unavailable')
        pat = process.stdout.strip()
        require('\n' not in pat and '\r' not in pat, 'keychain_credential_unavailable')
    except ProbeError:
        raise
    except Exception:
        raise ProbeError('keychain_credential_unavailable') from None
    return env, pat


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--project-ref', required=True, choices=[PROJECT])
    parser.add_argument('--run-id', required=True)
    parser.add_argument('--user-id')
    parser.add_argument('--cleanup-only', action='store_true')
    args = parser.parse_args()
    run_id = identifier(args.run_id)
    require(args.cleanup_only or args.user_id is not None, 'user_id_required')
    env, pat = load_credentials()
    api = API(JSONTransport(), pat, env['SUPABASE_ANON_KEY'], env['SUPABASE_SERVICE_ROLE_KEY'])
    _, remote, _ = api.management_request()
    check_project(read_json(ROOT / 'infra/account.json'), env, remote)
    if args.cleanup_only:
        path = ROOT / '.artifacts/pdf-verifier/hosted' / run_id / 'cleanup-journal.json'
        journal = validate_journal(read_json(path, 16384), run_id)
        require(not cleanup(api, journal, path), 'cleanup_required_journal_retained')
        print('Verified the tagged synthetic Auth/account and exact probe function are absent.')
    else:
        run_probe(api, run_id, identifier(args.user_id))
        print('Fixed-fixture compatibility probe completed; cleanup verified. No hosted admission was granted.')


if __name__ == '__main__':
    try:
        main()
    except ProbeError as error:
        raise SystemExit('Probe stopped: ' + str(error)) from None
    except Exception:
        raise SystemExit('Probe stopped: operator_failed; inspect the no-secret journal before further action.') from None
