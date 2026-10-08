#!/usr/bin/env python3
"""Refresh only the image of the existing Gradstep workflow-check job.

plan is read-only; apply requires its exact plan and an exclusive durable receipt.
verify only reads after an interrupted apply. No build, push, execute, notification,
schedule, secret, IAM or account mutation is exposed. Credentials/config values
stay in memory; evidence contains only fixed scope, image references and hashes.
"""
import argparse
import copy
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

PROJECT, REGION, JOB = 'gradstep', 'us-west1', 'gradstep-workflow-checks'
PROJECT_NUMBER = '885355087025'
NAME = f'projects/{PROJECT}/locations/{REGION}/jobs/{JOB}'
URL = 'https://run.googleapis.com/v2/' + NAME
IMAGE = f'{REGION}-docker.pkg.dev/{PROJECT}/cloud-run-source-deploy/{JOB}'
RUNTIME = 'gradstep-checks@gradstep.iam.gserviceaccount.com'
SUPABASE = 'coxhjvqpflgxkleydati'
SCHEDULES = {'gradstep-checks-canary': '0 */6 * * *', 'gradstep-checks-daily': '0 14 * * 1,3,5',
             'gradstep-checks-weekly': '0 15 * * 0'}
SCOPE = {'project': PROJECT, 'region': REGION, 'job': JOB}
WRITABLE = {'name', 'labels', 'annotations', 'client', 'clientVersion', 'launchStage', 'binaryAuthorization', 'template'}
OUTPUT = {'uid', 'generation', 'createTime', 'updateTime', 'deleteTime', 'expireTime', 'creator', 'lastModifier',
          'observedGeneration', 'terminalCondition', 'conditions', 'executionCount', 'latestCreatedExecution',
          'reconciling', 'satisfiesPzs', 'etag'}


class RefreshError(RuntimeError):
    """Only finite diagnostic codes may leave this module."""


def fail(code):
    raise RefreshError('workflow_image_' + code)


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(',', ':')).encode()).hexdigest()


def now():
    return dt.datetime.now(dt.timezone.utc).isoformat().replace('+00:00', 'Z')


def image_ref(value, *, immutable=False):
    tail = r'@sha256:[0-9a-f]{64}' if immutable else r'(?:@sha256:[0-9a-f]{64}|:[A-Za-z0-9][A-Za-z0-9_.-]{0,127})'
    if not isinstance(value, str) or not re.fullmatch(re.escape(IMAGE) + tail, value):
        fail('immutable_image_required' if immutable else 'image_scope')
    return value


def writable(job):
    if not isinstance(job, dict) or set(job) - WRITABLE - OUTPUT:
        fail('unknown_job_field')  # In particular never carry execution-creation tokens into PATCH.
    if job.get('name') != NAME or not job.get('uid') or not job.get('etag'):
        fail('job_identity')
    if job.get('deleteTime') or job.get('reconciling', False) or job.get('generation') != job.get('observedGeneration') \
            or job.get('terminalCondition', {}).get('state') != 'CONDITION_SUCCEEDED':
        fail('job_not_ready')
    result = copy.deepcopy({key: value for key, value in job.items() if key in WRITABLE})
    template = result.get('template', {})
    task = template.get('template', {})
    containers = task.get('containers', [])
    if template.get('taskCount', 1) != 1 or task.get('maxRetries', 3) != 0 or task.get('timeout') != '2700s' \
            or task.get('serviceAccount') != RUNTIME or len(containers) != 1:
        fail('task_configuration')
    container = containers[0]
    image_ref(container.get('image'))
    container.pop('buildInfo', None)  # Official output-only image metadata, never runtime configuration.
    values = container.get('env', [])
    if not isinstance(values, list) or any(not isinstance(row, dict) or not isinstance(row.get('name'), str) for row in values) \
            or len({row['name'] for row in values}) != len(values):
        fail('environment_shape')
    by_name = {row['name']: row for row in values}
    if by_name.get('SUPABASE_PROJECT_REF', {}).get('value') != SUPABASE \
            or not by_name.get('WORKFLOW_ALERT_EMAIL', {}).get('value'):
        fail('existing_environment_required')
    return result


def normalized(config):
    result = copy.deepcopy(config)
    result['template']['template']['containers'][0]['image'] = '<image-only-change>'
    return result


def scheduler_url(name):
    return f'https://cloudscheduler.googleapis.com/v1/projects/{PROJECT}/locations/{REGION}/jobs/{name}'


def request_scope(url, method, payload):
    if method == 'PATCH':
        if url != URL + '?allowMissing=false' or not isinstance(payload, dict): fail('request_scope')
        if set(payload) - WRITABLE - {'etag'} or payload.get('name') != NAME or not payload.get('etag'):
            fail('patch_scope')
        try: image_ref(payload['template']['template']['containers'][0]['image'], immutable=True)
        except (KeyError, TypeError, IndexError): fail('patch_shape')
        return
    allowed = {URL, URL + ':getIamPolicy?options.requestedPolicyVersion=3', *map(scheduler_url, SCHEDULES)}
    operation = re.fullmatch(r'https://run\.googleapis\.com/v2/projects/(?:' + PROJECT + '|' + PROJECT_NUMBER
                            + ')/locations/' + REGION + r'/operations/[A-Za-z0-9-]+', url)
    if method != 'GET' or payload is not None or url not in allowed and not operation:
        fail('request_scope')


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        fail('redirect_refused')


class API:
    def __init__(self):
        try:
            reply = subprocess.run(['gcloud', 'auth', 'print-access-token'], capture_output=True, text=True,
                timeout=30, env={**os.environ, 'CLOUDSDK_CORE_DISABLE_PROMPTS': '1',
                'CLOUDSDK_CORE_LOG_HTTP': 'false', 'CLOUDSDK_CORE_DISABLE_FILE_LOGGING': 'true'})
        except (OSError, subprocess.TimeoutExpired):
            fail('credential_unavailable')
        if reply.returncode or not reply.stdout.strip() or len(reply.stdout) > 8192:
            fail('credential_unavailable')
        self.token = reply.stdout.strip()

    def __call__(self, url, *, method='GET', payload=None):
        request_scope(url, method, payload)
        request = urllib.request.Request(url, method=method,
            data=None if payload is None else json.dumps(payload).encode(),
            headers={'Authorization': 'Bearer ' + self.token, 'Content-Type': 'application/json'})
        try:
            with urllib.request.build_opener(NoRedirect).open(request, timeout=30) as response:
                raw = response.read(1_048_577)
            if len(raw) > 1_048_576: fail('response_limit')
            return json.loads(raw)
        except urllib.error.HTTPError as error:
            fail('http_' + str(error.code))
        except (urllib.error.URLError, TimeoutError, OSError, ValueError):
            fail('transport_failed')


def observe(api):
    job = api(URL)
    config = writable(job)
    iam = api(URL + ':getIamPolicy?options.requestedPolicyVersion=3')
    if not isinstance(iam, dict) or not iam.get('etag'): fail('iam_unverified')
    triggers = {}
    for name, schedule in SCHEDULES.items():
        item = api(scheduler_url(name))
        if item.get('name') != f'projects/{PROJECT}/locations/{REGION}/jobs/{name}' \
                or item.get('schedule') != schedule or item.get('timeZone') != 'Etc/UTC' or item.get('state') != 'ENABLED' \
                or item.get('httpTarget', {}).get('uri') != URL + ':run':
            fail('scheduler_configuration')
        # These fields change with ordinary scheduled executions; all config, payload, auth and update time stay bound.
        triggers[name] = {k: v for k, v in item.items() if k not in {'lastAttemptTime', 'scheduleTime', 'status'}}
    return {'job': job, 'config': config, 'iam': iam, 'triggers': triggers}


def evidence(observation):
    job, config = observation['job'], observation['config']
    return {'version': 1, 'scope': SCOPE, 'observed_at': now(),
            'image': config['template']['template']['containers'][0]['image'],
            'configuration_sha256': digest({'uid': job['uid'], 'etag': job['etag'], 'config': config}),
            'unchanged_configuration_sha256': digest({'uid': job['uid'], 'config': normalized(config)}),
            'iam_sha256': digest(observation['iam']), 'scheduler_sha256': digest(observation['triggers']),
            'alert_email_configured': True, 'task_count': 1, 'max_retries': 0, 'timeout_seconds': 2700}


def make_plan(api, image, expected_image):
    image_ref(image, immutable=True); image_ref(expected_image)
    current = evidence(observe(api))
    if current['image'] != expected_image: fail('old_image_mismatch')
    if image == expected_image: fail('already_current')
    return {**current, 'target_image': image, 'operation': 'existing-job-image-only'}


def validate_plan(plan):
    keys = {'version', 'scope', 'observed_at', 'image', 'configuration_sha256', 'unchanged_configuration_sha256',
            'iam_sha256', 'scheduler_sha256', 'alert_email_configured', 'task_count', 'max_retries',
            'timeout_seconds', 'target_image', 'operation'}
    if not isinstance(plan, dict) or set(plan) != keys or plan.get('version') != 1 or plan.get('scope') != SCOPE \
            or plan.get('operation') != 'existing-job-image-only' or plan.get('alert_email_configured') is not True \
            or plan.get('task_count') != 1 or plan.get('max_retries') != 0 or plan.get('timeout_seconds') != 2700:
        fail('plan_scope')
    if not isinstance(plan.get('observed_at'), str) or not re.fullmatch(r'\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,6})?Z', plan['observed_at']):
        fail('plan_timestamp')
    image_ref(plan.get('image')); image_ref(plan.get('target_image'), immutable=True)
    for key in ('configuration_sha256', 'unchanged_configuration_sha256', 'iam_sha256', 'scheduler_sha256'):
        if not isinstance(plan.get(key), str) or not re.fullmatch('[0-9a-f]{64}', plan[key]): fail('plan_hash')


def verify(api, plan):
    validate_plan(plan)
    current = evidence(observe(api))
    if current['image'] != plan['target_image']: fail('new_image_unverified')
    for key in ('unchanged_configuration_sha256', 'iam_sha256', 'scheduler_sha256'):
        if current[key] != plan[key]: fail('preserved_configuration_mismatch')
    return {**current, 'status': 'verified', 'image_only': True, 'executed': False, 'notification_sent': False}


def write_exclusive(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open('x', encoding='utf8') as handle:
        os.chmod(path, 0o600)
        json.dump(value, handle, sort_keys=True, indent=2); handle.write('\n'); handle.flush(); os.fsync(handle.fileno())
    descriptor = os.open(path.parent, os.O_RDONLY)
    try: os.fsync(descriptor)
    finally: os.close(descriptor)


def apply(api, plan, receipt, *, sleep=time.sleep):
    validate_plan(plan)
    before = observe(api)
    current = evidence(before)
    for key in ('image', 'configuration_sha256', 'unchanged_configuration_sha256', 'iam_sha256', 'scheduler_sha256'):
        if current[key] != plan[key]: fail('plan_stale')
    payload = copy.deepcopy(before['config'])
    payload['etag'] = before['job']['etag']
    payload['template']['template']['containers'][0]['image'] = plan['target_image']
    write_exclusive(receipt, {'version': 1, 'status': 'attempted_outcome_unknown_until_verified',
                             'at': now(), 'plan': plan})
    # Exactly one send. A timeout or lost response requires read-only verify, never automatic re-PATCH.
    operation = api(URL + '?allowMissing=false', method='PATCH', payload=payload)
    for _ in range(90):
        if operation.get('done'):
            if operation.get('error'): fail('operation_failed')
            return verify(api, plan)
        name = operation.get('name', '')
        target = 'https://run.googleapis.com/v2/' + name
        request_scope(target, 'GET', None)
        if '/operations/' not in name: fail('operation_scope')
        sleep(2)
        operation = api(target)
    fail('operation_pending_use_verify')


def read_json(path):
    try:
        raw = Path(path).read_bytes()
        if len(raw) > 32768: fail('evidence_limit')
        result = json.loads(raw)
        if not isinstance(result, dict): fail('evidence_shape')
        return result
    except (OSError, ValueError):
        fail('evidence_unreadable')


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='command', required=True)
    plan = sub.add_parser('plan'); plan.add_argument('--image', required=True); plan.add_argument('--expected-image', required=True); plan.add_argument('--out', required=True)
    update = sub.add_parser('apply'); update.add_argument('--plan', required=True); update.add_argument('--receipt', required=True)
    check = sub.add_parser('verify'); check.add_argument('--receipt', required=True)
    args = parser.parse_args(argv)
    if args.command == 'plan':
        image_ref(args.image, immutable=True); image_ref(args.expected_image)
        write_exclusive(args.out, make_plan(API(), args.image, args.expected_image))
        print('Image-only plan saved; no change made.')
    elif args.command == 'apply':
        plan = read_json(args.plan); validate_plan(plan)
        if Path(args.receipt).exists(): fail('receipt_exists_use_verify')
        result = apply(API(), plan, args.receipt)
        write_exclusive(args.receipt + '.verified.json', result)
        print('Existing job image verified; schedules, IAM and runtime configuration unchanged. No execution or notification.')
    else:
        receipt = read_json(args.receipt)
        result = verify(API(), receipt.get('plan', {}))
        print(json.dumps(result, sort_keys=True))


if __name__ == '__main__':
    try:
        main()
    except RefreshError as error:
        print(str(error), file=sys.stderr); sys.exit(1)
    except (OSError, ValueError, KeyError, TypeError, AttributeError, IndexError):
        print('workflow_image_local_or_shape_error', file=sys.stderr); sys.exit(1)
