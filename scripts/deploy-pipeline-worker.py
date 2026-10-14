#!/usr/bin/env python3
"""Build and deploy the Gradstep paper pipeline worker (docs/architecture/PIPELINE_RELIABILITY.md).

  python3 scripts/deploy-pipeline-worker.py build            # local Docker image (gradstep-pipeline:local)
  python3 scripts/deploy-pipeline-worker.py run              # run that image locally against staging
  python3 scripts/deploy-pipeline-worker.py deploy --project <gcp-project> [--region us-west1]
  python3 scripts/deploy-pipeline-worker.py deploy --project gradstep --defer-activation
  python3 scripts/deploy-pipeline-worker.py readiness --project gradstep --expected-revision <paused-revision>
  python3 scripts/deploy-pipeline-worker.py activate --project gradstep --expected-revision <paused-revision> --evidence <manifest>
  python3 scripts/deploy-pipeline-worker.py cutover          # point staging's pg_cron/pg_net at the service
  python3 scripts/deploy-pipeline-worker.py retry-failed --label <deploy>  # legacy operator tool; never called by deploy

Secrets come from .env.staging / .env.providers into Secret Manager (deploy) or the
container environment (run); values are never printed. Deferred deploys do not
retry imports or run workflow checks. Activation leaves DB policies and the
scheduler paused; it requires reviewed external termination evidence.
"""
import argparse, importlib.util, json, os, re, shutil, subprocess, tempfile, time, urllib.error, urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SERVICE = 'gradstep-pipeline'
SPEC = importlib.util.spec_from_file_location('pipeline_readiness', Path(__file__).with_name('pipeline_readiness.py'))
READINESS = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(READINESS)
# ANTHROPIC_API_KEY: Claude Haiku topic tags (docs/architecture/TAGS.md); the Science Reader key, as for chat.
SECRETS = READINESS.SECRET_NAMES

def dotenv(path):
    values = {}
    for line in path.read_text().splitlines():
        if '=' in line and not line.lstrip().startswith('#'):
            k, v = line.split('=', 1); values[k.strip()] = v.strip().strip('"').strip("'")
    return values

def secrets():
    values = {**dotenv(ROOT / '.env.providers'), **dotenv(ROOT / '.env.staging')}
    assert values.get('SUPABASE_PROJECT_REF') == 'coxhjvqpflgxkleydati', 'staging only'
    missing = [name for name in SECRETS if not values.get(name)]
    if missing: raise SystemExit('missing: ' + ', '.join(missing))
    return {name: values[name] for name in SECRETS}

def context():
    """The build context: the worker directory plus the shared pipeline modules (no tests, no apps)."""
    target = Path(tempfile.mkdtemp(prefix='gradstep-pipeline-'))
    for name in ['Dockerfile', 'package.json', 'package-lock.json', 'server.ts', 'run.ts', 'podcast-run.ts', 'podcast-encode.ts']:
        shutil.copy(ROOT / 'services/pipeline-worker' / name, target / name)
    shutil.copytree(ROOT / 'supabase/functions/_shared', target / 'supabase/functions/_shared',
                    ignore=shutil.ignore_patterns('node_modules', '*.test.ts'))
    return target

def build():
    path = context()
    subprocess.run(['docker', 'build', '--platform', 'linux/amd64', '-t', f'{SERVICE}:local', str(path)], check=True)
    print('Built', f'{SERVICE}:local')

def run():
    env = {**secrets(), 'PIPELINE_MAINTENANCE': 'false'}
    args = ['docker', 'run', '--rm', '--platform', 'linux/amd64', '-p', '127.0.0.1:18080:8080', '--memory', '2g']
    for name in env: args += ['-e', name]
    subprocess.run(args + [f'{SERVICE}:local'], check=True, env={**os.environ, **env})

def gcloud(*args, input=None, capture=False):
    return subprocess.run(['gcloud', *args], check=True, input=input, text=True, capture_output=capture)

PODCAST_ENV = ('PODCAST_SPEECH_SERVICE_ACCOUNT', 'PODCAST_GCP_PROJECT')

def podcast_env():
    """Nonsecret speech identity (docs/architecture/PAPER_PODCASTS.md): the dedicated service account the
    worker impersonates for Vertex AI. Absent until the operator creates it; generated podcast jobs then stay queued."""
    config = json.loads((ROOT / 'infra/staging.json').read_text()).get('podcast_speech') or {}
    account, project = config.get('service_account'), config.get('project', 'gradstep')
    if not account: return {}
    if not re.fullmatch(r'[a-z][a-z0-9-]{4,28}[a-z0-9]@[a-z][a-z0-9-]{4,28}[a-z0-9]\.iam\.gserviceaccount\.com', account) \
            or not re.fullmatch(r'[a-z][a-z0-9-]{4,28}[a-z0-9]', project):
        raise SystemExit('invalid podcast_speech configuration')
    return {'PODCAST_SPEECH_SERVICE_ACCOUNT': account, 'PODCAST_GCP_PROJECT': project}

def deployment_args(project, region, image, account, mapping, *, deferred=False, extra_env=None):
    # Request-based billing depends on server.ts awaiting and joining its bounded worker thread.
    # Set both scopes: a revision-only maximum leaves the service ceiling at its old value.
    env = 'PIPELINE_MAINTENANCE=' + ('true' if deferred else 'false')
    for name, value in sorted((extra_env or {}).items()):
        if name not in PODCAST_ENV: raise ValueError('unexpected environment variable')
        env += f',{name}={value}'
    return ['run', 'deploy', SERVICE, '--project', project, '--region', region, '--image', image,
            '--memory', '2Gi', '--cpu', '1', '--concurrency', '1', '--max', '3', '--min', '0',
            '--max-instances', '3', '--min-instances', '0', '--timeout', '900', '--cpu-throttling',
            '--allow-unauthenticated', '--service-account', account, '--set-secrets', mapping,
            '--update-env-vars', env, '--quiet']

def deployment_policy(service):
    """Allowlisted, nonsecret shape used by deployment verification and spending inspection."""
    annotations = service.get('metadata', {}).get('annotations', {})
    template = service.get('spec', {}).get('template', {})
    revision = template.get('metadata', {}).get('annotations', {})
    spec = template.get('spec', {})
    containers = spec.get('containers', [])
    resources = containers[0].get('resources', {}).get('limits', {}) if len(containers) == 1 else {}
    switches = [entry.get('value') for entry in containers[0].get('env', []) if entry.get('name') == 'PIPELINE_MAINTENANCE'] if len(containers) == 1 else []
    return {
        'revision': service.get('status', {}).get('latestReadyRevisionName'),
        'maintenance': switches[0] if len(switches) == 1 and switches[0] in ('true', 'false') else None,
        'secret_versions': READINESS.pinned_secrets(containers[0], v1=True) if len(containers) == 1 else None,
        'cpu_throttling': revision.get('run.googleapis.com/cpu-throttling', 'true'),
        'service_min': annotations.get('run.googleapis.com/minScale', '0'),
        'service_max': annotations.get('run.googleapis.com/maxScale'),
        'revision_min': revision.get('autoscaling.knative.dev/minScale', '0'),
        'revision_max': revision.get('autoscaling.knative.dev/maxScale'),
        'concurrency': spec.get('containerConcurrency'), 'timeout_seconds': spec.get('timeoutSeconds'),
        'cpu': resources.get('cpu'), 'memory': resources.get('memory'),
        'container_count': len(containers),
        'traffic': [{'revision': row.get('revisionName'), 'percent': row.get('percent', 0)}
                    for row in service.get('status', {}).get('traffic', [])],
    }

def verify_policy(policy, *, maintenance=None):
    expected = {'cpu_throttling': 'true', 'service_min': '0', 'service_max': '3',
                'revision_min': '0', 'revision_max': '3', 'concurrency': 1,
                'timeout_seconds': 900, 'container_count': 1}
    mismatches = [name for name, value in expected.items() if policy.get(name) != value]
    if maintenance is not None and policy.get('maintenance') != ('true' if maintenance else 'false'):
        mismatches.append('maintenance')
    if maintenance is not None and policy.get('secret_versions') is None:
        mismatches.append('secret_versions')
    if policy.get('cpu') not in ('1', '1000m'): mismatches.append('cpu')
    if policy.get('memory') not in ('2Gi', '2048Mi', '2147483648'): mismatches.append('memory')
    traffic = policy.get('traffic', [])
    if not policy.get('revision') or traffic != [{'revision': policy['revision'], 'percent': 100}]:
        mismatches.append('traffic')
    if mismatches: raise RuntimeError('pipeline_configuration_mismatch: ' + ', '.join(mismatches))

def describe_service(project, region):
    READINESS.require_scope(project, region)
    value = json.loads(gcloud('run', 'services', 'describe', SERVICE, '--project', project, '--region', region,
                              '--format', 'json', capture=True).stdout)
    metadata = value.get('metadata', {})
    if metadata.get('name') != SERVICE or str(metadata.get('namespace')) != READINESS.PROJECT_NUMBER:
        raise RuntimeError('pipeline_service_identity_mismatch')
    return value


def verify_health(maintenance, revision=None):
    health = READINESS.json_request(READINESS.SERVICE_URL + '/health')
    if not isinstance(health, dict) or health.get('ok') is not True or health.get('mode') != ('maintenance' if maintenance else 'active'):
        raise RuntimeError('pipeline_activation_state_mismatch')
    if revision is not None and health.get('revision') != revision:
        raise RuntimeError('pipeline_health_revision_mismatch')
    return health


def upload_secrets(project, env, account):
    """Bind each created version, not latest, so activation preserves reviewed inputs."""
    mapping = []
    for name, value in env.items():
        secret = f'gradstep-{name.lower().replace("_", "-")}'
        exists = subprocess.run(['gcloud', 'secrets', 'describe', secret, '--project', project], capture_output=True).returncode == 0
        if not exists: gcloud('secrets', 'create', secret, '--project', project, '--replication-policy', 'automatic', capture=True)
        created = gcloud('secrets', 'versions', 'add', secret, '--project', project, '--data-file=-', '--format=value(name)', input=value, capture=True).stdout.strip()
        version = re.fullmatch(r'projects/(?:' + re.escape(project) + '|' + READINESS.PROJECT_NUMBER + r')/secrets/' + re.escape(secret) + r'/versions/([1-9][0-9]*)', created)
        if not version:
            # A lost/changed acknowledgement must not fall back to a mutable alias.
            raise RuntimeError('pipeline_secret_version_unverified')
        mapping.append(f'{name}={secret}:{version.group(1)}')
        gcloud('secrets', 'add-iam-policy-binding', secret, '--project', project, '--member', f'serviceAccount:{account}',
               '--role', 'roles/secretmanager.secretAccessor', capture=True)
    return ','.join(mapping)


def deploy(project, region, *, deferred=False):
    READINESS.require_scope(project, region)
    # An ordinary deployment must never implicitly clear a maintenance barrier.
    # Unknown older revisions also require the reviewed deferred cutover path.
    if not deferred:
        previous = deployment_policy(describe_service(project, region))
        verify_policy(previous, maintenance=False)
        verify_health(False, previous['revision'])
    env = secrets()
    # A dedicated runtime identity that can read only these secrets.
    account = f'{SERVICE}@{project}.iam.gserviceaccount.com'
    if subprocess.run(['gcloud', 'iam', 'service-accounts', 'describe', account, '--project', project], capture_output=True).returncode != 0:
        gcloud('iam', 'service-accounts', 'create', SERVICE, '--project', project, '--display-name', 'Gradstep pipeline worker', capture=True)
    mapping = upload_secrets(project, env, account)
    # Built here (linux/amd64) and pushed, so Cloud Build's default account needs no extra roles.
    repository = 'cloud-run-source-deploy'
    if subprocess.run(['gcloud', 'artifacts', 'repositories', 'describe', repository, '--project', project, '--location', region], capture_output=True).returncode != 0:
        gcloud('artifacts', 'repositories', 'create', repository, '--project', project, '--location', region, '--repository-format', 'docker', capture=True)
    tag = subprocess.run(['git', 'rev-parse', '--short', 'HEAD'], cwd=ROOT, capture_output=True, text=True, check=True).stdout.strip()
    image = f'{region}-docker.pkg.dev/{project}/{repository}/{SERVICE}:{tag}-{int(time.time())}'
    gcloud('auth', 'configure-docker', f'{region}-docker.pkg.dev', '--quiet', capture=True)
    subprocess.run(['docker', 'build', '--platform', 'linux/amd64', '-t', image, str(context())], check=True)
    subprocess.run(['docker', 'push', image], check=True)
    gcloud(*deployment_args(project, region, image, account, mapping, deferred=deferred, extra_env=podcast_env()))
    service = describe_service(project, region)
    policy = deployment_policy(service)
    verify_policy(policy, maintenance=deferred)
    verify_health(deferred, policy['revision'])
    print('Verified pipeline configuration', json.dumps(policy, sort_keys=True))
    url = service['status']['url']
    print('Deployed', url)
    return image.rsplit(':', 1)[1]

def retry_failed(label):
    """A deploy is when a code bug stops being one: every failed paper that can resume without
    charge (metadata, download, render; not too_large) is retried once per deploy label
    (migration 027, worker_pipeline_retry_failed). Prints counts only."""
    verify_health(False)
    env = secrets()
    request = urllib.request.Request(env['SUPABASE_URL'].rstrip('/') + '/rest/v1/rpc/worker_pipeline_retry_failed',
        data=json.dumps({'p_deploy': label}).encode(), method='POST',
        headers={'apikey': env['SUPABASE_SERVICE_ROLE_KEY'], 'Authorization': 'Bearer ' + env['SUPABASE_SERVICE_ROLE_KEY'],
                 'Content-Type': 'application/json'})
    try:
        with urllib.request.urlopen(request, timeout=60) as response: result = json.load(response)
    except urllib.error.HTTPError as error:
        print(f'Retry after deploy skipped (HTTP {error.code}; is migration 027 applied?)'); return
    print(f"Retry after deploy {label}: {result.get('papers', 0)} failed paper(s) retried once, "
          f"{result.get('retried', 0)} with readers waiting; {result.get('healed', 0)} import(s) healed")

def cutover(url):
    """Point staging's scheduler and import trigger at the worker (Vault: science_reader_pipeline_url)."""
    values = dotenv(ROOT / '.env.staging')
    token = subprocess.run(['security', 'find-generic-password', '-s', 'Supabase CLI', '-w'], capture_output=True, text=True, check=True).stdout.strip()
    literal = "'" + url.replace("'", "''") + "'"
    query = f"select vault.update_secret((select id from vault.secrets where name='science_reader_pipeline_url'),{literal})"
    request = urllib.request.Request(f"https://api.supabase.com/v1/projects/{values['SUPABASE_PROJECT_REF']}/database/query",
        data=json.dumps({'query': query}).encode(), headers={'Authorization': 'Bearer ' + token, 'Content-Type': 'application/json'})
    with urllib.request.urlopen(request, timeout=60) as response: response.read()
    print('Staging pipeline URL now', url)

def workflow_checks():
    """The free deploy suite (docs/architecture/WORKFLOW_CHECKS.md): the Vault URL is this service,
    it answers /health and refuses calls without the secret, the scheduler reaches it, nothing is
    stuck, and an arXiv paper imports to ready through it."""
    verify_health(False)
    print('Running workflow checks (deploy suite; --skip-checks to opt out)', flush=True)
    checks = subprocess.run(['node', str(ROOT / 'scripts/workflow-checks.mjs'), '--suite=deploy', '--trigger=deploy-pipeline-worker', '--record'], cwd=ROOT)
    if checks.returncode != 0:
        raise SystemExit('Deployed, but workflow checks FAILED (table above; report under .artifacts/workflow-checks/).')

def main(argv=None):
    parser = argparse.ArgumentParser()
    parser.add_argument('command', choices=['build', 'run', 'deploy', 'cutover', 'retry-failed', 'readiness', 'activate'])
    parser.add_argument('--project'); parser.add_argument('--region', default='us-west1'); parser.add_argument('--url'); parser.add_argument('--label')
    parser.add_argument('--skip-checks', action='store_true', help='Do not run workflow checks after deploy/cutover')
    parser.add_argument('--defer-activation', action='store_true', help='Deploy in maintenance without retry/checks; cutover only changes the URL to the maintenance worker')
    parser.add_argument('--expected-revision', help='Exact paused revision to inspect/activate')
    parser.add_argument('--evidence', type=Path, help='Scoped operator drain-evidence manifest; required for activate')
    parser.add_argument('--output', type=Path, help='Save the read-only readiness report')
    args = parser.parse_args(argv)
    if args.defer_activation and args.command not in ('deploy', 'cutover'):
        parser.error('--defer-activation is valid only for deploy/cutover')
    if args.command == 'build': build()
    elif args.command == 'run': run()
    elif args.command in ('readiness', 'activate'):
        if not args.project or not args.expected_revision:
            parser.error('--project and --expected-revision are required')
        if args.command == 'activate':
            if not args.evidence: parser.error('--evidence is required; elapsed time or empty queues are not drain proof')
            result = READINESS.activate(args.project, args.region, args.expected_revision, args.evidence)
        else:
            result, _, _ = READINESS.observe(args.project, args.region, args.expected_revision, args.evidence)
        encoded = json.dumps(result, indent=2, sort_keys=True) + '\n'
        if args.output:
            args.output.parent.mkdir(parents=True, exist_ok=True)
            args.output.write_text(encoded)
            print('Saved readiness/activation evidence to', args.output)
        else: print(encoded, end='')
    elif args.command == 'deploy':
        if not args.project: parser.error('--project is required')
        label = deploy(args.project, args.region, deferred=args.defer_activation)
        if args.defer_activation:
            print('Activation deferred: no retry or workflow checks; old invocations still require independent termination evidence')
        else:
            # HTML-first cutover never resumes legacy download, OCR or render jobs.
            if not args.skip_checks: workflow_checks()
    elif args.command == 'retry-failed':
        if not args.label: parser.error('--label is required (letters, digits, . _ : -)')
        retry_failed(args.label)
    else:
        if args.url != READINESS.SERVICE_URL:
            parser.error('--url must be the recorded Gradstep pipeline URL')
        verify_health(args.defer_activation)
        cutover(args.url)
        if not args.defer_activation and not args.skip_checks: workflow_checks()

if __name__ == '__main__':
    try: main()
    except READINESS.ReadinessError as error: raise SystemExit(str(error)) from None
