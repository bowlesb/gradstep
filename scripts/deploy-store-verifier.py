#!/usr/bin/env python3
"""Independent staging purchase-verifier operations. Nothing runs at import time.

All hosted commands are explicit. This tool never applies migrations, enables
purchase admission, schedules work, or touches the paper/AI worker. Private key
material stays in a protected ignored checkpoint directory or request memory.
"""
import argparse
import base64
import binascii
import copy
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import stat
import struct
import subprocess
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid

ROOT = Path(__file__).resolve().parents[1]
PROJECT = 'gradstep'
PROJECT_NUMBER = '885355087025'
REGION = 'us-west1'
SERVICE = 'gradstep-store-verifier'
RUNTIME = SERVICE + '@' + PROJECT + '.iam.gserviceaccount.com'
CALLER = 'gradstep-store-caller@' + PROJECT + '.iam.gserviceaccount.com'
SUPABASE = 'coxhjvqpflgxkleydati'
ORGANIZATION = 'mhiweqpcwyqtyorgqhla'
POLICY = 'app-store-sandbox-v1'
SERVICE_NAME = f'projects/{PROJECT}/locations/{REGION}/services/{SERVICE}'
SERVICE_URL = f'https://{SERVICE}-{PROJECT_NUMBER}.{REGION}.run.app'
IMAGE_PREFIX = f'{REGION}-docker.pkg.dev/{PROJECT}/cloud-run-source-deploy/{SERVICE}'
SCOPE = {'project': PROJECT, 'project_number': PROJECT_NUMBER, 'region': REGION,
         'service': SERVICE, 'supabase_project': SUPABASE, 'policy_id': POLICY}
SERVICE_FILES = ('Dockerfile', 'package.json', 'package-lock.json', 'server.ts',
                 'protocol.ts', 'thread-runner.ts', 'worker.ts', 'sdk-patch.ts')
SHARED_FILES = ('app-store.ts', 'store-purchases.ts', 'store-verifier-protocol.ts')
SECRET_NAME = 'STORE_VERIFIER_GOOGLE_CREDENTIALS'
SOURCE_LABEL = 'ai.gradstep.verifier.source-sha256'
CAPABILITIES = ('certificate_parse', 'certificate_string', 'certificate_raw',
                'public_key_export', 'certificate_verify', 'certificate_info_access')
SOURCE_VERSION = 1
EDGE_FUNCTIONS = ('store-verifier-health', 'store-sync', 'app-store-notifications')
SDK_SOURCE_SHA256 = '2ab29caa890958dcfc6dc4789fd5a500e8249102e037045525d35e5c15541bf1'
SDK_PATCHED_SHA256 = 'e2bbd098d9572596e6fa7572b69ee96fa4c34d5db5479672bc3a91a2c47241ad'


class OpsError(RuntimeError):
    """Finite error codes only: subprocess/vendor messages can contain secrets."""


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        raise OpsError('store_ops_redirect_refused')


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':')).encode()


def sha(value):
    return hashlib.sha256(value).hexdigest()


def now():
    return dt.datetime.now(dt.timezone.utc).isoformat().replace('+00:00', 'Z')


def run(args, *, input=None, cwd=None):
    try:
        result = subprocess.run(args, input=input, capture_output=True, text=True, cwd=cwd,
                                env={**os.environ, 'CLOUDSDK_CORE_DISABLE_PROMPTS': '1',
                                     'CLOUDSDK_CORE_LOG_HTTP': 'false', 'CLOUDSDK_CORE_DISABLE_FILE_LOGGING': 'true'}, check=False)
    except OSError:
        raise OpsError('store_ops_command_unavailable') from None
    if result.returncode:
        raise OpsError('store_ops_command_failed')
    if len(result.stdout) > 2_097_152:
        raise OpsError('store_ops_command_output_limit')
    return result.stdout


def gcloud(*args):
    return run(['gcloud', *args])


def parsed(raw):
    try:
        return json.loads(raw)
    except (ValueError, TypeError):
        raise OpsError('store_ops_invalid_json') from None


def require_digest(image):
    if not isinstance(image, str) or not re.fullmatch(re.escape(IMAGE_PREFIX) + r'@sha256:[0-9a-f]{64}', image):
        raise OpsError('store_ops_immutable_image_required')
    return image


def require_revision(value):
    if not isinstance(value, str) or len(value) > 63 or not re.fullmatch(SERVICE + r'-[a-z0-9-]{1,39}', value):
        raise OpsError('store_ops_revision_required')
    return value


def json_request(url, *, token=None, body=None, method=None, max_bytes=1_048_576):
    """Only the two administrative APIs; fixed caller code selects every path."""
    target = urllib.parse.urlsplit(url)
    if target.scheme != 'https' or target.username or target.password or target.fragment or target.port:
        raise OpsError('store_ops_request_scope')
    if target.hostname == 'api.supabase.com':
        allowed = r'/v1/projects/' + SUPABASE + r'(?:/secrets|/database/query|/functions/(?:store-verifier-health|store-sync|app-store-notifications)(?:/body)?)?'
    elif target.hostname == 'run.googleapis.com':
        allowed = r'/v2/projects/(?:' + PROJECT + '|' + PROJECT_NUMBER + r')/locations/' + REGION + r'/(?:services/' + SERVICE + r'|operations/[a-zA-Z0-9-]+)'
    elif target.hostname == 'iam.googleapis.com':
        allowed = r'/v1/projects/' + PROJECT + r'/serviceAccounts/' + re.escape(CALLER) + r'/keys'
        if method != 'POST':
            raise OpsError('store_ops_key_method')
    else:
        raise OpsError('store_ops_request_scope')
    if not re.fullmatch(allowed, target.path):
        raise OpsError('store_ops_request_scope')
    if target.query and not (target.hostname == 'run.googleapis.com' and target.query == 'updateMask=template%2Ctraffic'):
        raise OpsError('store_ops_request_query')
    request = urllib.request.Request(url, data=None if body is None else canonical(body), method=method,
                                    headers={'Content-Type': 'application/json', **({'Authorization': 'Bearer ' + token} if token else {})})
    try:
        with urllib.request.build_opener(NoRedirect).open(request, timeout=30) as response:
            raw = response.read(max_bytes + 1)
        if len(raw) > max_bytes:
            raise OpsError('store_ops_response_limit')
        return parsed(raw) if raw else None
    except urllib.error.HTTPError as error:
        raise OpsError(f'store_ops_http_{error.code}') from None
    except (urllib.error.URLError, TimeoutError, OSError):
        raise OpsError('store_ops_transport_failed') from None


def management_token():
    value = run(['security', 'find-generic-password', '-s', 'Supabase CLI', '-w']).strip()
    if not value:
        raise OpsError('store_ops_credential_missing')
    return value


def cloud_token():
    value = gcloud('auth', 'print-access-token').strip()
    if not value:
        raise OpsError('store_ops_credential_missing')
    return value


def supabase_identity(token):
    value = json_request('https://api.supabase.com/v1/projects/' + SUPABASE, token=token)
    if not isinstance(value, dict) or value.get('organization_id') != ORGANIZATION or value.get('name') != 'science-reader-staging':
        raise OpsError('store_ops_supabase_identity')


def project_identity():
    value = parsed(gcloud('projects', 'describe', PROJECT, '--format=json'))
    if value.get('projectId') != PROJECT or str(value.get('projectNumber')) != PROJECT_NUMBER or value.get('parent'):
        # Current inspected project has no organization/folder inheritance. A
        # future move needs a real inherited-policy review, not this assumption.
        raise OpsError('store_ops_project_identity_or_ancestry')
    return value


def protected_directory(path):
    """Credential state must stay inside the ignored task directory, no links."""
    path = Path(os.path.abspath(path))
    base = ROOT / '.artifacts' / 'store-verifier'
    if not path.is_relative_to(base) or path == base:
        raise OpsError('store_ops_checkpoint_location')
    current = ROOT
    for part in path.relative_to(ROOT).parts:
        current = current / part
        if current.is_symlink():
            raise OpsError('store_ops_checkpoint_symlink')
        if not current.exists():
            current.mkdir(mode=0o700)
        if not current.is_dir() or current.stat().st_uid != os.getuid():
            raise OpsError('store_ops_checkpoint_owner')
    if stat.S_IMODE(path.stat().st_mode) != 0o700:
        raise OpsError('store_ops_checkpoint_permissions')
    return path


def private_read(path, *, maximum=65_536):
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
        with os.fdopen(fd, 'rb') as stream:
            info = os.fstat(stream.fileno())
            if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o600:
                raise OpsError('store_ops_checkpoint_permissions')
            data = stream.read(maximum + 1)
        if len(data) > maximum:
            raise OpsError('store_ops_checkpoint_limit')
        return parsed(data)
    except OSError:
        raise OpsError('store_ops_checkpoint_unavailable') from None


def private_write(path, value):
    path = Path(path)
    if path.is_symlink():
        raise OpsError('store_ops_checkpoint_symlink')
    fd, temporary = tempfile.mkstemp(prefix='.checkpoint-', dir=path.parent)
    try:
        with os.fdopen(fd, 'wb') as stream:
            os.fchmod(stream.fileno(), 0o600)
            stream.write(canonical(value) + b'\n')
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
        directory = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def key_ids():
    value = parsed(gcloud('iam', 'service-accounts', 'keys', 'list', '--iam-account', CALLER,
                          '--project', PROJECT, '--managed-by=user', '--format=json'))
    if not isinstance(value, list):
        raise OpsError('store_ops_key_inventory')
    identities = []
    for row in value:
        name = row.get('name', '')
        match = re.fullmatch(r'projects/(?:' + PROJECT + '|' + PROJECT_NUMBER + r'|-)/serviceAccounts/(?:' +
                             re.escape(CALLER) + r'|[0-9]+)/keys/([a-zA-Z0-9_-]{16,128})', name)
        if not match or row.get('keyType') != 'USER_MANAGED':
            raise OpsError('store_ops_key_inventory')
        identities.append(match.group(1))
    if len(identities) != len(set(identities)):
        raise OpsError('store_ops_key_inventory')
    return sorted(identities)


def credentials(value):
    if not isinstance(value, dict) or value.get('type') != 'service_account' or value.get('project_id') != PROJECT \
       or value.get('client_email') != CALLER or value.get('token_uri') != 'https://oauth2.googleapis.com/token' \
       or not re.fullmatch(r'[a-zA-Z0-9_-]{16,128}', str(value.get('private_key_id', ''))) \
       or not isinstance(value.get('private_key'), str) or not value['private_key'].startswith('-----BEGIN PRIVATE KEY-----\n'):
        raise OpsError('store_ops_caller_credentials')
    return value


def create_key_material():
    # One documented REST POST, with no SDK/gcloud mutation retry behavior.
    # Cloud CLI is used only to obtain an access token; key data never enters
    # its HTTP/file logging. A lost acknowledgement cannot recover private data.
    value = json_request(f'https://iam.googleapis.com/v1/projects/{PROJECT}/serviceAccounts/{CALLER}/keys',
        token=cloud_token(), method='POST', max_bytes=65_536,
        body={'privateKeyType': 'TYPE_GOOGLE_CREDENTIALS_FILE', 'keyAlgorithm': 'KEY_ALG_RSA_2048'})
    try:
        if not isinstance(value, dict) or value.get('privateKeyType') != 'TYPE_GOOGLE_CREDENTIALS_FILE':
            raise ValueError()
        material = credentials(parsed(base64.b64decode(value['privateKeyData'], validate=True)))
        if not re.fullmatch(r'projects/(?:' + PROJECT + '|' + PROJECT_NUMBER + r')/serviceAccounts/(?:' +
                            re.escape(CALLER) + r'|[0-9]+)/keys/' + re.escape(material['private_key_id']), value.get('name', '')):
            raise ValueError()
    except (ValueError, KeyError, TypeError, binascii.Error):
        raise OpsError('store_ops_key_response_unverified') from None
    return material


def create_caller_key(directory):
    """Never repeat a possibly successful create, even if listing finds no key."""
    project_policy()
    verify_identities()
    service_iam()
    directory = protected_directory(directory)
    state_path, key_path = directory / 'checkpoint.json', directory / 'caller.json'
    if state_path.exists():
        state = private_read(state_path)
        if state.get('scope') != SCOPE or state.get('version') != 1 or state.get('caller') != CALLER:
            raise OpsError('store_ops_checkpoint_identity')
        if state.get('phase') not in ('creating', 'material_ready', 'installed'):
            raise OpsError('store_ops_checkpoint_state')
    else:
        if key_path.exists() or key_path.is_symlink():
            raise OpsError('store_ops_untracked_key_material')
        baseline = key_ids()
        if baseline:
            raise OpsError('store_ops_existing_keys_require_review')
        state = {'version': 1, 'scope': SCOPE, 'caller': CALLER, 'baseline': baseline,
                 'phase': 'creating', 'started_at': now()}
        private_write(state_path, state)  # Durable intent BEFORE the only create.
        try:
            private_write(key_path, create_key_material())
        except OpsError:
            raise OpsError('store_ops_key_creation_ambiguous_reconcile_before_retry') from None
    try:
        material = credentials(private_read(key_path))
        current = key_ids()
        key_id = material['private_key_id']
        if key_id in state['baseline'] or current != sorted([*state['baseline'], key_id]):
            raise OpsError('store_ops_key_inventory_changed')
        if state.get('key_id') not in (None, key_id):
            raise OpsError('store_ops_key_identity_changed')
    except OpsError:
        raise OpsError('store_ops_key_creation_ambiguous_reconcile_before_retry') from None
    if state['phase'] == 'creating':
        fd = os.open(key_path, os.O_RDONLY | os.O_NOFOLLOW)
        try:
            os.fsync(fd)
        finally:
            os.close(fd)
        state.update(phase='material_ready', key_id=key_id, material_observed_at=now())
        private_write(state_path, state)
    return {'phase': state['phase'], 'key_id': key_id, 'caller': CALLER}


def reconcile_caller_key(directory):
    directory = protected_directory(directory)
    state = private_read(directory / 'checkpoint.json')
    if state.get('scope') != SCOPE or state.get('caller') != CALLER:
        raise OpsError('store_ops_checkpoint_identity')
    current = key_ids()
    return {'phase': state.get('phase'), 'current_key_ids': current,
            'new_key_ids': sorted(set(current) - set(state.get('baseline', []))),
            'automatic_recreation_allowed': False}


def install_caller_secret(directory):
    verify_identities()
    directory = protected_directory(directory)
    state_path = directory / 'checkpoint.json'
    state = private_read(state_path)
    if state.get('scope') != SCOPE or state.get('phase') not in ('material_ready', 'installed'):
        raise OpsError('store_ops_key_not_ready')
    value = credentials(private_read(directory / 'caller.json'))
    if value['private_key_id'] != state.get('key_id') or key_ids() != [value['private_key_id']]:
        raise OpsError('store_ops_key_inventory_changed')
    token = management_token()
    supabase_identity(token)
    secrets = [{'name': SECRET_NAME, 'value': canonical(value).decode()},
               {'name': 'STORE_VERIFIER_URL', 'value': SERVICE_URL}]
    # Repeating this exact write is safe; it does not create another Google key.
    json_request(f'https://api.supabase.com/v1/projects/{SUPABASE}/secrets', token=token, body=secrets, method='POST')
    observed = json_request(f'https://api.supabase.com/v1/projects/{SUPABASE}/secrets', token=token)
    if not isinstance(observed, list):
        raise OpsError('store_ops_secret_readback')
    for expected in secrets:
        matches = [entry for entry in observed if entry.get('name') == expected['name']]
        # The Management API lists each secret's SHA-256 hex digest in `value` (never the secret itself).
        if len(matches) != 1 or matches[0].get('value') != sha(expected['value'].encode()):
            raise OpsError('store_ops_secret_readback')
    state.update(phase='installed', installed_at=now())
    private_write(state_path, state)
    return {'phase': 'installed', 'key_id': value['private_key_id'], 'secret_names': [item['name'] for item in secrets]}


def source_files(root=ROOT):
    return [root / 'services/store-verifier' / name for name in SERVICE_FILES] + \
           [root / 'supabase/functions/_shared' / name for name in SHARED_FILES]


def source_manifest(root=ROOT):
    files = {}
    for path in source_files(root):
        if not path.is_file() or path.is_symlink() or not path.resolve().is_relative_to(root.resolve()):
            raise OpsError('store_ops_build_source_missing')
        data = path.read_bytes()
        if len(data) > 1_048_576:
            raise OpsError('store_ops_build_source_limit')
        files[str(path.relative_to(root))] = sha(data)
    return {'version': SOURCE_VERSION, 'scope': SCOPE, 'files': files}


def build_context(root=ROOT):
    manifest = source_manifest(root)
    target = Path(tempfile.mkdtemp(prefix='gradstep-store-verifier-'))
    try:
        for path in source_files(root):
            relative = path.relative_to(root)
            destination = target / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(path, destination)
        return target, manifest
    except BaseException:
        shutil.rmtree(target)
        raise


def build_image(*, publish=False):
    project_identity() if publish else None
    context, manifest = build_context(ROOT)
    fingerprint = sha(canonical(manifest))
    tag = IMAGE_PREFIX + ':source-' + fingerprint if publish else SERVICE + ':local'
    try:
        run(['docker', 'build', '--platform', 'linux/amd64', '-f', str(context / 'services/store-verifier/Dockerfile'), '--label', SOURCE_LABEL + '=' + fingerprint,
             '--label', 'ai.gradstep.verifier.policy=' + POLICY, '-t', tag, str(context)])
        if publish:
            gcloud('auth', 'configure-docker', REGION + '-docker.pkg.dev', '--quiet')
            run(['docker', 'push', tag])
            digests = parsed(run(['docker', 'image', 'inspect', '--format', '{{json .RepoDigests}}', tag]))
            matches = [item for item in digests if isinstance(item, str) and item.startswith(IMAGE_PREFIX + '@')]
            if len(matches) != 1:
                raise OpsError('store_ops_image_push_readback')
            image = require_digest(matches[0])
        else:
            image = tag
        return {'version': 1, 'scope': SCOPE, 'created_at': now(), 'image': image,
                'source_sha256': fingerprint, 'source': manifest}
    finally:
        shutil.rmtree(context)


def verify_image_proof(proof):
    if not isinstance(proof, dict) or proof.get('version') != 1 or proof.get('scope') != SCOPE:
        raise OpsError('store_ops_image_proof')
    image = require_digest(proof.get('image'))
    manifest = source_manifest(ROOT)
    fingerprint = sha(canonical(manifest))
    if proof.get('source') != manifest or proof.get('source_sha256') != fingerprint:
        raise OpsError('store_ops_image_source_changed')
    run(['docker', 'pull', image])
    labels = parsed(run(['docker', 'image', 'inspect', '--format', '{{json .Config.Labels}}', image]))
    if not isinstance(labels, dict) or labels.get(SOURCE_LABEL) != fingerprint or labels.get('ai.gradstep.verifier.policy') != POLICY:
        raise OpsError('store_ops_image_labels')
    return image


def deployment_args(image):
    require_digest(image)
    return ['run', 'deploy', SERVICE, '--project', PROJECT, '--region', REGION, '--image', image,
            '--service-account', RUNTIME, '--memory', '512Mi', '--cpu', '1', '--concurrency', '2',
            '--min', '0', '--max', '1', '--min-instances', '0', '--max-instances', '1',
            '--timeout', '80', '--cpu-throttling', '--no-cpu-boost', '--ingress', 'all',
            '--invoker-iam-check', '--no-allow-unauthenticated', '--clear-secrets',
            '--set-env-vars', 'STORE_VERIFIER_POLICY_ID=' + POLICY + ',STORE_VERIFIER_MAINTENANCE=true', '--quiet']


def project_policy():
    project_identity()
    value = parsed(gcloud('projects', 'get-iam-policy', PROJECT, '--format=json'))
    if not isinstance(value.get('bindings', []), list):
        raise OpsError('store_ops_project_iam')
    for binding in value.get('bindings', []):
        members = binding.get('members', [])
        if any(member in members for member in ('allUsers', 'allAuthenticatedUsers', 'serviceAccount:' + CALLER, 'serviceAccount:' + RUNTIME)) \
           or any(isinstance(member, str) and member.startswith('principalSet:') for member in members):
            raise OpsError('store_ops_broad_identity_permissions')
    return {'project_has_no_parent': True, 'dedicated_identities_have_no_project_grants': True,
            'public_project_grants': False}


def service_iam(*, caller_required=True):
    value = parsed(gcloud('run', 'services', 'get-iam-policy', SERVICE, '--project', PROJECT, '--region', REGION, '--format=json'))
    bindings = value.get('bindings', [])
    expected = [{'role': 'roles/run.invoker', 'members': ['serviceAccount:' + CALLER]}]
    if bindings != expected and not (not caller_required and bindings == []):
        raise OpsError('store_ops_service_iam')
    if not value.get('etag'):
        raise OpsError('store_ops_service_iam_etag')
    return {'bindings': bindings, 'etag': value['etag']}


def identity_inventory():
    existing = parsed(gcloud('iam', 'service-accounts', 'list', '--project', PROJECT, '--format=json'))
    if not isinstance(existing, list):
        raise OpsError('store_ops_identity_inventory')
    result = {}
    for email in (RUNTIME, CALLER):
        matches = [row for row in existing if row.get('email') == email]
        if len(matches) > 1:
            raise OpsError('store_ops_identity_inventory')
        if matches:
            row = matches[0]
            if row.get('disabled', False) or row.get('projectId') != PROJECT or not re.fullmatch(r'[0-9]{10,30}', str(row.get('uniqueId', ''))):
                raise OpsError('store_ops_identity_unavailable')
            result[email] = str(row['uniqueId'])
    return result


def identity_state_path():
    return protected_directory(ROOT / '.artifacts/store-verifier/identities') / 'checkpoint.json'


def read_identity_state():
    value = private_read(identity_state_path())
    if not isinstance(value, dict) or value.get('version') != 1 or value.get('scope') != SCOPE \
       or not isinstance(value.get('identities'), dict) or set(value['identities']) != {RUNTIME, CALLER}:
        raise OpsError('store_ops_identity_checkpoint')
    for entry in value['identities'].values():
        if not isinstance(entry, dict) or entry.get('phase') not in ('not_started', 'creating', 'ready'):
            raise OpsError('store_ops_identity_checkpoint')
    return value


def verify_identities():
    state = read_identity_state()
    observed = identity_inventory()
    for email in (RUNTIME, CALLER):
        entry = state['identities'][email]
        if entry['phase'] != 'ready' or not entry.get('unique_id') or observed.get(email) != entry['unique_id']:
            raise OpsError('store_ops_identity_not_confirmed')
    return {'runtime_unique_id': observed[RUNTIME], 'caller_unique_id': observed[CALLER]}


def provision_identities():
    project_policy()
    path = identity_state_path()
    observed = identity_inventory()
    if path.exists():
        state = read_identity_state()
    else:
        if observed:
            raise OpsError('store_ops_untracked_existing_identity')
        state = {'version': 1, 'scope': SCOPE, 'started_at': now(),
                 'identities': {email: {'phase': 'not_started'} for email in (RUNTIME, CALLER)}}
        private_write(path, state)
    for email in (RUNTIME, CALLER):
        entry = state['identities'][email]
        if entry['phase'] == 'creating':
            raise OpsError('store_ops_identity_creation_ambiguous_reconcile_before_retry')
        if entry['phase'] == 'ready':
            if observed.get(email) != entry.get('unique_id'):
                raise OpsError('store_ops_identity_changed')
            continue
        if email in observed:
            raise OpsError('store_ops_untracked_existing_identity')
        entry.update(phase='creating', requested_at=now())
        private_write(path, state)
        try:
            gcloud('iam', 'service-accounts', 'create', email.split('@')[0], '--project', PROJECT,
                '--display-name', 'Gradstep purchase verification ' + ('runtime' if email == RUNTIME else 'caller'), '--quiet')
            observed = identity_inventory()
            if email not in observed:
                raise OpsError('store_ops_identity_unobserved')
        except OpsError:
            raise OpsError('store_ops_identity_creation_ambiguous_reconcile_before_retry') from None
        entry.update(phase='ready', unique_id=observed[email], observed_at=now())
        private_write(path, state)
    project_policy()
    return {'runtime': RUNTIME, 'caller': CALLER, **verify_identities(), 'project_permissions_granted': False}


def reconcile_identities():
    """No new identity or automatic acknowledgement of an ambiguous creation."""
    project_policy()
    state = read_identity_state()
    observed = identity_inventory()
    return {'scope': SCOPE, 'identities': [{'email': email, 'phase': state['identities'][email]['phase'],
        'requested_at': state['identities'][email].get('requested_at'), 'observed_unique_id': observed.get(email)} for email in (RUNTIME, CALLER)],
        'automatic_recreation_allowed': False}


def confirm_identity(identity, expected_unique_id):
    """An explicit local acknowledgement after inspecting reconciliation output."""
    project_policy()
    if identity not in ('runtime', 'caller') or not re.fullmatch(r'[0-9]{10,30}', expected_unique_id or ''):
        raise OpsError('store_ops_identity_confirmation')
    email = RUNTIME if identity == 'runtime' else CALLER
    state, observed = read_identity_state(), identity_inventory()
    entry = state['identities'][email]
    if entry['phase'] != 'creating' or observed.get(email) != expected_unique_id:
        raise OpsError('store_ops_identity_confirmation_mismatch')
    entry.update(phase='ready', unique_id=expected_unique_id, reconciled_at=now())
    private_write(identity_state_path(), state)
    return {'email': email, 'unique_id': expected_unique_id, 'phase': 'ready', 'hosted_mutations': False}


def cloud_service(token):
    return json_request('https://run.googleapis.com/v2/' + SERVICE_NAME, token=token)


def verified_service(value, revision, image, *, maintenance):
    require_revision(revision)
    require_digest(image)
    if value.get('name') not in (SERVICE_NAME, SERVICE_NAME.replace('/' + PROJECT + '/', '/' + PROJECT_NUMBER + '/')) \
       or SERVICE_URL not in [value.get('uri'), *value.get('urls', [])] or not value.get('uid') or not value.get('etag'):
        raise OpsError('store_ops_service_identity')
    template = value.get('template', {})
    containers = template.get('containers', [])
    container = containers[0] if len(containers) == 1 else {}
    resources = container.get('resources', {})
    expected_env = [{'name': 'STORE_VERIFIER_MAINTENANCE', 'value': str(maintenance).lower()},
                    {'name': 'STORE_VERIFIER_POLICY_ID', 'value': POLICY}]
    expected_traffic = [{'type': 'TRAFFIC_TARGET_ALLOCATION_TYPE_LATEST', 'percent': 100}]
    checks = {
        'stable': value.get('reconciling', False) is False and value.get('generation') == value.get('observedGeneration') and
                  value.get('terminalCondition', {}).get('state') == 'CONDITION_SUCCEEDED',
        'revision': value.get('latestReadyRevision', '').rsplit('/', 1)[-1] == revision and
                    value.get('latestCreatedRevision', '').rsplit('/', 1)[-1] == revision,
        'private': value.get('invokerIamDisabled', False) is False,
        'ingress': value.get('ingress') == 'INGRESS_TRAFFIC_ALL',
        'scaling': value.get('scaling', {}).get('minInstanceCount', 0) == 0 and value.get('scaling', {}).get('maxInstanceCount') == 1 and
                   template.get('scaling', {}).get('minInstanceCount', 0) == 0 and template.get('scaling', {}).get('maxInstanceCount') == 1,
        'runtime': template.get('serviceAccount') == RUNTIME and template.get('maxInstanceRequestConcurrency') == 2 and template.get('timeout') == '80s',
        'resources': resources.get('cpuIdle') is True and resources.get('startupCpuBoost', False) is False and
                     resources.get('limits', {}).get('cpu') in ('1', '1000m') and resources.get('limits', {}).get('memory') in ('512Mi', '536870912'),
        'container': len(containers) == 1 and container.get('image') == image and not container.get('volumeMounts') and not template.get('volumes') and
                     not container.get('command') and not container.get('args'),
        'env': sorted(container.get('env', []), key=lambda item: item.get('name', '')) == expected_env,
        'traffic': value.get('traffic') == expected_traffic and len(value.get('trafficStatuses', [])) == 1 and
                   value['trafficStatuses'][0].get('revision', '').rsplit('/', 1)[-1] == revision and value['trafficStatuses'][0].get('percent') == 100 and
                   not value['trafficStatuses'][0].get('tag'),
    }
    failures = [name for name, passed in checks.items() if not passed]
    if failures:
        raise OpsError('store_ops_configuration_mismatch:' + ','.join(failures))
    return {'revision': revision, 'image': image, 'uid': value['uid'], 'etag': value['etag'],
            'maintenance': maintenance, 'configuration_sha256': sha(canonical(value.get('template'))),
            'gateway_iam_enabled': True, 'bounds_verified': True}


def deploy_service(proof):
    project_policy()
    verify_identities()
    database_readiness(management_token())
    image = verify_image_proof(proof)
    # No key creation/installation, DB write, function deployment or activation.
    gcloud(*deployment_args(image))
    token = cloud_token()
    service = cloud_service(token)
    revision = service.get('latestReadyRevision', '').rsplit('/', 1)[-1]
    policy = verified_service(service, revision, image, maintenance=True)
    service_iam(caller_required=False)
    gcloud('run', 'services', 'add-iam-policy-binding', SERVICE, '--project', PROJECT, '--region', REGION,
           '--member', 'serviceAccount:' + CALLER, '--role', 'roles/run.invoker', '--condition=None', '--quiet')
    iam = service_iam()
    project_policy()
    return {'scope': SCOPE, 'service': policy, 'iam_sha256': sha(canonical(iam)), 'admission_enabled': False}


def compare_eszip(bundle, function, root=ROOT):
    """Exact original source from bounded ESZIP2.3 source maps, never dumps code.

    A new format/checksum variant fails closed for an explicit parser review.
    Format: denoland/deno libs/eszip/v2.rs. All module ranges are checked, not
    just string-searched snippets that might occur inside another module.
    """
    if function not in EDGE_FUNCTIONS or len(bundle) > 33_554_432 or bundle[:8] != b'ESZIP2.3':
        raise OpsError('store_ops_bundle_format')
    position = 8
    def section():
        nonlocal position
        if position + 4 > len(bundle):
            raise OpsError('store_ops_bundle_bounds')
        length = struct.unpack_from('>I', bundle, position)[0]
        position += 4
        if position + length > len(bundle):
            raise OpsError('store_ops_bundle_bounds')
        result = bundle[position:position + length]
        position += length
        return result
    if section() != b'\x00\x00\x01\x00':
        raise OpsError('store_ops_bundle_options')
    header = section()
    offset = 0
    def take(length):
        nonlocal offset
        if offset + length > len(header):
            raise OpsError('store_ops_bundle_header')
        value = header[offset:offset + length]
        offset += length
        return value
    def integer():
        return struct.unpack('>I', take(4))[0]
    modules, seen = {}, set()
    try:
        while offset < len(header):
            name = take(integer()).decode('utf8')
            kind = take(1)[0]
            if name in seen:
                raise OpsError('store_ops_bundle_duplicate')
            seen.add(name)
            if kind == 0:
                ranges = struct.unpack('>IIII', take(16))
                if take(1)[0] > 4:
                    raise OpsError('store_ops_bundle_kind')
                modules[name] = ranges
            elif kind == 1:
                take(integer())
            elif kind == 2:
                take(4)
            else:
                raise OpsError('store_ops_bundle_kind')
    except (UnicodeError, struct.error):
        raise OpsError('store_ops_bundle_header') from None
    section()  # npm package snapshot: private-free bytes, not source evidence.
    sources, maps = section(), section()
    if position != len(bundle) or f'functions/{function}/index.ts' not in modules:
        raise OpsError('store_ops_bundle_entrypoint')
    compared = []
    for name, (so, sl, mo, ml) in modules.items():
        if so + sl > len(sources) or mo + ml > len(maps):
            raise OpsError('store_ops_bundle_range')
        if not name.startswith('functions/'):
            continue
        if not re.fullmatch(r'functions/(?:_shared/[a-z0-9-]+|' + re.escape(function) + r'/index)\.ts', name):
            raise OpsError('store_ops_bundle_local_scope')
        # Edge must never import the Node-only Apple verifier after this repair.
        if name == 'functions/_shared/app-store.ts':
            raise OpsError('store_ops_bundle_local_verifier')
        source_map = parsed(maps[mo:mo + ml])
        originals = source_map.get('sourcesContent', [])
        if len(source_map.get('sources', [])) != 1 or len(originals) != 1 or not isinstance(originals[0], str):
            raise OpsError('store_ops_bundle_source_map')
        path = root / 'supabase' / name
        if not path.is_file() or path.is_symlink() or path.read_bytes() != originals[0].encode():
            raise OpsError('store_ops_bundle_source_mismatch')
        compared.append({'module': name, 'sha256': sha(originals[0].encode())})
    return {'format': 'ESZIP2.3', 'bundle_sha256': sha(bundle), 'modules': sorted(compared, key=lambda item: item['module'])}


def download_function(function, token):
    if function not in EDGE_FUNCTIONS:
        raise OpsError('store_ops_function_scope')
    request = urllib.request.Request(f'https://api.supabase.com/v1/projects/{SUPABASE}/functions/{function}/body',
                                     headers={'Authorization': 'Bearer ' + token})
    try:
        with urllib.request.build_opener(NoRedirect).open(request, timeout=30) as response:
            data = response.read(33_554_433)
        if len(data) > 33_554_432:
            raise OpsError('store_ops_bundle_limit')
        return data
    except urllib.error.HTTPError as error:
        raise OpsError(f'store_ops_function_http_{error.code}') from None
    except (urllib.error.URLError, TimeoutError, OSError):
        raise OpsError('store_ops_function_transport') from None


def function_readback(function, token):
    if function not in EDGE_FUNCTIONS:
        raise OpsError('store_ops_function_scope')
    metadata = json_request(f'https://api.supabase.com/v1/projects/{SUPABASE}/functions/{function}', token=token)
    if not isinstance(metadata, dict) or metadata.get('slug') != function or metadata.get('status') != 'ACTIVE' \
       or not isinstance(metadata.get('version'), int) or metadata.get('verify_jwt') is not False:
        raise OpsError('store_ops_function_metadata')
    proof = compare_eszip(download_function(function, token), function, ROOT)
    # `ezbr_sha256` hashes Supabase's compressed (EZBR) bundle; the body endpoint serves the decompressed ESZIP,
    # so the two digests differ by design. compare_eszip already proves every module's source; record both.
    ezbr = metadata.get('ezbr_sha256')
    if ezbr is not None and not re.fullmatch(r'[0-9a-f]{64}', ezbr):
        raise OpsError('store_ops_function_bundle_digest')
    proof = {**proof, 'ezbr_sha256': ezbr}
    after = json_request(f'https://api.supabase.com/v1/projects/{SUPABASE}/functions/{function}', token=token)
    if any(after.get(key) != metadata.get(key) for key in ('id', 'slug', 'version', 'status', 'verify_jwt', 'ezbr_sha256')):
        raise OpsError('store_ops_function_changed_during_readback')
    return {'function': function, 'version': metadata['version'], **proof}


def deploy_functions(functions):
    if not functions or len(set(functions)) != len(functions) or any(name not in EDGE_FUNCTIONS for name in functions):
        raise OpsError('store_ops_function_scope')
    token = management_token()
    supabase_identity(token)
    if any(function != 'store-verifier-health' for function in functions):
        database_readiness(token)
    results = []
    for function in functions:
        entry = ROOT / 'supabase/functions' / function / 'index.ts'
        if not entry.is_file() or entry.is_symlink():
            raise OpsError('store_ops_function_source_missing')
        # Token is an environment variable, never argv or saved CLI output.
        try:
            process = subprocess.run([str(ROOT / 'node_modules/.bin/supabase'), 'functions', 'deploy', function,
                '--project-ref', SUPABASE, '--use-api', '--no-verify-jwt', '--import-map', 'supabase/functions/deno.json'],
                cwd=ROOT, env={**os.environ, 'SUPABASE_ACCESS_TOKEN': token}, capture_output=True, text=True)
        except OSError:
            raise OpsError('store_ops_function_deploy_unavailable') from None
        if process.returncode:
            raise OpsError('store_ops_function_deploy_ambiguous_readback_before_retry')
        results.append(function_readback(function, token))
    return {'scope': SCOPE, 'functions': results, 'admission_enabled': False}


def validate_health(value, revision, *, maintenance):
    expected = {'version', 'ok', 'policy_id', 'policy_valid', 'maintenance', 'ready', 'revision', 'runtime'}
    if not isinstance(value, dict) or set(value) != expected or value['version'] != 1 or value['ok'] is not True \
       or value['policy_id'] != POLICY or value['policy_valid'] is not True or value['maintenance'] is not maintenance \
       or value['ready'] is not (not maintenance) or value['revision'] != require_revision(revision):
        raise OpsError('store_ops_health_shape')
    runtime = value['runtime']
    if not isinstance(runtime, dict) or set(runtime) != {'node', 'apple_library', 'capabilities', 'ocsp_freshness'} \
       or runtime['apple_library'] != '3.1.0' or not re.fullmatch(r'24\.\d{1,3}\.\d{1,3}', str(runtime['node'])) \
       or not isinstance(runtime['capabilities'], dict) or set(runtime['capabilities']) != set(CAPABILITIES) \
       or any(item is not True for item in runtime['capabilities'].values()):
        raise OpsError('store_ops_health_capabilities')
    if runtime['ocsp_freshness'] != {'policy': 'strict-utc-v1', 'applied': True,
        'source_sha256': SDK_SOURCE_SHA256, 'patched_sha256': SDK_PATCHED_SHA256}:
        raise OpsError('store_ops_sdk_freshness_unverified')
    return copy.deepcopy(value)


def staging_service_role():
    path = ROOT / '.env.staging'
    if not path.is_file() or path.is_symlink() or path.stat().st_uid != os.getuid() or path.stat().st_mode & 0o077:
        raise OpsError('store_ops_staging_credential_file')
    data = path.read_bytes()
    if len(data) > 65_536:
        raise OpsError('store_ops_staging_credential_limit')
    values = {}
    try:
        for line in data.decode().splitlines():
            if '=' in line and not line.lstrip().startswith('#'):
                key, value = line.split('=', 1)
                values[key.strip()] = value.strip().strip('"').strip("'")
    except UnicodeError:
        raise OpsError('store_ops_staging_credential_format') from None
    if values.get('SUPABASE_PROJECT_REF') != SUPABASE or values.get('SUPABASE_URL', '').rstrip('/') != f'https://{SUPABASE}.supabase.co' \
       or not values.get('SUPABASE_SERVICE_ROLE_KEY'):
        raise OpsError('store_ops_staging_credential_identity')
    # Hosted Edge functions receive the project's current secret API key as SUPABASE_SERVICE_ROLE_KEY once
    # new-style keys exist; the legacy JWT still works for PostgREST but not for the health handler's comparison.
    secret = values.get('SUPABASE_SECRET_KEY', '')
    if secret and not secret.startswith('sb_secret_'):
        raise OpsError('store_ops_staging_credential_format')
    return secret or values['SUPABASE_SERVICE_ROLE_KEY']


def invoke_health_probe(probe_id, service_role):
    # The only application invocation this tool supports: no customer receipt,
    # paid provider, SQL mutation, or user account is involved.
    request = urllib.request.Request(f'https://{SUPABASE}.supabase.co/functions/v1/store-verifier-health',
        method='GET', headers={'Authorization': 'Bearer ' + service_role, 'apikey': service_role,
                               'X-Verifier-Probe-ID': probe_id, 'Cache-Control': 'no-store'})
    try:
        with urllib.request.build_opener(NoRedirect).open(request, timeout=30) as response:
            data = response.read(16_385)
        if len(data) > 16_384:
            raise OpsError('store_ops_probe_response_limit')
        return parsed(data)
    except urllib.error.HTTPError as error:
        raise OpsError(f'store_ops_probe_http_{error.code}') from None
    except (urllib.error.URLError, TimeoutError, OSError):
        raise OpsError('store_ops_probe_transport') from None


def fresh_timestamp(value, *, seconds=600):
    try:
        parsed_at = dt.datetime.fromisoformat(value.replace('Z', '+00:00'))
        age = (dt.datetime.now(dt.timezone.utc) - parsed_at).total_seconds()
        if parsed_at.tzinfo is None or age < -30 or age > seconds:
            raise ValueError()
    except (ValueError, AttributeError, TypeError):
        raise OpsError('store_ops_stale_evidence') from None


def probe_health(revision, *, maintenance=True):
    require_revision(revision)
    token = management_token()
    supabase_identity(token)
    before = function_readback('store-verifier-health', token)
    probe_id = str(uuid.uuid4())
    value = invoke_health_probe(probe_id, staging_service_role())
    if not isinstance(value, dict) or set(value) != {'version', 'probe_id', 'observed_at', 'health'} \
       or value['version'] != 1 or value['probe_id'] != probe_id:
        raise OpsError('store_ops_probe_binding')
    fresh_timestamp(value['observed_at'], seconds=120)
    health = validate_health(value['health'], revision, maintenance=maintenance)
    after = function_readback('store-verifier-health', token)
    if before != after:
        raise OpsError('store_ops_probe_deployment_changed')
    return {'version': 1, 'scope': SCOPE, 'observed_at': now(), 'audience': SERVICE_URL,
            'probe_id': probe_id, 'edge': after, 'health': health}


def private_gateway_probe():
    request = urllib.request.Request(SERVICE_URL + '/health', method='GET', headers={'Cache-Control': 'no-store'})
    try:
        with urllib.request.build_opener(NoRedirect).open(request, timeout=10) as response:
            response.read(8193)
        raise OpsError('store_ops_gateway_accepted_anonymous_request')
    except urllib.error.HTTPError as error:
        if error.code not in (401, 403):
            raise OpsError('store_ops_gateway_denial_unverified') from None
        return {'anonymous_http_status': error.code, 'observed_at': now()}
    except (urllib.error.URLError, TimeoutError, OSError):
        raise OpsError('store_ops_gateway_probe_unavailable') from None


def database_readiness(token):
    supabase_identity(token)
    verify_admission_migration(token)
    rows = json_request(f'https://api.supabase.com/v1/projects/{SUPABASE}/database/query', token=token,
        # Readiness is service-role-only; the Management API's read-only role can't execute it, so run it as
        # service_role inside an explicitly read-only transaction (the API's read_only mode uses another role).
        body={'query': 'begin transaction read only; set local role service_role; '
                       'select public.worker_store_verifier_readiness() as state; commit;', 'read_only': False}, method='POST')
    if not isinstance(rows, list) or len(rows) != 1 or set(rows[0]) != {'state'}:
        raise OpsError('store_ops_admission_readiness')
    value = rows[0]['state']
    if not isinstance(value, dict) or set(value) != {'version', 'migration', 'policy_id', 'channels'} \
       or value['version'] != 1 or value['migration'] != '202610070033_purchase_verification_transport' or value['policy_id'] != POLICY:
        raise OpsError('store_ops_admission_readiness')
    channels = value['channels']
    expected = [('app', {'account_hour': 50, 'hour': 500, 'day': 300, 'month': 3000}),
                ('notification', {'account_hour': None, 'hour': 60, 'day': 200, 'month': 1000})]
    if not isinstance(channels, list) or len(channels) != 2:
        raise OpsError('store_ops_admission_channels')
    for item, (name, limits) in zip(channels, expected):
        if not isinstance(item, dict) or set(item) != {'channel', 'enabled', 'revision', 'limits', 'usage'} \
           or item['channel'] != name or item['enabled'] is not False or type(item['revision']) is not int or item['revision'] < 1 or item['limits'] != limits:
            raise OpsError('store_ops_admission_not_paused')
        if not isinstance(item['usage'], dict) or set(item['usage']) != {'hour', 'day', 'month'}:
            raise OpsError('store_ops_admission_usage')
        for period in item['usage'].values():
            if not isinstance(period, dict) or set(period) != {'period', 'starts', 'denied'} \
               or not isinstance(period['period'], str) or len(period['period']) > 40 \
               or any(type(period[key]) is not int or period[key] < 0 for key in ('starts', 'denied')):
                raise OpsError('store_ops_admission_usage')
    return value


def verify_admission_migration(token):
    filename = ROOT / 'supabase/migrations/202610070033_purchase_verification_transport.sql'
    if not filename.is_file() or filename.is_symlink():
        raise OpsError('store_ops_admission_migration_source_missing')
    expected = sha(filename.read_bytes())
    rows = json_request(f'https://api.supabase.com/v1/projects/{SUPABASE}/database/query', token=token,
        body={'query': "select version,sha256 from science_reader_migrations.versions where version='202610070033'", 'read_only': True}, method='POST')
    if rows != [{'version': '202610070033', 'sha256': expected}]:
        raise OpsError('store_ops_admission_migration_not_verified')
    return expected


def readiness(revision, proof, *, probe=None):
    image = verify_image_proof(proof)
    project = project_policy()
    identities = verify_identities()
    iam = service_iam()
    service = verified_service(cloud_service(cloud_token()), revision, image, maintenance=True)
    database = database_readiness(management_token())
    gateway = private_gateway_probe()
    if probe is not None:
        if not isinstance(probe, dict) or probe.get('version') != 1 or probe.get('scope') != SCOPE or probe.get('audience') != SERVICE_URL:
            raise OpsError('store_ops_auth_probe_scope')
        fresh_timestamp(probe.get('observed_at'))
        validate_health(probe.get('health'), revision, maintenance=True)
        # Read the exact current function again; an operator-supplied proof file
        # cannot silently refer to a retired health implementation.
        if probe.get('edge') != function_readback('store-verifier-health', management_token()):
            raise OpsError('store_ops_auth_probe_source_changed')
    return {'version': 1, 'scope': SCOPE, 'observed_at': now(), 'service': service,
            'project_iam': project, 'iam_sha256': sha(canonical(iam)), 'admission': database,
            'identities': identities,
            'gateway': gateway,
            'auth_probe_sha256': sha(canonical(probe)) if probe is not None else None,
            'activation_ready': probe is not None}


def activation_template(template):
    value = copy.deepcopy(template)
    value.pop('revision', None)
    for container in value.get('containers', []):
        container.pop('buildInfo', None)
        container['env'] = sorted(container.get('env', []), key=lambda item: item['name'])
    return value


def activate(revision, proof, evidence, probe):
    # Neither this report nor the Cloud Run ETag locks IAM or Postgres across the
    # PATCH. Operators keep admission paused throughout and inspect readback.
    fresh_timestamp(evidence.get('observed_at'))
    current = readiness(revision, proof, probe=probe)
    for key in ('version', 'scope', 'service', 'project_iam', 'iam_sha256', 'identities', 'admission', 'auth_probe_sha256'):
        if current.get(key) != evidence.get(key):
            raise OpsError('store_ops_activation_evidence_changed')
    if not current['activation_ready'] or evidence.get('activation_ready') is not True:
        raise OpsError('store_ops_activation_not_ready')
    token = cloud_token()
    before = cloud_service(token)
    verified_service(before, revision, proof['image'], maintenance=True)
    if before['etag'] != current['service']['etag'] or sha(canonical(service_iam())) != current['iam_sha256']:
        raise OpsError('store_ops_activation_race')
    template = activation_template(before['template'])
    for entry in template['containers'][0]['env']:
        if entry['name'] == 'STORE_VERIFIER_MAINTENANCE':
            entry['value'] = 'false'
    result = json_request('https://run.googleapis.com/v2/' + SERVICE_NAME + '?updateMask=template%2Ctraffic', token=token,
        method='PATCH', body={'name': before['name'], 'etag': before['etag'], 'template': template,
                             'traffic': [{'type': 'TRAFFIC_TARGET_ALLOCATION_TYPE_LATEST', 'percent': 100}]})
    operation = result.get('name', '') if isinstance(result, dict) else ''
    if not re.fullmatch(r'projects/(?:' + PROJECT + '|' + PROJECT_NUMBER + r')/locations/' + REGION + r'/operations/[a-zA-Z0-9-]+', operation):
        raise OpsError('store_ops_activation_ambiguous_inspect_before_retry')
    deadline = time.monotonic() + 180
    while not result.get('done') and time.monotonic() < deadline:
        time.sleep(2)
        result = json_request('https://run.googleapis.com/v2/' + operation, token=token)
    if not result.get('done') or result.get('error'):
        raise OpsError('store_ops_activation_ambiguous_inspect_before_retry')
    after = cloud_service(token)
    ready_revision = after.get('latestReadyRevision', '').rsplit('/', 1)[-1]
    policy = verified_service(after, ready_revision, proof['image'], maintenance=False)
    if ready_revision == revision or after['uid'] != before['uid'] or activation_template(after['template']) != template:
        raise OpsError('store_ops_activation_readback')
    if sha(canonical(service_iam())) != current['iam_sha256']:
        raise OpsError('store_ops_activation_iam_changed')
    project_policy()
    verify_identities()
    database_readiness(management_token())
    auth = probe_health(ready_revision, maintenance=False)
    return {'version': 1, 'scope': SCOPE, 'operation': operation, 'observed_at': now(), 'service': policy,
            'auth_probe': auth, 'admission_enabled': False}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=['plan', 'build', 'publish', 'provision-identities', 'reconcile-identities', 'confirm-identity', 'create-caller-key',
                                           'reconcile-caller-key', 'install-caller-secret', 'deploy',
                                           'deploy-edge', 'readback-edge', 'probe', 'readiness', 'activate'])
    parser.add_argument('--checkpoint', type=Path, help='Protected directory below .artifacts/store-verifier/')
    parser.add_argument('--image-proof', type=Path)
    parser.add_argument('--functions', nargs='+', choices=EDGE_FUNCTIONS)
    parser.add_argument('--expected-revision')
    parser.add_argument('--probe-evidence', type=Path)
    parser.add_argument('--evidence', type=Path)
    parser.add_argument('--identity', choices=['runtime', 'caller'])
    parser.add_argument('--unique-id', help='Exact observed Google service-account ID for explicit reconciliation')
    parser.add_argument('--active', action='store_true', help='Probe an already active revision (does not activate it)')
    parser.add_argument('--output', type=Path, help='Nonsecret JSON evidence file')
    args = parser.parse_args(argv)
    if args.active and args.command != 'probe':
        parser.error('--active only changes probe expectations')
    output = None
    if args.output:
        output = Path(os.path.abspath(args.output))
        reports = ROOT / '.artifacts/store-verifier/reports'
        if not output.is_relative_to(reports) or output == reports:
            raise OpsError('store_ops_report_location')
        protected_directory(output.parent)
    if args.command == 'plan':
        result = {'scope': SCOPE, 'runtime': RUNTIME, 'caller': CALLER,
                  'deployment': deployment_args(IMAGE_PREFIX + '@sha256:' + '0' * 64),
                  'mutations': False, 'admission_enabled': False}
    elif args.command in ('build', 'publish'):
        result = build_image(publish=args.command == 'publish')
    elif args.command == 'provision-identities':
        result = provision_identities()
    elif args.command == 'reconcile-identities':
        result = reconcile_identities()
    elif args.command == 'confirm-identity':
        if not args.identity or not args.unique_id:
            parser.error('--identity and --unique-id are required')
        result = confirm_identity(args.identity, args.unique_id)
    elif args.command in ('create-caller-key', 'reconcile-caller-key', 'install-caller-secret'):
        if not args.checkpoint:
            parser.error('--checkpoint is required')
        action = {'create-caller-key': create_caller_key, 'reconcile-caller-key': reconcile_caller_key,
                  'install-caller-secret': install_caller_secret}[args.command]
        result = action(args.checkpoint)
    elif args.command in ('deploy-edge', 'readback-edge'):
        if not args.functions:
            parser.error('--functions is required')
        if args.command == 'deploy-edge':
            result = deploy_functions(args.functions)
        else:
            token = management_token()
            supabase_identity(token)
            result = {'scope': SCOPE, 'functions': [function_readback(name, token) for name in args.functions]}
    elif args.command == 'probe':
        if not args.expected_revision:
            parser.error('--expected-revision is required')
        result = probe_health(args.expected_revision, maintenance=not args.active)
    else:
        if not args.image_proof:
            parser.error('--image-proof is required')
        proof = parsed(args.image_proof.read_bytes())
        if args.command == 'deploy':
            result = deploy_service(proof)
        else:
            if not args.expected_revision:
                parser.error('--expected-revision is required')
            probe = parsed(args.probe_evidence.read_bytes()) if args.probe_evidence else None
            if args.command == 'readiness':
                result = readiness(args.expected_revision, proof, probe=probe)
            else:
                if not args.evidence or not probe:
                    parser.error('--evidence and --probe-evidence are required')
                result = activate(args.expected_revision, proof, parsed(args.evidence.read_bytes()), probe)
    if output:
        private_write(output, result)
    print(json.dumps(result, sort_keys=True))


if __name__ == '__main__':
    try:
        main()
    except OpsError as error:
        raise SystemExit(str(error)) from None
