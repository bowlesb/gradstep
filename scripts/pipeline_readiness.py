"""Read-only cutover observations and evidence-checked worker activation.

No observation of a clock, zero traffic or expired lease establishes process
termination. The external drain documents are an operator attestation; this
module verifies their scope/integrity and current DB/config preconditions.
"""
import copy
import datetime as dt
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import subprocess
import time
import urllib.error
import urllib.parse
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
PROJECT = 'gradstep'
PROJECT_NUMBER = '885355087025'
REGION = 'us-west1'
SERVICE = 'gradstep-pipeline'
SUPABASE_PROJECT = 'coxhjvqpflgxkleydati'
ORGANIZATION = 'mhiweqpcwyqtyorgqhla'
SERVICE_NAME = f'projects/{PROJECT}/locations/{REGION}/services/{SERVICE}'
SERVICE_URL = f'https://{SERVICE}-{PROJECT_NUMBER}.{REGION}.run.app'
SECRET_NAMES = ('SUPABASE_URL', 'SUPABASE_SERVICE_ROLE_KEY', 'MATHPIX_APP_ID', 'MATHPIX_APP_KEY',
                'PIPELINE_SECRET', 'ANTHROPIC_API_KEY')
REQUIRED_MIGRATIONS = {f'2026100700{number}' for number in range(34, 39)}
EVIDENCE_KINDS = {'old_cloud_run_invocations_terminated', 'old_edge_invocations_terminated',
                  'admitted_edge_deployments_verified', 'legacy_liabilities_reviewed'}
SCOPE = {'project': PROJECT, 'region': REGION, 'service': SERVICE, 'supabase_project': SUPABASE_PROJECT}
SPEC = importlib.util.spec_from_file_location('readiness_migration_ledger', Path(__file__).with_name('migration_ledger.py'))
LEDGER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(LEDGER)

# Aggregates only. Do not include credentials, provider content, user identities,
# object paths or private request payloads in the saved readiness report.
STATE_SQL = """select jsonb_build_object(
 'budget',(select jsonb_build_object('period',period,'enabled',work_enabled,'spent_microusd',spent_microusd,
  'reserved_microusd',reserved_microusd,'limit_microusd',limit_microusd) from app_private.platform_budgets
  where period=date_trunc('month',now() at time zone 'UTC')::date),
 'pipeline_enabled',(select enabled from app_private.pipeline_policy where singleton),
 'tags_enabled',(select enabled from app_private.tag_policy where singleton),
 'provider_enabled',(select enabled from app_private.provider_spending_policy where singleton),
 'native_search_enabled',(select native_search_enabled from app_private.provider_spending_policy where singleton),
 'pipeline_claims',(select count(*) from app_private.pipeline_papers where claim_id is not null),
 'tag_claims',(select count(*) from app_private.catalog_tags where claim_id is not null),
 'legacy_open_chat',(select count(*) from app_private.metered_operations where kind='chat' and state<>'settled' and not attempt_accounting),
 'provider_unresolved',(select count(*) from app_private.provider_attempts where state in ('admitted','unknown')),
 'provider_liability_microusd',(select coalesce(sum(provider_liability_microusd),0) from app_private.metered_operations),
 'asset_writes_unresolved',(select count(*) from app_private.paper_asset_write_attempts where finished_at is null),
 'asset_enforced',(select enforced from app_private.paper_asset_policy where singleton),
 'inventory_verified_at',(select inventory_verified_at from app_private.paper_asset_policy where singleton),
 'inventory_discrepancies',(select inventory_discrepancies from app_private.paper_asset_policy where singleton),
 'inventory_scan_active',(select reconciliation_id is not null from app_private.paper_asset_policy where singleton),
 'reader_mode',(select mode from app_private.reader_delivery_policy where singleton),
 'purchase_cleanup',public.worker_store_verification_readiness()->'cleanup'
) as state"""


class ReadinessError(RuntimeError):
    pass


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        raise ReadinessError('readiness_redirect_refused')


def json_request(url, *, token=None, payload=None, method=None):
    parsed = urllib.parse.urlsplit(url)
    if parsed.scheme != 'https' or parsed.username or parsed.password or parsed.fragment:
        raise ReadinessError('readiness_request_scope')
    if parsed.hostname == 'api.supabase.com':
        if not re.fullmatch(r'/v1/projects/' + SUPABASE_PROJECT + r'(?:/database/query)?', parsed.path):
            raise ReadinessError('readiness_project_scope')
    elif parsed.hostname == 'run.googleapis.com':
        if not re.fullmatch(r'/v2/projects/(?:' + PROJECT + '|' + PROJECT_NUMBER + r')/locations/' + REGION +
                            r'/(?:services/' + SERVICE + r'|operations/[a-zA-Z0-9-]+)', parsed.path):
            raise ReadinessError('readiness_service_scope')
    elif url != SERVICE_URL + '/health' or token is not None or payload is not None:
        raise ReadinessError('readiness_request_scope')
    headers = {'Content-Type': 'application/json'}
    if token:
        headers['Authorization'] = 'Bearer ' + token
    request = urllib.request.Request(url, data=None if payload is None else json.dumps(payload).encode(), headers=headers, method=method)
    try:
        with urllib.request.build_opener(NoRedirect).open(request, timeout=30) as response:
            raw = response.read(1048577)
        if len(raw) > 1048576:
            raise ReadinessError('readiness_response_limit')
        return json.loads(raw)
    except urllib.error.HTTPError as error:
        raise ReadinessError(f'readiness_http_{error.code}') from None
    except (urllib.error.URLError, TimeoutError, ValueError, OSError):
        raise ReadinessError('readiness_transport_failed') from None


def credential(command):
    result = subprocess.run(command, capture_output=True, text=True)
    if result.returncode or not result.stdout.strip():
        raise ReadinessError('readiness_credential_unavailable')
    return result.stdout.strip()


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(',', ':')).encode()).hexdigest()


def activation_template(template):
    """Compare all reviewed runtime settings, ignoring only generated revision/build metadata."""
    value = copy.deepcopy(template)
    value.pop('revision', None)
    for container in value.get('containers', []):
        container.pop('buildInfo', None)  # Output-only image metadata.
        if 'env' in container:
            container['env'] = sorted(container['env'], key=lambda item: item['name'])
    return value


def require_scope(project, region):
    if project != PROJECT or region != REGION:
        raise ReadinessError('readiness_scope_mismatch')


def pinned_secrets(container, *, v1=False):
    """Known secret references and numeric versions only; never read/return values."""
    versions = {}
    for name in SECRET_NAMES:
        entries = [row for row in container.get('env', []) if row.get('name') == name]
        if len(entries) != 1 or 'value' in entries[0]:
            return None
        reference = entries[0].get('valueFrom' if v1 else 'valueSource', {}).get('secretKeyRef', {})
        secret, version = reference.get('name' if v1 else 'secret'), reference.get('key' if v1 else 'version')
        expected = 'gradstep-' + name.lower().replace('_', '-')
        if secret not in (expected, f'projects/{PROJECT}/secrets/{expected}', f'projects/{PROJECT_NUMBER}/secrets/{expected}'):
            return None
        if not isinstance(version, str) or not re.fullmatch(r'[1-9][0-9]*', version):
            return None
        versions[name] = version
    return versions


def service_policy(service):
    template = service.get('template', {})
    containers = template.get('containers', [])
    container = containers[0] if len(containers) == 1 else {}
    resources = container.get('resources', {})
    maintenance = [item.get('value') for item in container.get('env', []) if item.get('name') == 'PIPELINE_MAINTENANCE']
    # Only the known non-secret switch is reported, never arbitrary env values.
    return {
        'revision': service.get('latestReadyRevision', '').rsplit('/', 1)[-1],
        'created_revision': service.get('latestCreatedRevision', '').rsplit('/', 1)[-1],
        'stable': service.get('reconciling', False) is False and service.get('generation') == service.get('observedGeneration')
                  and service.get('terminalCondition', {}).get('state') == 'CONDITION_SUCCEEDED',
        'service_min': service.get('scaling', {}).get('minInstanceCount', 0),
        'service_max': service.get('scaling', {}).get('maxInstanceCount'),
        'revision_min': template.get('scaling', {}).get('minInstanceCount', 0),
        'revision_max': template.get('scaling', {}).get('maxInstanceCount'),
        'concurrency': template.get('maxInstanceRequestConcurrency'), 'timeout': template.get('timeout'),
        'cpu_idle': resources.get('cpuIdle'), 'cpu': resources.get('limits', {}).get('cpu'),
        'memory': resources.get('limits', {}).get('memory'), 'container_count': len(containers),
        'maintenance': maintenance[0] if len(maintenance) == 1 and maintenance[0] in ('true', 'false') else None,
        'secret_versions': pinned_secrets(container),
        'service_account': template.get('serviceAccount'),
        'traffic': [{'revision': item.get('revision', '').rsplit('/', 1)[-1], 'percent': item.get('percent', 0)}
                    for item in service.get('trafficStatuses', [])],
    }


def verify_service(service, expected_revision, maintenance):
    if service.get('name') not in (SERVICE_NAME, SERVICE_NAME.replace('/' + PROJECT + '/', '/' + PROJECT_NUMBER + '/')):
        raise ReadinessError('readiness_service_identity')
    if SERVICE_URL not in [service.get('uri'), *service.get('urls', [])] or not service.get('etag') or not service.get('uid'):
        raise ReadinessError('readiness_service_identity')
    if not re.fullmatch(SERVICE + r'-[a-z0-9-]+', expected_revision or ''):
        raise ReadinessError('readiness_revision_required')
    policy = service_policy(service)
    expected = {'revision': expected_revision, 'created_revision': expected_revision, 'stable': True,
                'service_min': 0, 'service_max': 3, 'revision_min': 0, 'revision_max': 3,
                'concurrency': 1, 'timeout': '900s', 'cpu_idle': True, 'container_count': 1,
                'maintenance': 'true' if maintenance else 'false',
                'service_account': f'{SERVICE}@{PROJECT}.iam.gserviceaccount.com',
                'traffic': [{'revision': expected_revision, 'percent': 100}]}
    failures = [name for name, value in expected.items() if policy.get(name) != value]
    if policy['cpu'] not in ('1', '1000m'):
        failures.append('cpu')
    if policy['memory'] not in ('2Gi', '2048Mi', '2147483648'):
        failures.append('memory')
    if policy['secret_versions'] is None:
        failures.append('secret_versions')
    if failures:
        raise ReadinessError('readiness_configuration_mismatch: ' + ','.join(failures))
    return policy


def immutable_image(revision):
    result = subprocess.run(['gcloud', 'run', 'revisions', 'describe', revision, '--project', PROJECT,
                             '--region', REGION, '--format=json'], capture_output=True, text=True)
    if result.returncode:
        raise ReadinessError('readiness_revision_unavailable')
    try:
        value = json.loads(result.stdout)
        if value.get('metadata', {}).get('name') != revision or str(value.get('metadata', {}).get('namespace')) != PROJECT_NUMBER:
            raise ReadinessError('readiness_revision_identity')
        image = value.get('status', {}).get('imageDigest', '')
        if not re.fullmatch(REGION + r'-docker\.pkg\.dev/' + PROJECT + r'/cloud-run-source-deploy/' + SERVICE + r'@sha256:[0-9a-f]{64}', image):
            raise ReadinessError('readiness_image_digest')
        return image
    except (ValueError, TypeError):
        raise ReadinessError('readiness_revision_invalid') from None


def database_observation(management):
    base = 'https://api.supabase.com/v1/projects/' + SUPABASE_PROJECT
    remote = json_request(base, token=management)
    if not isinstance(remote, dict) or remote.get('organization_id') != ORGANIZATION or remote.get('name') != 'science-reader-staging':
        raise ReadinessError('readiness_database_identity')
    rows = json_request(base + '/database/query', token=management,
                        payload={'query': 'select version,sha256 from science_reader_migrations.versions', 'read_only': True})
    if not isinstance(rows, list) or any(not isinstance(row, dict) or set(row) != {'version', 'sha256'} for row in rows):
        raise ReadinessError('readiness_migration_ledger')
    applied = {row['version']: row['sha256'] for row in rows}
    if len(applied) != len(rows):
        raise ReadinessError('readiness_migration_ledger')
    sources = LEDGER.source_ledger(ROOT / 'supabase/migrations')
    LEDGER.verify_applied_prefix(applied, sources)
    if not REQUIRED_MIGRATIONS <= set(applied):
        return {'migration_prefix_verified': False, 'missing_migrations': sorted(REQUIRED_MIGRATIONS - set(applied)), 'state': None}
    rows = json_request(base + '/database/query', token=management, payload={'query': STATE_SQL, 'read_only': True})
    if not isinstance(rows, list) or len(rows) != 1 or not isinstance(rows[0].get('state'), dict):
        raise ReadinessError('readiness_database_state')
    return {'migration_prefix_verified': True, 'required_hashes': {name: applied[name] for name in sorted(REQUIRED_MIGRATIONS)},
            'state': rows[0]['state']}


def database_blockers(database):
    if database.get('migration_prefix_verified') is not True:
        return ['required_migrations_missing']
    state = database.get('state') or {}
    blockers = []
    for name in ('pipeline_enabled', 'tags_enabled', 'native_search_enabled', 'inventory_scan_active'):
        if state.get(name) is not False:
            blockers.append(name + '_not_false')
    if (state.get('budget') or {}).get('enabled') is not False:
        blockers.append('budget_not_paused')
    for name in ('pipeline_claims', 'legacy_open_chat', 'asset_writes_unresolved', 'inventory_discrepancies'):
        if type(state.get(name)) is not int or state[name] != 0:
            blockers.append(name + '_not_zero')
    if state.get('asset_enforced') is not True or not state.get('inventory_verified_at'):
        blockers.append('asset_inventory_not_enforced')
    if state.get('reader_mode') not in ('legacy', 'dual', 'bounded'):
        blockers.append('reader_mode_unrecognized')
    cleanup = state.get('purchase_cleanup') or {}
    if cleanup.get('active') is not True or cleanup.get('expected_command') is not True or cleanup.get('schedule') != '17 * * * *':
        blockers.append('purchase_cleanup_not_ready')
    # Provider uncertainty and retained tag claims are observations, never an
    # instruction to zero reserves. Their exact state must be covered by evidence.
    for name in ('tag_claims', 'provider_unresolved', 'provider_liability_microusd'):
        if type(state.get(name)) is not int or state[name] < 0:
            blockers.append(name + '_invalid')
    return blockers


def verify_evidence(path, report):
    try:
        with Path(path).open('rb') as stream:
            raw = stream.read(65537)
        if len(raw) > 65536:
            raise ReadinessError('drain_evidence_limit')
        evidence = json.loads(raw)
        if evidence.get('format') != 1 or evidence.get('decision') != 'approved' or evidence.get('scope') != SCOPE:
            raise ReadinessError('drain_evidence_scope')
        for name in ('revision', 'image_digest', 'database_sha256', 'configuration_sha256'):
            if evidence.get(name) != report.get(name):
                raise ReadinessError('drain_evidence_stale_' + name)
        observed = dt.datetime.fromisoformat(evidence['observed_at'].replace('Z', '+00:00'))
        if observed.tzinfo is None or not dt.timedelta(minutes=-5) <= dt.datetime.now(dt.timezone.utc) - observed <= dt.timedelta(days=1):
            raise ReadinessError('drain_evidence_date')
        documents = evidence.get('documents')
        if not isinstance(documents, list) or len(documents) != len(EVIDENCE_KINDS) or any(not isinstance(row, dict) for row in documents) or {row.get('kind') for row in documents} != EVIDENCE_KINDS:
            raise ReadinessError('drain_evidence_documents')
        root = (ROOT / '.artifacts/rollout-evidence').resolve()
        for document in documents:
            relative, expected = document.get('path'), document.get('sha256')
            if not isinstance(relative, str) or not re.fullmatch(r'[A-Za-z0-9._/-]{1,240}', relative) or not re.fullmatch(r'[0-9a-f]{64}', expected or ''):
                raise ReadinessError('drain_evidence_document_identity')
            target = (ROOT / relative).resolve()
            if root not in target.parents or target.stat().st_size > 32 * 1024 * 1024:
                raise ReadinessError('drain_evidence_document_scope')
            with target.open('rb') as stream:
                contents = stream.read(32 * 1024 * 1024 + 1)
            if len(contents) > 32 * 1024 * 1024:
                raise ReadinessError('drain_evidence_document_scope')
            if hashlib.sha256(contents).hexdigest() != expected:
                raise ReadinessError('drain_evidence_document_changed')
        return {'status': 'operator_attestation_verified_for_scope_and_integrity', 'manifest_sha256': hashlib.sha256(raw).hexdigest()}
    except (KeyError, TypeError, ValueError, OSError):
        raise ReadinessError('drain_evidence_invalid') from None


def observe(project, region, expected_revision, evidence_path=None):
    require_scope(project, region)
    google = credential(['gcloud', 'auth', 'print-access-token'])
    management = credential(['security', 'find-generic-password', '-s', 'Supabase CLI', '-w'])
    service = json_request('https://run.googleapis.com/v2/' + SERVICE_NAME, token=google)
    policy = verify_service(service, expected_revision, maintenance=True)
    image = immutable_image(expected_revision)
    health = json_request(SERVICE_URL + '/health')
    if health != {'ok': True, 'mode': 'maintenance', 'revision': expected_revision}:
        raise ReadinessError('readiness_maintenance_health_mismatch')
    database = database_observation(management)
    report = {'format': 1, 'scope': SCOPE, 'observed_at': dt.datetime.now(dt.timezone.utc).isoformat(),
              'revision': expected_revision, 'image_digest': image, 'configuration': policy,
              'configuration_sha256': digest({'uid': service['uid'], 'etag': service['etag'], 'policy': policy, 'template': service['template']}),
              'database': database, 'database_sha256': digest(database),
              'blockers': database_blockers(database), 'external_evidence': {'status': 'required'},
              'limitations': ['Zero traffic, elapsed HTTP timeout, expired leases and empty queues do not prove old invocations terminated.',
                              'External termination and legacy-liability evidence is an operator attestation, not independently established by these APIs.',
                              'Unknown provider liabilities remain reserved; this command never releases a hold or clears a claim.',
                              'Legacy/dual signed reader URLs remain replayable; activation does not establish bounded-only delivery.']}
    if evidence_path:
        report['external_evidence'] = verify_evidence(evidence_path, report)
    else:
        report['blockers'].append('operator_drain_evidence_required')
    report['ready_for_activation'] = not report['blockers']
    return report, service, google


def activate(project, region, expected_revision, evidence_path):
    report, service, google = observe(project, region, expected_revision, evidence_path)
    if not report['ready_for_activation']:
        raise ReadinessError('activation_preconditions_failed: ' + ','.join(report['blockers']))
    # Update the exact observed service version with optimistic concurrency.
    # A concurrent deployment/configuration edit must reject this ETag, not be
    # overwritten by activation. The image is the observed immutable digest.
    containers = copy.deepcopy(service['template']['containers'])
    containers[0]['image'] = report['image_digest']
    containers[0].pop('buildInfo', None)  # Output-only API field.
    containers[0]['env'] = [item for item in containers[0].get('env', []) if item.get('name') != 'PIPELINE_MAINTENANCE']
    containers[0]['env'].append({'name': 'PIPELINE_MAINTENANCE', 'value': 'false'})
    expected_template = {**service['template'], 'containers': containers}
    payload = {'name': service['name'], 'etag': service['etag'], 'template': {'revision': '', 'containers': containers},
               'traffic': [{'type': 'TRAFFIC_TARGET_ALLOCATION_TYPE_LATEST', 'percent': 100}]}
    operation = json_request('https://run.googleapis.com/v2/' + SERVICE_NAME +
                             '?updateMask=template.revision,template.containers,traffic', token=google, payload=payload, method='PATCH')
    deadline = time.monotonic() + 600
    while operation.get('done') is not True:
        if time.monotonic() >= deadline:
            raise ReadinessError('activation_acknowledgement_unknown_inspect_before_retry')
        name = operation.get('name', '')
        if not re.fullmatch(r'projects/(?:' + PROJECT + '|' + PROJECT_NUMBER + r')/locations/' + REGION + r'/operations/[a-zA-Z0-9-]+', name):
            raise ReadinessError('activation_operation_scope')
        time.sleep(2)
        operation = json_request('https://run.googleapis.com/v2/' + name, token=google)
    if operation.get('error'):
        raise ReadinessError('activation_operation_failed_inspect_before_retry')
    result = operation.get('response') or {}
    if result.get('name') != service['name'] or not isinstance(result.get('latestReadyRevision'), str):
        raise ReadinessError('activation_result_missing_inspect_before_retry')
    revision = result['latestReadyRevision'].rsplit('/', 1)[-1]
    updated = json_request('https://run.googleapis.com/v2/' + SERVICE_NAME, token=google)
    if revision == expected_revision:
        raise ReadinessError('activation_revision_unchanged')
    policy = verify_service(updated, revision, maintenance=False)
    if activation_template(updated['template']) != activation_template(expected_template):
        raise ReadinessError('activation_configuration_changed_inspect_before_retry')
    if immutable_image(revision) != report['image_digest']:
        raise ReadinessError('activation_image_changed')
    if json_request(SERVICE_URL + '/health') != {'ok': True, 'mode': 'active', 'revision': revision}:
        raise ReadinessError('activation_health_mismatch')
    return {'activated_revision': revision, 'configuration': policy, 'evidence_manifest_sha256': report['external_evidence']['manifest_sha256'],
            'policies_and_scheduler_unchanged': True, 'workflow_checks_run': False}
