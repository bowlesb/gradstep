#!/usr/bin/env python3
"""Build and deploy the Gradstep paper pipeline worker (docs/architecture/PIPELINE_RELIABILITY.md).

  python3 scripts/deploy-pipeline-worker.py build            # local Docker image (gradstep-pipeline:local)
  python3 scripts/deploy-pipeline-worker.py run              # run that image locally against staging
  python3 scripts/deploy-pipeline-worker.py deploy --project <gcp-project> [--region us-west1]
  python3 scripts/deploy-pipeline-worker.py cutover          # point staging's pg_cron/pg_net at the service

Secrets come from .env.staging / .env.providers into Secret Manager (deploy) or the
container environment (run); values are never printed.
"""
import argparse, json, os, shutil, subprocess, tempfile, time, urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SERVICE = 'gradstep-pipeline'
SECRETS = ['SUPABASE_URL', 'SUPABASE_SERVICE_ROLE_KEY', 'MATHPIX_APP_ID', 'MATHPIX_APP_KEY', 'PIPELINE_SECRET']

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
    for name in ['Dockerfile', 'package.json', 'package-lock.json', 'server.ts']:
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
    gcloud('run', 'deploy', SERVICE, '--project', project, '--region', region, '--image', image,
           '--memory', '2Gi', '--cpu', '1', '--concurrency', '1', '--max-instances', '3', '--min-instances', '0',
           '--timeout', '900', '--no-cpu-throttling', '--allow-unauthenticated', '--service-account', account,
           '--set-secrets', mapping, '--quiet')
    url = gcloud('run', 'services', 'describe', SERVICE, '--project', project, '--region', region,
                 '--format', 'value(status.url)', capture=True).stdout.strip()
    print('Deployed', url)

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

parser = argparse.ArgumentParser()
parser.add_argument('command', choices=['build', 'run', 'deploy', 'cutover'])
parser.add_argument('--project'); parser.add_argument('--region', default='us-west1'); parser.add_argument('--url')
args = parser.parse_args()
if args.command == 'build': build()
elif args.command == 'run': run()
elif args.command == 'deploy':
    if not args.project: raise SystemExit('--project is required')
    deploy(args.project, args.region)
else:
    if not args.url or not args.url.startswith('https://'): raise SystemExit('--url https://… is required')
    cutover(args.url)
