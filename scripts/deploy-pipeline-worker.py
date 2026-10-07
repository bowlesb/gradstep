#!/usr/bin/env python3
"""Build and deploy the Gradstep paper pipeline worker (docs/architecture/PIPELINE_RELIABILITY.md).

  python3 scripts/deploy-pipeline-worker.py build            # local Docker image (gradstep-pipeline:local)
  python3 scripts/deploy-pipeline-worker.py run              # run that image locally against staging
  python3 scripts/deploy-pipeline-worker.py deploy --project <gcp-project> [--region us-west1]
  python3 scripts/deploy-pipeline-worker.py cutover          # point staging's pg_cron/pg_net at the service
  python3 scripts/deploy-pipeline-worker.py retry-failed --label <deploy>  # retry failed papers once (deploy does this)

Secrets come from .env.staging / .env.providers into Secret Manager (deploy) or the
container environment (run); values are never printed.
"""
import argparse, json, os, shutil, subprocess, tempfile, time, urllib.error, urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SERVICE = 'gradstep-pipeline'
# ANTHROPIC_API_KEY: Claude Haiku topic tags (docs/architecture/TAGS.md); the Science Reader key, as for chat.
SECRETS = ['SUPABASE_URL', 'SUPABASE_SERVICE_ROLE_KEY', 'MATHPIX_APP_ID', 'MATHPIX_APP_KEY', 'PIPELINE_SECRET', 'ANTHROPIC_API_KEY']

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
    for name in ['Dockerfile', 'package.json', 'package-lock.json', 'server.ts', 'run.ts']:
        shutil.copy(ROOT / 'services/pipeline-worker' / name, target / name)
    shutil.copytree(ROOT / 'supabase/functions/_shared', target / 'supabase/functions/_shared',
                    ignore=shutil.ignore_patterns('node_modules', '*.test.ts'))
    return target

def build():
    path = context()
    subprocess.run(['docker', 'build', '--platform', 'linux/amd64', '-t', f'{SERVICE}:local', str(path)], check=True)
    print('Built', f'{SERVICE}:local')

def run():
    env = secrets()
    args = ['docker', 'run', '--rm', '--platform', 'linux/amd64', '-p', '127.0.0.1:18080:8080', '--memory', '2g']
    for name in env: args += ['-e', name]
    subprocess.run(args + [f'{SERVICE}:local'], check=True, env={**os.environ, **env})

def gcloud(*args, input=None, capture=False):
    return subprocess.run(['gcloud', *args], check=True, input=input, text=True, capture_output=capture)

def deployment_args(project, region, image, account, mapping):
    # Request-based billing depends on server.ts awaiting and joining its bounded worker thread.
    # Set both scopes: a revision-only maximum leaves the service ceiling at its old value.
    return ['run', 'deploy', SERVICE, '--project', project, '--region', region, '--image', image,
            '--memory', '2Gi', '--cpu', '1', '--concurrency', '1', '--max', '3', '--min', '0',
            '--max-instances', '3', '--min-instances', '0', '--timeout', '900', '--cpu-throttling',
            '--allow-unauthenticated', '--service-account', account, '--set-secrets', mapping, '--quiet']

def deployment_policy(service):
    """Allowlisted, nonsecret shape used by deployment verification and spending inspection."""
    annotations = service.get('metadata', {}).get('annotations', {})
    template = service.get('spec', {}).get('template', {})
    revision = template.get('metadata', {}).get('annotations', {})
    spec = template.get('spec', {})
    containers = spec.get('containers', [])
    resources = containers[0].get('resources', {}).get('limits', {}) if len(containers) == 1 else {}
    return {
        'revision': service.get('status', {}).get('latestReadyRevisionName'),
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

def verify_policy(policy):
    expected = {'cpu_throttling': 'true', 'service_min': '0', 'service_max': '3',
                'revision_min': '0', 'revision_max': '3', 'concurrency': 1,
                'timeout_seconds': 900, 'container_count': 1}
    mismatches = [name for name, value in expected.items() if policy.get(name) != value]
    if policy.get('cpu') not in ('1', '1000m'): mismatches.append('cpu')
    if policy.get('memory') not in ('2Gi', '2048Mi', '2147483648'): mismatches.append('memory')
    traffic = policy.get('traffic', [])
    if not policy.get('revision') or traffic != [{'revision': policy['revision'], 'percent': 100}]:
        mismatches.append('traffic')
    if mismatches: raise RuntimeError('pipeline_configuration_mismatch: ' + ', '.join(mismatches))

def deploy(project, region):
    env = secrets()
    # A dedicated runtime identity that can read only these secrets.
    account = f'{SERVICE}@{project}.iam.gserviceaccount.com'
    if subprocess.run(['gcloud', 'iam', 'service-accounts', 'describe', account, '--project', project], capture_output=True).returncode != 0:
        gcloud('iam', 'service-accounts', 'create', SERVICE, '--project', project, '--display-name', 'Gradstep pipeline worker', capture=True)
    for name, value in env.items():
        secret = f'gradstep-{name.lower().replace("_", "-")}'
        exists = subprocess.run(['gcloud', 'secrets', 'describe', secret, '--project', project], capture_output=True).returncode == 0
        if not exists: gcloud('secrets', 'create', secret, '--project', project, '--replication-policy', 'automatic', capture=True)
        gcloud('secrets', 'versions', 'add', secret, '--project', project, '--data-file=-', input=value, capture=True)
        gcloud('secrets', 'add-iam-policy-binding', secret, '--project', project, '--member', f'serviceAccount:{account}',
               '--role', 'roles/secretmanager.secretAccessor', capture=True)
    # Built here (linux/amd64) and pushed, so Cloud Build's default account needs no extra roles.
    repository = 'cloud-run-source-deploy'
    if subprocess.run(['gcloud', 'artifacts', 'repositories', 'describe', repository, '--project', project, '--location', region], capture_output=True).returncode != 0:
        gcloud('artifacts', 'repositories', 'create', repository, '--project', project, '--location', region, '--repository-format', 'docker', capture=True)
    tag = subprocess.run(['git', 'rev-parse', '--short', 'HEAD'], cwd=ROOT, capture_output=True, text=True, check=True).stdout.strip()
    image = f'{region}-docker.pkg.dev/{project}/{repository}/{SERVICE}:{tag}-{int(time.time())}'
    gcloud('auth', 'configure-docker', f'{region}-docker.pkg.dev', '--quiet', capture=True)
    subprocess.run(['docker', 'build', '--platform', 'linux/amd64', '-t', image, str(context())], check=True)
    subprocess.run(['docker', 'push', image], check=True)
    mapping = ','.join(f'{name}=gradstep-{name.lower().replace("_", "-")}:latest' for name in env)
    gcloud(*deployment_args(project, region, image, account, mapping))
    service = json.loads(gcloud('run', 'services', 'describe', SERVICE, '--project', project, '--region', region,
                               '--format', 'json', capture=True).stdout)
    policy = deployment_policy(service)
    verify_policy(policy)
    print('Verified pipeline configuration', json.dumps(policy, sort_keys=True))
    url = service['status']['url']
    print('Deployed', url)
    return image.rsplit(':', 1)[1]

def retry_failed(label):
    """A deploy is when a code bug stops being one: every failed paper that can resume without
    charge (metadata, download, render; not too_large) is retried once per deploy label
    (migration 027, worker_pipeline_retry_failed). Prints counts only."""
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
    print('Running workflow checks (deploy suite; --skip-checks to opt out)', flush=True)
    checks = subprocess.run(['node', str(ROOT / 'scripts/workflow-checks.mjs'), '--suite=deploy', '--trigger=deploy-pipeline-worker', '--record'], cwd=ROOT)
    if checks.returncode != 0:
        raise SystemExit('Deployed, but workflow checks FAILED (table above; report under .artifacts/workflow-checks/).')

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('command', choices=['build', 'run', 'deploy', 'cutover', 'retry-failed'])
    parser.add_argument('--project'); parser.add_argument('--region', default='us-west1'); parser.add_argument('--url'); parser.add_argument('--label')
    parser.add_argument('--skip-checks', action='store_true', help='Do not run the workflow checks after deploy/cutover')
    args = parser.parse_args()
    if args.command == 'build': build()
    elif args.command == 'run': run()
    elif args.command == 'deploy':
        if not args.project: raise SystemExit('--project is required')
        label = deploy(args.project, args.region)
        retry_failed(label)
        if not args.skip_checks: workflow_checks()
    elif args.command == 'retry-failed':
        if not args.label: raise SystemExit('--label is required (letters, digits, . _ : -)')
        retry_failed(args.label)
    else:
        if not args.url or not args.url.startswith('https://'): raise SystemExit('--url https://… is required')
        cutover(args.url)
        if not args.skip_checks: workflow_checks()

if __name__ == '__main__': main()
