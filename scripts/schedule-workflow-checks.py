#!/usr/bin/env python3
"""Schedule the Gradstep workflow checks on Google Cloud (docs/architecture/WORKFLOW_CHECKS.md).

  python3 scripts/schedule-workflow-checks.py plan  [--project gradstep] [--region us-west1]   # print every step (default)
  python3 scripts/schedule-workflow-checks.py apply [--project gradstep] [--region us-west1]   # run them (owner/main session)

Creates, in the existing project: a runtime identity that can read only its secrets, the secrets
it needs (copied from .env.staging / .env.providers; values never printed), a Cloud Run job
running scripts/workflow-checks.mjs, and three Cloud Scheduler triggers:

  gradstep-checks-canary   every 6 hours           --suite=deploy   free (config, stuck imports, add paper, library, credits)
  gradstep-checks-daily    14:00 UTC Monday-Saturday --suite=daily  measured $0.27 of provider spend per run
  gradstep-checks-weekly   15:00 UTC Sundays       --suite=weekly   about $0.65 (adds the heavy imports' private OCR)

About $9.50/month in provider spend: more than staging's October cap allows. Decide the cap (or use
--daily-days=1,3,5) before apply.

Every run records its results (migration 024, admin Reliability tab) and, with WORKFLOW_ALERT_EMAIL
set, emails failures to the owner through Resend. Retries are off: a paid check never re-runs by
itself. Cost: Cloud Run jobs and three scheduler jobs fit the free tiers at this volume.
"""
import argparse, json, shutil, subprocess, sys, tempfile, time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
JOB, RUNTIME, INVOKER = 'gradstep-workflow-checks', 'gradstep-checks', 'gradstep-checks-scheduler'
# Secret Manager name → environment variable. The pipeline worker already created the first three.
SECRETS = {'gradstep-supabase-url': 'SUPABASE_URL', 'gradstep-supabase-service-role-key': 'SUPABASE_SERVICE_ROLE_KEY',
           'gradstep-pipeline-secret': 'PIPELINE_SECRET', 'gradstep-supabase-anon-key': 'SUPABASE_ANON_KEY',
           'gradstep-resend-api-key': 'RESEND_API_KEY'}
def schedules(daily_days):
    return [('gradstep-checks-canary', '0 */6 * * *', ['--suite=deploy', '--trigger=schedule', '--record', '--notify']),
            ('gradstep-checks-daily', f'0 14 * * {daily_days}', ['--suite=daily', '--trigger=schedule', '--record', '--notify']),
            ('gradstep-checks-weekly', '0 15 * * 0', ['--suite=weekly', '--trigger=schedule', '--record', '--notify'])]

def dotenv(path):
    values = {}
    if path.exists():
        for line in path.read_text().splitlines():
            if '=' in line and not line.lstrip().startswith('#'):
                k, v = line.split('=', 1); values[k.strip()] = v.strip().strip('"').strip("'")
    return values

def context():
    target = Path(tempfile.mkdtemp(prefix='gradstep-checks-'))
    (target / 'scripts').mkdir(); (target / 'infra').mkdir()
    shutil.copy(ROOT / 'services/workflow-checks/Dockerfile', target / 'Dockerfile')
    shutil.copy(ROOT / 'scripts/workflow-checks.mjs', target / 'scripts/workflow-checks.mjs')
    # downloads.corpus runs the pipeline's own download code (dependency-free TypeScript; Node 24 strips types).
    (target / 'supabase/functions/_shared').mkdir(parents=True)
    shutil.copy(ROOT / 'supabase/functions/_shared/web-source.ts', target / 'supabase/functions/_shared/web-source.ts')
    for name in ['staging.json', 'workflow-checks.json']:
        if (ROOT / 'infra' / name).exists(): shutil.copy(ROOT / 'infra' / name, target / 'infra' / name)
    return target

def steps(project, region, alert_email, daily_days):
    account = f'{RUNTIME}@{project}.iam.gserviceaccount.com'
    invoker = f'{INVOKER}@{project}.iam.gserviceaccount.com'
    tag = subprocess.run(['git', 'rev-parse', '--short', 'HEAD'], cwd=ROOT, capture_output=True, text=True).stdout.strip() or 'local'
    image = f'{region}-docker.pkg.dev/{project}/cloud-run-source-deploy/{JOB}:{tag}-{int(time.time())}'
    plan = [
        ('Runtime identity (reads its secrets only)', ['gcloud', 'iam', 'service-accounts', 'create', RUNTIME, '--project', project, '--display-name', 'Gradstep workflow checks']),
        ('Scheduler identity (may only start this job)', ['gcloud', 'iam', 'service-accounts', 'create', INVOKER, '--project', project, '--display-name', 'Gradstep workflow checks scheduler']),
    ]
    for secret in SECRETS:
        plan.append((f'Secret {secret} readable by the job', ['gcloud', 'secrets', 'add-iam-policy-binding', secret, '--project', project,
                     '--member', f'serviceAccount:{account}', '--role', 'roles/secretmanager.secretAccessor']))
    plan += [
        ('Docker credentials for Artifact Registry', ['gcloud', 'auth', 'configure-docker', f'{region}-docker.pkg.dev', '--quiet']),
        ('Build the image (linux/amd64)', ['docker', 'build', '--platform', 'linux/amd64', '-t', image, '<context>']),
        ('Push the image', ['docker', 'push', image]),
        ('Cloud Run job (1 task, no retries, 45 min limit)', ['gcloud', 'run', 'jobs', 'deploy', JOB, '--project', project, '--region', region,
          '--image', image, '--service-account', account, '--tasks', '1', '--max-retries', '0', '--task-timeout', '2700s',
          '--memory', '512Mi', '--cpu', '1',
          '--set-env-vars', f'SUPABASE_PROJECT_REF=coxhjvqpflgxkleydati{"," + "WORKFLOW_ALERT_EMAIL=" + alert_email if alert_email else ""}',
          '--set-secrets', ','.join(f'{env}={secret}:latest' for secret, env in SECRETS.items())]),
        ('Let the scheduler start the job with arguments', ['gcloud', 'run', 'jobs', 'add-iam-policy-binding', JOB, '--project', project, '--region', region,
          '--member', f'serviceAccount:{invoker}', '--role', 'roles/run.jobsExecutorWithOverrides']),
    ]
    for name, cron, arguments in schedules(daily_days):
        body = json.dumps({'overrides': {'containerOverrides': [{'args': arguments}]}})
        plan.append((f'Scheduler {name} ({cron} UTC)', ['gcloud', 'scheduler', 'jobs', 'create', 'http', name, '--project', project, '--location', region,
          '--schedule', cron, '--time-zone', 'Etc/UTC', '--http-method', 'POST',
          '--uri', f'https://run.googleapis.com/v2/projects/{project}/locations/{region}/jobs/{JOB}:run',
          '--message-body', body, '--headers', 'Content-Type=application/json',
          '--oauth-service-account-email', invoker, '--attempt-deadline', '60s', '--max-retry-attempts', '0']))
    return plan

def ensure_secrets(project):
    """Copies the two secrets the pipeline worker does not already have; values go through stdin."""
    values = {**dotenv(ROOT / '.env.providers'), **dotenv(ROOT / '.env.staging')}
    assert values.get('SUPABASE_PROJECT_REF') == 'coxhjvqpflgxkleydati', 'staging only'
    for secret, env in [('gradstep-supabase-anon-key', 'SUPABASE_ANON_KEY'), ('gradstep-resend-api-key', 'RESEND_API_KEY')]:
        if not values.get(env): raise SystemExit(f'missing {env}')
        if subprocess.run(['gcloud', 'secrets', 'describe', secret, '--project', project], capture_output=True).returncode != 0:
            subprocess.run(['gcloud', 'secrets', 'create', secret, '--project', project, '--replication-policy', 'automatic'], check=True, capture_output=True)
            subprocess.run(['gcloud', 'secrets', 'versions', 'add', secret, '--project', project, '--data-file=-'], input=values[env], text=True, check=True, capture_output=True)
            print('Created secret', secret)

parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
parser.add_argument('command', nargs='?', choices=['plan', 'apply'], default='plan')
parser.add_argument('--project', default='gradstep'); parser.add_argument('--region', default='us-west1')
parser.add_argument('--alert-email', help='Where failures are emailed (WORKFLOW_ALERT_EMAIL); omit for none')
parser.add_argument('--daily-days', default='1-6', help='Cron day-of-week field for the paid daily suite (default Monday-Saturday; e.g. 1,3,5)')
args = parser.parse_args()
plan = steps(args.project, args.region, args.alert_email, args.daily_days)
if args.command == 'plan':
    print('Plan (nothing is changed; run with apply to create):')
    print('  0. Secrets gradstep-supabase-anon-key and gradstep-resend-api-key from .env.staging / .env.providers (values via stdin)')
    for index, (title, command) in enumerate(plan, 1):
        print(f'  {index}. {title}\n     ' + ' '.join(command))
    sys.exit(0)
ensure_secrets(args.project)
build = context()
for title, command in plan:
    command = [str(build) if part == '<context>' else part for part in command]
    print('→', title, flush=True)
    result = subprocess.run(command, capture_output=True, text=True)
    if result.returncode != 0 and 'already exists' not in (result.stderr or ''):
        raise SystemExit(f'{title} failed: {(result.stderr or "").strip()[-400:]}')
print('Scheduled. Run once now: gcloud run jobs execute', JOB, '--project', args.project, '--region', args.region)
