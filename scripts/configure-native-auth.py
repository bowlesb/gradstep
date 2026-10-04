#!/usr/bin/env python3
"""Prepare the dedicated staging native-auth configuration; dry-run by default.

Only --apply mutates the fixed Apple bundle/capability and the allowlisted
Supabase Auth fields below. No provider login, email, purchase, app record,
profile, secret rotation, deletion or production project operation is exposed.
Credentials and complete remote configuration stay in memory.
"""
import argparse
import http.client
import json
from pathlib import Path
import re
import shutil
import ssl
import subprocess
import time
from urllib.parse import urlencode

ROOT = Path(__file__).resolve().parents[1]
REFERENCE = ROOT.parent / 'textbrain'
PROJECT = 'coxhjvqpflgxkleydati'
ORGANIZATION = 'mhiweqpcwyqtyorgqhla'
TEAM = '3BJ33TT599'
BUNDLE = 'com.sciencereader.ios'
REFERENCE_BUNDLE = 'com.textbrain.ios'
CALLBACK = 'sciencereader://auth/callback'
MANAGEMENT = 'api.supabase.com'
APPLE = 'api.appstoreconnect.apple.com'
AUTH_PATH = '/v1/projects/' + PROJECT + '/config/auth'
CAPABILITY = 'APPLE_ID_AUTH'
CONSENT = [{'key': 'APPLE_ID_AUTH_APP_CONSENT',
            'options': [{'key': 'PRIMARY_APP_CONSENT', 'enabled': True}]}]
CODE_TEMPLATE = ('<h2>Your Science Reader sign-in code</h2>\n'
                 '<p>Enter this code in the app:</p>\n'
                 '<p><strong>{{ .Token }}</strong></p>\n'
                 '<p>This code expires in 10 minutes. If you did not request it, ignore this email.</p>\n')
DESIRED_AUTH = {
    'external_apple_enabled': True,
    'external_apple_client_id': BUNDLE,
    'uri_allow_list': CALLBACK,
    'mailer_otp_length': 6,
    'mailer_otp_exp': 600,
    'mailer_templates_confirmation_content': CODE_TEMPLATE,
    'mailer_templates_magic_link_content': CODE_TEMPLATE,
    'disable_signup': True,
}


class ConfigurationError(RuntimeError):
    """Only fixed local codes, never a provider body, credential or raw error."""


def require(value, code):
    if not value:
        raise ConfigurationError(code)


def json_bytes(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':'), allow_nan=False).encode()


def bounded_file(path, maximum):
    with path.open('rb') as stream:
        data = stream.read(maximum + 1)
    require(len(data) <= maximum, 'local_file_limit')
    return data


def bundle_query(identifier):
    require(identifier in (BUNDLE, REFERENCE_BUNDLE), 'bundle_scope_refused')
    return '/v1/bundleIds?' + urlencode({'filter[identifier]': identifier, 'limit': 100})


def bundle_payload():
    return {'data': {'type': 'bundleIds', 'attributes': {
        'identifier': BUNDLE, 'name': 'Science Reader', 'platform': 'IOS', 'seedId': TEAM}}}


def capability_payload(bundle_id):
    require(safe_id(bundle_id), 'bundle_identity_mismatch')
    return {'data': {'type': 'bundleIdCapabilities',
        'attributes': {'capabilityType': CAPABILITY, 'settings': CONSENT},
        'relationships': {'bundleId': {'data': {'type': 'bundleIds', 'id': bundle_id}}}}}


class JSONTransport:
    """Fixed HTTPS hosts, no redirects/retries, bounded request/response bytes.

    Thirty-second I/O allowance; system DNS resolution is not a separately
    supervised hard execution deadline. This is an operator, not a worker.
    """
    def __init__(self, connect=None, clock=time.monotonic):
        self.connect = connect or (lambda host: http.client.HTTPSConnection(
            host, timeout=30, context=ssl.create_default_context()))
        self.clock = clock

    def request(self, host, path, token, method='GET', body=None, expected=200):
        management = host == MANAGEMENT and (
            method == 'GET' and path in ('/v1/projects/' + PROJECT, AUTH_PATH)
            or method == 'PATCH' and path == AUTH_PATH)
        apple = host == APPLE and (
            method == 'GET' and (path in (bundle_query(BUNDLE), bundle_query(REFERENCE_BUNDLE))
                or re.fullmatch(r'/v1/bundleIds/[A-Za-z0-9-]{1,80}/bundleIdCapabilities', path))
            or method == 'POST' and path in ('/v1/bundleIds', '/v1/bundleIdCapabilities'))
        require(management or apple, 'remote_scope_refused')
        require(isinstance(token, str) and 1 <= len(token) <= 16384
                and all(33 <= ord(c) <= 126 for c in token), 'credential_invalid')
        raw = None if body is None else json_bytes(body)
        require(raw is None or len(raw) <= 16384, 'request_limit')
        require((method == 'GET') == (body is None), 'request_shape')
        if method == 'PATCH':
            require(isinstance(body, dict) and body and all(
                k in DESIRED_AUTH and v == DESIRED_AUTH[k] for k, v in body.items()), 'auth_patch_refused')
        connection = response = socket_owner = None
        deadline = self.clock() + 30

        def remaining():
            value = deadline - self.clock()
            require(value > 0, 'transport_timeout')
            owner = connection.sock or socket_owner
            if owner is not None and owner.fileno() >= 0:
                owner.settimeout(value)

        try:
            connection = self.connect(host)
            headers = {'Authorization': 'Bearer ' + token, 'Accept': 'application/json', 'Accept-Encoding': 'identity'}
            if raw is not None:
                headers['Content-Type'] = 'application/json'
            connection.request(method, path, body=raw, headers=headers)
            socket_owner = connection.sock
            remaining()
            response = connection.getresponse()
            require(not 300 <= response.status < 400, 'redirect_refused')
            require(response.getheader('Content-Encoding') in (None, 'identity'), 'response_encoding')
            declared = response.getheader('Content-Length')
            require(declared is None or (re.fullmatch(r'[0-9]{1,9}', declared)
                    and int(declared) <= 262144), 'response_limit')
            data = bytearray()
            while True:
                remaining()
                part = response.read1(min(16384, 262145 - len(data)))
                if not part:
                    break
                data.extend(part)
                require(len(data) <= 262144, 'response_limit')
            remaining()
            require(declared is None or len(data) == int(declared), 'response_truncated')
            require(response.status == expected, 'http_' + str(response.status))
            try:
                value = json.loads(data)
            except (ValueError, UnicodeError):
                raise ConfigurationError('response_not_json') from None
            require(isinstance(value, dict), 'response_shape')
            return value
        except ConfigurationError:
            raise
        except Exception:
            raise ConfigurationError('transport_uncertain') from None
        finally:
            if response is not None:
                response.close()
            if connection is not None:
                connection.close()


def credentials():
    account = json.loads(bounded_file(ROOT / 'infra/account.json', 65536))
    require(account['organization']['slug'] == ORGANIZATION
            and account['projects']['staging']['id'] == PROJECT, 'local_project_guard_failed')
    keychain = subprocess.run(['security', 'find-generic-password', '-s', 'Supabase CLI', '-w'],
                              capture_output=True, text=True, timeout=15)
    require(keychain.returncode == 0 and keychain.stdout.strip(), 'management_credential_unavailable')
    names = {'ASC_KEY_ID', 'ASC_ISSUER_ID', 'ASC_KEY_PATH'}
    locators = {}
    for line in bounded_file(REFERENCE / '.env', 1048576).decode().splitlines():
        match = re.fullmatch(r'\s*(?:export\s+)?(ASC_KEY_ID|ASC_ISSUER_ID|ASC_KEY_PATH)\s*=\s*(.*?)\s*', line)
        if match:
            value = match[2]
            if len(value) > 1 and value[0] == value[-1] and value[0] in "\"'":
                value = value[1:-1]
            require(match[1] not in locators, 'duplicate_asc_locator')
            locators[match[1]] = value
    require(set(locators) == names and re.fullmatch(r'[A-Z0-9]{10}', locators['ASC_KEY_ID'])
            and re.fullmatch(r'[0-9a-fA-F-]{36}', locators['ASC_ISSUER_ID']), 'asc_locator_invalid')
    key = (REFERENCE / locators['ASC_KEY_PATH']).resolve(strict=True)
    require(key.is_relative_to(REFERENCE.resolve()) and key.is_file() and key.stat().st_size <= 16384,
            'asc_key_location_refused')
    node = shutil.which('node')
    require(node is not None, 'node_required_for_asc_signing')
    # Node's built-in crypto handles JOSE's IEEE-P1363 signature. The only
    # child output is captured in memory; no private key/JWT reaches stdout.
    program = """
      const fs=require('node:fs'),crypto=require('node:crypto');
      try {
        const p=JSON.parse(fs.readFileSync(0,'utf8'));
        const bytes=fs.readFileSync(p.path); if(bytes.length>16384)process.exit(1);
        const key=crypto.createPrivateKey(bytes), now=Math.floor(Date.now()/1000);
        const b64=x=>Buffer.from(JSON.stringify(x)).toString('base64url');
        const s=b64({alg:'ES256',kid:p.id,typ:'JWT'})+'.'+b64({iss:p.issuer,iat:now,exp:now+600,aud:'appstoreconnect-v1'});
        process.stdout.write(s+'.'+crypto.sign('sha256',Buffer.from(s),{key,dsaEncoding:'ieee-p1363'}).toString('base64url'));
      } catch {process.exit(1)}
    """
    signed = subprocess.run([node, '-e', program], input=json.dumps({
        'path': str(key), 'id': locators['ASC_KEY_ID'], 'issuer': locators['ASC_ISSUER_ID']}),
        capture_output=True, text=True, timeout=15)
    require(signed.returncode == 0 and re.fullmatch(r'[A-Za-z0-9_.-]{1,16384}', signed.stdout), 'asc_signing_failed')
    return keychain.stdout.strip(), signed.stdout


class Remote:
    def __init__(self, management_token, apple_token, transport=None):
        self.transport = transport or JSONTransport()
        self.management_token, self.apple_token = management_token, apple_token
        self.target_bundle_id = None

    def management(self, path, method='GET', body=None):
        return self.transport.request(MANAGEMENT, path, self.management_token, method, body)

    def apple(self, path, method='GET', body=None):
        if method == 'POST':
            if path == '/v1/bundleIds':
                require(body == bundle_payload(), 'bundle_create_refused')
            elif path == '/v1/bundleIdCapabilities':
                require(self.target_bundle_id is not None
                        and body == capability_payload(self.target_bundle_id), 'capability_create_refused')
            else:
                raise ConfigurationError('apple_write_refused')
        return self.transport.request(APPLE, path, self.apple_token, method, body, 201 if method == 'POST' else 200)

    def project(self):
        row = self.management('/v1/projects/' + PROJECT)
        require(row.get('id') == PROJECT and row.get('name') == 'science-reader-staging'
                and row.get('organization_id') == ORGANIZATION, 'remote_project_guard_failed')

    def bundle(self, identifier=BUNDLE):
        returned = collection(self.apple(bundle_query(identifier)))
        # Apple's filter includes prefix neighbours (for example watch apps).
        # Only the exact identifier can establish ownership or uniqueness.
        rows = [row for row in returned if isinstance(row.get('attributes'), dict)
                and row['attributes'].get('identifier') == identifier]
        require(len(rows) <= 1, 'ambiguous_bundle')
        if not rows:
            if identifier == BUNDLE:
                self.target_bundle_id = None
            return None
        row = rows[0]
        attrs = row.get('attributes', {})
        require(row.get('type') == 'bundleIds' and safe_id(row.get('id'))
                and attrs.get('identifier') == identifier and attrs.get('seedId') == TEAM
                and attrs.get('platform') in ('IOS', 'UNIVERSAL'), 'bundle_identity_mismatch')
        if identifier == BUNDLE:
            self.target_bundle_id = row['id']
        return row['id']

    def capability(self, bundle_id):
        require(safe_id(bundle_id) and bundle_id == self.target_bundle_id, 'bundle_identity_mismatch')
        # Omit optional query parameters: the live relationship endpoint rejects
        # limit=200 despite the published schema. collection still refuses a
        # paginated response instead of treating an incomplete page as absence.
        rows = collection(self.apple('/v1/bundleIds/' + bundle_id + '/bundleIdCapabilities'))
        require(all(isinstance(r.get('attributes'), dict) for r in rows), 'capability_config_shape')
        matches = [r for r in rows if r['attributes'].get('capabilityType') == CAPABILITY]
        require(len(matches) <= 1, 'ambiguous_capability')
        if not matches:
            return False
        row = matches[0]
        require(row.get('type') == 'bundleIdCapabilities' and safe_capability_id(row.get('id')),
                'capability_identity_mismatch')
        settings = row['attributes'].get('settings')
        require(isinstance(settings, list) and len(settings) == 1 and isinstance(settings[0], dict)
                and settings[0].get('key') == 'APPLE_ID_AUTH_APP_CONSENT', 'apple_primary_consent_unverified')
        options = settings[0].get('options')
        require(isinstance(options, list) and len(options) == 1 and isinstance(options[0], dict)
                and options[0].get('key') == 'PRIMARY_APP_CONSENT', 'apple_primary_consent_unverified')
        # The read model makes enabled optional; Apple returns the selected
        # primary option without it. This admits that exact single selection,
        # not a default for absent options or an explicit disabled/ambiguous one.
        require('enabled' not in options[0] or options[0]['enabled'] is True, 'apple_primary_consent_unverified')
        return True

    def auth(self):
        row = self.management(AUTH_PATH)
        required = set(DESIRED_AUTH) | {'external_apple_additional_client_ids', 'external_apple_secret'}
        require(required.issubset(row), 'auth_config_incomplete')
        require(type(row['external_apple_enabled']) is bool
                and type(row['mailer_otp_length']) is int and 1 <= row['mailer_otp_length'] <= 16
                and type(row['mailer_otp_exp']) is int and 1 <= row['mailer_otp_exp'] <= 86400
                and all(isinstance(row[k], str) for k in (
                    'mailer_templates_confirmation_content', 'mailer_templates_magic_link_content')),
                'auth_config_shape')
        require(row.get('disable_signup') is True, 'beta_signups_already_enabled')
        require(row.get('external_apple_client_id') in ('', None, BUNDLE)
                and row.get('external_apple_additional_client_ids') in ('', None)
                and row.get('external_apple_secret') in ('', None), 'existing_apple_oauth_requires_review')
        require(row.get('uri_allow_list') in ('', None, CALLBACK), 'existing_redirects_require_review')
        return row


def safe_id(value):
    return isinstance(value, str) and re.fullmatch(r'[A-Za-z0-9-]{1,80}', value) is not None


def safe_capability_id(value):
    # Apple's opaque capability IDs include underscores. They are read only;
    # bundle IDs used in request paths keep their separate stricter validation.
    return isinstance(value, str) and re.fullmatch(r'[A-Za-z0-9_-]{1,80}', value) is not None


def collection(value):
    rows = value.get('data')
    links = value.get('links', {})
    require(isinstance(rows, list) and len(rows) <= 200 and all(isinstance(r, dict) for r in rows)
            and isinstance(links, dict) and not links.get('next'), 'incomplete_apple_collection')
    return rows


def ensure_once(mutate, readback, matches):
    """One mutation, then GET reconciliation even if its acknowledgement is lost.

    An absent result is not proof of nonacceptance. Stop; a later invocation
    starts from fresh GETs. Server uniqueness protects bundle/capability create.
    """
    try:
        mutate()
    except ConfigurationError:
        # Do not replay an uncertain POST/PATCH, or print its provider body.
        pass
    value = readback()
    require(matches(value), 'mutation_not_confirmed_run_dry_run_before_retry')
    return value


def configure(remote, apply=False):
    remote.project()
    require(remote.bundle(REFERENCE_BUNDLE) is not None, 'apple_team_reference_missing')
    bundle_id = remote.bundle()
    capability = remote.capability(bundle_id) if bundle_id else False
    auth = remote.auth()
    patch = {k: v for k, v in DESIRED_AUTH.items() if auth[k] != v}
    report = {
        'mode': 'apply' if apply else 'dry-run', 'project': PROJECT, 'bundle': BUNDLE,
        'bundle_registration_needed': bundle_id is None, 'apple_capability_needed': not capability,
        'auth_fields_to_update': sorted(patch), 'desired_public_auth_fields': DESIRED_AUTH,
        'signups_remain_disabled': True, 'smtp_or_google_credentials_changed': False,
    }
    if not apply:
        return report
    if bundle_id is None:
        # Fresh GET immediately before create; never modify a foreign bundle.
        bundle_id = remote.bundle()
        if bundle_id is None:
            bundle_id = ensure_once(lambda: remote.apple('/v1/bundleIds', 'POST', bundle_payload()),
                                    remote.bundle, lambda value: value is not None)
    require(remote.bundle() == bundle_id, 'bundle_replaced_during_configuration')
    if not remote.capability(bundle_id):
        ensure_once(lambda: remote.apple('/v1/bundleIdCapabilities', 'POST', capability_payload(bundle_id)),
            lambda: remote.capability(bundle_id), lambda value: value is True)
    # The API has no documented CAS. Refuse observed drift in the fields we
    # own; operators must not concurrently edit these same auth fields.
    remote.project()
    latest = remote.auth()
    require(all(latest[k] == auth[k] or latest[k] == DESIRED_AUTH[k] for k in DESIRED_AUTH),
            'auth_fields_changed_during_configuration')
    patch = {k: v for k, v in DESIRED_AUTH.items() if latest[k] != v}
    if patch:
        ensure_once(lambda: remote.management(AUTH_PATH, 'PATCH', patch), remote.auth,
                    lambda row: all(row[k] == v for k, v in DESIRED_AUTH.items()))
    final = remote.auth()
    require(remote.bundle() == bundle_id and remote.capability(bundle_id)
            and all(final[k] == v for k, v in DESIRED_AUTH.items()), 'final_readback_failed')
    report['configuration_verified'] = True
    report['live_sign_in_verified'] = False
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--project-ref', required=True, choices=[PROJECT])
    parser.add_argument('--apply', action='store_true', help='Apply the reviewed, fixed staging configuration')
    args = parser.parse_args()
    try:
        management, apple = credentials()
        print(json.dumps(configure(Remote(management, apple), apply=args.apply), indent=2, sort_keys=True))
    except ConfigurationError as error:
        print(json.dumps({'error': str(error), 'configuration_verified': False}))
        return 1
    except Exception:
        print(json.dumps({'error': 'configuration_check_failed', 'configuration_verified': False}))
        return 1
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
